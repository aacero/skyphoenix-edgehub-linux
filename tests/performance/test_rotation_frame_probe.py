import io
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rotation_frame_probe import (  # noqa: E402
    dense_commit_cluster,
    parse_buffer_commits,
    summarise_transition,
    WaylandCommitObserver,
)


class RotationFrameProbeTest(unittest.TestCase):
    def test_parse_tracks_non_null_buffer_per_surface(self):
        lines = [
            "[ 100.000] -> wl_surface#4.attach(wl_buffer#9, 0, 0)",
            "[ 100.100] -> wl_surface#4.commit()",
            "[101.000] -> wl_surface#5.attach(nil, 0, 0)",
            "[101.100] -> wl_surface#5.commit()",
            "[102.000] -> wl_surface@4.attach(wl_buffer@10, 0, 0)",
            "[102.100] -> wl_surface@4.commit()",
        ]
        self.assertEqual(
            parse_buffer_commits(lines),
            {"wl_surface#4": [100.1], "wl_surface@4": [102.1]},
        )

    def test_dense_cluster_excludes_late_idle_commit(self):
        frames = [1000.0, 1016.6, 1033.2, 1049.8, 1600.0]
        self.assertEqual(
            dense_commit_cluster(frames, 999.0, observation_ms=900.0),
            frames[:4],
        )

    def test_observer_correlates_frame_request_and_done(self):
        protocol = (
            b"[ 100.000] -> wl_surface#4.frame(new id wl_callback#7)\n"
            b"[ 101.000] wl_callback#7.done(123)\n"
            b"[ 102.000] -> wl_surface#4.attach(wl_buffer#9, 0, 0)\n"
            b"[ 102.100] -> wl_surface#4.commit()\n"
            b"[ 103.000] wl_callback#8.done(456)\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stream = io.BytesIO(protocol)
            observer = WaylandCommitObserver(root / "raw.log", root / "events.jsonl")
            observer._drain(stream)
            observed = observer.finish(stream)
        self.assertEqual(len(observed["frame_callbacks"]["wl_surface#4"]), 1)
        self.assertEqual(len(observed["commits"]["wl_surface#4"]), 1)

    def test_summary_reports_observable_frame_timing(self):
        frames = [1005.0, 1021.6, 1038.2, 1054.8, 1088.0]
        summary = summarise_transition(
            {"wl_surface#7": frames, "wl_surface#8": [1006.0]},
            request_started_ms=1000.0,
            refresh_hz=60.0,
        )
        self.assertEqual(summary["surface"], "wl_surface#7")
        self.assertEqual(summary["frame_callback_count"], 5)
        self.assertAlmostEqual(summary["first_frame_after_request_ms"], 5.0)
        self.assertAlmostEqual(summary["interval_ms"]["median"], 16.6)
        self.assertAlmostEqual(summary["interval_ms"]["maximum"], 33.2)
        self.assertEqual(summary["estimated_missed_refreshes"], 1)
        self.assertEqual(summary["interval_count_over_1_5_refreshes"], 1)

    def test_summary_rejects_insufficient_frame_evidence(self):
        with self.assertRaisesRegex(Exception, "fewer than three"):
            summarise_transition(
                {"wl_surface#7": [1005.0, 1021.6]},
                request_started_ms=1000.0,
                refresh_hz=60.0,
            )


if __name__ == "__main__":
    unittest.main()
