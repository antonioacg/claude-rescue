import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from state_owner.archive import ArchiveIndex, ArchivePolicy, spool_archive_checkpoint


class ArchiveIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "state" / "state.db"
        self.archive = self.root / "archive"
        self.policy = ArchivePolicy(
            fine_seconds=60,
            medium_seconds=600,
            medium_bucket_seconds=60,
            coarse_seconds=3600,
            coarse_bucket_seconds=600,
            archive_seconds=7200,
            archive_bucket_seconds=1800,
            blob_seconds=300,
            orphan_grace_seconds=60,
            batch_size=100,
        )
        self.index = ArchiveIndex(self.database, self.archive, self.policy)
        self.source = self.root / "resurrect"
        self.source.mkdir()

    def tearDown(self) -> None:
        self.index.close()
        self.temporary.cleanup()

    def checkpoint(self, timestamp: int, *, content: bytes = b"pane-content") -> Path:
        stamp = datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y%m%dT%H%M%S")
        state = self.source / f"tmux_resurrect_{stamp}.txt"
        state.write_text("pane\ttest\n")
        state.with_suffix(".claude-userops.tsv").write_text("pane\ttest\n")
        (self.source / "pane_contents.tar.gz").write_bytes(content)
        os.utime(state, (timestamp, timestamp))
        return state

    def test_ingest_hardlinks_state_and_deduplicates_capture_blob(self) -> None:
        now = 2_000_000_000
        first = self.index.ingest(self.checkpoint(now, content=b"same"), now=now)
        second = self.index.ingest(self.checkpoint(now + 1, content=b"same"), now=now + 1)

        archived = self.archive / "saves" / f"{first['save_name']}.txt"
        self.assertTrue(archived.is_file())
        self.assertGreaterEqual(archived.stat().st_nlink, 2)
        self.assertEqual(first["capture_hash"], second["capture_hash"])
        self.assertEqual(1, self.index.status()["archive_blobs"])
        self.assertEqual(2, self.index.status()["archive_saves"])

    def test_same_timestamp_from_different_servers_keeps_both_checkpoints(self) -> None:
        now = 2_000_000_000
        states = []
        for server, content in (("server-a", "state-a"), ("server-b", "state-b")):
            directory = self.root / server
            directory.mkdir()
            state = directory / "tmux_resurrect_20330518T033320.txt"
            state.write_text(content)
            states.append(self.index.ingest(state, now=now))

        self.assertNotEqual(states[0]["save_name"], states[1]["save_name"])
        self.assertEqual(2, self.index.status()["archive_saves"])
        archived = {
            (self.archive / "saves" / f"{result['save_name']}.txt").read_text()
            for result in states
        }
        self.assertEqual({"state-a", "state-b"}, archived)

    def test_unreferenced_blob_survives_grace_then_is_collected(self) -> None:
        # Two checkpoints land in the same medium bucket, so retention thins one
        # of them. The thinned save takes its .pane_contents.hash with it, which
        # leaves that save's blob unreachable — nothing can ever reference it
        # again, and it must not sit on disk until blob_seconds elapses.
        now = 2_000_000_000
        self.index.ingest(self.checkpoint(now - 120, content=b"kept"), now=now)
        self.index.ingest(self.checkpoint(now - 130, content=b"thinned"), now=now)
        self.assertEqual(2, self.index.status()["archive_blobs"])

        maintained = self.index.maintain(now=now)
        self.assertEqual(1, maintained["deleted_saves"])
        # Still inside the grace window: ingest writes the blob row before the
        # save row, so collecting here could race a blob about to be referenced.
        self.assertEqual(0, maintained["deleted_blobs"])
        self.assertEqual(2, self.index.status()["archive_blobs"])

        maintained = self.index.maintain(now=now + self.policy.orphan_grace_seconds + 1)
        self.assertEqual(1, maintained["deleted_blobs"])
        self.assertEqual(1, self.index.status()["archive_blobs"])

        # The row and the file go together — a collected blob must not linger
        # on disk as an untracked orphan.
        surviving = list((self.archive / "blobs").iterdir())
        self.assertEqual(1, len(surviving))
        self.assertEqual(b"kept", surviving[0].read_bytes())

    def test_referenced_blob_outlives_the_grace_window(self) -> None:
        # The unreferenced arm must not touch a blob a live save still points at.
        now = 2_000_000_000
        self.index.ingest(self.checkpoint(now, content=b"referenced"), now=now)

        maintained = self.index.maintain(now=now + self.policy.orphan_grace_seconds + 1)
        self.assertEqual(0, maintained["deleted_blobs"])
        self.assertEqual(1, self.index.status()["archive_blobs"])

    def test_retention_keeps_each_servers_checkpoint_in_shared_bucket(self) -> None:
        now = 2_000_000_000
        timestamp = now - 120
        stamp = datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y%m%dT%H%M%S")
        for server in ("server-a", "server-b"):
            directory = self.root / server
            directory.mkdir()
            state = directory / f"tmux_resurrect_{stamp}.txt"
            state.write_text(server)
            self.index.ingest(state, now=now)

        maintained = self.index.maintain(now=now)
        self.assertEqual(0, maintained["deleted_saves"])
        self.assertEqual(2, self.index.status()["archive_saves"])

    def test_tiered_retention_keeps_one_checkpoint_per_older_bucket(self) -> None:
        now = 2_000_000_000
        offsets = [10, 20, 120, 130, 1200, 1250, 5000, 5100, 8000]
        for offset in offsets:
            self.index.ingest(self.checkpoint(now - offset), now=now)

        result = self.index.maintain(now=now)
        self.assertEqual(4, result["deleted_saves"])
        self.assertEqual(5, self.index.status()["archive_saves"])

    def test_retention_deletes_at_most_one_configured_batch(self) -> None:
        now = 2_000_000_000
        self.index.close()
        self.index = ArchiveIndex(
            self.database,
            self.archive,
            ArchivePolicy(
                fine_seconds=0,
                medium_seconds=0,
                coarse_seconds=0,
                archive_seconds=0,
                blob_seconds=10_000,
                batch_size=2,
            ),
        )
        for offset in range(1, 7):
            self.index.ingest(self.checkpoint(now - offset), now=now)

        result = self.index.maintain(now=now)
        self.assertEqual(2, result["deleted_saves"])
        self.assertEqual(4, self.index.status()["archive_saves"])

    def test_import_indexes_existing_files_without_rewriting_them(self) -> None:
        now = 2_000_000_000
        state = self.checkpoint(now)
        saves = self.archive / "saves"
        blobs = self.archive / "blobs"
        archived = saves / state.name
        archived.write_bytes(state.read_bytes())
        sidecar = saves / f"{state.stem}.claude-userops.tsv"
        sidecar.write_text("pane\ttest\n")
        blob = blobs / "legacy-hash.tar.gz"
        blob.write_bytes(b"legacy")
        (saves / f"{state.stem}.pane_contents.hash").write_text("legacy-hash\n")

        result = self.index.import_existing(now=now)
        self.assertEqual({"saves": 1, "blobs": 1}, result)
        self.assertEqual(1, self.index.status()["archive_saves"])
        self.assertEqual(1, self.index.status()["archive_blobs"])
        self.assertEqual(b"legacy", blob.read_bytes())

    def test_spool_namespaces_same_timestamp_by_server(self) -> None:
        spool = self.root / "state" / "archive-spool"
        entries = []
        for server, content in (("server-a", "state-a"), ("server-b", "state-b")):
            directory = self.root / server
            directory.mkdir()
            state = directory / "tmux_resurrect_20330518T033320.txt"
            state.write_text(content)
            entries.append(spool_archive_checkpoint(spool, state))

        self.assertNotEqual(entries[0].parent, entries[1].parent)
        self.assertEqual({"committed": 2, "invalid": 0}, self.index.drain_spool(spool))
        self.assertEqual(2, self.index.status()["archive_saves"])

    def test_spooled_checkpoint_replays_after_owner_recovery(self) -> None:
        now = 2_000_000_000
        state = self.checkpoint(now, content=b"spooled")
        spool = self.root / "state" / "archive-spool"
        spooled_state = spool_archive_checkpoint(spool, state)
        state.unlink()
        (self.source / "pane_contents.tar.gz").unlink()

        result = self.index.drain_spool(spool)
        self.assertEqual({"committed": 1, "invalid": 0}, result)
        self.assertEqual(1, self.index.status()["archive_saves"])
        self.assertEqual(1, self.index.status()["archive_blobs"])
        self.assertFalse(spooled_state.parent.exists())

    def test_blob_retention_is_index_driven_and_age_bounded(self) -> None:
        now = 2_000_000_000
        result = self.index.ingest(self.checkpoint(now - 1000, content=b"old"), now=now - 1000)
        blob = self.archive / "blobs" / f"{result['capture_hash']}.tar.gz"
        self.assertTrue(blob.exists())

        maintained = self.index.maintain(now=now)
        self.assertEqual(1, maintained["deleted_blobs"])
        self.assertFalse(blob.exists())
        self.assertEqual(0, self.index.status()["archive_blobs"])

    def test_in_flight_spool_entry_is_left_alone(self) -> None:
        # Same race as the Capture spool: the checkpoint writer stages under a
        # leading dot, so a drain firing mid-write must not claim the directory
        # and quarantine a checkpoint that was about to commit.
        spool = self.root / "state" / "archive-spool"
        in_flight = spool / ".default__tmux_resurrect_20260831T105600.4242.abc.tmp"
        in_flight.mkdir(parents=True)
        (in_flight / "tmux_resurrect_20260831T105600.txt").write_text("half-written")

        self.assertEqual({"committed": 0, "invalid": 0}, self.index.drain_spool(spool))
        self.assertTrue(in_flight.is_dir())
        self.assertEqual(0, self.index.status()["archive_saves"])


if __name__ == "__main__":
    unittest.main()
