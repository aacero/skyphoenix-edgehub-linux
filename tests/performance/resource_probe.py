#!/usr/bin/env python3
"""Fail-closed Linux process-tree resource measurement for release evidence.

The sampler deliberately reads Linux ``/proc`` instead of shelling out to
``ps``.  A report is only qualified when the root process and its complete
descendant set remain identifiable for the whole interval, sampling coverage
is sufficient, and every metric needed by the selected gate is present.

CPU percentages use the usual Linux convention where 100% means one logical
CPU core.  RSS is the sum of the root and all descendants at each sample.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import math
import os
import platform
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Iterable, Optional, Protocol, Sequence


MIB = 1024 * 1024
SCHEMA_VERSION = 1
SAMPLING_INTERVAL_SECONDS = 1.0
STARTUP_LIMIT_SECONDS = 2.0


class MeasurementError(RuntimeError):
    """A required observation could not be made reliably."""


@dataclass(frozen=True, slots=True)
class GateSpec:
    name: str
    minimum_duration_seconds: float
    maximum_average_cpu_percent: float
    maximum_rss_mib: float
    required_widget_count: int
    maximum_rss_growth_percent: Optional[float] = None


# These are release contracts, not tunable benchmark defaults.  In particular,
# no environment variable or CLI flag may shorten the qualifying intervals.
GATE_SPECS = {
    "idle-5m": GateSpec("idle-5m", 300.0, 1.0, 450.0, 0),
    "active-10x5m": GateSpec("active-10x5m", 300.0, 5.0, 480.0, 10),
    "idle-24h": GateSpec("idle-24h", 24.0 * 60.0 * 60.0, 1.0, 450.0, 0, 10.0),
    "idle-48h": GateSpec("idle-48h", 48.0 * 60.0 * 60.0, 1.0, 450.0, 0, 10.0),
}


@dataclass(frozen=True, slots=True)
class ParsedStat:
    pid: int
    parent_pid: int
    state: str
    cpu_ticks: int
    start_ticks: int


@dataclass(frozen=True, slots=True)
class ProcessReading:
    pid: int
    parent_pid: int
    start_ticks: int
    cpu_ticks: int
    rss_bytes: int
    threads: int
    file_descriptors: int
    socket_descriptors: int
    read_bytes: int
    write_bytes: int

    @property
    def identity(self) -> tuple[int, int]:
        return (self.pid, self.start_ticks)


@dataclass(frozen=True, slots=True)
class ProcSnapshot:
    processes: tuple[ProcessReading, ...]
    log_bytes: Optional[int]


@dataclass(frozen=True, slots=True)
class Sample:
    monotonic_seconds: float
    elapsed_seconds: float
    process_identities: tuple[tuple[int, int], ...]
    cpu_ticks: int
    rss_bytes: int
    threads: int
    file_descriptors: int
    socket_descriptors: int
    read_bytes: int
    write_bytes: int
    log_bytes: Optional[int]


class SnapshotSource(Protocol):
    clock_ticks_per_second: int

    def snapshot(self, root_pid: int, log_path: Optional[Path] = None) -> ProcSnapshot:
        ...


def parse_proc_stat(text: str) -> ParsedStat:
    """Parse fields needed from ``/proc/PID/stat``.

    The command name is parenthesised and may itself contain spaces or closing
    parentheses, so splitting the whole line is incorrect.  Linux limits the
    command length but does not forbid those characters.
    """

    opening = text.find("(")
    closing = text.rfind(")")
    if opening <= 0 or closing <= opening or closing + 2 > len(text):
        raise MeasurementError("malformed /proc stat record")
    try:
        pid = int(text[:opening].strip())
    except ValueError as exc:
        raise MeasurementError("non-numeric pid in /proc stat record") from exc
    fields = text[closing + 2 :].split()
    # fields starts at kernel field 3 (state); starttime is kernel field 22.
    if len(fields) < 20:
        raise MeasurementError("truncated /proc stat record")
    try:
        own_ticks = int(fields[11]) + int(fields[12])
        # Reaped children can be born and exit between one-second snapshots.
        # Linux retains their CPU in cutime/cstime; include it so short-lived
        # helper work cannot disappear from the average merely due to timing.
        waited_child_ticks = max(0, int(fields[13])) + max(0, int(fields[14]))
        return ParsedStat(
            pid=pid,
            parent_pid=int(fields[1]),
            state=fields[0],
            cpu_ticks=own_ticks + waited_child_ticks,
            start_ticks=int(fields[19]),
        )
    except (ValueError, IndexError) as exc:
        raise MeasurementError("invalid numeric field in /proc stat record") from exc


def _parse_status(text: str) -> tuple[int, int]:
    values: dict[str, list[str]] = {}
    for line in text.splitlines():
        key, separator, value = line.partition(":")
        if separator:
            values[key] = value.split()
    try:
        rss_tokens = values["VmRSS"]
        thread_tokens = values["Threads"]
        if len(rss_tokens) != 2 or rss_tokens[1] != "kB" or len(thread_tokens) != 1:
            raise ValueError
        rss_bytes = int(rss_tokens[0]) * 1024
        threads = int(thread_tokens[0])
    except (KeyError, ValueError) as exc:
        raise MeasurementError("VmRSS or Threads missing/malformed in /proc status") from exc
    if rss_bytes < 0 or threads <= 0:
        raise MeasurementError("invalid VmRSS or Threads value in /proc status")
    return rss_bytes, threads


def _parse_io(text: str) -> tuple[int, int]:
    values: dict[str, int] = {}
    for line in text.splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            continue
        try:
            values[key] = int(value.strip())
        except ValueError as exc:
            raise MeasurementError("malformed /proc io counter") from exc
    try:
        read_bytes = values["read_bytes"]
        write_bytes = values["write_bytes"]
    except KeyError as exc:
        raise MeasurementError("read_bytes or write_bytes missing in /proc io") from exc
    if read_bytes < 0 or write_bytes < 0:
        raise MeasurementError("negative /proc io counter")
    return read_bytes, write_bytes


class ProcReader:
    """Collect one coherent-enough snapshot of a Linux process tree."""

    def __init__(self, proc_root: Path | str = "/proc", retries: int = 3):
        self.proc_root = Path(proc_root)
        self.retries = retries
        try:
            self.clock_ticks_per_second = int(os.sysconf("SC_CLK_TCK"))
        except (ValueError, OSError) as exc:
            raise MeasurementError("cannot determine Linux clock tick rate") from exc
        if self.clock_ticks_per_second <= 0:
            raise MeasurementError("invalid Linux clock tick rate")

    @staticmethod
    def _read_text(path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise MeasurementError(f"cannot read required proc file: {path}: {exc}") from exc

    def _read_all_stats(self) -> dict[int, ParsedStat]:
        stats: dict[int, ParsedStat] = {}
        try:
            names = os.listdir(self.proc_root)
        except OSError as exc:
            raise MeasurementError(f"cannot enumerate {self.proc_root}: {exc}") from exc
        for name in names:
            if not name.isdigit():
                continue
            path = self.proc_root / name / "stat"
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                # A process can disappear between listdir and read.  Descendant
                # consistency is checked after the tree has been resolved.
                continue
            stat = parse_proc_stat(text)
            if stat.pid != int(name):
                raise MeasurementError(f"pid/path mismatch in {path}")
            stats[stat.pid] = stat
        return stats

    @staticmethod
    def _descendant_ids(stats: dict[int, ParsedStat], root_pid: int) -> set[int]:
        if root_pid not in stats:
            raise MeasurementError(f"root process {root_pid} is not alive")
        selected = {root_pid}
        changed = True
        while changed:
            changed = False
            for pid, stat in stats.items():
                if pid not in selected and stat.parent_pid in selected:
                    selected.add(pid)
                    changed = True
        return selected

    def _read_process(self, stat: ParsedStat) -> ProcessReading:
        base = self.proc_root / str(stat.pid)
        rss_bytes, threads = _parse_status(self._read_text(base / "status"))
        read_bytes, write_bytes = _parse_io(self._read_text(base / "io"))
        try:
            fd_names = os.listdir(base / "fd")
        except OSError as exc:
            raise MeasurementError(f"cannot enumerate file descriptors for pid {stat.pid}: {exc}") from exc
        socket_descriptors = 0
        surviving_descriptors = 0
        for name in fd_names:
            try:
                target = os.readlink(base / "fd" / name)
            except FileNotFoundError:
                # Descriptor churn within the sample is expected.  Do not count
                # an fd that was already closed when its target was inspected.
                continue
            except OSError as exc:
                raise MeasurementError(
                    f"cannot inspect file descriptor {name} for pid {stat.pid}: {exc}"
                ) from exc
            surviving_descriptors += 1
            if target.startswith("socket:["):
                socket_descriptors += 1
        return ProcessReading(
            pid=stat.pid,
            parent_pid=stat.parent_pid,
            start_ticks=stat.start_ticks,
            cpu_ticks=stat.cpu_ticks,
            rss_bytes=rss_bytes,
            threads=threads,
            file_descriptors=surviving_descriptors,
            socket_descriptors=socket_descriptors,
            read_bytes=read_bytes,
            write_bytes=write_bytes,
        )

    def snapshot(self, root_pid: int, log_path: Optional[Path] = None) -> ProcSnapshot:
        last_error: Optional[Exception] = None
        for _attempt in range(self.retries):
            try:
                stats = self._read_all_stats()
                selected = self._descendant_ids(stats, root_pid)
                readings = tuple(self._read_process(stats[pid]) for pid in sorted(selected))
                # Re-read the selected stat records.  This catches PID reuse and
                # a child exiting while its status/io/fd files were collected.
                for reading in readings:
                    current = parse_proc_stat(
                        self._read_text(self.proc_root / str(reading.pid) / "stat")
                    )
                    if current.start_ticks != reading.start_ticks:
                        raise MeasurementError(f"pid {reading.pid} was reused during sampling")
                log_bytes: Optional[int] = None
                if log_path is not None:
                    try:
                        log_bytes = log_path.stat().st_size
                    except OSError as exc:
                        raise MeasurementError(f"cannot stat required log file {log_path}: {exc}") from exc
                return ProcSnapshot(readings, log_bytes)
            except MeasurementError as exc:
                last_error = exc
        assert last_error is not None
        raise MeasurementError(
            f"could not obtain a stable process-tree snapshot after {self.retries} attempts: {last_error}"
        ) from last_error


def _to_sample(snapshot: ProcSnapshot, monotonic_seconds: float, start: float) -> Sample:
    processes = snapshot.processes
    if not processes:
        raise MeasurementError("empty process-tree snapshot")
    return Sample(
        monotonic_seconds=monotonic_seconds,
        elapsed_seconds=monotonic_seconds - start,
        process_identities=tuple(sorted(process.identity for process in processes)),
        cpu_ticks=sum(process.cpu_ticks for process in processes),
        rss_bytes=sum(process.rss_bytes for process in processes),
        threads=sum(process.threads for process in processes),
        file_descriptors=sum(process.file_descriptors for process in processes),
        socket_descriptors=sum(process.socket_descriptors for process in processes),
        read_bytes=sum(process.read_bytes for process in processes),
        write_bytes=sum(process.write_bytes for process in processes),
        log_bytes=snapshot.log_bytes,
    )


def collect_samples(
    source: SnapshotSource,
    root_pid: int,
    duration_seconds: float,
    interval_seconds: float = SAMPLING_INTERVAL_SECONDS,
    log_path: Optional[Path] = None,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
    on_sample: Optional[Callable[[Sample], None]] = None,
) -> list[Sample]:
    """Collect a fixed-duration series, rejecting process-tree ambiguity."""

    if root_pid <= 0:
        raise MeasurementError("root pid must be positive")
    if duration_seconds <= 0 or interval_seconds <= 0:
        raise MeasurementError("duration and interval must be positive")

    before_first = clock()
    first_snapshot = source.snapshot(root_pid, log_path)
    first_time = clock()
    if first_time < before_first:
        raise MeasurementError("monotonic clock moved backwards")
    samples = [_to_sample(first_snapshot, first_time, first_time)]
    if on_sample is not None:
        on_sample(samples[0])
    expected_identities = samples[0].process_identities
    deadline = first_time + duration_seconds

    while True:
        now = clock()
        remaining = deadline - now
        if remaining <= 0:
            break
        sleeper(min(interval_seconds, remaining))
        snapshot = source.snapshot(root_pid, log_path)
        sampled_at = clock()
        if sampled_at <= samples[-1].monotonic_seconds:
            raise MeasurementError("monotonic clock did not advance between samples")
        sample = _to_sample(snapshot, sampled_at, first_time)
        if sample.process_identities != expected_identities:
            raise MeasurementError(
                "process tree changed during the qualifying interval: "
                f"expected {expected_identities}, observed {sample.process_identities}"
            )
        previous = samples[-1]
        for counter_name in ("cpu_ticks", "read_bytes", "write_bytes"):
            if getattr(sample, counter_name) < getattr(previous, counter_name):
                raise MeasurementError(f"aggregate {counter_name} counter moved backwards")
        if (
            sample.log_bytes is not None
            and previous.log_bytes is not None
            and sample.log_bytes < previous.log_bytes
        ):
            raise MeasurementError("measured log file shrank during the interval")
        samples.append(sample)
        if on_sample is not None:
            on_sample(sample)

    if len(samples) < 2:
        raise MeasurementError("fewer than two samples were collected")
    return samples


def _rss_trend(samples: Sequence[Sample]) -> dict[str, float]:
    xs = [sample.elapsed_seconds for sample in samples]
    ys = [sample.rss_bytes / MIB for sample in samples]
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    if denominator <= 0:
        raise MeasurementError("cannot calculate RSS trend without elapsed time")
    slope_mib_per_second = sum(
        (x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)
    ) / denominator
    window = max(1, len(ys) // 5)
    first_median = statistics.median(ys[:window])
    last_median = statistics.median(ys[-window:])
    if first_median <= 0:
        raise MeasurementError("cannot calculate RSS growth from zero initial RSS")
    return {
        "least_squares_mib_per_hour": slope_mib_per_second * 3600.0,
        "first_window_median_mib": first_median,
        "last_window_median_mib": last_median,
        "window_sample_count": window,
        "growth_percent": ((last_median - first_median) / first_median) * 100.0,
    }


def summarise_samples(
    samples: Sequence[Sample],
    clock_ticks_per_second: int,
    requested_duration_seconds: float,
    interval_seconds: float,
) -> dict:
    if len(samples) < 2 or clock_ticks_per_second <= 0:
        raise MeasurementError("insufficient samples or invalid clock tick rate")
    elapsed = samples[-1].elapsed_seconds - samples[0].elapsed_seconds
    if elapsed <= 0:
        raise MeasurementError("non-positive observed duration")
    cpu_tick_delta = samples[-1].cpu_ticks - samples[0].cpu_ticks
    if cpu_tick_delta < 0:
        raise MeasurementError("CPU ticks moved backwards")
    average_cpu = cpu_tick_delta / clock_ticks_per_second / elapsed * 100.0

    interval_cpu: list[float] = []
    gaps: list[float] = []
    for previous, current in zip(samples, samples[1:]):
        gap = current.monotonic_seconds - previous.monotonic_seconds
        if gap <= 0:
            raise MeasurementError("non-positive sample gap")
        gaps.append(gap)
        interval_cpu.append(
            (current.cpu_ticks - previous.cpu_ticks)
            / clock_ticks_per_second
            / gap
            * 100.0
        )

    log_growth: Optional[int] = None
    if samples[0].log_bytes is not None and samples[-1].log_bytes is not None:
        log_growth = samples[-1].log_bytes - samples[0].log_bytes

    return {
        "requested_duration_seconds": requested_duration_seconds,
        "observed_duration_seconds": elapsed,
        "sampling_interval_seconds": interval_seconds,
        "sample_count": len(samples),
        "maximum_sample_gap_seconds": max(gaps),
        "process_count": len(samples[0].process_identities),
        "process_identities": [list(identity) for identity in samples[0].process_identities],
        "average_cpu_percent": average_cpu,
        "maximum_interval_cpu_percent": max(interval_cpu),
        "rss_final_mib": samples[-1].rss_bytes / MIB,
        "rss_peak_mib": max(sample.rss_bytes for sample in samples) / MIB,
        "threads_initial": samples[0].threads,
        "threads_final": samples[-1].threads,
        "threads_peak": max(sample.threads for sample in samples),
        "threads_delta": samples[-1].threads - samples[0].threads,
        "file_descriptors_initial": samples[0].file_descriptors,
        "file_descriptors_final": samples[-1].file_descriptors,
        "file_descriptors_peak": max(sample.file_descriptors for sample in samples),
        "file_descriptors_delta": samples[-1].file_descriptors - samples[0].file_descriptors,
        "socket_descriptors_initial": samples[0].socket_descriptors,
        "socket_descriptors_final": samples[-1].socket_descriptors,
        "socket_descriptors_peak": max(sample.socket_descriptors for sample in samples),
        "socket_descriptors_delta": samples[-1].socket_descriptors - samples[0].socket_descriptors,
        "read_bytes_delta": samples[-1].read_bytes - samples[0].read_bytes,
        "write_bytes_delta": samples[-1].write_bytes - samples[0].write_bytes,
        "log_bytes_delta": log_growth,
        "rss_trend": _rss_trend(samples),
        "duration_qualifications": {
            "five_minutes": elapsed >= 300.0,
            "twenty_four_hours": elapsed >= 24.0 * 60.0 * 60.0,
            "forty_eight_hours": elapsed >= 48.0 * 60.0 * 60.0,
        },
        # Socket-fd count is useful leak evidence but is not a byte counter.
        # The existing NetHub/no-egress suite remains the network-policy gate.
        "network_bytes": None,
        "network_measurement_note": "not available from /proc; socket descriptors are recorded",
        "gpu_usage": None,
        "gpu_measurement_note": "no portable per-process Linux counter is available",
    }


def evaluate_gate(metrics: dict, spec: GateSpec, widget_count: int) -> list[str]:
    """Return every gate failure; an empty list means PASS."""

    failures: list[str] = []
    observed = float(metrics["observed_duration_seconds"])
    interval = float(metrics["sampling_interval_seconds"])
    count = int(metrics["sample_count"])
    if observed + 1e-6 < spec.minimum_duration_seconds:
        failures.append(
            f"observed duration {observed:.3f}s is below required "
            f"{spec.minimum_duration_seconds:.3f}s"
        )
    if interval > SAMPLING_INTERVAL_SECONDS + 1e-9:
        failures.append(
            f"sampling interval {interval:.3f}s exceeds {SAMPLING_INTERVAL_SECONDS:.3f}s"
        )
    expected_count = math.floor(spec.minimum_duration_seconds / interval) + 1
    minimum_count = math.ceil(expected_count * 0.95)
    if count < minimum_count:
        failures.append(f"only {count} samples were collected; at least {minimum_count} are required")
    maximum_gap = float(metrics["maximum_sample_gap_seconds"])
    if maximum_gap > max(interval * 3.0, interval + 0.25):
        failures.append(f"maximum sample gap {maximum_gap:.3f}s is too large")
    average_cpu = float(metrics["average_cpu_percent"])
    if average_cpu >= spec.maximum_average_cpu_percent:
        failures.append(
            f"average CPU {average_cpu:.3f}% is not below {spec.maximum_average_cpu_percent:.3f}%"
        )
    peak_rss = float(metrics["rss_peak_mib"])
    if peak_rss >= spec.maximum_rss_mib:
        failures.append(f"peak RSS {peak_rss:.3f}MiB is not below {spec.maximum_rss_mib:.3f}MiB")
    if widget_count != spec.required_widget_count:
        failures.append(
            f"profile has {widget_count} widgets; exactly {spec.required_widget_count} are required"
        )
    if spec.maximum_rss_growth_percent is not None:
        growth = float(metrics["rss_trend"]["growth_percent"])
        if growth >= spec.maximum_rss_growth_percent:
            failures.append(
                f"RSS growth {growth:.3f}% is not below {spec.maximum_rss_growth_percent:.3f}%"
            )
    return failures


def build_resource_report(
    profile: str,
    samples: Sequence[Sample],
    clock_ticks_per_second: int,
    widget_count: int,
    started_utc: str,
    completed_utc: str,
    interval_seconds: float = SAMPLING_INTERVAL_SECONDS,
    extra_metadata: Optional[dict] = None,
) -> dict:
    try:
        spec = GATE_SPECS[profile]
    except KeyError as exc:
        raise MeasurementError(f"unknown gate profile: {profile}") from exc
    metrics = summarise_samples(
        samples,
        clock_ticks_per_second,
        spec.minimum_duration_seconds,
        interval_seconds,
    )
    failures = evaluate_gate(metrics, spec, widget_count)
    if profile == "idle-48h":
        # A 48-hour release soak also has to be healthy at its first 24-hour
        # boundary; recovery late in day two must not conceal day-one growth.
        checkpoint_end = next(
            (
                index
                for index, sample in enumerate(samples)
                if sample.elapsed_seconds - samples[0].elapsed_seconds >= 24.0 * 60.0 * 60.0
            ),
            None,
        )
        if checkpoint_end is None:
            failures.append("48-hour series has no real 24-hour checkpoint")
            metrics["twenty_four_hour_checkpoint"] = None
        else:
            checkpoint_metrics = summarise_samples(
                samples[: checkpoint_end + 1],
                clock_ticks_per_second,
                GATE_SPECS["idle-24h"].minimum_duration_seconds,
                interval_seconds,
            )
            checkpoint_failures = evaluate_gate(
                checkpoint_metrics, GATE_SPECS["idle-24h"], widget_count
            )
            metrics["twenty_four_hour_checkpoint"] = {
                "status": "PASS" if not checkpoint_failures else "FAIL",
                "failures": checkpoint_failures,
                "metrics": checkpoint_metrics,
            }
            failures.extend(f"24-hour checkpoint: {item}" for item in checkpoint_failures)
    return {
        "schema_version": SCHEMA_VERSION,
        "evidence_type": "linux-proc-process-tree",
        "profile": profile,
        "status": "PASS" if not failures else "FAIL",
        "qualified": not failures,
        "failures": failures,
        "started_utc": started_utc,
        "completed_utc": completed_utc,
        "host": {
            "platform": platform.platform(),
            "logical_cpu_count": os.cpu_count(),
            "clock_ticks_per_second": clock_ticks_per_second,
        },
        "load": {"widget_count": widget_count},
        "limits": asdict(spec),
        "metrics": metrics,
        "metadata": extra_metadata or {},
        "samples": [
            {
                "elapsed_seconds": sample.elapsed_seconds,
                "cpu_ticks": sample.cpu_ticks,
                "rss_bytes": sample.rss_bytes,
                "threads": sample.threads,
                "file_descriptors": sample.file_descriptors,
                "socket_descriptors": sample.socket_descriptors,
                "read_bytes": sample.read_bytes,
                "write_bytes": sample.write_bytes,
                "log_bytes": sample.log_bytes,
            }
            for sample in samples
        ],
    }


def measure_resource_profile(
    root_pid: int,
    profile: str,
    widget_count: int,
    log_path: Optional[Path] = None,
    extra_metadata: Optional[dict] = None,
    source: Optional[SnapshotSource] = None,
    on_sample: Optional[Callable[[Sample], None]] = None,
) -> dict:
    try:
        spec = GATE_SPECS[profile]
    except KeyError as exc:
        raise MeasurementError(f"unknown gate profile: {profile}") from exc
    source = source or ProcReader()
    started = _datetime.datetime.now(_datetime.timezone.utc).isoformat()
    samples = collect_samples(
        source,
        root_pid,
        spec.minimum_duration_seconds,
        SAMPLING_INTERVAL_SECONDS,
        log_path,
        on_sample=on_sample,
    )
    completed = _datetime.datetime.now(_datetime.timezone.utc).isoformat()
    return build_resource_report(
        profile,
        samples,
        source.clock_ticks_per_second,
        widget_count,
        started,
        completed,
        SAMPLING_INTERVAL_SECONDS,
        extra_metadata,
    )


class WaylandFirstFrameDetector:
    """Detect the first non-null wl_buffer attachment followed by a commit."""

    def __init__(self) -> None:
        self._surfaces_with_buffer: set[str] = set()

    @staticmethod
    def _surface_and_call(line: str) -> Optional[tuple[str, str, str]]:
        # Current libwayland debug output uses ``wl_surface#N``; older builds
        # and fixtures can use ``wl_surface@N``.  Only outgoing client calls
        # count, never compositor events printed with the reverse arrow.
        if "->" not in line:
            return None
        arrow = line.split("->", 1)[1].strip()
        for marker in ("wl_surface#", "wl_surface@"):
            start = arrow.find(marker)
            if start < 0:
                continue
            open_paren = arrow.find("(", start)
            dot = arrow.rfind(".", start, open_paren)
            close_paren = arrow.rfind(")")
            if dot < 0 or open_paren < 0 or close_paren < open_paren:
                return None
            surface = arrow[start:dot]
            call = arrow[dot + 1 : open_paren]
            arguments = arrow[open_paren + 1 : close_paren]
            return surface, call, arguments
        return None

    def feed(self, line: str) -> bool:
        parsed = self._surface_and_call(line)
        if parsed is None:
            return False
        surface, call, arguments = parsed
        if call == "attach":
            first_argument = arguments.split(",", 1)[0].strip().lower()
            if "wl_buffer" in first_argument and "nil" not in first_argument:
                self._surfaces_with_buffer.add(surface)
            else:
                self._surfaces_with_buffer.discard(surface)
            return False
        return call == "commit" and surface in self._surfaces_with_buffer


def _terminate_owned_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=3)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=3)


def measure_wayland_first_frame(
    command: Sequence[str],
    environment: dict[str, str],
    working_directory: Path,
    log_path: Path,
    timeout_seconds: float = 10.0,
    clock: Callable[[], float] = time.monotonic,
) -> dict:
    """Measure a conservative upper bound to the first Wayland frame commit.

    ``WAYLAND_DEBUG=client`` exposes the protocol event without modifying the
    application.  Receipt of a non-null buffer attach followed by a commit is
    stronger evidence than socket readiness or root-object construction: the
    client has submitted rendered pixels to the compositor.
    """

    if not command or timeout_seconds <= 0:
        raise MeasurementError("startup command and positive timeout are required")
    env = dict(environment)
    env["WAYLAND_DEBUG"] = "client"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started_utc = _datetime.datetime.now(_datetime.timezone.utc).isoformat()
    started = clock()
    detector = WaylandFirstFrameDetector()
    first_frame_seconds: Optional[float] = None
    failure: Optional[str] = None

    with log_path.open("wb") as log:
        process = subprocess.Popen(
            list(command),
            cwd=working_directory,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            bufsize=0,
        )
        assert process.stdout is not None
        os.set_blocking(process.stdout.fileno(), False)
        pending = b""
        try:
            deadline = started + timeout_seconds
            while clock() < deadline:
                try:
                    chunk = os.read(process.stdout.fileno(), 65536)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    log.write(chunk)
                    log.flush()
                    pending += chunk
                    lines = pending.split(b"\n")
                    pending = lines.pop()
                    for raw_line in lines:
                        if detector.feed(raw_line.decode("utf-8", errors="replace")):
                            first_frame_seconds = clock() - started
                            break
                    if first_frame_seconds is not None:
                        break
                if process.poll() is not None:
                    # Drain anything written just before exit before failing.
                    try:
                        tail = os.read(process.stdout.fileno(), 65536)
                    except (BlockingIOError, OSError):
                        tail = b""
                    if tail:
                        log.write(tail)
                        pending += tail
                        for raw_line in pending.splitlines():
                            if detector.feed(raw_line.decode("utf-8", errors="replace")):
                                first_frame_seconds = clock() - started
                                break
                    if first_frame_seconds is None:
                        failure = f"process exited with code {process.returncode} before a frame commit"
                    break
                time.sleep(0.005)
            if first_frame_seconds is None and failure is None:
                failure = f"no Wayland frame commit observed within {timeout_seconds:.3f}s"
        finally:
            _terminate_owned_process(process)
            process.stdout.close()

    if first_frame_seconds is not None and first_frame_seconds >= STARTUP_LIMIT_SECONDS:
        failure = (
            f"first frame upper bound {first_frame_seconds:.6f}s is not below "
            f"{STARTUP_LIMIT_SECONDS:.3f}s"
        )
    completed_utc = _datetime.datetime.now(_datetime.timezone.utc).isoformat()
    failures = [failure] if failure else []
    return {
        "schema_version": SCHEMA_VERSION,
        "evidence_type": "wayland-non-null-buffer-commit",
        "profile": "startup-first-render",
        "status": "PASS" if not failures else "FAIL",
        "qualified": not failures,
        "failures": failures,
        "started_utc": started_utc,
        "completed_utc": completed_utc,
        "limits": {"maximum_first_render_seconds": STARTUP_LIMIT_SECONDS},
        "metrics": {
            "first_render_upper_bound_seconds": first_frame_seconds,
            "observer_timeout_seconds": timeout_seconds,
        },
        "metadata": {
            "command": list(command),
            "log_path": str(log_path),
            "note": "control-socket readiness is intentionally not accepted as first-render evidence",
        },
    }


def write_json_atomic(path: Path, document: dict) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def write_error_report(path: Path, profile: str, error: BaseException) -> None:
    write_json_atomic(
        path,
        {
            "schema_version": SCHEMA_VERSION,
            "profile": profile,
            "status": "FAIL",
            "qualified": False,
            "failures": [f"{type(error).__name__}: {error}"],
            "completed_utc": _datetime.datetime.now(_datetime.timezone.utc).isoformat(),
        },
    )


def _sample_cli(arguments: argparse.Namespace) -> int:
    output = Path(arguments.output).resolve()
    log_path = Path(arguments.log).resolve() if arguments.log else None
    spec = GATE_SPECS[arguments.profile]
    try:
        report = measure_resource_profile(
            arguments.pid,
            arguments.profile,
            arguments.widgets,
            log_path,
            {"invocation": "attach-to-existing-process"},
        )
    except BaseException as exc:
        write_error_report(output, spec.name, exc)
        print(f"FAIL {spec.name}: {exc}", file=sys.stderr)
        return 1
    write_json_atomic(output, report)
    print(
        f"{report['status']} {spec.name}: CPU={report['metrics']['average_cpu_percent']:.3f}% "
        f"RSS-peak={report['metrics']['rss_peak_mib']:.3f}MiB evidence={output}",
        flush=True,
    )
    for failure in report["failures"]:
        print(f"  {failure}", file=sys.stderr)
    return 0 if report["qualified"] else 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    sample = subparsers.add_parser("sample", help="measure an already-running process tree")
    sample.add_argument("--pid", type=int, required=True)
    sample.add_argument("--profile", choices=sorted(GATE_SPECS), required=True)
    sample.add_argument("--widgets", type=int, required=True)
    sample.add_argument("--log", help="optional process log whose growth must remain observable")
    sample.add_argument("--output", required=True, help="JSON evidence path")
    sample.set_defaults(handler=_sample_cli)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _build_parser().parse_args(argv)
    return int(arguments.handler(arguments))


if __name__ == "__main__":
    raise SystemExit(main())
