import io
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rotation_frame_probe import (  # noqa: E402
    calibrate_frame_callbacks,
    dense_commit_cluster,
    parse_buffer_commits,
    qualify_transition,
    summarise_transition,
    WaylandCommitObserver,
)


def calibrated_callbacks(
    timestamps, observer_lags=None, surface="wl_surface#7"
):
    lags = observer_lags or [0.0] * len(timestamps)
    raw = {
        surface: [
            {
                "wayland_timestamp_ms": timestamp,
                "observer_monotonic_ms": timestamp + lag,
            }
            for timestamp, lag in zip(timestamps, lags)
        ]
    }
    return calibrate_frame_callbacks(raw)[0]


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
            {
                **calibrated_callbacks(frames),
                **calibrated_callbacks(
                    [1006.0, 1007.0, 1008.0], surface="wl_surface#8"
                ),
            },
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

    def test_summary_starts_animation_cluster_at_apply_ack(self):
        frames = [1005.0, 1092.0] + [
            1110.0 + 16.6 * index for index in range(35)
        ]
        summary = summarise_transition(
            calibrated_callbacks(frames),
            request_started_ms=1000.0,
            refresh_hz=60.0,
            cluster_started_ms=1100.0,
        )
        self.assertAlmostEqual(summary["first_frame_after_request_ms"], 110.0)
        self.assertLess(summary["interval_ms"]["maximum"], 17.0)
        self.assertEqual(summary["estimated_missed_refreshes"], 0)

    def test_summary_rejects_insufficient_frame_evidence(self):
        with self.assertRaisesRegex(Exception, "fewer than three"):
            summarise_transition(
                calibrated_callbacks([1005.0, 1021.6]),
                request_started_ms=1000.0,
                refresh_hz=60.0,
            )

    def test_protocol_cadence_is_not_compressed_by_reader_timing(self):
        protocol = [1005.0, 1021.6, 1038.2, 1054.8, 1071.4]
        callbacks = calibrated_callbacks(
            protocol, [0.0, 0.8, 0.2, 0.9, 0.4]
        )
        summary = summarise_transition(callbacks, 1000.0, 60.0)
        self.assertAlmostEqual(summary["interval_ms"]["median"], 16.6)
        self.assertEqual(
            summary["frame_callback_timestamps_ms"], protocol
        )

    def test_reader_backlog_invalidates_the_measurement(self):
        raw = {
            "wl_surface#7": [
                {
                    "wayland_timestamp_ms": 1000.0 + 16.6 * index,
                    "observer_monotonic_ms":
                        1000.0 + 16.6 * index + index * 1.1,
                }
                for index in range(5)
            ]
        }
        with self.assertRaisesRegex(Exception, "observer backlog"):
            calibrate_frame_callbacks(raw)

    def test_smooth_full_duration_transition_meets_release_slo(self):
        frames = [1005.0 + 16.67 * index for index in range(34)]
        summary = summarise_transition(
            calibrated_callbacks(frames),
            request_started_ms=1000.0,
            refresh_hz=60.0,
        )
        qualification = qualify_transition(summary, 60.0)
        self.assertTrue(qualification["passed"])
        self.assertTrue(
            all(check["passed"] for check in qualification["checks"])
        )

    def test_short_immediate_transition_fails_release_slo(self):
        frames = [1005.0, 1021.6, 1038.2, 1054.8]
        summary = summarise_transition(
            calibrated_callbacks(frames),
            request_started_ms=1000.0,
            refresh_hz=60.0,
        )
        qualification = qualify_transition(summary, 60.0)
        self.assertFalse(qualification["passed"])
        failed = {
            check["name"]
            for check in qualification["checks"]
            if not check["passed"]
        }
        self.assertIn("animation-span-minimum", failed)

    def test_janky_transition_fails_refresh_normalized_slo(self):
        frames = [1005.0 + 50.0 * index for index in range(12)]
        summary = summarise_transition(
            calibrated_callbacks(frames),
            request_started_ms=1000.0,
            refresh_hz=60.0,
        )
        qualification = qualify_transition(summary, 60.0)
        self.assertFalse(qualification["passed"])
        failed = {
            check["name"]
            for check in qualification["checks"]
            if not check["passed"]
        }
        self.assertIn("effective-callback-rate", failed)
        self.assertIn("p95-frame-interval", failed)
        self.assertIn("missed-refresh-ratio", failed)


if __name__ == "__main__":
    unittest.main()
