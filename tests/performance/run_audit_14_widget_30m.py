#!/usr/bin/env python3
"""Run the owner-approved 30-minute, 14-widget release observation.

The release owner explicitly waived the historical 48-hour soak. This exact,
non-scalable observation is the accepted substitute. It proves a complete live
load and complete resource measurements while retaining the existing active
CPU/RSS budgets.
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import statistics
import sys
import time
from pathlib import Path
from typing import Optional, Sequence


HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
HARDWARE = REPO / "tests" / "hardware"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HARDWARE))

import e2e_harness as harness  # noqa: E402
from e2e_harness import E2E, doc, page, tile  # noqa: E402
from resource_probe import (  # noqa: E402
    MIB,
    MeasurementError,
    ProcReader,
    collect_samples,
    measure_wayland_first_frame,
    summarise_samples,
    write_error_report,
    write_json_atomic,
)
from run_hub_profiles import validate_candidate_build  # noqa: E402


AUDIT_DURATION_SECONDS = 1800.0
AUDIT_INTERVAL_SECONDS = 30.0
WARMUP_SECONDS = 30.0
MAXIMUM_AVERAGE_CPU_PERCENT = 5.0
MAXIMUM_RSS_MIB = 480.0
AUDIT_WIDGET_TYPES = (
    "cpu",
    "gpu",
    "ram",
    "net",
    "disk",
    "packages",
    "sinceinstall",
    "clock",
    "analog",
    "moon",
    "rightnow",
    "notes",
    "habit",
    "hydration",
)


def _iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _appearance() -> dict:
    return {
        "mode": "dark",
        "themeMode": "midnight",
        "accent": "#58A6FF",
        "bgStyle": "none",
        "animatedBg": False,
        "glass": 0.0,
        "glow": False,
        "reduceMotion": False,
        "orientation": "auto",
        "gridCols": 2,
    }


def audit_document() -> dict:
    tiles = [
        tile(f"audit-{index:02d}-{widget}", widget, "0.5x0.5")
        for index, widget in enumerate(AUDIT_WIDGET_TYPES)
    ]
    return doc(
        [page("14-widget audit", tiles)],
        appearance=_appearance(),
    )


def _hub_environment(instance: E2E) -> dict[str, str]:
    environment = dict(os.environ)
    environment["XDG_CONFIG_HOME"] = instance.cfg
    environment["XDG_RUNTIME_DIR"] = instance.run_dir
    harness._abs_wayland_display(environment)
    return environment


def _verify_live_load(instance: E2E) -> dict:
    state = instance.get_state()
    pages = state.get("pages")
    if not isinstance(pages, list) or len(pages) != 1:
        raise MeasurementError("live audit state must contain exactly one page")
    tiles = pages[0].get("tiles") if isinstance(pages[0], dict) else None
    if not isinstance(tiles, list):
        raise MeasurementError("live audit page has no tile list")
    observed = tuple(
        item.get("type") if isinstance(item, dict) else None for item in tiles
    )
    if observed != AUDIT_WIDGET_TYPES:
        raise MeasurementError(
            f"live widget manifest differs: expected {AUDIT_WIDGET_TYPES}, "
            f"observed {observed}"
        )
    sizes = [
        item.get("size") if isinstance(item, dict) else None for item in tiles
    ]
    if sizes != ["0.5x0.5"] * len(AUDIT_WIDGET_TYPES):
        raise MeasurementError(f"live widget sizes differ: {sizes}")
    if instance.hub_current_page() != 0:
        raise MeasurementError("Hub is not displaying the sole audit page")
    return {
        "page_count": 1,
        "widget_count": len(tiles),
        "widget_types": list(observed),
        "widget_sizes": sizes,
        "current_page": 0,
        "verified": True,
    }


def _drm_memory_mib(process_ids: Sequence[int]) -> Optional[float]:
    clients: dict[tuple[str, str], tuple[int, int]] = {}
    for pid in process_ids:
        fdinfo = Path("/proc") / str(pid) / "fdinfo"
        try:
            entries = list(fdinfo.iterdir())
        except OSError:
            continue
        for entry in entries:
            try:
                values = {}
                for line in entry.read_text(
                    encoding="utf-8", errors="replace"
                ).splitlines():
                    key, separator, raw = line.partition(":")
                    if separator:
                        values[key.strip()] = raw.strip()
                client = values.get("drm-client-id")
                device = values.get("drm-pdev")
                if not client or not device:
                    continue

                def kib(name: str) -> int:
                    tokens = values.get(name, "").split()
                    return (
                        int(tokens[0])
                        if len(tokens) == 2 and tokens[1] == "KiB"
                        else 0
                    )

                key = (device, client)
                resident = (
                    kib("drm-resident-vram"),
                    kib("drm-resident-gtt"),
                )
                previous = clients.get(key, (0, 0))
                clients[key] = (
                    max(previous[0], resident[0]),
                    max(previous[1], resident[1]),
                )
            except (OSError, ValueError):
                continue
    if not clients:
        return None
    return sum(vram + gtt for vram, gtt in clients.values()) / 1024.0


def _trend(xs: Sequence[float], ys: Sequence[float]) -> dict:
    if len(xs) != len(ys) or len(xs) < 2:
        raise MeasurementError("trend needs at least two aligned observations")
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    if denominator <= 0:
        raise MeasurementError("trend has no elapsed-time span")
    slope = sum(
        (x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)
    ) / denominator
    total = sum((y - y_mean) ** 2 for y in ys)
    residual = sum(
        (y - (y_mean + slope * (x - x_mean))) ** 2
        for x, y in zip(xs, ys)
    )
    return {
        "per_hour": slope * 3600.0,
        "r_squared": 1.0 if total == 0 else max(0.0, 1.0 - residual / total),
    }


def _trend_report(samples, gpu_values: Sequence[Optional[float]], tick_rate: int) -> dict:
    elapsed = [sample.elapsed_seconds for sample in samples]
    cpu_times = []
    cpu_values = []
    for previous, current in zip(samples, samples[1:]):
        gap = current.monotonic_seconds - previous.monotonic_seconds
        cpu_times.append(
            (previous.elapsed_seconds + current.elapsed_seconds) / 2.0
        )
        cpu_values.append(
            (current.cpu_ticks - previous.cpu_ticks) / tick_rate / gap * 100.0
        )
    result = {
        "rss_mib": _trend(
            elapsed, [sample.rss_bytes / MIB for sample in samples]
        ),
        "file_descriptors": _trend(
            elapsed, [float(sample.file_descriptors) for sample in samples]
        ),
        "threads": _trend(
            elapsed, [float(sample.threads) for sample in samples]
        ),
        "cpu_percent": _trend(cpu_times, cpu_values),
    }
    if all(value is not None for value in gpu_values):
        result["gpu_memory_mib"] = _trend(
            elapsed, [float(value) for value in gpu_values]
        )
    else:
        result["gpu_memory_mib"] = None
    return result


def _run_startup(binary: Path, output_dir: Path, candidate: dict) -> dict:
    instance = E2E(str(output_dir / "startup-work"))
    try:
        instance.write_config(audit_document())
        report = measure_wayland_first_frame(
            [str(binary)],
            _hub_environment(instance),
            REPO,
            output_dir / "startup-wayland.log",
        )
        report["metadata"].update(
            {
                "candidate": candidate,
                "widget_count": len(AUDIT_WIDGET_TYPES),
                "edge_output": instance.edge_name,
            }
        )
        write_json_atomic(output_dir / "startup-first-render.json", report)
        return report
    finally:
        instance.cleanup()


def run(binary: Path, output_dir: Path) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    if any(output_dir.iterdir()):
        raise MeasurementError("audit output directory must be empty")
    harness.HUB = str(binary)
    harness.assert_binaries_current((str(binary),))
    candidate = validate_candidate_build(binary)
    started_utc = _iso_now()
    startup = _run_startup(binary, output_dir, candidate)

    instance = E2E(str(output_dir / "active-work"))
    trace = None
    try:
        instance.write_config(audit_document())
        if not instance.launch_hub():
            raise MeasurementError("Hub did not expose its private control socket")
        assert instance.proc is not None
        observed_load = _verify_live_load(instance)
        deadline = time.monotonic() + WARMUP_SECONDS
        while time.monotonic() < deadline:
            if instance.proc.poll() is not None:
                raise MeasurementError("Hub exited during warm-up")
            time.sleep(min(1.0, deadline - time.monotonic()))

        source = ProcReader()
        gpu_values: list[Optional[float]] = []
        trace = (output_dir / "samples.jsonl").open(
            "x", encoding="utf-8", buffering=1
        )

        def record(sample) -> None:
            gpu = _drm_memory_mib(
                [identity[0] for identity in sample.process_identities]
            )
            gpu_values.append(gpu)
            trace.write(
                json.dumps(
                    {
                        "elapsed_seconds": sample.elapsed_seconds,
                        "cpu_ticks": sample.cpu_ticks,
                        "rss_bytes": sample.rss_bytes,
                        "threads": sample.threads,
                        "file_descriptors": sample.file_descriptors,
                        "gpu_memory_mib": gpu,
                    },
                    sort_keys=True,
                )
                + "\n"
            )
            trace.flush()
            os.fsync(trace.fileno())
            print(
                f"{sample.elapsed_seconds:6.0f}s "
                f"RSS={sample.rss_bytes / MIB:7.2f}MiB "
                f"FD={sample.file_descriptors:3d} "
                f"threads={sample.threads:3d} "
                f"GPU={gpu if gpu is not None else 'n/a'}",
                flush=True,
            )

        samples = collect_samples(
            source,
            instance.proc.pid,
            AUDIT_DURATION_SECONDS,
            AUDIT_INTERVAL_SECONDS,
            Path(instance.log.name),
            on_sample=record,
        )
        metrics = summarise_samples(
            samples,
            source.clock_ticks_per_second,
            AUDIT_DURATION_SECONDS,
            AUDIT_INTERVAL_SECONDS,
        )
        metrics["slopes"] = _trend_report(
            samples, gpu_values, source.clock_ticks_per_second
        )
        steady = [
            sample for sample in samples if sample.elapsed_seconds >= 600.0
        ]
        metrics["steady_state_last_20m"] = summarise_samples(
            steady,
            source.clock_ticks_per_second,
            1200.0,
            AUDIT_INTERVAL_SECONDS,
        )
        metrics["gpu_memory"] = {
            "available": all(value is not None for value in gpu_values),
            "initial_mib": gpu_values[0],
            "final_mib": gpu_values[-1],
            "peak_mib": max(
                value for value in gpu_values if value is not None
            )
            if any(value is not None for value in gpu_values)
            else None,
            "method": "deduplicated DRM client resident VRAM plus GTT from /proc/PID/fdinfo",
        }
        failures: list[str] = []
        if startup.get("qualified") is not True:
            failures.append("startup-to-first-frame gate failed")
        if metrics["observed_duration_seconds"] + 1e-6 < AUDIT_DURATION_SECONDS:
            failures.append("the full 30-minute observation was not completed")
        minimum_samples = math.ceil(
            (math.floor(AUDIT_DURATION_SECONDS / AUDIT_INTERVAL_SECONDS) + 1)
            * 0.95
        )
        if metrics["sample_count"] < minimum_samples:
            failures.append(
                f"only {metrics['sample_count']} samples were retained; "
                f"at least {minimum_samples} are required"
            )
        if metrics["maximum_sample_gap_seconds"] > AUDIT_INTERVAL_SECONDS * 3.0:
            failures.append("the sample trace contains an excessive time gap")
        if metrics["average_cpu_percent"] >= MAXIMUM_AVERAGE_CPU_PERCENT:
            failures.append(
                f"average CPU {metrics['average_cpu_percent']:.3f}% is not "
                f"below {MAXIMUM_AVERAGE_CPU_PERCENT:.3f}%"
            )
        steady_cpu = metrics["steady_state_last_20m"]["average_cpu_percent"]
        if steady_cpu >= MAXIMUM_AVERAGE_CPU_PERCENT:
            failures.append(
                f"steady-state CPU {steady_cpu:.3f}% is not below "
                f"{MAXIMUM_AVERAGE_CPU_PERCENT:.3f}%"
            )
        if metrics["rss_peak_mib"] >= MAXIMUM_RSS_MIB:
            failures.append(
                f"peak RSS {metrics['rss_peak_mib']:.3f}MiB is not below "
                f"{MAXIMUM_RSS_MIB:.3f}MiB"
            )
        if metrics["gpu_memory"]["available"] is not True:
            failures.append("GPU memory could not be measured for every sample")
        for metric_name in (
            "rss_mib",
            "file_descriptors",
            "threads",
            "cpu_percent",
        ):
            trend = metrics["slopes"].get(metric_name)
            if not isinstance(trend, dict) or not math.isfinite(
                float(trend.get("per_hour", math.nan))
            ):
                failures.append(f"{metric_name} slope is unavailable")
        report = {
            "schema_version": 1,
            "evidence_type": "xeneon-hub-14-widget-30-minute-audit",
            "status": "PASS" if not failures else "FAIL",
            "qualified": not failures,
            "failures": failures,
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
            "started_utc": started_utc,
            "completed_utc": _iso_now(),
            "candidate": candidate,
            "edge_output": instance.edge_name,
            "edge_geometry": {
                "x": instance.ex,
                "y": instance.ey,
                "width": instance.ew,
                "height": instance.eh,
            },
            "load": observed_load,
            "warmup_seconds": WARMUP_SECONDS,
            "sample_interval_seconds": AUDIT_INTERVAL_SECONDS,
            "startup": startup,
            "metrics": metrics,
        }
        write_json_atomic(output_dir / "report.json", report)
        return 0 if not failures else 1
    except BaseException as exc:
        write_error_report(
            output_dir / "report.json",
            "xeneon-hub-14-widget-30-minute-audit",
            exc,
        )
        raise
    finally:
        log_handle = getattr(instance, "log", None)
        instance.cleanup()
        if log_handle is not None:
            log_handle.close()
        if trace is not None:
            trace.close()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    return parser


if __name__ == "__main__":
    args = _parser().parse_args()
    raise SystemExit(run(args.hub.resolve(), args.output_dir.resolve()))
