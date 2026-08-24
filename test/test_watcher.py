import tempfile
import unittest
from pathlib import Path

from state_owner import CapturePublisher, StatePaths
from state_owner.watcher import PaneState, default_cleaned_title, plan_tick


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
            )
            released = publisher.release(
                server="default",
                epoch="1",
                pane_spec="work:0.0",
            )

            self.assertEqual("spooled", ingested["status"])
            self.assertEqual("spooled", released["status"])
            self.assertEqual(2, len(list(paths.capture_spool.iterdir())))


if __name__ == "__main__":
    unittest.main()
