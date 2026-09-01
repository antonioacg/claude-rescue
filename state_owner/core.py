from __future__ import annotations

import fcntl
import math
import os
import socket
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .archive import ArchiveIndex
from .capture import CaptureIndex
from .events import Event, EventStore, drain_spool
from .paths import StatePaths
from .protocol import MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, encode_message, read_message
from .retention import Retention


def observed_now() -> float:
    return datetime.now(timezone.utc).timestamp()


class StateOwner:
    """Single writer for History Events, Recovery Checkpoints, and Captures."""

    def __init__(self, paths: StatePaths):
        self.paths = paths
        self.store = EventStore(paths.database)
        self.archive = ArchiveIndex(paths.database, paths.archive)
        self.captures = CaptureIndex(paths.database, paths.data_home)
        self.retention = Retention(
            paths.database,
            archive=self.archive,
            captures=self.captures,
            debug_dir=paths.debug,
        )
        self._listener: socket.socket | None = None
        self._lock_file: Any = None
        self._stop: threading.Event | None = None
        self._closed = False

    def _acquire_owner_lock(self) -> None:
        self.paths.cache_home.mkdir(parents=True, exist_ok=True)
        lock_file = self.paths.lock.open("a+")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            lock_file.close()
            raise RuntimeError("state owner is already running") from error
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(f"{os.getpid()}\n")
        lock_file.flush()
        os.fsync(lock_file.fileno())
        self._lock_file = lock_file

    def _open_listener(self) -> None:
        self._acquire_owner_lock()
        self.paths.socket.parent.mkdir(parents=True, exist_ok=True)
        self.paths.socket.unlink(missing_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.paths.socket))
        os.chmod(self.paths.socket, 0o600)
        listener.listen(32)
        listener.settimeout(0.25)
        self._listener = listener

    def serve(self, stop: threading.Event | None = None) -> None:
        stop = stop or threading.Event()
        self._stop = stop
        try:
            self._open_listener()
            self._drain_spools()
            while not stop.is_set():
                try:
                    connection, _ = self._listener.accept()
                except socket.timeout:
                    self._drain_spools(limit=100)
                    continue
                with connection:
                    self._handle(connection)
                self._drain_spools(limit=100)
        finally:
            self.close()

    def _drain_spools(self, *, limit: int = 1000) -> None:
        drain_spool(self.store, self.paths.spool, limit=limit)
        self.archive.drain_spool(self.paths.archive_spool, limit=max(1, limit // 10))
        self.captures.drain_spool(self.paths.capture_spool, limit=max(1, limit // 10))

    def _handle(self, connection: socket.socket) -> None:
        try:
            request = read_message(connection, max_bytes=MAX_REQUEST_BYTES)
            response = self._dispatch(request)
        except Exception as error:
            response = {"ok": False, "error": str(error)}
        try:
            encoded = encode_message(response, max_bytes=MAX_RESPONSE_BYTES)
        except ValueError:
            encoded = encode_message(
                {"ok": False, "error": "response exceeds maximum size"},
                max_bytes=MAX_RESPONSE_BYTES,
            )
        try:
            connection.sendall(encoded)
        except OSError:
            # The client may have timed out and durably spooled the same event.
            # Keep serving; event-id deduplication removes the replay later.
            pass

    def _dispatch(self, request: Mapping[str, Any]) -> dict[str, Any]:
        operation = request.get("operation")
        if operation == "publish":
            value = request.get("event")
            if not isinstance(value, Mapping):
                raise ValueError("event must be an object")
            sequence, inserted = self.store.append(Event.from_mapping(value))
            return {"ok": True, "sequence": sequence, "inserted": inserted}
        if operation == "status":
            event_spooled = (
                len(list(self.paths.spool.glob("*.json"))) if self.paths.spool.is_dir() else 0
            )
            archive_spooled = _spool_directory_count(self.paths.archive_spool)
            capture_spooled = _spool_directory_count(self.paths.capture_spool)
            return {
                "ok": True,
                "pid": os.getpid(),
                "socket": str(self.paths.socket),
                "spooled": event_spooled,
                "event_spooled": event_spooled,
                "archive_spooled": archive_spooled,
                "capture_spooled": capture_spooled,
                **self.store.status(),
                **self.archive.status(),
                **self.captures.status(),
            }
        if operation == "events":
            after = request.get("after", 0)
            limit = request.get("limit", 100)
            if not isinstance(after, int) or not isinstance(limit, int):
                raise ValueError("after and limit must be integers")
            return {"ok": True, "events": self.store.events(after=after, limit=limit)}
        if operation == "archive_ingest":
            path = request.get("path")
            if not isinstance(path, str) or not path:
                raise ValueError("archive checkpoint path is required")
            ingested = self.archive.ingest(Path(path))
            maintained = self.retention.run_if_due()
            return {"ok": True, **ingested, "maintenance": maintained}
        if operation == "archive_import":
            return {"ok": True, **self.archive.import_existing()}
        if operation == "retention_run":
            return {"ok": True, **self.retention.run()}
        if operation == "capture_ingest":
            required = ("path", "server", "epoch", "pane_spec", "reason")
            values = {name: request.get(name) for name in required}
            if any(not isinstance(value, str) or not value for value in values.values()):
                raise ValueError("capture path, server, epoch, pane_spec, and reason are required")
            pane_uuid = request.get("pane_uuid")
            if pane_uuid is not None and not isinstance(pane_uuid, str):
                raise ValueError("pane_uuid must be a string or null")
            observed_at = _capture_observed_at(request)
            captured = self.captures.ingest(
                Path(values["path"]),
                server=values["server"],
                epoch=values["epoch"],
                pane_spec=values["pane_spec"],
                pane_uuid=pane_uuid,
                reason=values["reason"],
                observed_at=observed_at,
            )
            maintained = self.retention.run_if_due()
            return {"ok": True, **captured, "maintenance": maintained}
        if operation == "capture_release":
            required = ("server", "epoch", "pane_spec")
            values = {name: request.get(name) for name in required}
            if any(not isinstance(value, str) or not value for value in values.values()):
                raise ValueError("capture server, epoch, and pane_spec are required")
            return {
                "ok": True,
                "released": self.captures.release_current(
                    server=values["server"],
                    epoch=values["epoch"],
                    pane_spec=values["pane_spec"],
                    observed_at=_capture_observed_at(request),
                ),
            }
        if operation == "control":
            command = request.get("command")
            if command != "shutdown":
                raise ValueError(f"unknown control command: {command}")
            if self._stop is None:
                raise RuntimeError("state owner is not serving")
            self._stop.set()
            return {"ok": True, "status": "stopping"}
        raise ValueError(f"unknown operation: {operation}")

    def close(self) -> None:
        if self._closed:
            return
        owned_socket = self._listener is not None
        if self._listener is not None:
            self._listener.close()
            self._listener = None
        if owned_socket:
            self.paths.socket.unlink(missing_ok=True)
        self.retention.close()
        self.captures.close()
        self.archive.close()
        self.store.close()
        if self._lock_file is not None:
            fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None
        self._stop = None
        self._closed = True


def _capture_observed_at(request: Mapping[str, Any]) -> float:
    observed_at = request.get("observed_at", observed_now())
    if (
        isinstance(observed_at, bool)
        or not isinstance(observed_at, (int, float))
        or not math.isfinite(observed_at)
        or observed_at < 0
    ):
        raise ValueError("capture observed_at must be a non-negative number")
    return float(observed_at)


def _spool_directory_count(path: Path) -> int:
    if not path.is_dir():
        return 0
    return sum(
        1
        for entry in path.iterdir()
        if entry.is_dir() and not entry.name.endswith(".invalid")
    )
