from __future__ import annotations

import hashlib
import os
import shutil
import sqlite3
import uuid
from pathlib import Path


def open_database(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    connection = sqlite3.connect(path, timeout=5, check_same_thread=False)
    os.chmod(path, 0o600)
    connection.row_factory = sqlite3.Row
    with connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA foreign_keys=ON")
    return connection


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def link_or_copy(source: Path, destination: Path) -> None:
    if destination.exists():
        return
    try:
        os.link(source, destination)
    except OSError:
        atomic_copy(source, destination)


def atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    try:
        with source.open("rb") as incoming, temporary.open("xb") as outgoing:
            shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
            outgoing.flush()
            os.fsync(outgoing.fileno())
        os.replace(temporary, destination)
        fsync_directory(destination.parent)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_write(destination: Path, content: bytes) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    try:
        with temporary.open("xb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        fsync_directory(destination.parent)
    finally:
        temporary.unlink(missing_ok=True)


def published_spool_entries(spool_dir: Path) -> list[Path]:
    """Directory spool entries that are complete and safe to drain.

    Every writer here stages in-flight work under a leading dot — `atomic_write`
    and `atomic_copy` for single files, `spool_capture` and
    `spool_archive_checkpoint` for whole directories — and publishes by
    `os.replace`-ing onto an undotted name. Only undotted entries are complete.

    A drain that skips just `.invalid` races the writer: it can list a directory
    whose manifest has not landed yet, fail to parse it, and quarantine work that
    was about to commit. Observed 2026-08-31 — a quarantined Capture still held
    its manifest in `.tmp` form beside a fully-linked capture.txt, and the
    writer's own `os.replace` then failed on the renamed directory.
    """
    if not spool_dir.is_dir():
        return []
    return sorted(
        entry
        for entry in spool_dir.iterdir()
        if entry.is_dir()
        and not entry.name.startswith(".")
        and not entry.name.endswith(".invalid")
    )


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
