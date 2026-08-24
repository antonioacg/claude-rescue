from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import socket
import tempfile
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .archive import ArchiveIndex
from .capture import CaptureIndex
from .storage import atomic_write, open_database

SCHEMA_VERSION = 1
MAX_MESSAGE_BYTES = 1024 * 1024
_EVENT_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


@dataclass(frozen=True)
class StatePaths:
    data_home: Path
    cache_home: Path

    @classmethod
    def from_environment(cls) -> "StatePaths":
        home = Path.home()
        data_home = Path(
            os.environ.get(
                "CLAUDE_RESCUE_DATA_HOME",
                os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share")) + "/claude-rescue",
            )
        )
        cache_home = Path(
            os.environ.get(
                "CLAUDE_RESCUE_CACHE_HOME",
                os.environ.get("XDG_CACHE_HOME", str(home / ".cache")) + "/claude-rescue",
            )
        )
        return cls(data_home=data_home, cache_home=cache_home)

    @property
    def database(self) -> Path:
        return self.data_home / "state" / "state.db"

    @property
    def spool(self) -> Path:
        return self.data_home / "state" / "spool"

    @property
    def archive(self) -> Path:
        return Path(os.environ.get("CLAUDE_RESCUE_ARCHIVE_DIR", self.data_home / "archive"))

    @property
    def archive_spool(self) -> Path:
        return self.data_home / "state" / "archive-spool"

    @property
    def capture_spool(self) -> Path:
        return self.data_home / "state" / "capture-spool"

    @property
    def socket(self) -> Path:
        runtime_home = Path(os.environ.get("XDG_RUNTIME_DIR", self.cache_home))
        candidate = runtime_home / "claude-rescue-state.sock"
        # sockaddr_un.sun_path is only 104 bytes on macOS. A hashed path in the
        # user's temporary directory keeps custom/test data homes usable.
        if len(os.fsencode(candidate)) < 100:
            return candidate
        digest = hashlib.sha256(os.fsencode(self.cache_home)).hexdigest()[:12]
        return Path(tempfile.gettempdir()) / f"claude-rescue-{os.getuid()}-{digest}.sock"

    @property
    def lock(self) -> Path:
        return self.cache_home / "state-owner.lock"

    @property
    def log(self) -> Path:
        return self.cache_home / "state-owner.log"


@dataclass(frozen=True)
class Event:
    event_id: str
    source: str
    kind: str
    occurred_at: str
    epoch: str | None = None
    pane_uuid: str | None = None
    session_id: str | None = None
    payload: Mapping[str, Any] = field(default_factory=dict)

    @classmethod
    def create(
        cls,
        *,
        source: str,
        kind: str,
        epoch: str | None = None,
        pane_uuid: str | None = None,
        session_id: str | None = None,
        payload: Mapping[str, Any] | None = None,
        event_id: str | None = None,
        occurred_at: str | None = None,
    ) -> "Event":
        return cls.from_mapping(
            {
                "event_id": event_id or str(uuid.uuid4()),
                "source": source,
                "kind": kind,
                "occurred_at": occurred_at or utc_now(),
                "epoch": epoch,
                "pane_uuid": pane_uuid,
                "session_id": session_id,
                "payload": dict(payload or {}),
            }
        )

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "Event":
        event_id = value.get("event_id")
        source = value.get("source")
        kind = value.get("kind")
        occurred_at = value.get("occurred_at")
        payload = value.get("payload", {})

        if not isinstance(event_id, str) or not _EVENT_ID.fullmatch(event_id):
            raise ValueError("event_id must contain 1-128 letters, digits, dots, underscores, or dashes")
        if not isinstance(source, str) or not source.strip():
            raise ValueError("source is required")
        if not isinstance(kind, str) or not kind.strip():
            raise ValueError("kind is required")
        if not isinstance(occurred_at, str) or not occurred_at.strip():
            raise ValueError("occurred_at is required")
        if not isinstance(payload, Mapping):
            raise ValueError("payload must be a JSON object")

        optional: dict[str, str | None] = {}
        for name in ("epoch", "pane_uuid", "session_id"):
            item = value.get(name)
            if item is not None and not isinstance(item, str):
                raise ValueError(f"{name} must be a string or null")
            optional[name] = item

        event = cls(
            event_id=event_id,
            source=source,
            kind=kind,
            occurred_at=occurred_at,
            epoch=optional["epoch"],
            pane_uuid=optional["pane_uuid"],
            session_id=optional["session_id"],
            payload=dict(payload),
        )
        json.dumps(event.to_mapping(), separators=(",", ":"), sort_keys=True)
        return event

    def to_mapping(self) -> dict[str, Any]:
        return {
            "event_id": self.event_id,
            "source": self.source,
            "kind": self.kind,
            "occurred_at": self.occurred_at,
            "epoch": self.epoch,
            "pane_uuid": self.pane_uuid,
            "session_id": self.session_id,
            "payload": dict(self.payload),
        }


class EventStore:
    def __init__(self, path: Path):
        self._connection = open_database(path)
        self._lock = threading.Lock()
        with self._connection:
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL UNIQUE,
                    occurred_at TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    epoch TEXT,
                    pane_uuid TEXT,
                    session_id TEXT,
                    payload_json TEXT NOT NULL
                )
                """
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS events_pane_sequence ON events(pane_uuid, sequence)"
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS events_session_sequence ON events(session_id, sequence)"
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS events_kind_sequence ON events(kind, sequence)"
            )
            self._connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")

    def append(self, event: Event) -> tuple[int, bool]:
        payload = json.dumps(event.payload, separators=(",", ":"), sort_keys=True)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                INSERT OR IGNORE INTO events (
                    event_id, occurred_at, received_at, source, kind,
                    epoch, pane_uuid, session_id, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event.event_id,
                    event.occurred_at,
                    utc_now(),
                    event.source,
                    event.kind,
                    event.epoch,
                    event.pane_uuid,
                    event.session_id,
                    payload,
                ),
            )
            inserted = cursor.rowcount == 1
            if inserted:
                return int(cursor.lastrowid), True
            row = self._connection.execute(
                """
                SELECT sequence, occurred_at, source, kind, epoch, pane_uuid,
                       session_id, payload_json
                FROM events WHERE event_id = ?
                """,
                (event.event_id,),
            ).fetchone()
            if row is None:
                raise RuntimeError("event insert was ignored without an existing event")
            existing = (
                row["occurred_at"],
                row["source"],
                row["kind"],
                row["epoch"],
                row["pane_uuid"],
                row["session_id"],
                row["payload_json"],
            )
            proposed = (
                event.occurred_at,
                event.source,
                event.kind,
                event.epoch,
                event.pane_uuid,
                event.session_id,
                payload,
            )
            if existing != proposed:
                raise ValueError(f"event_id {event.event_id} was reused with different content")
            return int(row["sequence"]), False

    def status(self) -> dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                "SELECT COUNT(*) AS event_count, COALESCE(MAX(sequence), 0) AS latest_sequence FROM events"
            ).fetchone()
            return {
                "schema_version": SCHEMA_VERSION,
                "event_count": int(row["event_count"]),
                "latest_sequence": int(row["latest_sequence"]),
            }

    def events(self, *, after: int = 0, limit: int = 100) -> list[dict[str, Any]]:
        if after < 0:
            raise ValueError("after must be non-negative")
        if not 1 <= limit <= 1000:
            raise ValueError("limit must be between 1 and 1000")
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT sequence, event_id, occurred_at, received_at, source, kind,
                       epoch, pane_uuid, session_id, payload_json
                FROM events WHERE sequence > ? ORDER BY sequence LIMIT ?
                """,
                (after, limit),
            ).fetchall()
        return [
            {
                "sequence": int(row["sequence"]),
                "event_id": row["event_id"],
                "occurred_at": row["occurred_at"],
                "received_at": row["received_at"],
                "source": row["source"],
                "kind": row["kind"],
                "epoch": row["epoch"],
                "pane_uuid": row["pane_uuid"],
                "session_id": row["session_id"],
                "payload": json.loads(row["payload_json"]),
            }
            for row in rows
        ]

    def close(self) -> None:
        with self._lock:
            self._connection.close()


def spool_event(path: Path, event: Event) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    destination = path / f"{event.event_id}.json"
    if destination.exists():
        return destination

    encoded = json.dumps(event.to_mapping(), separators=(",", ":"), sort_keys=True).encode() + b"\n"
    atomic_write(destination, encoded)
    return destination


def drain_spool(store: EventStore, path: Path, *, limit: int = 1000) -> dict[str, int]:
    result = {"committed": 0, "duplicates": 0, "invalid": 0}
    if not path.is_dir():
        return result

    for item in sorted(path.glob("*.json"))[:limit]:
        try:
            event = Event.from_mapping(json.loads(item.read_text()))
            _, inserted = store.append(event)
        except (OSError, ValueError, json.JSONDecodeError, TypeError):
            invalid = item.with_suffix(item.suffix + ".invalid")
            os.replace(item, invalid)
            result["invalid"] += 1
            continue
        item.unlink(missing_ok=True)
        result["committed" if inserted else "duplicates"] += 1
    return result


class OwnerUnavailable(ConnectionError):
    pass


class StateClient:
    def __init__(self, paths: StatePaths, *, timeout: float = 0.25):
        self.paths = paths
        self.timeout = timeout

    def _request(self, request: Mapping[str, Any]) -> dict[str, Any]:
        encoded = json.dumps(request, separators=(",", ":"), sort_keys=True).encode() + b"\n"
        if len(encoded) > MAX_MESSAGE_BYTES:
            raise ValueError("request exceeds maximum size")

        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        try:
            connection.connect(str(self.paths.socket))
            connection.sendall(encoded)
            response = _read_message(connection)
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError) as error:
            raise OwnerUnavailable(str(error)) from error
        finally:
            connection.close()

        if not response.get("ok"):
            raise RuntimeError(str(response.get("error", "state owner request failed")))
        return response

    def publish(self, event: Event) -> dict[str, Any]:
        return self._request({"operation": "publish", "event": event.to_mapping()})

    def status(self) -> dict[str, Any]:
        return self._request({"operation": "status"})

    def events(self, *, after: int = 0, limit: int = 100) -> dict[str, Any]:
        return self._request({"operation": "events", "after": after, "limit": limit})

    def archive_ingest(self, path: Path) -> dict[str, Any]:
        return self._request({"operation": "archive_ingest", "path": str(path)})

    def archive_import(self) -> dict[str, Any]:
        return self._request({"operation": "archive_import"})

    def archive_maintain(self) -> dict[str, Any]:
        return self._request({"operation": "archive_maintain"})

    def capture_ingest(
        self,
        path: Path,
        *,
        server: str,
        epoch: str,
        pane_spec: str,
        pane_uuid: str | None,
        reason: str,
    ) -> dict[str, Any]:
        return self._request(
            {
                "operation": "capture_ingest",
                "path": str(path),
                "server": server,
                "epoch": epoch,
                "pane_spec": pane_spec,
                "pane_uuid": pane_uuid,
                "reason": reason,
            }
        )

    def capture_release(self, *, server: str, epoch: str, pane_spec: str) -> dict[str, Any]:
        return self._request(
            {
                "operation": "capture_release",
                "server": server,
                "epoch": epoch,
                "pane_spec": pane_spec,
            }
        )

    def control(self, command: str) -> dict[str, Any]:
        return self._request({"operation": "control", "command": command})


class Publisher:
    def __init__(self, paths: StatePaths, *, timeout: float = 0.25):
        self.paths = paths
        self.client = StateClient(paths, timeout=timeout)

    def publish(self, event: Event) -> dict[str, Any]:
        try:
            response = self.client.publish(event)
            return {
                "status": "committed",
                "sequence": response["sequence"],
                "inserted": response["inserted"],
            }
        except (OwnerUnavailable, RuntimeError):
            destination = spool_event(self.paths.spool, event)
            return {"status": "spooled", "path": str(destination)}


class StateOwner:
    def __init__(self, paths: StatePaths):
        self.paths = paths
        self.store = EventStore(paths.database)
        self.archive = ArchiveIndex(paths.database, paths.archive)
        self.captures = CaptureIndex(paths.database, paths.data_home)
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
        self._open_listener()
        self._drain_spools()
        try:
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
            request = _read_message(connection)
            response = self._dispatch(request)
        except Exception as error:
            response = {"ok": False, "error": str(error)}
        try:
            connection.sendall(
                json.dumps(response, separators=(",", ":"), sort_keys=True).encode() + b"\n"
            )
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
            return {
                "ok": True,
                "pid": os.getpid(),
                "socket": str(self.paths.socket),
                "spooled": len(list(self.paths.spool.glob("*.json"))) if self.paths.spool.is_dir() else 0,
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
            maintained = self.archive.maintain_if_due()
            return {"ok": True, **ingested, "maintenance": maintained}
        if operation == "archive_import":
            return {"ok": True, **self.archive.import_existing()}
        if operation == "archive_maintain":
            return {"ok": True, **self.archive.maintain(), **self.captures.maintain()}
        if operation == "capture_ingest":
            required = ("path", "server", "epoch", "pane_spec", "reason")
            values = {name: request.get(name) for name in required}
            if any(not isinstance(value, str) or not value for value in values.values()):
                raise ValueError("capture path, server, epoch, pane_spec, and reason are required")
            pane_uuid = request.get("pane_uuid")
            if pane_uuid is not None and not isinstance(pane_uuid, str):
                raise ValueError("pane_uuid must be a string or null")
            captured = self.captures.ingest(
                Path(values["path"]),
                server=values["server"],
                epoch=values["epoch"],
                pane_spec=values["pane_spec"],
                pane_uuid=pane_uuid,
                reason=values["reason"],
            )
            maintained = self.captures.maintain_if_due()
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
        self.captures.close()
        self.archive.close()
        self.store.close()
        if self._lock_file is not None:
            fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None
        self._stop = None
        self._closed = True


def _read_message(connection: socket.socket) -> dict[str, Any]:
    chunks: list[bytes] = []
    size = 0
    while True:
        chunk = connection.recv(min(65536, MAX_MESSAGE_BYTES + 1 - size))
        if not chunk:
            break
        newline = chunk.find(b"\n")
        if newline >= 0:
            chunks.append(chunk[:newline])
            break
        chunks.append(chunk)
        size += len(chunk)
        if size > MAX_MESSAGE_BYTES:
            raise ValueError("message exceeds maximum size")
    raw = b"".join(chunks)
    if not raw:
        raise ValueError("empty request")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("request must be a JSON object")
    return value
