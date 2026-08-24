from __future__ import annotations

import socket
import time
from pathlib import Path
from typing import Any, Mapping

from .capture import spool_capture, spool_capture_release
from .events import Event, spool_event
from .paths import StatePaths
from .protocol import MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, encode_message, read_message


class OwnerUnavailable(ConnectionError):
    pass


class StateClient:
    """Typed client for the State Owner's local socket Interface."""

    def __init__(self, paths: StatePaths, *, timeout: float = 0.25):
        self.paths = paths
        self.timeout = timeout

    def _request(self, request: Mapping[str, Any]) -> dict[str, Any]:
        encoded = encode_message(request, max_bytes=MAX_REQUEST_BYTES)
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        try:
            connection.connect(str(self.paths.socket))
            connection.sendall(encoded)
            response = read_message(connection, max_bytes=MAX_RESPONSE_BYTES)
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
        observed_at: float | None = None,
    ) -> dict[str, Any]:
        observed_at = time.time() if observed_at is None else observed_at
        return self._request(
            {
                "operation": "capture_ingest",
                "path": str(path),
                "server": server,
                "epoch": epoch,
                "pane_spec": pane_spec,
                "pane_uuid": pane_uuid,
                "reason": reason,
                "observed_at": observed_at,
            }
        )

    def capture_release(
        self,
        *,
        server: str,
        epoch: str,
        pane_spec: str,
        observed_at: float | None = None,
    ) -> dict[str, Any]:
        observed_at = time.time() if observed_at is None else observed_at
        return self._request(
            {
                "operation": "capture_release",
                "server": server,
                "epoch": epoch,
                "pane_spec": pane_spec,
                "observed_at": observed_at,
            }
        )

    def control(self, command: str) -> dict[str, Any]:
        return self._request({"operation": "control", "command": command})


class EventPublisher:
    """Publish History Events with durable outage fallback."""

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


class CapturePublisher:
    """Publish Capture ownership changes with durable outage fallback."""

    def __init__(self, paths: StatePaths, *, timeout: float = 5.0):
        self.paths = paths
        self.client = StateClient(paths, timeout=timeout)

    def ingest(
        self,
        path: Path,
        *,
        server: str,
        epoch: str,
        pane_spec: str,
        pane_uuid: str | None,
        reason: str,
        observed_at: float | None = None,
    ) -> dict[str, Any]:
        observed_at = time.time() if observed_at is None else observed_at
        try:
            return self.client.capture_ingest(
                path,
                server=server,
                epoch=epoch,
                pane_spec=pane_spec,
                pane_uuid=pane_uuid,
                reason=reason,
                observed_at=observed_at,
            )
        except (OwnerUnavailable, RuntimeError):
            destination = spool_capture(
                self.paths.capture_spool,
                path,
                server=server,
                epoch=epoch,
                pane_spec=pane_spec,
                pane_uuid=pane_uuid,
                reason=reason,
                observed_at=observed_at,
            )
            return {"ok": True, "status": "spooled", "path": str(destination)}

    def release(
        self,
        *,
        server: str,
        epoch: str,
        pane_spec: str,
        observed_at: float | None = None,
    ) -> dict[str, Any]:
        observed_at = time.time() if observed_at is None else observed_at
        try:
            return self.client.capture_release(
                server=server,
                epoch=epoch,
                pane_spec=pane_spec,
                observed_at=observed_at,
            )
        except (OwnerUnavailable, RuntimeError):
            destination = spool_capture_release(
                self.paths.capture_spool,
                server=server,
                epoch=epoch,
                pane_spec=pane_spec,
                observed_at=observed_at,
            )
            return {"ok": True, "status": "spooled", "path": str(destination)}


# Compatibility name for callers introduced before the Interface was named.
Publisher = EventPublisher
