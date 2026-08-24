import json
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from state_owner import Event, EventStore, Publisher, StateClient, StateOwner, StatePaths, spool_event


class OwnerHarness:
    def __init__(self, root: Path):
        self.paths = StatePaths(root / "data", root / "cache")
        self.owner = StateOwner(self.paths)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.owner.serve, args=(self.stop,), daemon=True)

    def start(self) -> None:
        self.thread.start()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if self.paths.socket.exists():
                try:
                    StateClient(self.paths).status()
                    return
                except ConnectionError:
                    pass
            time.sleep(0.01)
        raise RuntimeError("State Owner did not start")

    def close(self) -> None:
        self.stop.set()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise RuntimeError("State Owner did not stop")
        self.owner.close()


class EventStoreTests(unittest.TestCase):
    def test_duplicate_event_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = EventStore(Path(temporary) / "state.db")
            event = Event.create(source="test", kind="session.started", event_id="same-event")
            first = store.append(event)
            second = store.append(event)
            self.assertEqual((1, True), first)
            self.assertEqual((1, False), second)
            self.assertEqual(1, store.status()["event_count"])
            self.assertEqual(0o600, stat.S_IMODE((Path(temporary) / "state.db").stat().st_mode))
            self.assertEqual(0o700, stat.S_IMODE(Path(temporary).stat().st_mode))
            store.close()

    def test_event_id_cannot_be_reused_with_different_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = EventStore(Path(temporary) / "state.db")
            first = Event.create(source="test", kind="session.started", event_id="same-event")
            conflicting = Event.create(source="test", kind="session.ended", event_id="same-event")
            store.append(first)
            with self.assertRaisesRegex(ValueError, "reused with different content"):
                store.append(conflicting)
            self.assertEqual(1, store.status()["event_count"])
            store.close()

    def test_events_are_returned_in_commit_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = EventStore(Path(temporary) / "state.db")
            store.append(Event.create(source="test", kind="first"))
            store.append(Event.create(source="test", kind="second"))
            self.assertEqual(["first", "second"], [event["kind"] for event in store.events()])
            store.close()


class StateOwnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.harnesses: list[OwnerHarness] = []

    def tearDown(self) -> None:
        for harness in reversed(self.harnesses):
            harness.close()
        self.temporary.cleanup()

    def start_owner(self) -> OwnerHarness:
        harness = OwnerHarness(self.root)
        harness.start()
        self.harnesses.append(harness)
        return harness

    def test_unavailable_owner_spools_then_replays(self) -> None:
        paths = StatePaths(self.root / "data", self.root / "cache")
        event = Event.create(source="test", kind="session.started")
        result = Publisher(paths, timeout=0.01).publish(event)
        self.assertEqual("spooled", result["status"])
        self.assertTrue((paths.spool / f"{event.event_id}.json").is_file())
        self.assertEqual(0o700, stat.S_IMODE(paths.spool.stat().st_mode))

        self.start_owner()
        status = StateClient(paths).status()
        self.assertEqual(1, status["event_count"])
        self.assertEqual([], list(paths.spool.glob("*.json")))

    def test_live_publish_and_query(self) -> None:
        harness = self.start_owner()
        event = Event.create(
            source="claude-hook",
            kind="session.started",
            pane_uuid="pane-1",
            session_id="session-1",
            payload={"cwd": "/tmp/work"},
        )
        result = Publisher(harness.paths).publish(event)
        self.assertEqual("committed", result["status"])
        response = StateClient(harness.paths).events()
        self.assertEqual("session.started", response["events"][0]["kind"])
        self.assertEqual({"cwd": "/tmp/work"}, response["events"][0]["payload"])

    def test_client_disconnect_after_publish_does_not_stop_owner(self) -> None:
        harness = self.start_owner()
        event = Event.create(source="test", kind="client.disconnected")
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(str(harness.paths.socket))
        request = {"operation": "publish", "event": event.to_mapping()}
        connection.sendall(json.dumps(request).encode() + b"\n")
        connection.close()

        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if StateClient(harness.paths).status()["event_count"] == 1:
                break
            time.sleep(0.02)
        self.assertEqual(1, StateClient(harness.paths).status()["event_count"])

    def test_concurrent_publishers_do_not_lose_events(self) -> None:
        harness = self.start_owner()
        events = [
            Event.create(source="test", kind="pane.observed", event_id=f"event-{index}")
            for index in range(50)
        ]

        with ThreadPoolExecutor(max_workers=16) as executor:
            results = list(executor.map(lambda event: Publisher(harness.paths, timeout=2).publish(event), events))

        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if StateClient(harness.paths).status()["event_count"] == len(events):
                break
            time.sleep(0.02)
        self.assertEqual(len(events), StateClient(harness.paths).status()["event_count"])
        self.assertTrue(all(result["status"] in {"committed", "spooled"} for result in results))

    def test_committed_spool_duplicate_is_removed(self) -> None:
        harness = self.start_owner()
        event = Event.create(source="test", kind="pane.focused", event_id="replayed-event")
        Publisher(harness.paths).publish(event)
        spool_event(harness.paths.spool, event)

        deadline = time.monotonic() + 2
        target = harness.paths.spool / f"{event.event_id}.json"
        while target.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(target.exists())
        self.assertEqual(1, StateClient(harness.paths).status()["event_count"])

    def test_second_owner_cannot_take_the_single_writer_lock(self) -> None:
        harness = self.start_owner()
        second = StateOwner(harness.paths)
        try:
            with self.assertRaisesRegex(RuntimeError, "already running"):
                second.serve(threading.Event())
        finally:
            second.close()
        self.assertEqual(0, StateClient(harness.paths).status()["event_count"])

    def test_long_cache_path_uses_short_socket_fallback(self) -> None:
        long_cache = self.root / ("very-long-cache-segment-" * 8)
        paths = StatePaths(self.root / "data", long_cache)
        self.assertLess(len(str(paths.socket).encode()), 100)

    def test_malformed_spool_is_quarantined(self) -> None:
        paths = StatePaths(self.root / "data", self.root / "cache")
        paths.spool.mkdir(parents=True)
        malformed = paths.spool / "broken.json"
        malformed.write_text("not json")
        self.start_owner()
        self.assertFalse(malformed.exists())
        self.assertTrue((paths.spool / "broken.json.invalid").exists())


if __name__ == "__main__":
    unittest.main()
