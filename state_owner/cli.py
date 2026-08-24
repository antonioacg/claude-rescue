from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from .core import Event, OwnerUnavailable, Publisher, StateClient, StateOwner, StatePaths


def _json_object(value: str) -> dict[str, Any]:
    parsed = json.loads(value)
    if not isinstance(parsed, dict):
        raise argparse.ArgumentTypeError("value must be a JSON object")
    return parsed


def _print(value: Any) -> None:
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))


def _publish(args: argparse.Namespace, paths: StatePaths) -> int:
    payload = args.payload
    if payload is None and not sys.stdin.isatty():
        raw = sys.stdin.read().strip()
        payload = _json_object(raw) if raw else {}
    event = Event.create(
        source=args.source,
        kind=args.kind,
        epoch=args.epoch,
        pane_uuid=args.pane_uuid,
        session_id=args.session_id,
        payload=payload or {},
        event_id=args.event_id,
        occurred_at=args.occurred_at,
    )
    _print(Publisher(paths, timeout=args.timeout).publish(event))
    return 0


def _publish_window_event(args: argparse.Namespace, paths: StatePaths) -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        raise ValueError("window event JSON is required on stdin")
    legacy = _json_object(raw)
    kind = legacy.get("kind")
    if not isinstance(kind, str) or not kind:
        raise ValueError("window event kind is required")
    occurred_at = legacy.get("ts")
    if occurred_at is not None and not isinstance(occurred_at, str):
        raise ValueError("window event ts must be a string")
    event = Event.create(
        source="window-log",
        kind=kind,
        pane_uuid=legacy.get("pane_uuid"),
        session_id=legacy.get("session_id"),
        occurred_at=occurred_at,
        payload={"window_uuid": args.window_uuid, "event": legacy},
    )
    _print(Publisher(paths, timeout=args.timeout).publish(event))
    return 0


def _serve(paths: StatePaths) -> int:
    stop = threading.Event()

    def request_stop(_signum: int, _frame: Any) -> None:
        stop.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    owner = StateOwner(paths)
    owner.serve(stop)
    return 0


def _ensure(args: argparse.Namespace, paths: StatePaths) -> int:
    client = StateClient(paths, timeout=0.1)
    try:
        _print({"status": "running", **client.status()})
        return 0
    except OwnerUnavailable:
        pass

    paths.cache_home.mkdir(parents=True, exist_ok=True)
    executable = str(Path(sys.argv[0]).resolve())
    with paths.log.open("ab", buffering=0) as log:
        child = subprocess.Popen(
            [sys.executable, executable, "serve"],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
            close_fds=True,
            env=os.environ.copy(),
        )

    deadline = time.monotonic() + args.wait
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError(f"state owner exited during startup; see {paths.log}")
        try:
            _print({"status": "started", **client.status()})
            return 0
        except OwnerUnavailable:
            time.sleep(0.05)
    raise RuntimeError(f"state owner did not start within {args.wait:g}s; see {paths.log}")


def _status(args: argparse.Namespace, paths: StatePaths) -> int:
    _print(StateClient(paths, timeout=args.timeout).status())
    return 0


def _events(args: argparse.Namespace, paths: StatePaths) -> int:
    response = StateClient(paths, timeout=args.timeout).events(after=args.after, limit=args.limit)
    for event in response["events"]:
        _print(event)
    return 0


def _stop(args: argparse.Namespace, paths: StatePaths) -> int:
    _print(StateClient(paths, timeout=args.timeout).control("shutdown"))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="claude-rescue-state",
        description="Publish and inspect durable claude-rescue state events.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    publish = commands.add_parser("publish", help="commit an event or spool it while the owner is down")
    publish.add_argument("--source", required=True)
    publish.add_argument("--kind", required=True)
    publish.add_argument("--epoch")
    publish.add_argument("--pane-uuid")
    publish.add_argument("--session-id")
    publish.add_argument("--event-id")
    publish.add_argument("--occurred-at")
    publish.add_argument("--payload", type=_json_object)
    publish.add_argument("--timeout", type=float, default=0.25)

    publish_window = commands.add_parser(
        "publish-window-event", help="mirror one legacy window JSONL event into the journal"
    )
    publish_window.add_argument("--window-uuid", required=True)
    publish_window.add_argument("--timeout", type=float, default=0.25)

    commands.add_parser("serve", help="run the single-writer State Owner")

    ensure = commands.add_parser("ensure", help="start the State Owner when it is not running")
    ensure.add_argument("--wait", type=float, default=3.0)

    status = commands.add_parser("status", help="show State Owner health and event counts")
    status.add_argument("--timeout", type=float, default=0.25)

    events = commands.add_parser("events", help="stream committed events as JSON lines")
    events.add_argument("--after", type=int, default=0)
    events.add_argument("--limit", type=int, default=100)
    events.add_argument("--timeout", type=float, default=0.25)

    stop = commands.add_parser("stop", help="stop the running State Owner")
    stop.add_argument("--timeout", type=float, default=0.25)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    paths = StatePaths.from_environment()
    try:
        if args.command == "publish":
            return _publish(args, paths)
        if args.command == "publish-window-event":
            return _publish_window_event(args, paths)
        if args.command == "serve":
            return _serve(paths)
        if args.command == "ensure":
            return _ensure(args, paths)
        if args.command == "status":
            return _status(args, paths)
        if args.command == "events":
            return _events(args, paths)
        if args.command == "stop":
            return _stop(args, paths)
    except (OwnerUnavailable, RuntimeError, ValueError, OSError, json.JSONDecodeError) as error:
        print(f"claude-rescue-state: {error}", file=sys.stderr)
        return 1
    parser.error(f"unknown command: {args.command}")
    return 2
