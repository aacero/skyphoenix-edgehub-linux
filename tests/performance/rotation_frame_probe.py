#!/usr/bin/env python3
"""Measure Hub rotation animation frame commits on the real Wayland output.

The probe uses an isolated Hub config and runtime directory. It changes the
fixed orientation through the same local control protocol as the Manager, then
derives frame timing from the Hub's outgoing non-null wl_buffer commits.
No input is injected and no KScreen setting is changed.
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Iterable, Optional


HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
HARDWARE = REPO / "tests" / "hardware"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HARDWARE))

import e2e_harness as harness  # noqa: E402
from e2e_harness import E2E  # noqa: E402
from resource_probe import (  # noqa: E402
    MeasurementError,
    write_error_report,
    write_json_atomic,
)
from run_audit_14_widget_30m import _appearance, _verify_live_load  # noqa: E402
from run_hub_profiles import validate_candidate_build  # noqa: E402


WAYLAND_CALL = re.compile(
    r"^\[\s*(?P<timestamp>[0-9]+(?:\.[0-9]+)?)\].*?"
    r"->\s+(?P<surface>wl_surface[#@][0-9]+)\."
    r"(?P<call>attach|commit)\((?P<arguments>.*)\)\s*$"
)
WAYLAND_FRAME_REQUEST = re.compile(
    r"^\[\s*(?P<timestamp>[0-9]+(?:\.[0-9]+)?)\].*?"
    r"->\s+(?P<surface>wl_surface[#@][0-9]+)\.frame"
    r"\(new id (?P<callback>wl_callback[#@][0-9]+)\)\s*$"
)
WAYLAND_FRAME_DONE = re.compile(
    r"^\[\s*(?P<timestamp>[0-9]+(?:\.[0-9]+)?)\].*?"
    r"(?<!->\s)(?P<callback>wl_callback[#@][0-9]+)\.done\(.*\)\s*$"
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
ACTIVE_MODE = re.compile(r"(?P<width>[0-9]+)x(?P<height>[0-9]+)@(?P<hz>[0-9.]+)\*")
ROTATION_OBSERVATION_MS = 700.0
ROTATION_FIRST_FRAME_MAX_MS = 150.0
ROTATION_SPAN_MIN_MS = 400.0
ROTATION_SPAN_MAX_MS = 680.0
ROTATION_MIN_CALLBACK_RATE_RATIO = 0.70
ROTATION_P95_MAX_REFRESH_MULTIPLIER = 2.0
ROTATION_MAX_MISSED_REFRESH_RATIO = 0.20
ROTATION_MAX_OBSERVER_LAG_SPREAD_MS = 2.0

# The performance audit deliberately uses widgets driven by the two-second
# metrics poll. That is correct for resource measurement but wrong for
# attributing the end of one rotation animation: an unrelated gauge update can
# keep the single Wayland surface committing after rotation has finished. Use a
# full 14-widget screen made from the same idle, deterministic widget. Repeating
# one type is deliberate: mixing widget implementations lets an unrelated
# widget-local timer or initial transition extend the single Wayland surface's
# callback stream, which makes it impossible to attribute the end to rotation.
# Widget diversity is covered by the render and compositor suites; this probe
# isolates animation cadence while retaining the production 14-tile load.
ROTATION_WIDGET_TYPES = (
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
    "tasks",
)


def rotation_document() -> dict:
    tiles = [
        harness.tile(
            f"rotation-{index:02d}-{widget}",
            widget,
            "0.5x0.5",
        )
        for index, widget in enumerate(ROTATION_WIDGET_TYPES)
    ]
    return harness.doc(
        [harness.page("14-widget rotation", tiles)],
        appearance=_appearance(),
    )


def iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def parse_buffer_commits(lines: Iterable[str]) -> dict[str, list[float]]:
    """Return non-null-buffer commit timestamps grouped by surface."""

    buffered: set[str] = set()
    commits: dict[str, list[float]] = {}
    for line in lines:
        match = WAYLAND_CALL.match(line.rstrip())
        if match is None:
            continue
        surface = match.group("surface")
        if match.group("call") == "attach":
            first = match.group("arguments").split(",", 1)[0].strip().lower()
            if "wl_buffer" in first and "nil" not in first:
                buffered.add(surface)
            else:
                buffered.discard(surface)
            continue
        if surface in buffered:
            commits.setdefault(surface, []).append(float(match.group("timestamp")))
    return commits


class WaylandCommitObserver:
    """Drain a Hub protocol pipe and timestamp commits on the observer clock."""

    def __init__(self, raw_path: Path, event_path: Path) -> None:
        self._raw = raw_path.open("xb", buffering=0)
        self._events = event_path.open("x", encoding="utf-8", buffering=1)
        self._buffered: set[str] = set()
        self._commits: dict[str, list[float]] = {}
        self._pending_callbacks: dict[str, str] = {}
        self._frames: dict[str, list[dict[str, float]]] = {}
        self._error: Optional[BaseException] = None
        self._thread: Optional[threading.Thread] = None

    def start(self, stream) -> None:
        if self._thread is not None:
            raise MeasurementError("Wayland observer was already started")
        self._thread = threading.Thread(
            target=self._drain,
            args=(stream,),
            name="wayland-commit-observer",
            daemon=True,
        )
        self._thread.start()

    def _drain(self, stream) -> None:
        try:
            for raw in iter(stream.readline, b""):
                observed_ms = time.monotonic() * 1000.0
                self._raw.write(raw)
                match = WAYLAND_CALL.match(
                    raw.decode("utf-8", errors="replace").rstrip()
                )
                frame_request = WAYLAND_FRAME_REQUEST.match(
                    raw.decode("utf-8", errors="replace").rstrip()
                )
                frame_done = WAYLAND_FRAME_DONE.match(
                    raw.decode("utf-8", errors="replace").rstrip()
                )
                if frame_request is not None:
                    callback = frame_request.group("callback")
                    surface = frame_request.group("surface")
                    self._pending_callbacks[callback] = surface
                    self._write_event(
                        observed_ms,
                        float(frame_request.group("timestamp")),
                        surface,
                        "frame_request",
                    )
                    continue
                if frame_done is not None:
                    callback = frame_done.group("callback")
                    surface = self._pending_callbacks.pop(callback, None)
                    if surface is not None:
                        self._frames.setdefault(surface, []).append({
                            "observer_monotonic_ms": observed_ms,
                            "wayland_timestamp_ms": float(
                                frame_done.group("timestamp")
                            ),
                        })
                        self._write_event(
                            observed_ms,
                            float(frame_done.group("timestamp")),
                            surface,
                            "frame_done",
                        )
                    continue
                if match is None:
                    continue
                surface = match.group("surface")
                call = match.group("call")
                if call == "attach":
                    first = match.group("arguments").split(",", 1)[0].strip().lower()
                    if "wl_buffer" in first and "nil" not in first:
                        self._buffered.add(surface)
                    else:
                        self._buffered.discard(surface)
                elif surface in self._buffered:
                    self._commits.setdefault(surface, []).append(observed_ms)
                self._write_event(
                    observed_ms,
                    float(match.group("timestamp")),
                    surface,
                    call,
                    non_null_buffer=surface in self._buffered,
                )
        except BaseException as error:
            self._error = error

    def _write_event(
        self,
        observed_ms: float,
        wayland_ms: float,
        surface: str,
        event: str,
        non_null_buffer: Optional[bool] = None,
    ) -> None:
        record = {
            "observer_monotonic_ms": observed_ms,
            "wayland_timestamp_ms": wayland_ms,
            "surface": surface,
            "event": event,
        }
        if non_null_buffer is not None:
            record["non_null_buffer"] = non_null_buffer
        self._events.write(json.dumps(record, sort_keys=True) + "\n")
        self._events.flush()

    def finish(self, stream) -> dict[str, dict[str, list]]:
        if self._thread is not None:
            self._thread.join(timeout=5.0)
            if self._thread.is_alive():
                stream.close()
                raise MeasurementError("Wayland observer did not stop after Hub exit")
        stream.close()
        self._raw.close()
        self._events.flush()
        os.fsync(self._events.fileno())
        self._events.close()
        if self._error is not None:
            raise MeasurementError(f"Wayland observer failed: {self._error}")
        return {
            "commits": {
                surface: list(values) for surface, values in self._commits.items()
            },
            "frame_callbacks": {
                surface: [dict(value) for value in values]
                for surface, values in self._frames.items()
            },
        }

    def close(self) -> None:
        if not self._raw.closed:
            self._raw.close()
        if not self._events.closed:
            self._events.close()


def dense_commit_cluster(
    timestamps: Iterable[float],
    request_started_ms: float,
    observation_ms: float = ROTATION_OBSERVATION_MS,
    maximum_gap_ms: float = 100.0,
) -> list[float]:
    """Find the first dense frame cluster following an orientation request."""

    window = sorted(
        timestamp
        for timestamp in timestamps
        if request_started_ms <= timestamp <= request_started_ms + observation_ms
    )
    best: list[float] = []
    current: list[float] = []
    for timestamp in window:
        if current and timestamp - current[-1] > maximum_gap_ms:
            if len(current) > len(best):
                best = current
            current = []
        current.append(timestamp)
    if len(current) > len(best):
        best = current
    return best


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise MeasurementError("a percentile requires at least one value")
    ordered = sorted(values)
    rank = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[rank]


def calibrate_frame_callbacks(
    frames_by_surface: dict[str, list[dict[str, float]]],
) -> tuple[dict[str, list[dict[str, float]]], dict[str, float]]:
    """Align Wayland timestamps to monotonic time and reject reader backlog.

    Wayland's protocol timestamp preserves the real callback cadence. The
    observer timestamp shares a clock with the orientation request but includes
    pipe-drain delay. Their minimum offset aligns the clocks conservatively;
    variation above the small bound means the reader was backlogged and the
    measurement is invalid instead of optimistically compressing frame gaps.
    """

    samples = [
        sample
        for frames in frames_by_surface.values()
        for sample in frames
    ]
    if len(samples) < 3:
        raise MeasurementError("fewer than three frame callbacks were observed")
    offsets = []
    for sample in samples:
        observer_ms = sample.get("observer_monotonic_ms")
        wayland_ms = sample.get("wayland_timestamp_ms")
        if (
            not isinstance(observer_ms, (int, float))
            or not isinstance(wayland_ms, (int, float))
            or not math.isfinite(float(observer_ms))
            or not math.isfinite(float(wayland_ms))
        ):
            raise MeasurementError("frame callback timestamps are incomplete")
        offsets.append(float(observer_ms) - float(wayland_ms))
    clock_offset_ms = min(offsets)
    lag_spread_ms = max(offsets) - clock_offset_ms
    if lag_spread_ms > ROTATION_MAX_OBSERVER_LAG_SPREAD_MS:
        raise MeasurementError(
            "Wayland observer backlog is too large for frame qualification: "
            f"{lag_spread_ms:.3f}ms > "
            f"{ROTATION_MAX_OBSERVER_LAG_SPREAD_MS:.3f}ms"
        )

    aligned: dict[str, list[dict[str, float]]] = {}
    for surface, frames in frames_by_surface.items():
        aligned[surface] = [
            {
                **sample,
                "aligned_monotonic_ms": (
                    float(sample["wayland_timestamp_ms"]) + clock_offset_ms
                ),
                "observer_lag_above_minimum_ms": (
                    float(sample["observer_monotonic_ms"])
                    - float(sample["wayland_timestamp_ms"])
                    - clock_offset_ms
                ),
            }
            for sample in frames
        ]
    return aligned, {
        "wayland_to_monotonic_offset_ms": clock_offset_ms,
        "observer_lag_spread_ms": lag_spread_ms,
        "maximum_observer_lag_spread_ms":
            ROTATION_MAX_OBSERVER_LAG_SPREAD_MS,
    }


def dense_frame_cluster(
    frames: Iterable[dict[str, float]],
    request_started_ms: float,
    observation_ms: float = ROTATION_OBSERVATION_MS,
    maximum_gap_ms: float = 100.0,
) -> list[dict[str, float]]:
    """Return the first dense post-request cluster using protocol cadence."""

    window = sorted(
        (
            frame
            for frame in frames
            if request_started_ms
            <= frame["aligned_monotonic_ms"]
            <= request_started_ms + observation_ms
        ),
        key=lambda frame: frame["wayland_timestamp_ms"],
    )
    best: list[dict[str, float]] = []
    current: list[dict[str, float]] = []
    for frame in window:
        if (
            current
            and frame["wayland_timestamp_ms"]
            - current[-1]["wayland_timestamp_ms"]
            > maximum_gap_ms
        ):
            if len(current) > len(best):
                best = current
            current = []
        current.append(frame)
    if len(current) > len(best):
        best = current
    return best


def summarise_transition(
    frames_by_surface: dict[str, list[dict[str, float]]],
    request_started_ms: float,
    refresh_hz: float,
    cluster_started_ms: Optional[float] = None,
) -> dict:
    if cluster_started_ms is None:
        cluster_started_ms = request_started_ms
    candidates = [
        (surface, dense_frame_cluster(frames, cluster_started_ms))
        for surface, frames in frames_by_surface.items()
    ]
    surface, frames = max(candidates, key=lambda item: len(item[1]), default=("", []))
    if len(frames) < 3:
        raise MeasurementError(
            "fewer than three rendered frames followed animation start at "
            f"{cluster_started_ms:.3f}ms"
        )
    protocol_timestamps = [
        frame["wayland_timestamp_ms"] for frame in frames
    ]
    observer_timestamps = [
        frame["observer_monotonic_ms"] for frame in frames
    ]
    intervals = [
        later - earlier
        for earlier, later in zip(
            protocol_timestamps, protocol_timestamps[1:]
        )
    ]
    duration = protocol_timestamps[-1] - protocol_timestamps[0]
    nominal_interval = 1000.0 / refresh_hz
    missed_refreshes = sum(
        max(0, round(interval / nominal_interval) - 1) for interval in intervals
    )
    return {
        "surface": surface,
        "frame_callback_count": len(frames),
        # The reader timestamp can only make this latency more conservative.
        # Cadence and duration below use protocol timestamps, so reader backlog
        # cannot compress a janky transition into a pass.
        "first_frame_after_request_ms": (
            observer_timestamps[0] - request_started_ms
        ),
        "observation_span_ms": duration,
        "effective_callback_rate_hz": (
            (len(frames) - 1) * 1000.0 / duration if duration > 0 else None
        ),
        "interval_ms": {
            "minimum": min(intervals),
            "median": statistics.median(intervals),
            "p95": percentile(intervals, 0.95),
            "maximum": max(intervals),
        },
        "interval_count_over_1_5_refreshes": sum(
            interval > nominal_interval * 1.5 for interval in intervals
        ),
        "estimated_missed_refreshes": missed_refreshes,
        "frame_callback_timestamps_ms": protocol_timestamps,
        "frame_callback_observer_timestamps_ms": observer_timestamps,
    }


def qualify_transition(summary: dict, refresh_hz: float) -> dict:
    """Apply the release smoothness SLO to one observed quarter-turn."""

    nominal_interval = 1000.0 / refresh_hz
    interval_count = max(0, summary["frame_callback_count"] - 1)
    missed_refreshes = summary["estimated_missed_refreshes"]
    refresh_opportunities = interval_count + missed_refreshes
    missed_ratio = (
        missed_refreshes / refresh_opportunities
        if refresh_opportunities > 0
        else 1.0
    )
    minimum_callback_rate = refresh_hz * ROTATION_MIN_CALLBACK_RATE_RATIO
    maximum_p95_interval = (
        nominal_interval * ROTATION_P95_MAX_REFRESH_MULTIPLIER
    )
    checks = [
        {
            "name": "first-frame-latency",
            "observed": summary["first_frame_after_request_ms"],
            "maximum": ROTATION_FIRST_FRAME_MAX_MS,
            "passed": (
                summary["first_frame_after_request_ms"]
                <= ROTATION_FIRST_FRAME_MAX_MS
            ),
        },
        {
            "name": "animation-span-minimum",
            "observed": summary["observation_span_ms"],
            "minimum": ROTATION_SPAN_MIN_MS,
            "passed": summary["observation_span_ms"] >= ROTATION_SPAN_MIN_MS,
        },
        {
            "name": "animation-span-maximum",
            "observed": summary["observation_span_ms"],
            "maximum": ROTATION_SPAN_MAX_MS,
            "passed": summary["observation_span_ms"] <= ROTATION_SPAN_MAX_MS,
        },
        {
            "name": "effective-callback-rate",
            "observed": summary["effective_callback_rate_hz"],
            "minimum": minimum_callback_rate,
            "passed": (
                summary["effective_callback_rate_hz"] is not None
                and summary["effective_callback_rate_hz"]
                >= minimum_callback_rate
            ),
        },
        {
            "name": "p95-frame-interval",
            "observed": summary["interval_ms"]["p95"],
            "maximum": maximum_p95_interval,
            "passed": (
                summary["interval_ms"]["p95"] <= maximum_p95_interval
            ),
        },
        {
            "name": "missed-refresh-ratio",
            "observed": missed_ratio,
            "maximum": ROTATION_MAX_MISSED_REFRESH_RATIO,
            "passed": missed_ratio <= ROTATION_MAX_MISSED_REFRESH_RATIO,
        },
    ]
    return {
        "passed": all(check["passed"] for check in checks),
        "checks": checks,
    }


def active_refresh_hz(output_name: str) -> float:
    result = subprocess.run(
        ["kscreen-doctor", "-o"], capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        raise MeasurementError("kscreen-doctor failed while reading the active mode")
    text = ANSI_ESCAPE.sub("", result.stdout)
    blocks = re.split(r"(?=^Output:\s)", text, flags=re.MULTILINE)
    block = next(
        (
            candidate
            for candidate in blocks
            if re.search(rf"^Output:\s+\d+\s+{re.escape(output_name)}(?:\s|$)", candidate)
        ),
        None,
    )
    if block is None:
        raise MeasurementError(f"output {output_name} is absent from kscreen-doctor")
    mode = ACTIVE_MODE.search(block)
    if mode is None:
        raise MeasurementError(f"output {output_name} has no parseable active mode")
    return float(mode.group("hz"))


def hub_environment(instance: E2E) -> dict[str, str]:
    environment = dict(os.environ)
    environment["XDG_CONFIG_HOME"] = instance.cfg
    environment["XDG_RUNTIME_DIR"] = instance.run_dir
    environment["WAYLAND_DEBUG"] = "client"
    harness._abs_wayland_display(environment)
    return environment


def set_orientation(instance: E2E, state: dict, mode: str) -> dict:
    state["appearance"]["orientation"] = mode
    started_ms = time.monotonic() * 1000.0
    reply = instance._ipc({"type": "setUiState", "state": json.dumps(state)})
    acknowledged_ms = time.monotonic() * 1000.0
    if reply.get("type") != "ok":
        raise MeasurementError(f"orientation request was rejected: {reply}")
    time.sleep(1.0)
    reflected = instance._ipc({"type": "getUiState"})
    expected_rotation = 0 if mode == "portrait" else 90
    if reflected.get("rotation") != expected_rotation:
        raise MeasurementError(
            f"{mode} requested but Hub reported rotation {reflected.get('rotation')}"
        )
    return {
        "from": "landscape" if mode == "portrait" else "portrait",
        "to": mode,
        "request_started_monotonic_ms": started_ms,
        "acknowledged_monotonic_ms": acknowledged_ms,
        "ack_latency_ms": acknowledged_ms - started_ms,
        "reported_rotation": reflected.get("rotation"),
    }


def run(binary: Path, output_dir: Path, cycles: int) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    if any(output_dir.iterdir()):
        raise MeasurementError("rotation output directory must be empty")
    if cycles < 1:
        raise MeasurementError("at least one rotation cycle is required")

    harness.HUB = str(binary)
    harness.assert_binaries_current((str(binary),))
    candidate = validate_candidate_build(binary)
    instance = E2E(str(output_dir / "work"))
    refresh_hz = active_refresh_hz(instance.edge_name)
    state = rotation_document()
    state["appearance"]["orientation"] = "portrait"
    raw_log = output_dir / "wayland.log"
    event_log = output_dir / "wayland-events.jsonl"
    request_log = output_dir / "orientation-requests.jsonl"
    started_utc = iso_now()
    observer = WaylandCommitObserver(raw_log, event_log)
    stream = None

    try:
        instance.write_config(state)
        environment = hub_environment(instance)
        instance.proc = subprocess.Popen(
            [str(binary)],
            cwd=REPO,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            bufsize=0,
        )
        assert instance.proc.stdout is not None
        stream = instance.proc.stdout
        observer.start(stream)
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if instance.proc.poll() is not None:
                raise MeasurementError(
                    f"Hub exited during launch with code {instance.proc.returncode}"
                )
            if os.path.exists(instance.sock):
                try:
                    if instance.get_state()["appearance"]["orientation"] == "portrait":
                        break
                except (OSError, KeyError, ValueError):
                    pass
            time.sleep(0.1)
        else:
            raise MeasurementError("Hub control socket did not become ready")

        observed_load = _verify_live_load(
            instance, ROTATION_WIDGET_TYPES
        )
        time.sleep(1.0)
        transitions = []
        with request_log.open("x", encoding="utf-8", buffering=1) as requests:
            for _ in range(cycles):
                for mode in ("landscape", "portrait"):
                    transition = set_orientation(instance, state, mode)
                    transitions.append(transition)
                    requests.write(json.dumps(transition, sort_keys=True) + "\n")
                    requests.flush()
                    os.fsync(requests.fileno())

        instance.stop_hub()
        protocol = observer.finish(stream)
        stream = None
        calibrated_callbacks, observer_calibration = calibrate_frame_callbacks(
            protocol["frame_callbacks"]
        )
        for transition in transitions:
            transition["frames"] = summarise_transition(
                calibrated_callbacks,
                transition["request_started_monotonic_ms"],
                refresh_hz,
                transition["acknowledged_monotonic_ms"],
            )
            transition["smoothness_slo"] = qualify_transition(
                transition["frames"], refresh_hz
            )

        all_intervals = [
            interval
            for transition in transitions
            for interval in (
                later - earlier
                for earlier, later in zip(
                    transition["frames"]["frame_callback_timestamps_ms"],
                    transition["frames"]["frame_callback_timestamps_ms"][1:],
                )
            )
        ]
        qualified = all(
            transition["smoothness_slo"]["passed"]
            for transition in transitions
        )
        report = {
            "schema_version": 2,
            "evidence_type": "wayland-rotation-frame-callback-timing",
            "status": "PASS" if qualified else "FAIL",
            "qualified": qualified,
            "qualification_note": (
                "Every observed quarter-turn must meet the recorded "
                "refresh-normalized response, duration, cadence, and missed-frame "
                "limits."
            ),
            "started_utc": started_utc,
            "completed_utc": iso_now(),
            "candidate": candidate,
            "output": {
                "name": instance.edge_name,
                "geometry": {
                    "x": instance.ex,
                    "y": instance.ey,
                    "width": instance.ew,
                    "height": instance.eh,
                },
                "refresh_hz": refresh_hz,
                "nominal_refresh_interval_ms": 1000.0 / refresh_hz,
            },
            "rotation_observation_window_ms": ROTATION_OBSERVATION_MS,
            "observer_clock_calibration": observer_calibration,
            "smoothness_slo": {
                "first_frame_max_ms": ROTATION_FIRST_FRAME_MAX_MS,
                "animation_span_min_ms": ROTATION_SPAN_MIN_MS,
                "animation_span_max_ms": ROTATION_SPAN_MAX_MS,
                "minimum_callback_rate_ratio":
                    ROTATION_MIN_CALLBACK_RATE_RATIO,
                "p95_interval_max_refresh_multiplier":
                    ROTATION_P95_MAX_REFRESH_MULTIPLIER,
                "maximum_missed_refresh_ratio":
                    ROTATION_MAX_MISSED_REFRESH_RATIO,
                "maximum_observer_lag_spread_ms":
                    ROTATION_MAX_OBSERVER_LAG_SPREAD_MS,
            },
            "load": {
                **observed_load,
            },
            "transition_count": len(transitions),
            "transitions": transitions,
            "aggregate": {
                "interval_ms": {
                    "minimum": min(all_intervals),
                    "median": statistics.median(all_intervals),
                    "p95": percentile(all_intervals, 0.95),
                    "maximum": max(all_intervals),
                },
                "estimated_missed_refreshes": sum(
                    transition["frames"]["estimated_missed_refreshes"]
                    for transition in transitions
                ),
                "frame_callback_count": sum(
                    transition["frames"]["frame_callback_count"]
                    for transition in transitions
                ),
            },
        }
        write_json_atomic(output_dir / "report.json", report)
        print(json.dumps({
            "aggregate": report["aggregate"],
            "qualified": qualified,
        }, indent=2, sort_keys=True))
        return 0 if qualified else 1
    finally:
        instance.cleanup()
        if stream is not None:
            try:
                observer.finish(stream)
            except BaseException:
                pass
        observer.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hub", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=3)
    arguments = parser.parse_args()
    try:
        return run(arguments.hub.resolve(), arguments.output_dir.resolve(), arguments.cycles)
    except BaseException as error:
        arguments.output_dir.mkdir(parents=True, exist_ok=True)
        write_error_report(arguments.output_dir / "error.json", "rotation-frame-timing", error)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
