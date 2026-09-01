import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from state_owner.archive import ArchiveIndex, ArchivePolicy
from state_owner.capture import CaptureIndex, CapturePolicy
from state_owner.retention import Retention, RetentionPolicy


class RetentionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "state" / "state.db"
        self.debug = self.root / "debug"
        self.debug.mkdir()
        self.archive = ArchiveIndex(self.database, self.root / "archive", ArchivePolicy())
        self.captures = CaptureIndex(self.database, self.root, CapturePolicy())
        self.policy = RetentionPolicy(
            hot_keep=3,
            debug_keep_seconds=600,
            interval_seconds=3600,
            file_batch_size=100,
        )
        self.retention = Retention(
            self.database,
            archive=self.archive,
            captures=self.captures,
            debug_dir=self.debug,
            policy=self.policy,
        )
        self.hot = self.root / "resurrect"
        self.hot.mkdir()

    def tearDown(self) -> None:
        self.retention.close()
        self.captures.close()
        self.archive.close()
        self.temporary.cleanup()

    def checkpoint(self, timestamp: int, *, sidecar: bool = True) -> Path:
        stamp = datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y%m%dT%H%M%S")
        state = self.hot / f"tmux_resurrect_{stamp}.txt"
        state.write_text("pane\ttest\n")
        if sidecar:
            state.with_suffix(".claude-userops.tsv").write_text("pane\ttest\n")
        return state

    def states(self) -> set[str]:
        return {path.name for path in self.hot.glob("tmux_resurrect_*.txt")}

    def sidecars(self) -> set[str]:
        return {path.name for path in self.hot.glob("*.claude-userops.tsv")}

    def test_ingest_teaches_retention_where_the_hot_dir_is(self) -> None:
        # Nothing configures the resurrect dir — the owner learns it from the
        # checkpoints it is handed, which is what makes the prune reachable on
        # the default route.
        state = self.checkpoint(2_000_000_000)
        self.archive.ingest(state, now=2_000_000_000)

        # ingest resolves the checkpoint, so the recorded directory is the real
        # path — a symlinked hot dir cannot be recorded twice under two names.
        self.assertEqual(
            {"resurrect": self.hot.resolve()}, self.retention.checkpoint_directories()
        )

    def test_hot_dir_keeps_newest_checkpoints_and_their_sidecars(self) -> None:
        base = 2_000_000_000
        for offset in range(6):
            self.checkpoint(base + offset * 60)
        self.archive.ingest(self.checkpoint(base + 600), now=base)

        result = self.retention.run(now=base)

        self.assertEqual(4, result["deleted_checkpoints"])
        self.assertEqual(4, result["deleted_sidecars"])
        self.assertEqual(self.policy.hot_keep, len(self.states()))
        # A kept checkpoint keeps its sidecar; a dropped one takes it along.
        self.assertEqual(
            {name.replace(".txt", ".claude-userops.tsv") for name in self.states()},
            self.sidecars(),
        )

    def test_sidecars_without_a_checkpoint_are_collected(self) -> None:
        # The leak this module exists to close: tmux-resurrect rotates its own
        # .txt files away, and a prune that only pairs sidecar deletion to
        # checkpoint deletion can never reach the sidecars left behind.
        base = 2_000_000_000
        state = self.checkpoint(base)
        self.archive.ingest(state, now=base)
        for offset in range(1, 21):
            stamp = datetime.fromtimestamp(base - offset * 60, timezone.utc).strftime(
                "%Y%m%dT%H%M%S"
            )
            (self.hot / f"tmux_resurrect_{stamp}.claude-userops.tsv").write_text("stray\n")
        self.assertEqual(21, len(self.sidecars()))

        result = self.retention.run(now=base)

        self.assertEqual(0, result["deleted_checkpoints"])
        self.assertEqual(20, result["deleted_sidecars"])
        self.assertEqual(self.states(), {name.replace(".claude-userops.tsv", ".txt") for name in self.sidecars()})

    def test_restore_target_is_never_evicted(self) -> None:
        base = 2_000_000_000
        oldest = self.checkpoint(base)
        for offset in range(1, 8):
            self.checkpoint(base + offset * 60)
        self.archive.ingest(oldest, now=base)
        # `last` is what a restore actually loads; age must not outrank it.
        (self.hot / "last").symlink_to(oldest.name)

        self.retention.run(now=base)

        self.assertIn(oldest.name, self.states())
        self.assertEqual(self.policy.hot_keep + 1, len(self.states()))

    def test_debug_logs_older_than_the_window_are_dropped(self) -> None:
        import os

        base = 2_000_000_000
        fresh = self.debug / "watcher-2033-05-18.log"
        stale = self.debug / "watcher-2033-05-01.log"
        keep_other = self.debug / "notes.txt"
        for path in (fresh, stale, keep_other):
            path.write_text("row\n")
        os.utime(fresh, (base, base))
        os.utime(stale, (base - 6000, base - 6000))
        os.utime(keep_other, (base - 6000, base - 6000))

        result = self.retention.run(now=base)

        self.assertEqual(1, result["deleted_debug_logs"])
        self.assertTrue(fresh.exists())
        self.assertFalse(stale.exists())
        # Only self-dated .log files are ours to collect.
        self.assertTrue(keep_other.exists())

    def test_due_check_claims_the_interval_once(self) -> None:
        base = 2_000_000_000
        self.archive.ingest(self.checkpoint(base), now=base)

        self.assertNotEqual({}, self.retention.run_if_due(now=base))
        self.assertEqual({}, self.retention.run_if_due(now=base + 60))
        self.assertNotEqual(
            {}, self.retention.run_if_due(now=base + self.policy.interval_seconds)
        )

    def test_every_job_reports_a_counter(self) -> None:
        # A job missing from `run` is exactly how the hot dir stopped being
        # pruned. Pin the full set so a dropped job fails here.
        self.archive.ingest(self.checkpoint(2_000_000_000), now=2_000_000_000)

        result = self.retention.run(now=2_000_000_000)

        self.assertEqual(
            {
                "deleted_saves",
                "deleted_blobs",
                "deleted_capture_refs",
                "deleted_capture_blobs",
                "deleted_checkpoints",
                "deleted_sidecars",
                "deleted_debug_logs",
            },
            set(result),
        )


if __name__ == "__main__":
    unittest.main()
