#!/usr/bin/env python3
"""Build a compact, semantically complete release-run contract fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import statistics
import sys
from typing import Any


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "scripts"))

from lib import audit_artifact_contract as contract  # noqa: E402


MIB = 1024 * 1024
STARTED = "2026-07-27T00:00:00+00:00"
COMPLETED = "2026-07-27T00:05:01+00:00"
EDGE_OUTPUT = "DP-3"
GEOMETRY = {"x": 0, "y": 1080, "width": 2560, "height": 720}
VERSION = "SkyPhoenix EdgeHub 1.0.0"
BINARY = "/fixture/cmake-build-release-performance/xeneon-edge-hub"
CACHE = "/fixture/cmake-build-release-performance/CMakeCache.txt"


def _write_json(path: pathlib.Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _linear_trend(xs: list[float], ys: list[float]) -> dict[str, float]:
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((value - x_mean) ** 2 for value in xs)
    slope = sum(
        (x - x_mean) * (y - y_mean)
        for x, y in zip(xs, ys, strict=True)
    ) / denominator
    total = sum((value - y_mean) ** 2 for value in ys)
    residual = sum(
        (y - (y_mean + slope * (x - x_mean))) ** 2
        for x, y in zip(xs, ys, strict=True)
    )
    return {
        "per_hour": slope * 3600.0,
        "r_squared": (
            1.0 if total == 0 else max(0.0, 1.0 - residual / total)
        ),
    }


def _rss_trend(observations: list[dict[str, Any]]) -> dict[str, Any]:
    elapsed = [float(item["elapsed_seconds"]) for item in observations]
    rss = [float(item["rss_bytes"]) / MIB for item in observations]
    window = max(1, len(rss) // 5)
    first = statistics.median(rss[:window])
    last = statistics.median(rss[-window:])
    trend = _linear_trend(elapsed, rss)
    return {
        "least_squares_mib_per_hour": trend["per_hour"],
        "first_window_median_mib": first,
        "last_window_median_mib": last,
        "window_sample_count": window,
        "growth_percent": (last - first) / first * 100.0,
    }


def _candidate(commit: str) -> dict[str, Any]:
    return {
        "source_commit": commit,
        "cmake_cache": CACHE,
        "cmake_build_type": "Release",
        "cmake_install_prefix": "/usr",
        "test_targets": "OFF",
        "coverage_instrumentation": "OFF",
        "qa_hooks": "OFF",
        "binary_sha256": "a" * 64,
        "binary_version": VERSION,
    }


def _resource_observations(
    count: int, interval: float, *, audit_trace: bool = False
) -> list[dict[str, Any]]:
    observations: list[dict[str, Any]] = []
    for index in range(count):
        common: dict[str, Any] = {
            "elapsed_seconds": index * interval,
            "cpu_ticks": 1000,
            "rss_bytes": 64 * MIB,
            "threads": 4,
            "file_descriptors": 8,
        }
        if audit_trace:
            common["gpu_memory_mib"] = 32.0
        else:
            common.update(
                {
                    "socket_descriptors": 1,
                    "read_bytes": 0,
                    "write_bytes": 0,
                    "log_bytes": 0,
                }
            )
        observations.append(common)
    return observations


def _resource_metrics(
    observations: list[dict[str, Any]],
    requested_duration: float,
    interval: float,
) -> dict[str, Any]:
    elapsed = float(observations[-1]["elapsed_seconds"]) - float(
        observations[0]["elapsed_seconds"]
    )
    gaps = [
        float(current["elapsed_seconds"]) - float(previous["elapsed_seconds"])
        for previous, current in zip(observations, observations[1:])
    ]
    socket_initial = observations[0].get("socket_descriptors", 1)
    socket_final = observations[-1].get("socket_descriptors", 1)
    read_initial = observations[0].get("read_bytes", 0)
    read_final = observations[-1].get("read_bytes", 0)
    write_initial = observations[0].get("write_bytes", 0)
    write_final = observations[-1].get("write_bytes", 0)
    return {
        "requested_duration_seconds": requested_duration,
        "observed_duration_seconds": elapsed,
        "sampling_interval_seconds": interval,
        "sample_count": len(observations),
        "maximum_sample_gap_seconds": max(gaps),
        "process_count": 1,
        "process_identities": [[42, 100]],
        "average_cpu_percent": 0.0,
        "maximum_interval_cpu_percent": 0.0,
        "rss_final_mib": 64.0,
        "rss_peak_mib": 64.0,
        "threads_initial": observations[0]["threads"],
        "threads_final": observations[-1]["threads"],
        "threads_peak": max(item["threads"] for item in observations),
        "threads_delta": (
            observations[-1]["threads"] - observations[0]["threads"]
        ),
        "file_descriptors_initial": observations[0]["file_descriptors"],
        "file_descriptors_final": observations[-1]["file_descriptors"],
        "file_descriptors_peak": max(
            item["file_descriptors"] for item in observations
        ),
        "file_descriptors_delta": (
            observations[-1]["file_descriptors"]
            - observations[0]["file_descriptors"]
        ),
        "socket_descriptors_initial": socket_initial,
        "socket_descriptors_final": socket_final,
        "socket_descriptors_peak": max(socket_initial, socket_final),
        "socket_descriptors_delta": socket_final - socket_initial,
        "read_bytes_delta": read_final - read_initial,
        "write_bytes_delta": write_final - write_initial,
        "log_bytes_delta": 0,
        "rss_trend": _rss_trend(observations),
        "duration_qualifications": {
            "five_minutes": elapsed >= 300.0,
            "twenty_four_hours": elapsed >= 24.0 * 60.0 * 60.0,
            "forty_eight_hours": elapsed >= 48.0 * 60.0 * 60.0,
        },
        "network_bytes": None,
        "network_measurement_note": (
            "not available from /proc; socket descriptors are recorded"
        ),
        "gpu_usage": None,
        "gpu_measurement_note": (
            "no portable per-process Linux counter is available"
        ),
    }


def _first_render(
    candidate: dict[str, Any], output_root: str, kind: str
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "command": [BINARY],
        "log_path": f"{output_root}/startup-wayland.log",
        "note": (
            "control-socket readiness is intentionally not accepted as "
            "first-render evidence"
        ),
    }
    if kind == "short":
        metadata.update(
            {
                "application": "xeneon-edge-hub",
                "binary": BINARY,
                "git_revision": candidate["source_commit"],
                "mode": "startup",
                "edge_output": EDGE_OUTPUT,
                "edge_geometry": GEOMETRY,
                "warmup_seconds": 30,
                "active_widget_types": [],
                "candidate_build": candidate,
            }
        )
    else:
        metadata.update(
            {
                "candidate": candidate,
                "widget_count": len(contract.AUDIT_14_WIDGET_TYPES),
                "edge_output": EDGE_OUTPUT,
            }
        )
    return {
        "schema_version": 1,
        "evidence_type": "wayland-non-null-buffer-commit",
        "profile": "startup-first-render",
        "status": "PASS",
        "qualified": True,
        "failures": [],
        "started_utc": STARTED,
        "completed_utc": COMPLETED,
        "limits": {"maximum_first_render_seconds": 2.0},
        "metrics": {
            "first_render_upper_bound_seconds": 0.25,
            "observer_timeout_seconds": 10.0,
        },
        "metadata": metadata,
    }


def _short_resource_report(
    profile: str, candidate: dict[str, Any]
) -> dict[str, Any]:
    observations = _resource_observations(301, 1.0)
    active = profile == "active-10x5m"
    widget_types = (
        list(contract.SHORT_ACTIVE_WIDGET_TYPES) if active else []
    )
    max_cpu = 5.0 if active else 1.0
    max_rss = 250.0 if active else 150.0
    widget_count = len(widget_types)
    return {
        "schema_version": 1,
        "evidence_type": "linux-proc-process-tree",
        "profile": profile,
        "status": "PASS",
        "qualified": True,
        "failures": [],
        "started_utc": STARTED,
        "completed_utc": COMPLETED,
        "host": {
            "platform": "Linux fixture",
            "logical_cpu_count": 8,
            "clock_ticks_per_second": 100,
        },
        "load": {"widget_count": widget_count},
        "limits": {
            "name": profile,
            "minimum_duration_seconds": 300.0,
            "maximum_average_cpu_percent": max_cpu,
            "maximum_rss_mib": max_rss,
            "required_widget_count": widget_count,
            "maximum_rss_growth_percent": None,
        },
        "metrics": _resource_metrics(observations, 300.0, 1.0),
        "metadata": {
            "application": "xeneon-edge-hub",
            "binary": BINARY,
            "git_revision": candidate["source_commit"],
            "mode": "active" if active else "idle",
            "edge_output": EDGE_OUTPUT,
            "edge_geometry": GEOMETRY,
            "warmup_seconds": 30,
            "active_widget_types": widget_types,
            "candidate_build": candidate,
            "control_socket_ready_seconds_diagnostic_only": 0.5,
            "control_socket_note": (
                "not accepted as startup-to-first-render evidence"
            ),
            "observed_load": {
                "observed_page_count": 1,
                "observed_widget_count": widget_count,
                "observed_widget_types": widget_types,
                "observed_tile_sizes": ["1x1"] * widget_count,
                "observed_current_page": 0,
                "live_state_verified": True,
            },
        },
        "samples": observations,
    }


def _audit_load() -> dict[str, Any]:
    return {
        "page_count": 1,
        "widget_count": len(contract.AUDIT_14_WIDGET_TYPES),
        "widget_types": list(contract.AUDIT_14_WIDGET_TYPES),
        "widget_sizes": ["0.5x0.5"] * len(contract.AUDIT_14_WIDGET_TYPES),
        "current_page": 0,
        "verified": True,
    }


def _rotation_report(candidate: dict[str, Any]) -> dict[str, Any]:
    refresh_hz = 60.0
    nominal = 1000.0 / refresh_hz
    transitions: list[dict[str, Any]] = []
    all_intervals: list[float] = []
    for index in range(6):
        requested = 1000.0 + index * 2000.0
        timestamps = [requested + 20.0 + frame * 16.0 for frame in range(31)]
        intervals = [
            later - earlier
            for earlier, later in zip(timestamps, timestamps[1:])
        ]
        all_intervals.extend(intervals)
        span = timestamps[-1] - timestamps[0]
        callback_rate = (len(timestamps) - 1) * 1000.0 / span
        to_mode = "landscape" if index % 2 == 0 else "portrait"
        checks = [
            {
                "name": "first-frame-latency",
                "observed": 20.0,
                "maximum": 100.0,
                "passed": True,
            },
            {
                "name": "animation-span-minimum",
                "observed": span,
                "minimum": 400.0,
                "passed": True,
            },
            {
                "name": "animation-span-maximum",
                "observed": span,
                "maximum": 680.0,
                "passed": True,
            },
            {
                "name": "effective-callback-rate",
                "observed": callback_rate,
                "minimum": refresh_hz * 0.70,
                "passed": True,
            },
            {
                "name": "p95-frame-interval",
                "observed": 16.0,
                "maximum": nominal * 2.0,
                "passed": True,
            },
            {
                "name": "missed-refresh-ratio",
                "observed": 0.0,
                "maximum": 0.20,
                "passed": True,
            },
        ]
        transitions.append(
            {
                "from": (
                    "portrait" if to_mode == "landscape" else "landscape"
                ),
                "to": to_mode,
                "request_started_monotonic_ms": requested,
                "acknowledged_monotonic_ms": requested + 1.0,
                "ack_latency_ms": 1.0,
                "reported_rotation": 90 if to_mode == "landscape" else 0,
                "frames": {
                    "surface": "wl_surface#1",
                    "frame_callback_count": len(timestamps),
                    "first_frame_after_request_ms": 20.0,
                    "observation_span_ms": span,
                    "effective_callback_rate_hz": callback_rate,
                    "interval_ms": {
                        "minimum": min(intervals),
                        "median": statistics.median(intervals),
                        "p95": 16.0,
                        "maximum": max(intervals),
                    },
                    "interval_count_over_1_5_refreshes": 0,
                    "estimated_missed_refreshes": 0,
                    "frame_callback_timestamps_ms": timestamps,
                },
                "smoothness_slo": {"passed": True, "checks": checks},
            }
        )
    return {
        "schema_version": 2,
        "evidence_type": "wayland-rotation-frame-callback-timing",
        "status": "PASS",
        "qualified": True,
        "qualification_note": (
            "Every observed quarter-turn must meet the recorded "
            "refresh-normalized response, duration, cadence, and missed-frame "
            "limits."
        ),
        "started_utc": STARTED,
        "completed_utc": COMPLETED,
        "candidate": candidate,
        "output": {
            "name": EDGE_OUTPUT,
            "geometry": GEOMETRY,
            "refresh_hz": refresh_hz,
            "nominal_refresh_interval_ms": nominal,
        },
        "rotation_observation_window_ms": 700.0,
        "smoothness_slo": dict(contract.ROTATION_SLO),
        "load": _audit_load(),
        "transition_count": len(transitions),
        "transitions": transitions,
        "aggregate": {
            "interval_ms": {
                "minimum": min(all_intervals),
                "median": statistics.median(all_intervals),
                "p95": 16.0,
                "maximum": max(all_intervals),
            },
            "estimated_missed_refreshes": 0,
            "frame_callback_count": 31 * 6,
        },
    }


def build_release_run_fixture(
    artifact_dir: pathlib.Path, commit: str, run_id: str
) -> None:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    candidate = _candidate(commit)

    preflight = [
        check
        if check is not None
        else "live Wayland socket (/run/user/1000/wayland-0)"
        for check in contract.EXPECTED_PREFLIGHT_CHECKS
    ]
    preflight_payload = (
        "result\tcheck\n"
        + "".join(f"PASS\t{check}\n" for check in preflight)
    ).encode()
    summary_payload = (
        "result\tsuite\n"
        + "".join(
            f"PASS\t{suite}\n" for suite in contract.EXPECTED_RELEASE_SUITES
        )
    ).encode()
    (artifact_dir / "PREFLIGHT.tsv").write_bytes(preflight_payload)
    (artifact_dir / "SUMMARY.tsv").write_bytes(summary_payload)
    _write_json(
        artifact_dir / "RUN.json",
        {
            "schema": contract.RUN_SCHEMA,
            "source_commit": commit,
            "run_id": run_id,
            "completed_at": "2026-07-27T00:31:00Z",
            "result": "PASS",
            "preflight_rows": len(preflight),
            "preflight_sha256": hashlib.sha256(preflight_payload).hexdigest(),
            "summary_rows": len(contract.EXPECTED_RELEASE_SUITES),
            "summary_sha256": hashlib.sha256(summary_payload).hexdigest(),
        },
    )

    _write_json(
        artifact_dir / "display-lifecycle" / "RESULT.json",
        {
            "schema": contract.DISPLAY_LIFECYCLE_SCHEMA,
            "source_commit": commit,
            "status": "PASS",
            "restore_verified": True,
            "edge_output": EDGE_OUTPUT,
            "hub": {
                "path": BINARY,
                "sha256": candidate["binary_sha256"],
                "version": candidate["binary_version"],
                "candidate_build": candidate,
            },
            "checks": [
                {
                    "name": "fixture display lifecycle",
                    "status": "PASS",
                    "detail": "display changed and exact baseline restored",
                }
            ],
            "error": False,
        },
    )
    _write_json(
        artifact_dir / "performance" / "rotation-frame" / "report.json",
        _rotation_report(candidate),
    )

    short_root = artifact_dir / "performance" / "short"
    short_startup = _first_render(candidate, str(short_root), "short")
    _write_json(short_root / "startup-first-render.json", short_startup)
    _write_json(
        short_root / "idle-5m.json",
        _short_resource_report("idle-5m", candidate),
    )
    _write_json(
        short_root / "active-10x5m.json",
        _short_resource_report("active-10x5m", candidate),
    )
    _write_json(
        short_root / "summary.json",
        {
            "schema_version": 1,
            "evidence_type": "xeneon-hub-performance-run",
            "mode": "short",
            "status": "PASS",
            "qualified": True,
            "started_utc": STARTED,
            "completed_utc": COMPLETED,
            "scope_note": (
                "This run qualifies only startup and the two five-minute gates. "
                "It does not qualify either long-duration trend requirement."
            ),
            "profiles": [
                {
                    "profile": profile,
                    "status": "PASS",
                    "qualified": True,
                    "failures": [],
                }
                for profile in contract.SHORT_PERFORMANCE_PROFILES
            ],
        },
    )

    audit_root = artifact_dir / "performance" / "14-widget-30m"
    audit_startup = _first_render(candidate, str(audit_root), "audit-14")
    _write_json(audit_root / "startup-first-render.json", audit_startup)
    audit_trace = _resource_observations(61, 30.0, audit_trace=True)
    audit_root.mkdir(parents=True, exist_ok=True)
    (audit_root / "samples.jsonl").write_text(
        "".join(
            json.dumps(item, sort_keys=True) + "\n" for item in audit_trace
        ),
        encoding="utf-8",
    )
    metrics = _resource_metrics(audit_trace, 1800.0, 30.0)
    steady_trace = [
        item for item in audit_trace if item["elapsed_seconds"] >= 600.0
    ]
    metrics.update(
        {
            "slopes": {
                "rss_mib": _linear_trend(
                    [item["elapsed_seconds"] for item in audit_trace],
                    [item["rss_bytes"] / MIB for item in audit_trace],
                ),
                "file_descriptors": _linear_trend(
                    [item["elapsed_seconds"] for item in audit_trace],
                    [float(item["file_descriptors"]) for item in audit_trace],
                ),
                "threads": _linear_trend(
                    [item["elapsed_seconds"] for item in audit_trace],
                    [float(item["threads"]) for item in audit_trace],
                ),
                "cpu_percent": {"per_hour": 0.0, "r_squared": 1.0},
                "gpu_memory_mib": _linear_trend(
                    [item["elapsed_seconds"] for item in audit_trace],
                    [float(item["gpu_memory_mib"]) for item in audit_trace],
                ),
            },
            "steady_state_last_20m": _resource_metrics(
                steady_trace, 1200.0, 30.0
            ),
            "gpu_memory": {
                "available": True,
                "initial_mib": 32.0,
                "final_mib": 32.0,
                "peak_mib": 32.0,
                "method": (
                    "deduplicated DRM client resident VRAM plus GTT from "
                    "/proc/PID/fdinfo"
                ),
            },
        }
    )
    _write_json(
        audit_root / "report.json",
        {
            "schema_version": 1,
            "evidence_type": "xeneon-hub-14-widget-30-minute-audit",
            "status": "PASS",
            "qualified": True,
            "failures": [],
            "qualification_note": (
                "Owner-approved substitute for the waived 48-hour soak. "
                "Qualification requires the complete 30-minute trace, exact "
                "14-widget load, startup pass, CPU/RSS budgets, GPU-memory "
                "availability, and finite CPU/RSS/FD/thread slopes."
            ),
            "accepted_risk": (
                "The release owner explicitly waived the historical 48-hour "
                "idle soak; this result does not claim 48-hour endurance."
            ),
            "started_utc": STARTED,
            "completed_utc": COMPLETED,
            "candidate": candidate,
            "edge_output": EDGE_OUTPUT,
            "edge_geometry": GEOMETRY,
            "load": _audit_load(),
            "warmup_seconds": 30.0,
            "sample_interval_seconds": 30.0,
            "startup": audit_startup,
            "metrics": metrics,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=pathlib.Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-id", required=True)
    arguments = parser.parse_args()
    build_release_run_fixture(
        arguments.artifact_dir.resolve(), arguments.commit, arguments.run_id
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
