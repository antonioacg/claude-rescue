import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from state_owner.capture import CaptureIndex, CapturePolicy, spool_capture


class CaptureIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.index = CaptureIndex(self.root / "state" / "state.db", self.root / "data")
        self.capture = self.root / "pane.txt"

    def tearDown(self) -> None:
        self.index.close()
        self.temporary.cleanup()

    def ingest(
        self, *, content: str, reason: str = "title", epoch: str = "1", observed_at: int = 100
    ):
        self.capture.write_text(content)
        return self.index.ingest(
            self.capture,
            server="default",
            epoch=epoch,
            pane_spec="work:1.0",
            pane_uuid="pane-uuid",
            reason=reason,
            observed_at=observed_at,
        )

    def test_capture_content_is_deduplicated_and_current_is_updated(self) -> None:
        first = self.ingest(content="alpha")
        unchanged = self.ingest(content="alpha")
        changed = self.ingest(content="beta")

        self.assertEqual("first", first["status"])
        self.assertEqual("unchanged", unchanged["status"])
        self.assertEqual("changed", changed["status"])
        status = self.index.status()
        self.assertEqual(2, status["capture_blobs"])
        self.assertEqual(1, status["capture_current"])
        self.assertEqual(2, status["capture_references"])

    def test_floor_capture_updates_current_without_creating_history_reference(self) -> None:
        self.ingest(content="alpha", reason="floor")
        self.ingest(content="beta", reason="floor")
        status = self.index.status()
        self.assertEqual(2, status["capture_blobs"])
        self.assertEqual(0, status["capture_references"])

    def test_epoch_prevents_recycled_pane_spec_from_sharing_current_state(self) -> None:
        first = self.ingest(content="alpha", epoch="1")
        next_epoch = self.ingest(content="alpha", epoch="2")
        self.assertEqual("first", first["status"])
        self.assertEqual("first", next_epoch["status"])
        self.assertEqual(1, self.index.status()["capture_current"])
        self.assertEqual(1, self.index.status()["capture_blobs"])

    def test_release_and_retention_delete_unreferenced_blobs_in_batches(self) -> None:
        self.index.close()
        self.index = CaptureIndex(
            self.root / "state" / "state.db",
            self.root / "data",
            CapturePolicy(
                fine_seconds=0,
                archive_seconds=0,
                archive_bucket_seconds=1,
                orphan_grace_seconds=0,
                batch_size=1,
            ),
        )
        self.ingest(content="alpha", observed_at=1)
        self.ingest(content="beta", observed_at=2)
        self.assertTrue(
            self.index.release_current(server="default", epoch="1", pane_spec="work:1.0")
        )

        first = self.index.maintain(now=100)
        self.assertEqual(1, first["deleted_capture_refs"])
        self.assertEqual(1, first["deleted_capture_blobs"])
        self.assertEqual(1, self.index.status()["capture_references"])
        self.assertEqual(1, self.index.status()["capture_blobs"])

        second = self.index.maintain(now=100)
        self.assertEqual(1, second["deleted_capture_refs"])
        self.assertEqual(1, second["deleted_capture_blobs"])
        self.assertEqual(0, self.index.status()["capture_references"])
        self.assertEqual(0, self.index.status()["capture_blobs"])

    def test_spooled_capture_survives_source_removal_and_replays(self) -> None:
        self.capture.write_text("offline")
        spool = self.root / "state" / "capture-spool"
        entry = spool_capture(
            spool,
            self.capture,
            server="default",
            epoch="1",
            pane_spec="work:1.0",
            pane_uuid="pane-uuid",
            reason="visibility",
            observed_at=100,
        )
        self.capture.unlink()

        result = self.index.drain_spool(spool)
        self.assertEqual({"committed": 1, "invalid": 0}, result)
        self.assertFalse(entry.exists())
        self.assertEqual(1, self.index.status()["capture_blobs"])
        self.assertEqual(1, self.index.status()["capture_references"])


if __name__ == "__main__":
    unittest.main()
