from __future__ import annotations

import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

from .core import CapturePublisher, OwnerUnavailable, StateClient, StatePaths
from .storage import atomic_write

_FIELD_SEPARATOR = "\x1f"
_TMUX_FIELDS = (
    "#{pane_id}",
    "#{session_name}:#{window_index}.#{pane_index}",
    "#{@claude-pane-id}",
    "#{@claude-window-id}",
    "#{window_name}",
    "#{pane_current_command}",
    "#{pane_title}",
    "#{pane_unseen_changes}",
    "#{pane_active}",
    "#{window_active}",
    "#{session_attached}",
)
_TMUX_FORMAT = _FIELD_SEPARATOR.join(_TMUX_FIELDS)
_LEADING_STATUS = re.compile(r"^[^\x20-\x7e]+ *")
_STATE_VERSION = 1


class TmuxUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class WatcherConfig:
    visible_floor_seconds: int = 5
    background_floor_seconds: int = 300
    lines: int = 2000
    queue_per_tick: int = 8
    pace_seconds: float = 0.05
    owner_check_seconds: int = 60
    tick_seconds: float = 1.0
    title_formatter: Path | None = None

    @classmethod
    def from_environment(cls) -> "WatcherConfig":
        defaults = cls()

        def integer(name: str, default: int) -> int:
            value = int(os.environ.get(name, default))
            if value < 0:
                raise ValueError(f"{name} must be non-negative")
            return value

        formatter = os.environ.get("CLAUDE_RESCUE_TITLE_FORMATTER")
        return cls(
            visible_floor_seconds=integer(
                "CLAUDE_RESCUE_WATCHER_VISIBLE_FLOOR_S", defaults.visible_floor_seconds
            ),
            background_floor_seconds=integer(
                "CLAUDE_RESCUE_WATCHER_BACKGROUND_FLOOR_S",
                defaults.background_floor_seconds,
            ),
            lines=integer("CLAUDE_RESCUE_WATCHER_LINES", defaults.lines),
            queue_per_tick=integer(
                "CLAUDE_RESCUE_WATCHER_QUEUE_PER_TICK", defaults.queue_per_tick
            ),
            pace_seconds=(
                integer(
                    "CLAUDE_RESCUE_WATCHER_PACE_MS",
                    round(defaults.pace_seconds * 1000),
                )
                / 1000
            ),
            owner_check_seconds=integer(
                "CLAUDE_RESCUE_OWNER_CHECK_S", defaults.owner_check_seconds
            ),
            tick_seconds=defaults.tick_seconds,
            title_formatter=Path(formatter) if formatter else None,
        )


@dataclass(frozen=True)
class PaneState:
    pane_id: str
    pane_spec: str
    pane_uuid: str
    window_uuid: str
    window_name: str
    command: str
    raw_title: str
    unseen: str
    active: bool
    visible: bool
    cleaned_title: str

    @property
    def raw_key(self) -> tuple[str, str, str]:
        return self.window_name, self.command, self.raw_title

    def to_mapping(self) -> dict[str, object]:
        return {
            "pane_id": self.pane_id,
            "pane_spec": self.pane_spec,
            "pane_uuid": self.pane_uuid,
            "window_uuid": self.window_uuid,
            "window_name": self.window_name,
            "command": self.command,
            "raw_title": self.raw_title,
            "unseen": self.unseen,
            "active": self.active,
            "visible": self.visible,
            "cleaned_title": self.cleaned_title,
        }

    @classmethod
    def from_mapping(cls, value: Mapping[str, object]) -> "PaneState":
        strings = (
            "pane_id",
            "pane_spec",
            "pane_uuid",
            "window_uuid",
            "window_name",
            "command",
            "raw_title",
            "unseen",
            "cleaned_title",
        )
        if any(not isinstance(value.get(name), str) for name in strings):
            raise ValueError("invalid watcher pane state")
        active = value.get("active")
        visible = value.get("visible")
        if not isinstance(active, bool) or not isinstance(visible, bool):
            raise ValueError("invalid watcher pane visibility state")
        return cls(
            pane_id=str(value["pane_id"]),
            pane_spec=str(value["pane_spec"]),
            pane_uuid=str(value["pane_uuid"]),
            window_uuid=str(value["window_uuid"]),
            window_name=str(value["window_name"]),
            command=str(value["command"]),
            raw_title=str(value["raw_title"]),
            unseen=str(value["unseen"]),
            active=active,
            visible=visible,
            cleaned_title=str(value["cleaned_title"]),
        )


@dataclass(frozen=True)
class CaptureRequest:
    pane: PaneState
    reason: str
    floor_only: bool


@dataclass(frozen=True)
class TickPlan:
    created: tuple[PaneState, ...]
    titles: tuple[PaneState, ...]
    died: tuple[PaneState, ...]
    captures: tuple[CaptureRequest, ...]


def default_cleaned_title(
    window_name: str,
    command: str,
    pane_title: str,
    host_short: str,
) -> str:
    if window_name.startswith("[tmux]"):
        window_name = command

    custom = window_name if window_name != command else ""
    meaningful_title = bool(pane_title) and pane_title != host_short
    if command in {"nvim", "claude"}:
        if meaningful_title:
            sequence = (
                _LEADING_STATUS.sub("", pane_title) if command == "claude" else pane_title
            )
            base = f"{sequence} - {command}"
        else:
            base = command
    elif meaningful_title:
        base = f"{command} - {pane_title}"
    else:
        base = command

    return f"{custom}: {base}" if custom else base


def plan_tick(
    previous: Mapping[str, PaneState],
    current: Mapping[str, PaneState],
    *,
    first_tick: bool,
    now: float,
    last_captured: Mapping[str, float],
    visible_floor_seconds: int,
    background_floor_seconds: int,
) -> TickPlan:
    created: list[PaneState] = []
    titles: list[PaneState] = []
    captures: list[CaptureRequest] = []

    for pane in current.values():
        prior = previous.get(pane.pane_id)
        request: CaptureRequest | None = None
        if prior is None:
            if not first_tick:
                created.append(pane)
            request = CaptureRequest(pane, "created", False)
        else:
            if pane.cleaned_title != prior.cleaned_title:
                titles.append(pane)
                request = CaptureRequest(pane, "title", False)
            elif pane.unseen != prior.unseen:
                request = CaptureRequest(pane, "activity", False)
            elif pane.active != prior.active:
                request = CaptureRequest(pane, "visibility", False)

        if request is None:
            floor = (
                visible_floor_seconds if pane.visible else background_floor_seconds
            )
            last = last_captured.get(pane.pane_spec)
            if last is None or now - last >= floor:
                request = CaptureRequest(pane, "floor", True)
        if request is not None:
            captures.append(request)

    died = tuple(pane for pane_id, pane in previous.items() if pane_id not in current)
    return TickPlan(tuple(created), tuple(titles), died, tuple(captures))


class Watcher:
    def __init__(
        self,
        paths: StatePaths,
        repository: Path,
        *,
        config: WatcherConfig | None = None,
    ):
        self.paths = paths
        self.repository = repository
        self.config = config or WatcherConfig.from_environment()
        self.tmux = shutil.which("tmux") or "tmux"
        self.host_short = socket.gethostname().split(".", 1)[0]
        self.server_name, self.epoch = self._server_identity()
        self.outdir = paths.data_home / "scrollback" / self.server_name
        self.state_file = self.outdir / ".state"
        self.server_pid_file = self.outdir / ".server-pid"
        self.pid_file = paths.data_home / f"watcher-{self.server_name}.pid"
        self.audit_file = paths.data_home / "watcher-audit.log"
        self.error_file = paths.cache_home / f"watcher-{self.server_name}.log"
        self.capture_publisher = CapturePublisher(paths)
        self.owner_client = StateClient(paths, timeout=0.1)
        self.pending: OrderedDict[str, CaptureRequest] = OrderedDict()
        self.children: list[subprocess.Popen[bytes]] = []
        self.stop_requested = False
        self.next_owner_check = 0.0

        self.outdir.mkdir(parents=True, exist_ok=True)
        paths.cache_home.mkdir(parents=True, exist_ok=True)
        self._migrate_legacy_layout()
        self._prepare_epoch()
        self.previous = self._load_state()
        self.first_tick = not self.previous
        self.last_captured = self._load_capture_times()

    def _server_identity(self) -> tuple[str, str]:
        tmux_environment = os.environ.get("TMUX", "")
        parts = tmux_environment.split(",", 2)
        if len(parts) >= 2 and parts[0] and parts[1]:
            return Path(parts[0]).name or "default", parts[1]

        result = subprocess.run(
            [self.tmux, "display-message", "-p", f"#{{socket_path}}{_FIELD_SEPARATOR}#{{pid}}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise TmuxUnavailable("tmux server is unavailable")
        identity = result.stdout.strip().split(_FIELD_SEPARATOR, 1)
        if len(identity) != 2 or not identity[0] or not identity[1]:
            raise TmuxUnavailable("tmux server identity is unavailable")
        return Path(identity[0]).name or "default", identity[1]

    def _migrate_legacy_layout(self) -> None:
        if self.server_name != "default":
            return
        flat = self.paths.data_home / "scrollback"
        if not any(flat.glob("pane-*")):
            return
        self.outdir.mkdir(parents=True, exist_ok=True)
        for pattern in ("pane-*", ".hash-*", ".touch-*"):
            for source in flat.glob(pattern):
                destination = self.outdir / source.name
                if not destination.exists():
                    try:
                        os.replace(source, destination)
                    except OSError:
                        pass

    def _prepare_epoch(self) -> None:
        try:
            stored_epoch = self.server_pid_file.read_text().strip()
        except OSError:
            stored_epoch = ""
        if stored_epoch != self.epoch:
            self.state_file.unlink(missing_ok=True)
            for pattern in ("pane-*", ".hash-*", ".touch-*"):
                for path in self.outdir.glob(pattern):
                    path.unlink(missing_ok=True)
            atomic_write(self.server_pid_file, self.epoch.encode())

    def _load_state(self) -> dict[str, PaneState]:
        try:
            state = json.loads(self.state_file.read_text())
            if state.get("version") != _STATE_VERSION or state.get("epoch") != self.epoch:
                return {}
            panes = [PaneState.from_mapping(item) for item in state["panes"]]
        except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError):
            return {}
        return {pane.pane_id: pane for pane in panes}

    def _save_state(self, panes: Mapping[str, PaneState]) -> None:
        state = {
            "version": _STATE_VERSION,
            "epoch": self.epoch,
            "panes": [pane.to_mapping() for pane in panes.values()],
        }
        atomic_write(
            self.state_file,
            (json.dumps(state, separators=(",", ":"), sort_keys=True) + "\n").encode(),
        )

    def _load_capture_times(self) -> dict[str, float]:
        captured: dict[str, float] = {}
        for path in self.outdir.glob(".touch-*"):
            try:
                captured[path.name.removeprefix(".touch-")] = path.stat().st_mtime
            except OSError:
                pass
        return captured

    def _pid_command_contains(self, pid: int, expected: str) -> bool:
        try:
            os.kill(pid, 0)
        except (OSError, ValueError):
            return False
        result = subprocess.run(
            ["ps", "-o", "command=", "-p", str(pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        return result.returncode == 0 and expected in result.stdout

    def _claim_pid(self) -> bool:
        try:
            other_pid = int(self.pid_file.read_text().strip())
        except (OSError, ValueError):
            other_pid = 0
        if other_pid and other_pid != os.getpid():
            if self._pid_command_contains(other_pid, "claude-rescue-state watch"):
                return False
            if self._pid_command_contains(other_pid, str(self.repository / "bin/claude-rescue-watcher")):
                return False
        atomic_write(self.pid_file, f"{os.getpid()}\n".encode())
        return True

    def _release_pid(self) -> None:
        try:
            owner = int(self.pid_file.read_text().strip())
        except (OSError, ValueError):
            return
        if owner == os.getpid():
            self.pid_file.unlink(missing_ok=True)

    def _cleaned_title(
        self,
        window_name: str,
        command: str,
        raw_title: str,
    ) -> str:
        formatter = self.config.title_formatter
        if formatter is not None and os.access(formatter, os.X_OK):
            try:
                result = subprocess.run(
                    [str(formatter), window_name, command, raw_title, self.host_short],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=2,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                result = None
            if result is not None and result.returncode == 0:
                return result.stdout.rstrip("\n")
        return default_cleaned_title(window_name, command, raw_title, self.host_short)

    def _list_panes(self) -> dict[str, PaneState]:
        result = subprocess.run(
            [self.tmux, "list-panes", "-aF", _TMUX_FORMAT],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise TmuxUnavailable("tmux server is unavailable")

        panes: dict[str, PaneState] = {}
        for line in result.stdout.splitlines():
            fields = line.split(_FIELD_SEPARATOR)
            if len(fields) != len(_TMUX_FIELDS):
                self._log_error(f"ignored malformed tmux pane row with {len(fields)} fields")
                continue
            (
                pane_id,
                pane_spec,
                pane_uuid,
                window_uuid,
                window_name,
                command,
                raw_title,
                unseen,
                active,
                window_active,
                session_attached,
            ) = fields
            prior = self.previous.get(pane_id)
            raw_key = (window_name, command, raw_title)
            cleaned = (
                prior.cleaned_title
                if prior is not None and prior.raw_key == raw_key
                else self._cleaned_title(window_name, command, raw_title)
            )
            panes[pane_id] = PaneState(
                pane_id=pane_id,
                pane_spec=pane_spec,
                pane_uuid=pane_uuid,
                window_uuid=window_uuid,
                window_name=window_name,
                command=command,
                raw_title=raw_title,
                unseen=unseen,
                active=active == "1",
                visible=(active == "1" and window_active == "1" and session_attached != "0"),
                cleaned_title=cleaned,
            )
        return panes

    def _emit_log(self, *arguments: str) -> None:
        self._reap_children()
        child = subprocess.Popen(
            [str(self.repository / "bin/claude-rescue-log"), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.children.append(child)

    def _reap_children(self) -> None:
        self.children = [child for child in self.children if child.poll() is None]

    def _enqueue(self, request: CaptureRequest) -> None:
        existing = self.pending.get(request.pane.pane_id)
        if existing is None or (existing.floor_only and not request.floor_only):
            self.pending[request.pane.pane_id] = request
            return
        self.pending[request.pane.pane_id] = CaptureRequest(
            pane=request.pane,
            reason=existing.reason,
            floor_only=existing.floor_only,
        )

    def _capture(self, request: CaptureRequest) -> str | None:
        descriptor, temporary_name = tempfile.mkstemp(prefix=".capture-", dir=self.outdir)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as output:
                result = subprocess.run(
                    [
                        self.tmux,
                        "capture-pane",
                        "-epJ",
                        "-S",
                        f"-{self.config.lines}",
                        "-t",
                        request.pane.pane_id,
                        "-p",
                    ],
                    stdout=output,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            if result.returncode != 0:
                return None

            response = self.capture_publisher.ingest(
                temporary,
                server=self.server_name,
                epoch=self.epoch,
                pane_spec=request.pane.pane_spec,
                pane_uuid=request.pane.pane_uuid or None,
                reason=request.reason,
            )
            status = response.get("status")
            if status not in {"first", "changed", "unchanged", "stale", "spooled"}:
                raise RuntimeError(f"unexpected Capture result: {status}")

            target = self.outdir / f"pane-{request.pane.pane_spec}"
            if status in {"first", "changed", "spooled"}:
                os.replace(temporary, target)
            touch = self.outdir / f".touch-{request.pane.pane_spec}"
            touch.touch()
            self.last_captured[request.pane.pane_spec] = touch.stat().st_mtime
            return str(status)
        except OSError as error:
            self._log_error(f"Capture failed for {request.pane.pane_id}: {error}")
            return None
        finally:
            temporary.unlink(missing_ok=True)

    def _audit_floor_change(self, request: CaptureRequest) -> None:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            with self.audit_file.open("a") as audit:
                audit.write(
                    f"{timestamp}\tfloor-caught\t{request.pane.pane_id}\t"
                    f"{request.pane.pane_spec}\n"
                )
        except OSError:
            pass

    def _release_dead(self, pane: PaneState) -> None:
        try:
            self.capture_publisher.release(
                server=self.server_name,
                epoch=self.epoch,
                pane_spec=pane.pane_spec,
            )
        except OSError as error:
            self._log_error(f"Capture release failed for {pane.pane_id}: {error}")
        for prefix in ("pane-", ".hash-", ".touch-"):
            (self.outdir / f"{prefix}{pane.pane_spec}").unlink(missing_ok=True)
        self.last_captured.pop(pane.pane_spec, None)
        self.pending.pop(pane.pane_id, None)

    def _drain_captures(self, current: Mapping[str, PaneState]) -> None:
        drained = 0
        while self.pending and drained < self.config.queue_per_tick:
            pane_id, request = self.pending.popitem(last=False)
            live = current.get(pane_id)
            if live is None or live.pane_spec != request.pane.pane_spec:
                continue
            if live != request.pane:
                request = CaptureRequest(live, request.reason, request.floor_only)
            status = self._capture(request)
            if status is None:
                self.pending[pane_id] = request
            elif status == "changed" and request.floor_only:
                self._audit_floor_change(request)
            drained += 1
            if self.pending and drained < self.config.queue_per_tick and self.config.pace_seconds:
                time.sleep(self.config.pace_seconds)

    def _repair_owner_if_due(self, now: float) -> None:
        if now < self.next_owner_check:
            return
        try:
            self.owner_client.status()
        except (OwnerUnavailable, RuntimeError):
            try:
                subprocess.run(
                    [str(self.repository / "bin/claude-rescue-state"), "ensure"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                pass
        self.next_owner_check = now + self.config.owner_check_seconds

    def _log_error(self, message: str) -> None:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            with self.error_file.open("a") as error_file:
                error_file.write(f"[{timestamp}] {message}\n")
        except OSError:
            pass

    def tick(self) -> None:
        now = time.time()
        self._repair_owner_if_due(now)
        current = self._list_panes()
        plan = plan_tick(
            self.previous,
            current,
            first_tick=self.first_tick,
            now=now,
            last_captured=self.last_captured,
            visible_floor_seconds=self.config.visible_floor_seconds,
            background_floor_seconds=self.config.background_floor_seconds,
        )

        for pane in plan.created:
            self._emit_log("pane-created", pane.pane_id, pane.window_uuid, pane.pane_uuid)
        for pane in plan.titles:
            self._emit_log(
                "title-now",
                pane.pane_id,
                pane.cleaned_title,
                pane.window_uuid,
                pane.pane_uuid,
            )
        for pane in plan.died:
            self._emit_log("pane-died", pane.pane_id, pane.window_uuid, pane.pane_uuid)
            self._release_dead(pane)
        for request in plan.captures:
            self._enqueue(request)

        self._drain_captures(current)
        self._save_state(current)
        self.previous = current
        self.first_tick = False

    def run(self) -> int:
        if not self._claim_pid():
            return 0

        def request_stop(_signum: int, _frame: object) -> None:
            self.stop_requested = True

        signal.signal(signal.SIGHUP, request_stop)
        signal.signal(signal.SIGINT, request_stop)
        signal.signal(signal.SIGTERM, request_stop)
        try:
            while not self.stop_requested:
                started = time.monotonic()
                try:
                    self.tick()
                except TmuxUnavailable:
                    break
                except Exception as error:
                    self._log_error(f"tick failed: {error}")
                delay = self.config.tick_seconds - (time.monotonic() - started)
                if delay > 0:
                    time.sleep(delay)
        finally:
            self._release_pid()
            self._reap_children()
        return 0
