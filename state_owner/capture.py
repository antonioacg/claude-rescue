from __future__ import annotations

import json
import os
import shutil
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .storage import atomic_copy, atomic_write, link_or_copy, open_database, sha256_file


@dataclass(frozen=True)
class CapturePolicy:
    fine_seconds: int = 24 * 60 * 60
    archive_seconds: int = 14 * 24 * 60 * 60
    archive_bucket_seconds: int = 60 * 60
    orphan_grace_seconds: int = 60 * 60
    batch_size: int = 500

    @classmethod
    def from_environment(cls) -> "CapturePolicy":
        defaults = cls()

        def integer(name: str, default: int) -> int:
            value = int(os.environ.get(name, default))
            if value < 0:
                raise ValueError(f"{name} must be non-negative")
            return value

        return cls(
            fine_seconds=integer("CLAUDE_RESCUE_CAPTURE_FINE_SECONDS", defaults.fine_seconds),
            archive_seconds=integer(
                "CLAUDE_RESCUE_CAPTURE_ARCHIVE_SECONDS", defaults.archive_seconds
            ),
            archive_bucket_seconds=integer(
                "CLAUDE_RESCUE_CAPTURE_ARCHIVE_BUCKET_SECONDS",
                defaults.archive_bucket_seconds,
            ),
            orphan_grace_seconds=integer(
                "CLAUDE_RESCUE_CAPTURE_ORPHAN_GRACE_SECONDS",
                defaults.orphan_grace_seconds,
            ),
            batch_size=integer("CLAUDE_RESCUE_RETENTION_BATCH_SIZE", defaults.batch_size),
        )


class CaptureIndex:
    def __init__(self, database: Path, data_home: Path, policy: CapturePolicy | None = None):
        self.blobs_dir = data_home / "captures" / "blobs"
        self.policy = policy or CapturePolicy.from_environment()
        self.blobs_dir.mkdir(parents=True, exist_ok=True)
        self._connection = open_database(database)
        self._lock = threading.Lock()
        with self._connection:
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS capture_blobs (
                    capture_hash TEXT PRIMARY KEY,
                    blob_path TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    last_seen_at INTEGER NOT NULL
                )
                """
            )
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS capture_current (
                    server TEXT NOT NULL,
                    epoch TEXT NOT NULL,
                    pane_spec TEXT NOT NULL,
                    pane_uuid TEXT,
                    capture_hash TEXT NOT NULL,
                    observed_at INTEGER NOT NULL,
                    PRIMARY KEY(server, epoch, pane_spec)
                )
                """
            )
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS capture_refs (
                    reference_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    server TEXT NOT NULL,
                    epoch TEXT NOT NULL,
                    pane_spec TEXT NOT NULL,
                    pane_uuid TEXT,
                    capture_hash TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    captured_at INTEGER NOT NULL
                )
                """
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS capture_refs_time ON capture_refs(captured_at)"
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS capture_refs_hash ON capture_refs(capture_hash)"
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
        self,
        source: Path,
        *,
        server: str,
        epoch: str,
        pane_spec: str,
        pane_uuid: str | None,
        reason: str,
        observed_at: int | None = None,
    ) -> dict[str, Any]:
        if not source.is_file():
            raise ValueError(f"Capture does not exist: {source}")
        if not server or not epoch or not pane_spec or not reason:
            raise ValueError("server, epoch, pane_spec, and reason are required")
        if pane_uuid == "-":
            pane_uuid = None
        observed_at = _now() if observed_at is None else observed_at
        capture_hash = sha256_file(source)

        with self._lock, self._connection:
            # A tmux pane spec can be recycled after a server restart. Once the
            # new Epoch produces its first Capture, old current pointers stop
            # protecting stale blobs from retention.
            self._connection.execute(
                "DELETE FROM capture_current WHERE server = ? AND epoch <> ?",
                (server, epoch),
            )
            current = self._connection.execute(
                """
                SELECT capture_hash FROM capture_current
                WHERE server = ? AND epoch = ? AND pane_spec = ?
                """,
                (server, epoch, pane_spec),
            ).fetchone()
        first = current is None
        changed = first or current["capture_hash"] != capture_hash

        if changed:
            blob = self.blobs_dir / f"{capture_hash}.txt"
            if not blob.exists():
                atomic_copy(source, blob)
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO capture_blobs (
                        capture_hash, blob_path, size_bytes, created_at, last_seen_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(capture_hash) DO UPDATE SET last_seen_at=excluded.last_seen_at
                    """,
                    (capture_hash, str(blob), blob.stat().st_size, observed_at, observed_at),
                )
                self._connection.execute(
                    """
                    INSERT INTO capture_current (
                        server, epoch, pane_spec, pane_uuid, capture_hash, observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server, epoch, pane_spec) DO UPDATE SET
                        pane_uuid=excluded.pane_uuid,
                        capture_hash=excluded.capture_hash,
                        observed_at=excluded.observed_at
                    """,
                    (server, epoch, pane_spec, pane_uuid, capture_hash, observed_at),
                )
                if reason != "floor":
                    self._connection.execute(
                        """
                        INSERT INTO capture_refs (
                            server, epoch, pane_spec, pane_uuid,
                            capture_hash, reason, captured_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (server, epoch, pane_spec, pane_uuid, capture_hash, reason, observed_at),
                    )
        else:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    UPDATE capture_current SET pane_uuid = ?, observed_at = ?
                    WHERE server = ? AND epoch = ? AND pane_spec = ?
                    """,
                    (pane_uuid, observed_at, server, epoch, pane_spec),
                )
                self._connection.execute(
                    "UPDATE capture_blobs SET last_seen_at = ? WHERE capture_hash = ?",
                    (observed_at, capture_hash),
                )

        return {
            "status": "first" if first else "changed" if changed else "unchanged",
            "capture_hash": capture_hash,
        }

    def drain_spool(self, spool_dir: Path, *, limit: int = 50) -> dict[str, int]:
        result = {"committed": 0, "invalid": 0}
        if not spool_dir.is_dir():
            return result
        entries = [entry for entry in sorted(spool_dir.iterdir()) if entry.is_dir()]
        for entry in entries[:limit]:
            manifest_path = entry / "manifest.json"
            capture_path = entry / "capture.txt"
            try:
                manifest = json.loads(manifest_path.read_text())
                self.ingest(
                    capture_path,
                    server=manifest["server"],
                    epoch=manifest["epoch"],
                    pane_spec=manifest["pane_spec"],
                    pane_uuid=manifest.get("pane_uuid"),
                    reason=manifest["reason"],
                    observed_at=manifest["observed_at"],
                )
            except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError):
                invalid = entry.with_name(f"{entry.name}.invalid")
                if invalid.exists():
                    shutil.rmtree(invalid)
                os.replace(entry, invalid)
                result["invalid"] += 1
                continue
            shutil.rmtree(entry)
            result["committed"] += 1
        return result

    def release_current(self, *, server: str, epoch: str, pane_spec: str) -> bool:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                DELETE FROM capture_current
                WHERE server = ? AND epoch = ? AND pane_spec = ?
                """,
                (server, epoch, pane_spec),
            )
        return cursor.rowcount == 1

    def maintain_if_due(
        self, *, now: int | None = None, interval_seconds: int = 60 * 60
    ) -> dict[str, int]:
        now = _now() if now is None else now
        with self._lock, self._connection:
            row = self._connection.execute(
                "SELECT value FROM state_owner_meta WHERE key = 'captures_maintained_at'"
            ).fetchone()
            last = int(row["value"]) if row is not None else 0
            if now - last < interval_seconds:
                return {"deleted_capture_refs": 0, "deleted_capture_blobs": 0}
            self._connection.execute(
                """
                INSERT INTO state_owner_meta(key, value) VALUES('captures_maintained_at', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """,
                (str(now),),
            )
        return self.maintain(now=now)

    def maintain(self, *, now: int | None = None) -> dict[str, int]:
        now = _now() if now is None else now
        policy = self.policy
        with self._lock:
            references = self._connection.execute(
                """
                WITH classified AS (
                    SELECT reference_id, captured_at,
                        CASE
                            WHEN captured_at >= :fine_cutoff
                                THEN 'fine:' || reference_id
                            WHEN captured_at >= :archive_cutoff
                                THEN 'archive:' || server || ':' || epoch || ':' || pane_spec || ':' ||
                                     CAST(captured_at / :archive_bucket AS INTEGER)
                            ELSE 'expired'
                        END AS bucket,
                        CASE WHEN captured_at < :archive_cutoff THEN 1 ELSE 0 END AS expired
                    FROM capture_refs
                ), ranked AS (
                    SELECT reference_id, captured_at, expired,
                           ROW_NUMBER() OVER (
                               PARTITION BY bucket ORDER BY captured_at DESC, reference_id DESC
                           ) AS bucket_rank
                    FROM classified
                )
                SELECT reference_id FROM ranked
                WHERE expired = 1 OR bucket_rank > 1
                ORDER BY captured_at
                LIMIT :batch_size
                """,
                {
                    "fine_cutoff": now - policy.fine_seconds,
                    "archive_cutoff": now - policy.archive_seconds,
                    "archive_bucket": max(1, policy.archive_bucket_seconds),
                    "batch_size": policy.batch_size,
                },
            ).fetchall()
        deleted_refs = 0
        for row in references:
            with self._lock, self._connection:
                self._connection.execute(
                    "DELETE FROM capture_refs WHERE reference_id = ?", (row["reference_id"],)
                )
            deleted_refs += 1

        orphan_cutoff = now - policy.orphan_grace_seconds
        with self._lock:
            blobs = self._connection.execute(
                """
                SELECT capture_hash, blob_path FROM capture_blobs AS blob
                WHERE blob.last_seen_at < ?
                  AND NOT EXISTS (
                      SELECT 1 FROM capture_current AS current
                      WHERE current.capture_hash = blob.capture_hash
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM capture_refs AS reference
                      WHERE reference.capture_hash = blob.capture_hash
                  )
                ORDER BY blob.last_seen_at
                LIMIT ?
                """,
                (orphan_cutoff, policy.batch_size),
            ).fetchall()
        deleted_blobs = 0
        for row in blobs:
            Path(row["blob_path"]).unlink(missing_ok=True)
            with self._lock, self._connection:
                self._connection.execute(
                    "DELETE FROM capture_blobs WHERE capture_hash = ?", (row["capture_hash"],)
                )
            deleted_blobs += 1
        return {"deleted_capture_refs": deleted_refs, "deleted_capture_blobs": deleted_blobs}

    def status(self) -> dict[str, int]:
        with self._lock:
            blobs = self._connection.execute("SELECT COUNT(*) FROM capture_blobs").fetchone()[0]
            current = self._connection.execute("SELECT COUNT(*) FROM capture_current").fetchone()[0]
            references = self._connection.execute("SELECT COUNT(*) FROM capture_refs").fetchone()[0]
            bytes_ = self._connection.execute(
                "SELECT COALESCE(SUM(size_bytes), 0) FROM capture_blobs"
            ).fetchone()[0]
        return {
            "capture_blobs": int(blobs),
            "capture_current": int(current),
            "capture_references": int(references),
            "capture_bytes": int(bytes_),
        }

    def close(self) -> None:
        with self._lock:
            self._connection.close()


def spool_capture(
    spool_dir: Path,
    source: Path,
    *,
    server: str,
    epoch: str,
    pane_spec: str,
    pane_uuid: str | None,
    reason: str,
    observed_at: int | None = None,
) -> Path:
    if not source.is_file():
        raise ValueError(f"Capture does not exist: {source}")
    observed_at = _now() if observed_at is None else observed_at
    spool_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(spool_dir, 0o700)
    identity = uuid.uuid4().hex
    destination = spool_dir / identity
    temporary = spool_dir / f".{identity}.tmp"
    temporary.mkdir()
    try:
        link_or_copy(source, temporary / "capture.txt")
        manifest = {
            "server": server,
            "epoch": epoch,
            "pane_spec": pane_spec,
            "pane_uuid": None if pane_uuid == "-" else pane_uuid,
            "reason": reason,
            "observed_at": observed_at,
        }
        atomic_write(temporary / "manifest.json", json.dumps(manifest, sort_keys=True).encode())
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return destination


def _now() -> int:
    return int(datetime.now(timezone.utc).timestamp())
