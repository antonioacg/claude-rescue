from __future__ import annotations

import json
import os
import shutil
import sqlite3
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from .retention import record_checkpoint_directory
from .storage import (
    atomic_copy,
    atomic_write,
    fsync_directory,
    link_or_copy,
    open_database,
    sha256_file,
)


@dataclass(frozen=True)
class ArchivePolicy:
    fine_seconds: int = 60 * 60
    medium_seconds: int = 24 * 60 * 60
    medium_bucket_seconds: int = 10 * 60
    coarse_seconds: int = 14 * 24 * 60 * 60
    coarse_bucket_seconds: int = 60 * 60
    archive_seconds: int = 90 * 24 * 60 * 60
    archive_bucket_seconds: int = 24 * 60 * 60
    blob_seconds: int = 14 * 24 * 60 * 60
    orphan_grace_seconds: int = 60 * 60
    batch_size: int = 500

    @classmethod
    def from_environment(cls) -> "ArchivePolicy":
        defaults = cls()

        def integer(name: str, default: int) -> int:
            value = int(os.environ.get(name, default))
            if value < 0:
                raise ValueError(f"{name} must be non-negative")
            return value

        return cls(
            fine_seconds=integer("CLAUDE_RESCUE_HISTORY_FINE_SECONDS", defaults.fine_seconds),
            medium_seconds=integer("CLAUDE_RESCUE_HISTORY_MEDIUM_SECONDS", defaults.medium_seconds),
            medium_bucket_seconds=integer(
                "CLAUDE_RESCUE_HISTORY_MEDIUM_BUCKET_SECONDS", defaults.medium_bucket_seconds
            ),
            coarse_seconds=integer("CLAUDE_RESCUE_HISTORY_COARSE_SECONDS", defaults.coarse_seconds),
            coarse_bucket_seconds=integer(
                "CLAUDE_RESCUE_HISTORY_COARSE_BUCKET_SECONDS", defaults.coarse_bucket_seconds
            ),
            archive_seconds=integer("CLAUDE_RESCUE_HISTORY_ARCHIVE_SECONDS", defaults.archive_seconds),
            archive_bucket_seconds=integer(
                "CLAUDE_RESCUE_HISTORY_ARCHIVE_BUCKET_SECONDS", defaults.archive_bucket_seconds
            ),
            blob_seconds=integer("CLAUDE_RESCUE_HISTORY_BLOB_SECONDS", defaults.blob_seconds),
            orphan_grace_seconds=integer(
                "CLAUDE_RESCUE_HISTORY_ORPHAN_GRACE_SECONDS", defaults.orphan_grace_seconds
            ),
            batch_size=integer("CLAUDE_RESCUE_RETENTION_BATCH_SIZE", defaults.batch_size),
        )


class ArchiveIndex:
    def __init__(self, database: Path, archive_dir: Path, policy: ArchivePolicy | None = None):
        self.archive_dir = archive_dir
        self.saves_dir = archive_dir / "saves"
        self.blobs_dir = archive_dir / "blobs"
        self.policy = policy or ArchivePolicy.from_environment()
        self.saves_dir.mkdir(parents=True, exist_ok=True)
        self.blobs_dir.mkdir(parents=True, exist_ok=True)
        self._connection = open_database(database)
        self._lock = threading.Lock()
        with self._connection:
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS archive_saves (
                    save_name TEXT PRIMARY KEY,
                    captured_at INTEGER NOT NULL,
                    state_path TEXT NOT NULL,
                    sidecar_path TEXT,
                    capture_hash TEXT,
                    indexed_at INTEGER NOT NULL
                )
                """
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS archive_saves_captured ON archive_saves(captured_at DESC)"
            )
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS archive_blobs (
                    capture_hash TEXT PRIMARY KEY,
                    blob_path TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    indexed_at INTEGER NOT NULL
                )
                """
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS archive_blobs_created ON archive_blobs(created_at)"
            )
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS state_owner_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )

    def ingest(
        self, state_file: Path, *, server: str | None = None, now: int | None = None
    ) -> dict[str, Any]:
        state_file = state_file.resolve()
        if not state_file.is_file():
            raise ValueError(f"checkpoint does not exist: {state_file}")
        now = int(datetime.now(timezone.utc).timestamp()) if now is None else now
        source_name = state_file.stem
        server = server or state_file.parent.name or "default"
        save_name = _archive_key(server, source_name)
        captured_at = _timestamp_from_name(source_name, fallback=int(state_file.stat().st_mtime))

        archived_state = self.saves_dir / f"{save_name}.txt"
        link_or_copy(state_file, archived_state)

        source_sidecar = state_file.with_suffix(".claude-userops.tsv")
        archived_sidecar: Path | None = None
        if source_sidecar.is_file():
            archived_sidecar = self.saves_dir / f"{save_name}.claude-userops.tsv"
            link_or_copy(source_sidecar, archived_sidecar)

        capture_hash: str | None = None
        pane_contents = state_file.parent / "pane_contents.tar.gz"
        if pane_contents.is_file():
            capture_hash = sha256_file(pane_contents)
            blob = self.blobs_dir / f"{capture_hash}.tar.gz"
            if not blob.exists():
                atomic_copy(pane_contents, blob)
            hash_file = self.saves_dir / f"{save_name}.pane_contents.hash"
            atomic_write(hash_file, f"{capture_hash}\n".encode())
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT OR IGNORE INTO archive_blobs (
                        capture_hash, blob_path, size_bytes, created_at, indexed_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (capture_hash, str(blob), blob.stat().st_size, now, now),
                )

        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO archive_saves (
                    save_name, captured_at, state_path, sidecar_path, capture_hash, indexed_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(save_name) DO UPDATE SET
                    captured_at=excluded.captured_at,
                    state_path=excluded.state_path,
                    sidecar_path=excluded.sidecar_path,
                    capture_hash=excluded.capture_hash,
                    indexed_at=excluded.indexed_at
                """,
                (
                    save_name,
                    captured_at,
                    str(archived_state),
                    str(archived_sidecar) if archived_sidecar else None,
                    capture_hash,
                    now,
                ),
            )
            # The hot dir this checkpoint came from is tmux-resurrect's, not
            # ours, and nothing else tells us where it is. Recording it here is
            # what lets Retention bound it — see retention.record_checkpoint_directory.
            record_checkpoint_directory(self._connection, server, state_file.parent)
        return {"server": server, "save_name": save_name, "capture_hash": capture_hash}

    def drain_spool(self, spool_dir: Path, *, limit: int = 20) -> dict[str, int]:
        result = {"committed": 0, "invalid": 0}
        if not spool_dir.is_dir():
            return result
        entries = [
            entry
            for entry in sorted(spool_dir.iterdir())
            if entry.is_dir() and not entry.name.endswith(".invalid")
        ]
        for entry in entries[:limit]:
            states = list(entry.glob("tmux_resurrect_*.txt"))
            if len(states) != 1:
                invalid = entry.with_name(f"{entry.name}.invalid")
                if invalid.exists():
                    shutil.rmtree(invalid)
                os.replace(entry, invalid)
                result["invalid"] += 1
                continue
            try:
                manifest_path = entry / "manifest.json"
                manifest = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
                server = manifest.get("server")
                if server is None and entry.name.startswith("tmux_resurrect_"):
                    server = "legacy"
                if server is not None and (not isinstance(server, str) or not server):
                    raise ValueError("archive spool server must be a non-empty string")
                self.ingest(states[0], server=server)
            except (OSError, TypeError, ValueError, json.JSONDecodeError):
                invalid = entry.with_name(f"{entry.name}.invalid")
                if invalid.exists():
                    shutil.rmtree(invalid)
                os.replace(entry, invalid)
                result["invalid"] += 1
                continue
            shutil.rmtree(entry)
            result["committed"] += 1
        return result

    def import_existing(self, *, now: int | None = None) -> dict[str, int]:
        now = int(datetime.now(timezone.utc).timestamp()) if now is None else now
        result = {"saves": 0, "blobs": 0}
        with self._lock, self._connection:
            for state in self.saves_dir.glob("tmux_resurrect_*.txt"):
                save_name = state.stem
                sidecar = self.saves_dir / f"{save_name}.claude-userops.tsv"
                hash_file = self.saves_dir / f"{save_name}.pane_contents.hash"
                capture_hash = hash_file.read_text().strip() if hash_file.is_file() else None
                self._connection.execute(
                    """
                    INSERT OR IGNORE INTO archive_saves (
                        save_name, captured_at, state_path, sidecar_path, capture_hash, indexed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        save_name,
                        _timestamp_from_name(save_name, fallback=int(state.stat().st_mtime)),
                        str(state),
                        str(sidecar) if sidecar.is_file() else None,
                        capture_hash,
                        now,
                    ),
                )
                result["saves"] += 1
            for blob in self.blobs_dir.glob("*.tar.gz"):
                capture_hash = blob.name.removesuffix(".tar.gz")
                created_at = int(blob.stat().st_mtime)
                self._connection.execute(
                    """
                    INSERT OR IGNORE INTO archive_blobs (
                        capture_hash, blob_path, size_bytes, created_at, indexed_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (capture_hash, str(blob), blob.stat().st_size, created_at, now),
                )
                result["blobs"] += 1
        return result

    def maintain(self, *, now: int | None = None) -> dict[str, int]:
        now = int(datetime.now(timezone.utc).timestamp()) if now is None else now
        victims = self._retention_victims(now)
        deleted_saves = 0
        for row in victims:
            for path in _save_artifacts(self.saves_dir, row["save_name"]):
                path.unlink(missing_ok=True)
            with self._lock, self._connection:
                self._connection.execute(
                    "DELETE FROM archive_saves WHERE save_name = ?", (row["save_name"],)
                )
            deleted_saves += 1

        # A blob outlives its own age limit only while some save still points at
        # it. Age alone is not enough: the retention pass above thins save rows
        # far faster than blob_seconds elapses, and deleting a save also deletes
        # its .pane_contents.hash, so an unreferenced blob can never be reached
        # again — it is garbage the moment its last save row goes. Collecting on
        # age alone left 98% of the tier (19k blobs, 3.1 GB) parked for the full
        # blob_seconds window with nothing able to read it.
        #
        # The grace window is what makes the unreferenced arm safe: ingest()
        # writes the blob row before the save row that references it, so a
        # maintenance pass landing between those two writes would otherwise
        # collect a blob that is about to be referenced. Same guard, same
        # reasoning as CapturePolicy.orphan_grace_seconds.
        with self._lock:
            blob_rows = self._connection.execute(
                """
                SELECT capture_hash, blob_path FROM archive_blobs AS blob
                WHERE blob.created_at < :blob_cutoff
                   OR (
                       blob.created_at < :orphan_cutoff
                       AND NOT EXISTS (
                           SELECT 1 FROM archive_saves AS save
                           WHERE save.capture_hash = blob.capture_hash
                       )
                   )
                ORDER BY blob.created_at
                LIMIT :batch_size
                """,
                {
                    "blob_cutoff": now - self.policy.blob_seconds,
                    "orphan_cutoff": now - self.policy.orphan_grace_seconds,
                    "batch_size": self.policy.batch_size,
                },
            ).fetchall()
        deleted_blobs = 0
        for row in blob_rows:
            Path(row["blob_path"]).unlink(missing_ok=True)
            with self._lock, self._connection:
                self._connection.execute(
                    "DELETE FROM archive_blobs WHERE capture_hash = ?", (row["capture_hash"],)
                )
            deleted_blobs += 1
        return {"deleted_saves": deleted_saves, "deleted_blobs": deleted_blobs}

    def _retention_victims(self, now: int) -> list[sqlite3.Row]:
        policy = self.policy
        with self._lock:
            return self._connection.execute(
                """
                WITH scoped AS (
                    SELECT save_name, captured_at,
                        CASE
                            WHEN instr(save_name, '__') > 0
                                THEN substr(save_name, 1, instr(save_name, '__') - 1)
                            ELSE 'legacy'
                        END AS server_key
                    FROM archive_saves
                ), classified AS (
                    SELECT save_name, captured_at,
                        CASE
                            WHEN captured_at >= :fine_cutoff THEN 'fine:' || save_name
                            WHEN captured_at >= :medium_cutoff
                                THEN 'medium:' || server_key || ':' ||
                                     CAST(captured_at / :medium_bucket AS INTEGER)
                            WHEN captured_at >= :coarse_cutoff
                                THEN 'coarse:' || server_key || ':' ||
                                     CAST(captured_at / :coarse_bucket AS INTEGER)
                            WHEN captured_at >= :archive_cutoff
                                THEN 'archive:' || server_key || ':' ||
                                     CAST(captured_at / :archive_bucket AS INTEGER)
                            ELSE 'expired'
                        END AS bucket,
                        CASE WHEN captured_at < :archive_cutoff THEN 1 ELSE 0 END AS expired
                    FROM scoped
                ), ranked AS (
                    SELECT save_name, captured_at, expired,
                           ROW_NUMBER() OVER (
                               PARTITION BY bucket ORDER BY captured_at DESC, save_name DESC
                           ) AS bucket_rank
                    FROM classified
                )
                SELECT save_name, captured_at FROM ranked
                WHERE expired = 1 OR bucket_rank > 1
                ORDER BY captured_at
                LIMIT :batch_size
                """,
                {
                    "fine_cutoff": now - policy.fine_seconds,
                    "medium_cutoff": now - policy.medium_seconds,
                    "medium_bucket": max(1, policy.medium_bucket_seconds),
                    "coarse_cutoff": now - policy.coarse_seconds,
                    "coarse_bucket": max(1, policy.coarse_bucket_seconds),
                    "archive_cutoff": now - policy.archive_seconds,
                    "archive_bucket": max(1, policy.archive_bucket_seconds),
                    "batch_size": policy.batch_size,
                },
            ).fetchall()

    def status(self) -> dict[str, int]:
        with self._lock:
            saves = self._connection.execute("SELECT COUNT(*) FROM archive_saves").fetchone()[0]
            blobs = self._connection.execute("SELECT COUNT(*) FROM archive_blobs").fetchone()[0]
            bytes_ = self._connection.execute(
                "SELECT COALESCE(SUM(size_bytes), 0) FROM archive_blobs"
            ).fetchone()[0]
        return {"archive_saves": int(saves), "archive_blobs": int(blobs), "archive_bytes": int(bytes_)}

    def close(self) -> None:
        with self._lock:
            self._connection.close()


def spool_archive_checkpoint(spool_dir: Path, state_file: Path) -> Path:
    state_file = state_file.resolve()
    if not state_file.is_file():
        raise ValueError(f"checkpoint does not exist: {state_file}")
    spool_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(spool_dir, 0o700)
    server = state_file.parent.name or "default"
    destination = spool_dir / _archive_key(server, state_file.stem)
    destination_state = destination / state_file.name
    if destination_state.is_file():
        return destination_state

    temporary = spool_dir / f".{destination.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    temporary.mkdir()
    try:
        link_or_copy(state_file, temporary / state_file.name)
        sidecar = state_file.with_suffix(".claude-userops.tsv")
        if sidecar.is_file():
            link_or_copy(sidecar, temporary / sidecar.name)
        pane_contents = state_file.parent / "pane_contents.tar.gz"
        if pane_contents.is_file():
            link_or_copy(pane_contents, temporary / pane_contents.name)
        atomic_write(
            temporary / "manifest.json",
            json.dumps({"server": server}, separators=(",", ":"), sort_keys=True).encode(),
        )
        try:
            os.replace(temporary, destination)
            fsync_directory(spool_dir)
        except OSError:
            if not destination_state.is_file():
                raise
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return destination_state


def _archive_key(server: str, checkpoint_name: str) -> str:
    server_key = quote(server, safe=".-").replace("_", "%5F")
    return f"{server_key}__{checkpoint_name}"


def _timestamp_from_name(name: str, *, fallback: int) -> int:
    prefix = "tmux_resurrect_"
    position = name.rfind(prefix)
    if position < 0:
        return fallback
    raw = name[position + len(prefix) :]
    try:
        parsed = datetime.strptime(raw, "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return fallback
    return int(parsed.timestamp())


def _save_artifacts(saves_dir: Path, save_name: str) -> tuple[Path, Path, Path]:
    return (
        saves_dir / f"{save_name}.txt",
        saves_dir / f"{save_name}.claude-userops.tsv",
        saves_dir / f"{save_name}.pane_contents.hash",
    )
