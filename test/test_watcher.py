import json
import tempfile
import unittest
from collections import OrderedDict
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock, patch

from state_owner import CapturePublisher, StatePaths
from state_owner.watcher import (
    TmuxUnavailable,
    Watcher,
    WatcherConfig,
    WatcherLease,
    parse_tmux_snapshot,
)
from state_owner.watcher_model import (
    PaneState,
    abbreviate_label,
    default_cleaned_title,
    labels_by_window,
    plan_tick,
)


def pane(
    pane_id: str,
    *,
    spec: str | None = None,
    title: str = "task",
    unseen: str = "0",
    active: bool = False,
    visible: bool = False,
) -> PaneState:
    return PaneState(
        pane_id=pane_id,
        pane_spec=spec or f"work:0.{pane_id.removeprefix('%')}",
        pane_uuid=f"pane-{pane_id}",
        window_id="@1",
        window_uuid="window-1",
        window_name="claude",
        command="claude",
        raw_title=title,
        unseen=unseen,
        active=active,
        visible=visible,
        cleaned_title=default_cleaned_title("claude", "claude", title, "host"),
    )


class TitleFormattingTests(unittest.TestCase):
    def test_default_formatter_matches_tmux_title_rules(self) -> None:
        self.assertEqual(
            "Working - claude",
            default_cleaned_title("claude", "claude", "✳ Working", "host"),
        )
        self.assertEqual(
            "api: zsh",
            default_cleaned_title("api", "zsh", "host", "host"),
        )
        self.assertEqual(
            "nvim",
            default_cleaned_title("[tmux] copy mode", "nvim", "host", "host"),
        )

    def test_inactive_label_matches_the_previous_shell_abbreviation(self) -> None:
        self.assertEqual("Wrkng", abbreviate_label("Working - claude"))
        self.assertEqual(
            "RvwPR",
            abbreviate_label("Review PR #1500 against MCP C# SDK - claude"),
        )

    def test_window_label_uses_the_window_active_pane(self) -> None:
        inactive = pane("%1", title="old", active=False)
        active = replace(pane("%2", title="current", active=True), window_id="@1")
        labels = labels_by_window({inactive.pane_id: inactive, active.pane_id: active})

        self.assertEqual("current - claude", labels["@1"].full)
        self.assertEqual("crrnt", labels["@1"].short)


class TmuxSnapshotTests(unittest.TestCase):
    def row(self, *, epoch: str = "1") -> str:
        return "\x1f".join(
            (
                epoch,
                "%1",
                "work:0.0",
                "pane-1",
                "@1",
                "window-1",
                "claude",
                "claude",
                "✳ Working",
                "0",
                "1",
                "1",
                "1",
            )
        )

    def test_snapshot_parses_one_consolidated_tmux_row(self) -> None:
        panes = parse_tmux_snapshot(
            self.row(),
            expected_epoch="1",
            previous={},
            clean_title=lambda window, command, title: default_cleaned_title(
                window, command, title, "host"
            ),
        )
        self.assertEqual(["%1"], list(panes))
        self.assertEqual("Working - claude", panes["%1"].cleaned_title)
        self.assertTrue(panes["%1"].visible)

    def test_snapshot_rejects_a_replaced_tmux_server_epoch(self) -> None:
        with self.assertRaisesRegex(TmuxUnavailable, "Epoch changed"):
            parse_tmux_snapshot(
                self.row(epoch="2"),
                expected_epoch="1",
                previous={},
                clean_title=lambda _window, _command, title: title,
            )

    def test_snapshot_rejects_malformed_rows_instead_of_inventing_deaths(self) -> None:
        with self.assertRaisesRegex(ValueError, "malformed tmux pane row"):
            parse_tmux_snapshot(
                "too\x1ffew",
                expected_epoch="1",
                previous={},
                clean_title=lambda _window, _command, title: title,
            )


class WatcherLeaseTests(unittest.TestCase):
    def test_only_one_watcher_can_hold_a_server_lease(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = WatcherLease(root / "watcher.lock", root / "watcher.pid", expected_commands=())
            second = WatcherLease(root / "watcher.lock", root / "watcher.pid", expected_commands=())
            try:
                self.assertTrue(first.acquire())
                self.assertFalse(second.acquire())
            finally:
                first.release()
                second.release()


class WatcherPlanningTests(unittest.TestCase):
    def test_tick_detects_title_create_death_and_capture_reasons(self) -> None:
        old = pane("%1", title="old")
        dead = pane("%2")
        changed = pane("%1", title="new")
        created = pane("%3")

        plan = plan_tick(
            {old.pane_id: old, dead.pane_id: dead},
            {changed.pane_id: changed, created.pane_id: created},
            first_tick=False,
            now=100,
            last_captured={old.pane_spec: 99},
            visible_floor_seconds=5,
            background_floor_seconds=300,
        )

        self.assertEqual(["%3"], [item.pane_id for item in plan.created])
        self.assertEqual(["%1"], [item.pane_id for item in plan.titles])
        self.assertEqual(["%2"], [item.pane_id for item in plan.died])
        self.assertEqual(
            {"%1": "title", "%3": "created"},
            {item.pane.pane_id: item.reason for item in plan.captures},
        )

    def test_first_tick_suppresses_created_events_but_captures_baseline(self) -> None:
        current = pane("%1")
        plan = plan_tick(
            {},
            {current.pane_id: current},
            first_tick=True,
            now=100,
            last_captured={},
            visible_floor_seconds=5,
            background_floor_seconds=300,
        )
        self.assertEqual((), plan.created)
        self.assertEqual("created", plan.captures[0].reason)

    def test_floor_uses_true_visibility_and_marks_audit_only_capture(self) -> None:
        visible = pane("%1", active=True, visible=True)
        background = pane("%2", active=True, visible=False)
        plan = plan_tick(
            {visible.pane_id: visible, background.pane_id: background},
            {visible.pane_id: visible, background.pane_id: background},
            first_tick=False,
            now=100,
            last_captured={visible.pane_spec: 94, background.pane_spec: 94},
            visible_floor_seconds=5,
            background_floor_seconds=300,
        )
        self.assertEqual(["%1"], [item.pane.pane_id for item in plan.captures])
        self.assertTrue(plan.captures[0].floor_only)
    def test_capture_failure_preserves_the_pending_request(self) -> None:
        current = pane("%1")
        request = plan_tick(
            {},
            {current.pane_id: current},
            first_tick=True,
            now=100,
            last_captured={},
            visible_floor_seconds=5,
            background_floor_seconds=300,
        ).captures[0]
        watcher = object.__new__(Watcher)
        watcher.pending = OrderedDict({current.pane_id: request})
        watcher.config = WatcherConfig(queue_per_tick=1, pace_seconds=0)

        def fail_capture(_request):
            raise RuntimeError("capture failed")

        watcher._capture = fail_capture
        with self.assertRaisesRegex(RuntimeError, "capture failed"):
            watcher._drain_captures({current.pane_id: current})
        self.assertEqual(request, watcher.pending[current.pane_id])


class WatcherStatusTests(unittest.TestCase):
    def test_changed_labels_are_batched_into_one_tmux_process(self) -> None:
        watcher = object.__new__(Watcher)
        watcher.tmux = "/opt/tmux"
        watcher.window_labels = {}
        current = pane("%1", title="Working", active=True)

        with patch("state_owner.watcher.subprocess.run", return_value=Mock(returncode=0)) as run:
            watcher._update_window_labels({current.pane_id: current})
            arguments = run.call_args.args[0]
            self.assertEqual("/opt/tmux", arguments[0])
            self.assertIn("@claude-window-label", arguments)
            self.assertIn("Working - claude", arguments)
            self.assertIn("@claude-window-label-short", arguments)
            self.assertIn("Wrkng", arguments)

            run.reset_mock()
            watcher._update_window_labels({current.pane_id: current})
            run.assert_not_called()

    def test_continuum_due_check_runs_at_most_once_per_interval(self) -> None:
        watcher = object.__new__(Watcher)
        watcher.config = WatcherConfig(continuum_check_seconds=60)
        watcher.continuum_save = Path("/tmp/continuum-save")
        watcher.next_continuum_check = 0
        watcher.children = []

        child = Mock()
        with (
            patch("state_owner.watcher.os.access", return_value=True),
            patch("state_owner.watcher.subprocess.Popen", return_value=child) as popen,
            patch.object(watcher, "_reap_children"),
        ):
            watcher._run_continuum_if_due(100)
            watcher._run_continuum_if_due(101)

        popen.assert_called_once()
        self.assertEqual(160, watcher.next_continuum_check)
        self.assertEqual([child], watcher.children)


class CapturePublisherTests(unittest.TestCase):
    def test_owner_outage_spools_ingest_and_release_through_one_interface(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = StatePaths(root / "data", root / "cache")
            capture = root / "capture.txt"
            capture.write_text("content")
            publisher = CapturePublisher(paths, timeout=0.01)

            ingested = publisher.ingest(
                capture,
                server="default",
                epoch="1",
                pane_spec="work:0.0",
                pane_uuid="pane-1",
                reason="title",
                observed_at=123,
            )
            released = publisher.release(
                server="default",
                epoch="1",
                pane_spec="work:0.0",
                observed_at=124,
            )

            self.assertEqual("spooled", ingested["status"])
            self.assertEqual("spooled", released["status"])
            manifests = [
                json.loads((entry / "manifest.json").read_text())
                for entry in paths.capture_spool.iterdir()
            ]
            self.assertEqual(
                {"ingest": 123, "release": 124},
                {manifest["operation"]: manifest["observed_at"] for manifest in manifests},
            )


if __name__ == "__main__":
    unittest.main()
