from __future__ import annotations

import json
import os
import re
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .storage import atomic_write, open_database

SCHEMA_VERSION = 1
_EVENT_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


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
            raise ValueError(
                "event_id must contain 1-128 letters, digits, dots, underscores, or dashes"
            )
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
        json.dumps(
            event.to_mapping(),
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
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
    """Idempotent, commit-ordered History Event journal."""

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
        payload = json.dumps(
            event.payload,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
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
    os.chmod(path, 0o700)
    destination = path / f"{event.event_id}.json"
    if destination.exists():
        return destination

    encoded = (
        json.dumps(
            event.to_mapping(),
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        + b"\n"
    )
    atomic_write(destination, encoded)
    return destination


def _event_spool_order(item: Path) -> tuple[int, float, int, str]:
    try:
        modified_ns = item.stat().st_mtime_ns
    except OSError:
        modified_ns = 0
    try:
        event = Event.from_mapping(json.loads(item.read_text()))
        parsed = datetime.fromisoformat(event.occurred_at.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return 0, parsed.timestamp(), modified_ns, item.name
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return 1, modified_ns / 1_000_000_000, modified_ns, item.name


def drain_spool(store: EventStore, path: Path, *, limit: int = 1000) -> dict[str, int]:
    result = {"committed": 0, "duplicates": 0, "invalid": 0}
    if not path.is_dir():
        return result

    items = list(path.glob("*.json"))
    items.sort(key=_event_spool_order)
    for item in items[:limit]:
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
