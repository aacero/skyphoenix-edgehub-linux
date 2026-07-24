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
import time
from pathlib import Path
from typing import Iterable


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
from run_audit_14_widget_30m import audit_document, _verify_live_load  # noqa: E402
from run_hub_profiles import validate_candidate_build  # noqa: E402


WAYLAND_CALL = re.compile(
    r"^\[(?P<timestamp>[0-9]+(?:\.[0-9]+)?)\].*?"
    r"->\s+(?P<surface>wl_surface[#@][0-9]+)\."
    r"(?P<call>attach|commit)\((?P<arguments>.*)\)\s*$"
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
ACTIVE_MODE = re.compile(r"(?P<width>[0-9]+)x(?P<height>[0-9]+)@(?P<hz>[0-9.]+)\*")


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


def dense_commit_cluster(
    timestamps: Iterable[float],
    request_started_ms: float,
    observation_ms: float = 900.0,
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


def summarise_transition(
    commits_by_surface: dict[str, list[float]],
    request_started_ms: float,
    refresh_hz: float,
) -> dict:
    candidates = [
        (surface, dense_commit_cluster(timestamps, request_started_ms))
        for surface, timestamps in commits_by_surface.items()
    ]
    surface, frames = max(candidates, key=lambda item: len(item[1]), default=("", []))
    if len(frames) < 3:
        raise MeasurementError(
            f"fewer than three rendered frames followed request at {request_started_ms:.3f}ms"
        )
    intervals = [later - earlier for earlier, later in zip(frames, frames[1:])]
    duration = frames[-1] - frames[0]
    nominal_interval = 1000.0 / refresh_hz
    missed_refreshes = sum(
        max(0, round(interval / nominal_interval) - 1) for interval in intervals
    )
    return {
        "surface": surface,
        "frame_count": len(frames),
        "first_frame_after_request_ms": frames[0] - request_started_ms,
        "commit_span_ms": duration,
        "effective_commit_rate_hz": (
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
        "frame_timestamps_ms": frames,
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
    state = audit_document()
    state["appearance"]["orientation"] = "portrait"
    raw_log = output_dir / "wayland.log"
    started_utc = iso_now()

    try:
        instance.write_config(state)
        environment = hub_environment(instance)
        instance.log = raw_log.open("wb", buffering=0)
        instance.proc = subprocess.Popen(
            [str(binary)],
            cwd=REPO,
            env=environment,
            stdout=instance.log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
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

        observed_load = _verify_live_load(instance)
        time.sleep(1.0)
        transitions = []
        for _ in range(cycles):
            transitions.append(set_orientation(instance, state, "landscape"))
            transitions.append(set_orientation(instance, state, "portrait"))

        instance.stop_hub()
        instance.log.close()
        commits = parse_buffer_commits(raw_log.read_text(errors="replace").splitlines())
        for transition in transitions:
            transition["frames"] = summarise_transition(
                commits,
                transition["request_started_monotonic_ms"],
                refresh_hz,
            )

        all_intervals = [
            interval
            for transition in transitions
            for interval in (
                later - earlier
                for earlier, later in zip(
                    transition["frames"]["frame_timestamps_ms"],
                    transition["frames"]["frame_timestamps_ms"][1:],
                )
            )
        ]
        report = {
            "schema_version": 1,
            "evidence_type": "wayland-rotation-buffer-commit-timing",
            "status": "MEASURED",
            "qualified": None,
            "qualification_note": (
                "No release threshold is defined; state reflection is asserted and "
                "frame timing is reported without inventing a pass criterion."
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
                "frame_count": sum(
                    transition["frames"]["frame_count"] for transition in transitions
                ),
            },
        }
        write_json_atomic(output_dir / "report.json", report)
        print(json.dumps(report["aggregate"], indent=2, sort_keys=True))
        return 0
    finally:
        instance.cleanup()
        if getattr(instance, "log", None) and not instance.log.closed:
            instance.log.close()


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
