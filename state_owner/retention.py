"""The single owner of every retention job claude-rescue runs.

Retention used to be spread across four implementations with no shared list of
what had to be bounded: two Python indexes (archive, capture), an inline shell
prune for the resurrect hot dir, and another for debug logs. The shell pair were
reachable only through the legacy archive path, so routing checkpoints to the
State Owner silently stopped them — the hot dir then grew unbounded until
tmux-resurrect's own glob-based rotation died on "argument list too long", with
its errors going to /dev/null.

Naming the whole set in one place is the fix: a job that is not listed here does
not run, and adding a store means adding it to `run`. The module also holds the
one due-check, so callers no longer schedule each store separately.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol

from .storage import open_database

CHECKPOINT_DIR_PREFIX = "checkpoint_dir:"
SIDECAR_SUFFIX = ".claude-userops.tsv"
_STATE_NAME = re.compile(r"^tmux_resurrect_\d{8}T\d{6}\.txt$")


class _Index(Protocol):
    def maintain(self, *, now: int | None = ...) -> dict[str, int]: ...


@dataclass(frozen=True)
class RetentionPolicy:
    hot_keep: int = 2000
    debug_keep_seconds: int = 7 * 24 * 60 * 60
    interval_seconds: int = 60 * 60
    # Filesystem jobs get their own bound. The database jobs delete a few
    # hundred indexed rows per pass; these walk directories that can hold tens
    # of thousands of stray files after a period with no owner, and an unlink
    # is far cheaper than a row delete plus artifact unlink.
    file_batch_size: int = 5000

    @classmethod
    def from_environment(cls) -> "RetentionPolicy":
        defaults = cls()

        def integer(name: str, default: int) -> int:
            value = int(os.environ.get(name, default))
            if value < 0:
                raise ValueError(f"{name} must be non-negative")
            return value

        return cls(
            hot_keep=integer("CLAUDE_RESCUE_HOT_KEEP", defaults.hot_keep),
            debug_keep_seconds=integer(
                "CLAUDE_RESCUE_DEBUG_KEEP_DAYS", defaults.debug_keep_seconds // 86400
            )
            * 86400,
            interval_seconds=integer(
                "CLAUDE_RESCUE_RETENTION_INTERVAL_SECONDS", defaults.interval_seconds
            ),
            file_batch_size=integer(
                "CLAUDE_RESCUE_RETENTION_FILE_BATCH_SIZE", defaults.file_batch_size
            ),
        )


class Retention:
    """Runs every retention job on one schedule.

    `archive` and `captures` bound their own indexed stores; this module bounds
    the two directories nothing else owns — the tmux-resurrect hot dir it learns
    from ingested checkpoints, and the debug log dir.
    """

    def __init__(
        self,
        database: Path,
        *,
        archive: _Index,
        captures: _Index,
        debug_dir: Path,
        policy: RetentionPolicy | None = None,
    ) -> None:
        self.archive = archive
        self.captures = captures
        self.debug_dir = debug_dir
        self.policy = policy or RetentionPolicy.from_environment()
        self._connection = open_database(database)
        with self._connection:
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS state_owner_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )

    def run(self, *, now: int | None = None) -> dict[str, int]:
        now = _now() if now is None else now
        result: dict[str, int] = {}
        result.update(self.archive.maintain(now=now))
        result.update(self.captures.maintain(now=now))
        result.update(self._prune_checkpoint_dirs())
        result.update(self._prune_debug(now))
        return result

    def run_if_due(self, *, now: int | None = None) -> dict[str, int]:
        now = _now() if now is None else now
        with self._connection:
            row = self._connection.execute(
                "SELECT value FROM state_owner_meta WHERE key = 'retention_ran_at'"
            ).fetchone()
            last = int(row["value"]) if row is not None else 0
            if now - last < self.policy.interval_seconds:
                return {}
            # Claim the interval before doing the work. The State Owner is the
            # only writer, so a crash delays the next pass rather than letting
            # two passes race over the same directories.
            self._connection.execute(
                """
                INSERT INTO state_owner_meta(key, value) VALUES('retention_ran_at', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """,
                (str(now),),
            )
        return self.run(now=now)

    def checkpoint_directories(self) -> dict[str, Path]:
        with self._connection:
            rows = self._connection.execute(
                "SELECT key, value FROM state_owner_meta WHERE key LIKE ?",
                (f"{CHECKPOINT_DIR_PREFIX}%",),
            ).fetchall()
        return {
            row["key"][len(CHECKPOINT_DIR_PREFIX) :]: Path(row["value"])
            for row in rows
        }

    def _prune_checkpoint_dirs(self) -> dict[str, int]:
        deleted_states = 0
        deleted_sidecars = 0
        for directory in self.checkpoint_directories().values():
            states, sidecars = _prune_checkpoint_dir(
                directory,
                keep=self.policy.hot_keep,
                limit=self.policy.file_batch_size,
            )
            deleted_states += states
            deleted_sidecars += sidecars
        return {
            "deleted_checkpoints": deleted_states,
            "deleted_sidecars": deleted_sidecars,
        }

    def _prune_debug(self, now: int) -> dict[str, int]:
        if self.policy.debug_keep_seconds <= 0 or not self.debug_dir.is_dir():
            return {"deleted_debug_logs": 0}
        cutoff = now - self.policy.debug_keep_seconds
        deleted = 0
        with os.scandir(self.debug_dir) as entries:
            for entry in entries:
                if deleted >= self.policy.file_batch_size:
                    break
                if not entry.name.endswith(".log") or not entry.is_file():
                    continue
                try:
                    if entry.stat().st_mtime >= cutoff:
                        continue
                    Path(entry.path).unlink(missing_ok=True)
                except OSError:
                    continue
                deleted += 1
        return {"deleted_debug_logs": deleted}

    def close(self) -> None:
        self._connection.close()


def record_checkpoint_directory(connection: Any, server: str, directory: Path) -> None:
    """Remember where a server's checkpoints come from.

    The hot dir belongs to tmux-resurrect, not to us, so there is nothing to
    configure and nothing to discover at startup. Learning it from each ingested
    checkpoint keeps the prune correct for every server that is actually saving,
    including ones added after the owner started.
    """
    connection.execute(
        """
        INSERT INTO state_owner_meta(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value
        """,
        (f"{CHECKPOINT_DIR_PREFIX}{server}", str(directory)),
    )


def _prune_checkpoint_dir(directory: Path, *, keep: int, limit: int) -> tuple[int, int]:
    """Drop all but the newest `keep` checkpoints, and every stray sidecar.

    Two separate leaks live here. Aged checkpoints are the obvious one. The
    quiet one is sidecars: pairing a sidecar's deletion to its checkpoint's
    deletion only collects sidecars we drop ourselves, so every sidecar whose
    checkpoint was rotated away by tmux-resurrect became permanently
    unreachable — 87,046 of 90,264 files on the machine this was found on.
    A sidecar with no checkpoint has nothing to annotate; it is garbage.
    """
    if not directory.is_dir():
        return (0, 0)

    states: list[str] = []
    sidecar_bases: set[str] = set()
    try:
        with os.scandir(directory) as entries:
            for entry in entries:
                name = entry.name
                if _STATE_NAME.match(name):
                    states.append(name[: -len(".txt")])
                elif name.endswith(SIDECAR_SUFFIX):
                    sidecar_bases.add(name[: -len(SIDECAR_SUFFIX)])
    except OSError:
        return (0, 0)

    # Checkpoint names are timestamped, so lexicographic order is chronological.
    states.sort(reverse=True)
    live = set(states)
    # Never evict what a restore would actually load.
    pinned = _last_target(directory)
    drop = [base for base in states[keep:] if base != pinned]

    deleted_states = 0
    deleted_sidecars = 0
    budget = limit
    for base in drop:
        if budget <= 0:
            break
        (directory / f"{base}.txt").unlink(missing_ok=True)
        deleted_states += 1
        budget -= 1
        if base in sidecar_bases:
            (directory / f"{base}{SIDECAR_SUFFIX}").unlink(missing_ok=True)
            sidecar_bases.discard(base)
            deleted_sidecars += 1
        live.discard(base)

    for base in sorted(sidecar_bases - live):
        if budget <= 0:
            break
        (directory / f"{base}{SIDECAR_SUFFIX}").unlink(missing_ok=True)
        deleted_sidecars += 1
        budget -= 1

    return (deleted_states, deleted_sidecars)


def _last_target(directory: Path) -> str | None:
    link = directory / "last"
    try:
        target = os.readlink(link)
    except OSError:
        return None
    name = Path(target).name
    return name[: -len(".txt")] if name.endswith(".txt") else None


def _now() -> int:
    return int(datetime.now(timezone.utc).timestamp())
