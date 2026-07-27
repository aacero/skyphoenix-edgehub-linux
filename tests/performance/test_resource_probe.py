#!/usr/bin/env python3
"""Unit tests for the fail-closed /proc performance sampler."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from resource_probe import (
    GATE_SPECS,
    MIB,
    MeasurementError,
    ProcReader,
    ProcSnapshot,
    ProcessReading,
    Sample,
    WaylandFirstFrameDetector,
    build_resource_report,
    collect_samples,
    evaluate_gate,
    measure_wayland_first_frame,
    parse_proc_stat,
    summarise_samples,
    write_json_atomic,
)


def _stat_line(
    pid: int,
    command: str,
    parent_pid: int,
    user_ticks: int = 0,
    system_ticks: int = 0,
    child_user_ticks: int = 0,
    child_system_ticks: int = 0,
    start_ticks: int = 1000,
) -> str:
    fields = [
        "S",
        str(parent_pid),
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        str(user_ticks),
        str(system_ticks),
        str(child_user_ticks),
        str(child_system_ticks),
        "20",
        "0",
        "1",
        "0",
        str(start_ticks),
    ]
    return f"{pid} ({command}) " + " ".join(fields) + "\n"


def _make_proc_process(
    root: Path,
    pid: int,
    parent_pid: int,
    *,
    rss_kib: int,
    threads: int,
    user_ticks: int,
    start_ticks: int,
    read_bytes: int,
    write_bytes: int,
    sockets: int = 0,
    regular_fds: int = 0,
) -> None:
    process = root / str(pid)
    (process / "fd").mkdir(parents=True)
    (process / "stat").write_text(
        _stat_line(
            pid,
            "name with ) paren",
            parent_pid,
            user_ticks=user_ticks,
            system_ticks=0,
            start_ticks=start_ticks,
        ),
        encoding="utf-8",
    )
    (process / "status").write_text(
        f"Name:\ttest\nVmRSS:\t{rss_kib} kB\nThreads:\t{threads}\n",
        encoding="utf-8",
    )
    (process / "io").write_text(
        f"rchar: 0\nwchar: 0\nread_bytes: {read_bytes}\nwrite_bytes: {write_bytes}\n",
        encoding="utf-8",
    )
    for index in range(sockets):
        (process / "fd" / str(index)).symlink_to(f"socket:[{100 + index}]")
    for index in range(sockets, sockets + regular_fds):
        target = process / f"regular-{index}"
        target.write_text("x", encoding="utf-8")
        (process / "fd" / str(index)).symlink_to(target)


def _sample(
    elapsed: float,
    cpu_ticks: int,
    rss_mib: float = 100.0,
    identities: tuple[tuple[int, int], ...] = ((123, 1000),),
) -> Sample:
    return Sample(
        monotonic_seconds=1000.0 + elapsed,
        elapsed_seconds=elapsed,
        process_identities=identities,
        cpu_ticks=cpu_ticks,
        rss_bytes=int(rss_mib * MIB),
        threads=4,
        file_descriptors=8,
        socket_descriptors=1,
        read_bytes=int(elapsed) * 10,
        write_bytes=int(elapsed) * 5,
        log_bytes=100 + int(elapsed),
    )


def _gate_metrics(duration: float, cpu: float, rss: float, growth: float = 0.0) -> dict:
    interval = 1.0
    return {
        "observed_duration_seconds": duration,
        "sampling_interval_seconds": interval,
        "sample_count": int(duration) + 1,
        "maximum_sample_gap_seconds": interval,
        "average_cpu_percent": cpu,
        "rss_peak_mib": rss,
        "rss_trend": {"growth_percent": growth},
    }


class FakeClock:
    def __init__(self) -> None:
        self.value = 50.0

    def __call__(self) -> float:
        return self.value

    def sleep(self, seconds: float) -> None:
        self.value += seconds


class ScriptedSource:
    clock_ticks_per_second = 100

    def __init__(self, snapshots: list[ProcSnapshot]) -> None:
        self.snapshots = snapshots
        self.index = 0

    def snapshot(self, _root_pid: int, _log_path: Path | None = None) -> ProcSnapshot:
        if self.index >= len(self.snapshots):
            raise MeasurementError("scripted source exhausted")
        result = self.snapshots[self.index]
        self.index += 1
        return result


def _reading(pid: int, start: int, ticks: int, parent: int = 1) -> ProcessReading:
    return ProcessReading(
        pid=pid,
        parent_pid=parent,
        start_ticks=start,
        cpu_ticks=ticks,
        rss_bytes=20 * MIB,
        threads=2,
        file_descriptors=3,
        socket_descriptors=1,
        read_bytes=ticks * 10,
        write_bytes=ticks * 5,
    )


class ProcParsingTests(unittest.TestCase):
    def test_stat_parser_handles_spaces_and_closing_parentheses(self) -> None:
        parsed = parse_proc_stat(
            _stat_line(
                42,
                "odd name ) ok",
                7,
                user_ticks=11,
                system_ticks=13,
                child_user_ticks=5,
                child_system_ticks=7,
                start_ticks=999,
            )
        )
        self.assertEqual(parsed.pid, 42)
        self.assertEqual(parsed.parent_pid, 7)
        self.assertEqual(parsed.cpu_ticks, 36)
        self.assertEqual(parsed.start_ticks, 999)

    def test_stat_parser_rejects_truncated_input(self) -> None:
        with self.assertRaises(MeasurementError):
            parse_proc_stat("42 (short) S 1 2\n")

    def test_proc_reader_aggregates_only_root_and_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            _make_proc_process(
                proc,
                100,
                1,
                rss_kib=10_000,
                threads=3,
                user_ticks=20,
                start_ticks=500,
                read_bytes=100,
                write_bytes=200,
                sockets=1,
                regular_fds=2,
            )
            _make_proc_process(
                proc,
                101,
                100,
                rss_kib=5_000,
                threads=2,
                user_ticks=7,
                start_ticks=600,
                read_bytes=50,
                write_bytes=75,
                sockets=2,
                regular_fds=1,
            )
            _make_proc_process(
                proc,
                900,
                1,
                rss_kib=99_000,
                threads=20,
                user_ticks=99,
                start_ticks=700,
                read_bytes=999,
                write_bytes=999,
            )
            log = proc / "hub.log"
            log.write_bytes(b"abc")
            snapshot = ProcReader(proc).snapshot(100, log)

            self.assertEqual([reading.pid for reading in snapshot.processes], [100, 101])
            self.assertEqual(sum(reading.rss_bytes for reading in snapshot.processes), 15_000 * 1024)
            self.assertEqual(sum(reading.cpu_ticks for reading in snapshot.processes), 27)
            self.assertEqual(sum(reading.socket_descriptors for reading in snapshot.processes), 3)
            self.assertEqual(sum(reading.file_descriptors for reading in snapshot.processes), 6)
            self.assertEqual(snapshot.log_bytes, 3)

    def test_proc_reader_fails_when_required_status_metric_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            _make_proc_process(
                proc,
                100,
                1,
                rss_kib=10,
                threads=1,
                user_ticks=0,
                start_ticks=1,
                read_bytes=0,
                write_bytes=0,
            )
            (proc / "100" / "status").write_text("Name:\ttest\nThreads:\t1\n", encoding="utf-8")
            with self.assertRaisesRegex(MeasurementError, "VmRSS"):
                ProcReader(proc).snapshot(100)

    def test_proc_reader_fails_when_root_is_absent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(MeasurementError, "root process"):
                ProcReader(Path(temporary)).snapshot(999)


class CollectionTests(unittest.TestCase):
    def test_collection_uses_complete_stable_tree(self) -> None:
        snapshots = [
            ProcSnapshot((_reading(10, 100, ticks), _reading(11, 200, ticks // 2, 10)), ticks)
            for ticks in (0, 10, 20)
        ]
        clock = FakeClock()
        observed = []
        samples = collect_samples(
            ScriptedSource(snapshots),
            10,
            2.0,
            1.0,
            clock=clock,
            sleeper=clock.sleep,
            on_sample=lambda sample: observed.append(sample.elapsed_seconds),
        )
        self.assertEqual(len(samples), 3)
        self.assertEqual(samples[-1].elapsed_seconds, 2.0)
        self.assertEqual(samples[-1].cpu_ticks, 30)
        self.assertEqual(samples[-1].rss_bytes, 40 * MIB)
        self.assertEqual(observed, [0.0, 1.0, 2.0])

    def test_collection_rejects_descendant_churn(self) -> None:
        snapshots = [
            ProcSnapshot((_reading(10, 100, 0),), 0),
            ProcSnapshot((_reading(10, 100, 10), _reading(11, 200, 0, 10)), 1),
        ]
        clock = FakeClock()
        with self.assertRaisesRegex(MeasurementError, "process tree changed"):
            collect_samples(
                ScriptedSource(snapshots),
                10,
                1.0,
                1.0,
                clock=clock,
                sleeper=clock.sleep,
            )

    def test_collection_rejects_reused_root_pid(self) -> None:
        snapshots = [
            ProcSnapshot((_reading(10, 100, 0),), 0),
            ProcSnapshot((_reading(10, 999, 10),), 1),
        ]
        clock = FakeClock()
        with self.assertRaisesRegex(MeasurementError, "process tree changed"):
            collect_samples(
                ScriptedSource(snapshots),
                10,
                1.0,
                1.0,
                clock=clock,
                sleeper=clock.sleep,
            )


class GateTests(unittest.TestCase):
    def test_idle_gate_passes_real_five_minute_window(self) -> None:
        samples = [_sample(float(second), second // 2) for second in range(301)]
        report = build_resource_report(
            "idle-5m", samples, 100, 0, "start", "end"
        )
        self.assertTrue(report["qualified"])
        self.assertEqual(report["status"], "PASS")
        self.assertAlmostEqual(report["metrics"]["average_cpu_percent"], 0.5)
        self.assertTrue(report["metrics"]["duration_qualifications"]["five_minutes"])
        self.assertFalse(report["metrics"]["duration_qualifications"]["twenty_four_hours"])

    def test_active_gate_requires_exactly_ten_widgets(self) -> None:
        metrics = _gate_metrics(300.0, 4.0, 200.0)
        self.assertEqual(evaluate_gate(metrics, GATE_SPECS["active-10x5m"], 10), [])
        failures = evaluate_gate(metrics, GATE_SPECS["active-10x5m"], 9)
        self.assertTrue(any("exactly 10" in failure for failure in failures))

    def test_limits_are_strictly_below_not_less_than_or_equal(self) -> None:
        metrics = _gate_metrics(300.0, 1.0, 450.0)
        failures = evaluate_gate(metrics, GATE_SPECS["idle-5m"], 0)
        self.assertTrue(any("average CPU" in failure for failure in failures))
        self.assertTrue(any("peak RSS" in failure for failure in failures))

    def test_short_duration_and_sparse_sampling_fail_closed(self) -> None:
        metrics = _gate_metrics(299.0, 0.1, 50.0)
        metrics["sample_count"] = 2
        metrics["maximum_sample_gap_seconds"] = 299.0
        failures = evaluate_gate(metrics, GATE_SPECS["idle-5m"], 0)
        self.assertTrue(any("below required" in failure for failure in failures))
        self.assertTrue(any("samples" in failure for failure in failures))
        self.assertTrue(any("sample gap" in failure for failure in failures))

    def test_24h_gate_cannot_be_qualified_by_short_trend(self) -> None:
        metrics = _gate_metrics(300.0, 0.1, 50.0, growth=0.0)
        failures = evaluate_gate(metrics, GATE_SPECS["idle-24h"], 0)
        self.assertTrue(any("86400.000s" in failure for failure in failures))

    def test_24h_growth_limit_is_strict(self) -> None:
        metrics = _gate_metrics(86_400.0, 0.5, 100.0, growth=10.0)
        failures = evaluate_gate(metrics, GATE_SPECS["idle-24h"], 0)
        self.assertTrue(any("RSS growth" in failure for failure in failures))
        metrics["rss_trend"]["growth_percent"] = 9.999
        self.assertEqual(evaluate_gate(metrics, GATE_SPECS["idle-24h"], 0), [])

    def test_duration_flags_report_48_hours_without_simulation(self) -> None:
        samples = [_sample(0.0, 0), _sample(172_800.0, 100)]
        metrics = summarise_samples(samples, 100, 172_800.0, 172_800.0)
        self.assertTrue(metrics["duration_qualifications"]["twenty_four_hours"])
        self.assertTrue(metrics["duration_qualifications"]["forty_eight_hours"])

    def test_48h_report_cannot_hide_a_failed_24h_checkpoint(self) -> None:
        samples = [_sample(0.0, 0), _sample(86_400.0, 10), _sample(172_800.0, 20)]
        full_metrics = _gate_metrics(172_800.0, 0.1, 80.0, growth=1.0)
        full_metrics["duration_qualifications"] = {
            "five_minutes": True,
            "twenty_four_hours": True,
            "forty_eight_hours": True,
        }
        checkpoint_metrics = _gate_metrics(86_400.0, 0.1, 80.0, growth=11.0)
        with mock.patch(
            "resource_probe.summarise_samples",
            side_effect=(full_metrics, checkpoint_metrics),
        ):
            report = build_resource_report(
                "idle-48h", samples, 100, 0, "start", "end"
            )
        self.assertFalse(report["qualified"])
        self.assertEqual(report["metrics"]["twenty_four_hour_checkpoint"]["status"], "FAIL")
        self.assertTrue(any("24-hour checkpoint" in item for item in report["failures"]))


class StartupObserverTests(unittest.TestCase):
    def test_non_null_attach_then_commit_is_first_frame(self) -> None:
        detector = WaylandFirstFrameDetector()
        self.assertFalse(
            detector.feed("[1.000]  -> wl_surface#21.attach(wl_buffer#33, 0, 0)")
        )
        self.assertTrue(detector.feed("[1.010]  -> wl_surface#21.commit()"))

    def test_null_attach_and_compositor_events_do_not_qualify(self) -> None:
        detector = WaylandFirstFrameDetector()
        detector.feed("[1.000]  -> wl_surface@4.attach(nil, 0, 0)")
        self.assertFalse(detector.feed("[1.010]  -> wl_surface@4.commit()"))
        detector.feed("[1.020] wl_surface@4.enter(wl_output@2)")
        self.assertFalse(detector.feed("[1.030]  -> wl_surface@4.commit()"))

    def test_attach_on_one_surface_does_not_qualify_another(self) -> None:
        detector = WaylandFirstFrameDetector()
        detector.feed("[1.000]  -> wl_surface#1.attach(wl_buffer#8, 0, 0)")
        self.assertFalse(detector.feed("[1.010]  -> wl_surface#2.commit()"))

    def test_process_observer_records_qualified_buffer_commit(self) -> None:
        program = (
            "import sys,time; "
            "print('[1.0] -> wl_surface#3.attach(wl_buffer#4, 0, 0)', flush=True); "
            "print('[1.1] -> wl_surface#3.commit()', flush=True); "
            "time.sleep(10)"
        )
        with tempfile.TemporaryDirectory() as temporary:
            report = measure_wayland_first_frame(
                [sys.executable, "-c", program],
                {},
                Path(temporary),
                Path(temporary) / "startup.log",
                timeout_seconds=1.0,
            )
        self.assertTrue(report["qualified"])
        self.assertEqual(report["evidence_type"], "wayland-non-null-buffer-commit")
        self.assertLess(report["metrics"]["first_render_upper_bound_seconds"], 1.0)

    def test_process_observer_fails_when_process_exits_without_frame(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report = measure_wayland_first_frame(
                [sys.executable, "-c", "print('not a frame', flush=True)"],
                {},
                Path(temporary),
                Path(temporary) / "startup.log",
                timeout_seconds=1.0,
            )
        self.assertFalse(report["qualified"])
        self.assertTrue(any("before a frame commit" in item for item in report["failures"]))


class EvidenceTests(unittest.TestCase):
    def test_atomic_json_write_replaces_complete_document(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "evidence.json"
            write_json_atomic(path, {"qualified": False, "value": 1})
            write_json_atomic(path, {"qualified": True, "value": 2})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["value"], 2)
            self.assertEqual(list(Path(temporary).glob("*.tmp")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
