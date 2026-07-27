#!/usr/bin/env python3
"""Run fixed, release-qualifying performance profiles on the real Edge.

This orchestrator intentionally has no duration override.  ``short`` means the
real 5-minute idle and 5-minute active windows plus startup-to-first-frame; the
24-hour and 48-hour modes wait their complete wall-clock intervals.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
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
    MeasurementError,
    measure_resource_profile,
    measure_wayland_first_frame,
    write_error_report,
    write_json_atomic,
)


WARMUP_SECONDS = 30
ACTIVE_WIDGET_TYPES = (
    "cpu",
    "gpu",
    "ram",
    "net",
    "disk",
    "clock",
    "analog",
    "break",
    "moon",
    "rightnow",
)
ACTIVE_WIDGET_SIZES = (
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
    "0.5x0.5",
)


def _iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _git_revision() -> str:
    result = subprocess.run(
        ["git", "describe", "--tags", "--always", "--dirty"],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    return result.stdout.strip() or "unavailable"


def _source_commit() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD^{commit}"],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    commit = result.stdout.strip()
    if result.returncode != 0 or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise MeasurementError(
            "performance evidence requires one exact lowercase source commit"
        )
    return commit


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_candidate_build(binary: Path) -> dict:
    """Require a current, non-instrumented CMake Release candidate."""

    cache_path = binary.parent / "CMakeCache.txt"
    if not cache_path.is_file():
        raise MeasurementError(
            f"Hub performance evidence requires its CMakeCache.txt: {cache_path}"
        )
    cache: dict[str, str] = {}
    for line in cache_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith(("#", "//")) or "=" not in line:
            continue
        key_with_type, value = line.split("=", 1)
        key = key_with_type.split(":", 1)[0]
        cache[key] = value
    required = {
        "CMAKE_BUILD_TYPE": "Release",
        "CMAKE_INSTALL_PREFIX": "/usr",
        "XENEON_BUILD_TESTS": "OFF",
        "XENEON_COVERAGE": "OFF",
        "XENEON_QA_HOOKS": "OFF",
    }
    failures = [
        f"{key} is {cache.get(key, 'MISSING')!r}, required {expected!r}"
        for key, expected in required.items()
        if cache.get(key) != expected
    ]
    if failures:
        raise MeasurementError("invalid performance candidate: " + "; ".join(failures))
    version = subprocess.run(
        [str(binary), "--version"],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if version.returncode != 0 or not version.stdout.strip():
        raise MeasurementError(
            f"candidate --version failed with code {version.returncode}: {version.stderr.strip()}"
        )
    return {
        "source_commit": _source_commit(),
        "cmake_cache": str(cache_path),
        "cmake_build_type": cache["CMAKE_BUILD_TYPE"],
        "cmake_install_prefix": cache["CMAKE_INSTALL_PREFIX"],
        "test_targets": cache["XENEON_BUILD_TESTS"],
        "coverage_instrumentation": cache["XENEON_COVERAGE"],
        "qa_hooks": cache["XENEON_QA_HOOKS"],
        "binary_sha256": _sha256(binary),
        "binary_version": version.stdout.strip(),
    }


def _appearance() -> dict:
    # A static background makes the profile measure the widgets and shared
    # dashboard tick rather than an optional decorative animation.
    return {
        "mode": "dark",
        "themeMode": "midnight",
        "accent": "#58A6FF",
        "bgStyle": "none",
        "animatedBg": False,
        "glass": 0.0,
        "glow": False,
        "gridCols": 1,
    }


def idle_document() -> dict:
    return doc([page("Performance idle", [])], appearance=_appearance())


def active_document(today: str) -> dict:
    tiles = [
        tile(f"perf-{index:02d}-{widget}", widget, size)
        for index, (widget, size) in enumerate(
            zip(ACTIVE_WIDGET_TYPES, ACTIVE_WIDGET_SIZES, strict=True)
        )
    ]
    now_ms = int(time.time() * 1000)
    settings = {
        "perf-07-break": {
            "intervalMin": 30,
            "running": True,
            "due": False,
            "endEpoch": now_ms + 30 * 60 * 1000,
            "pausedRemaining": 1800,
            "breaksToday": 0,
            "day": today,
        },
    }
    return doc([page("Performance active", tiles)], settings=settings, appearance=_appearance())


def _hub_environment(instance: E2E) -> dict[str, str]:
    environment = dict(os.environ)
    environment["XDG_CONFIG_HOME"] = instance.cfg
    environment["XDG_RUNTIME_DIR"] = instance.run_dir
    harness._abs_wayland_display(environment)
    return environment


def _metadata(instance: E2E, binary: Path, mode: str, candidate: dict) -> dict:
    return {
        "application": "xeneon-edge-hub",
        "binary": str(binary),
        "git_revision": _git_revision(),
        "mode": mode,
        "edge_output": instance.edge_name,
        "edge_geometry": {
            "x": instance.ex,
            "y": instance.ey,
            "width": instance.ew,
            "height": instance.eh,
        },
        "warmup_seconds": WARMUP_SECONDS,
        "active_widget_types": list(ACTIVE_WIDGET_TYPES) if mode == "active" else [],
        "candidate_build": candidate,
    }


def _wait_warmup(instance: E2E) -> None:
    deadline = time.monotonic() + WARMUP_SECONDS
    while time.monotonic() < deadline:
        if instance.proc is None or instance.proc.poll() is not None:
            code = None if instance.proc is None else instance.proc.returncode
            raise MeasurementError(f"Hub exited during warm-up with code {code}")
        time.sleep(min(1.0, deadline - time.monotonic()))


def _verify_loaded_profile(
    instance: E2E,
    expected_types: tuple[str, ...],
    expected_sizes: tuple[str, ...],
) -> dict:
    """Prove that the live Hub accepted the load the report will name.

    Counting the document written before launch is not evidence that the
    current parser/store/render path retained it.  Read the state back through
    the production control socket and reject every missing, reordered, resized,
    or unexpectedly running/static profile before the timed interval begins.
    """

    state = instance.get_state()
    pages = state.get("pages")
    if not isinstance(pages, list) or len(pages) != 1:
        raise MeasurementError(
            f"live profile has {0 if not isinstance(pages, list) else len(pages)} pages; exactly one is required"
        )
    tiles = pages[0].get("tiles") if isinstance(pages[0], dict) else None
    if not isinstance(tiles, list):
        raise MeasurementError("live profile page has no tile list")
    observed_types = tuple(
        item.get("type") if isinstance(item, dict) else None for item in tiles
    )
    if observed_types != expected_types:
        raise MeasurementError(
            f"live widget manifest differs: expected {expected_types}, observed {observed_types}"
        )
    observed_sizes = tuple(
        item.get("size") if isinstance(item, dict) else None for item in tiles
    )
    if observed_sizes != expected_sizes:
        raise MeasurementError(
            f"live tile sizes differ: expected {expected_sizes}, "
            f"observed {observed_sizes}"
        )

    appearance = state.get("appearance")
    required_appearance = _appearance()
    if not isinstance(appearance, dict):
        raise MeasurementError("live profile has no appearance object")
    appearance_mismatches = {
        key: appearance.get(key)
        for key, expected in required_appearance.items()
        if appearance.get(key) != expected
    }
    if appearance_mismatches:
        raise MeasurementError(
            "live profile did not retain the fixed static appearance: "
            f"{appearance_mismatches}"
        )
    if instance.hub_current_page() != 0:
        raise MeasurementError("live Hub is not displaying the sole performance page")

    settings = state.get("settings", {})
    if expected_types:
        tile_id = "perf-07-break"
        value = settings.get(tile_id) if isinstance(settings, dict) else None
        if not isinstance(value, dict) or value.get("running") is not True:
            raise MeasurementError(f"active timer is not running in live state: {tile_id}")
    elif settings:
        raise MeasurementError("idle profile unexpectedly retained widget settings")

    return {
        "observed_page_count": len(pages),
        "observed_widget_count": len(tiles),
        "observed_widget_types": list(observed_types),
        "observed_tile_sizes": list(observed_sizes),
        "observed_current_page": 0,
        "live_state_verified": True,
    }


def run_startup_profile(binary: Path, output_dir: Path, candidate: dict) -> dict:
    work = output_dir / "startup-work"
    instance = E2E(str(work))
    report_path = output_dir / "startup-first-render.json"
    try:
        instance.write_config(idle_document())
        instance._remove_own_socket()
        report = measure_wayland_first_frame(
            [str(binary)],
            _hub_environment(instance),
            REPO,
            output_dir / "startup-wayland.log",
        )
        report["metadata"].update(_metadata(instance, binary, "startup", candidate))
        write_json_atomic(report_path, report)
        return report
    except BaseException as exc:
        write_error_report(report_path, "startup-first-render", exc)
        return {
            "profile": "startup-first-render",
            "status": "FAIL",
            "qualified": False,
            "failures": [f"{type(exc).__name__}: {exc}"],
        }
    finally:
        instance.cleanup()


def run_resource_profile(binary: Path, profile: str, output_dir: Path, candidate: dict) -> dict:
    work = output_dir / f"{profile}-work"
    instance = E2E(str(work))
    report_path = output_dir / f"{profile}.json"
    log_handle = None
    trace_handle = None
    try:
        if profile == "active-10x5m":
            document = active_document(instance.today)
            widget_count = len(ACTIVE_WIDGET_TYPES)
            mode = "active"
        else:
            document = idle_document()
            widget_count = 0
            mode = "idle"
        instance.write_config(document)
        launched_at = time.monotonic()
        if not instance.launch_hub():
            raise MeasurementError("Hub did not expose its isolated control socket within 15 seconds")
        control_ready_seconds = time.monotonic() - launched_at
        assert instance.proc is not None
        log_handle = instance.log
        expected_types = ACTIVE_WIDGET_TYPES if mode == "active" else ()
        expected_sizes = ACTIVE_WIDGET_SIZES if mode == "active" else ()
        observed_load = _verify_loaded_profile(
            instance, expected_types, expected_sizes
        )
        _wait_warmup(instance)
        log_handle.flush()
        metadata = _metadata(instance, binary, mode, candidate)
        metadata["control_socket_ready_seconds_diagnostic_only"] = control_ready_seconds
        metadata["control_socket_note"] = "not accepted as startup-to-first-render evidence"
        metadata["observed_load"] = observed_load
        trace_handle = (output_dir / f"{profile}-samples.jsonl").open(
            "x", encoding="utf-8", buffering=1
        )
        progress_bucket = -1

        def record_sample(sample) -> None:
            nonlocal progress_bucket
            trace_handle.write(
                json.dumps(
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
                    },
                    sort_keys=True,
                )
                + "\n"
            )
            minute = int(sample.elapsed_seconds // 60)
            if minute % 5 == 0 and minute != progress_bucket:
                progress_bucket = minute
                trace_handle.flush()
                os.fsync(trace_handle.fileno())
                print(
                    f"{profile}: {sample.elapsed_seconds:.0f}s elapsed, "
                    f"RSS={sample.rss_bytes / (1024 * 1024):.2f}MiB, "
                    f"threads={sample.threads}, fds={sample.file_descriptors}",
                    flush=True,
                )

        report = measure_resource_profile(
            instance.proc.pid,
            profile,
            widget_count,
            Path(log_handle.name),
            metadata,
            on_sample=record_sample,
        )
        write_json_atomic(report_path, report)
        return report
    except BaseException as exc:
        write_error_report(report_path, profile, exc)
        return {
            "profile": profile,
            "status": "FAIL",
            "qualified": False,
            "failures": [f"{type(exc).__name__}: {exc}"],
        }
    finally:
        instance.cleanup()
        if log_handle is not None:
            log_handle.close()
        if trace_handle is not None:
            trace_handle.close()


def _prepare_output_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    leftovers = list(path.iterdir())
    if leftovers:
        raise MeasurementError(
            f"evidence directory must be empty to prevent stale-result mixing: {path}"
        )


def run(mode: str, binary: Path, output_dir: Path) -> int:
    _prepare_output_dir(output_dir)
    harness.HUB = str(binary)
    harness.assert_binaries_current((str(binary),))
    candidate = validate_candidate_build(binary)
    started = _iso_now()
    reports: list[dict] = []

    if mode == "short":
        reports.append(run_startup_profile(binary, output_dir, candidate))
        reports.append(run_resource_profile(binary, "idle-5m", output_dir, candidate))
        reports.append(run_resource_profile(binary, "active-10x5m", output_dir, candidate))
        scope_note = (
            "This run qualifies only startup and the two five-minute gates. "
            "It does not qualify either long-duration trend requirement."
        )
    elif mode == "idle-24h":
        reports.append(run_resource_profile(binary, "idle-24h", output_dir, candidate))
        scope_note = "This run waits a real 24-hour interval; it is not duration-scaled."
    elif mode == "idle-48h":
        reports.append(run_resource_profile(binary, "idle-48h", output_dir, candidate))
        scope_note = "This run waits a real 48-hour interval; it is not duration-scaled."
    else:
        raise MeasurementError(f"unsupported mode: {mode}")

    qualified = all(report.get("qualified") is True for report in reports)
    summary = {
        "schema_version": 1,
        "evidence_type": "xeneon-hub-performance-run",
        "mode": mode,
        "status": "PASS" if qualified else "FAIL",
        "qualified": qualified,
        "started_utc": started,
        "completed_utc": _iso_now(),
        "scope_note": scope_note,
        "profiles": [
            {
                "profile": report.get("profile"),
                "status": report.get("status"),
                "qualified": report.get("qualified"),
                "failures": report.get("failures", []),
            }
            for report in reports
        ],
    }
    write_json_atomic(output_dir / "summary.json", summary)
    for entry in summary["profiles"]:
        print(f"{entry['status']:4s} {entry['profile']}", flush=True)
        for failure in entry["failures"]:
            print(f"     {failure}", file=sys.stderr)
    print(f"Evidence: {output_dir}", flush=True)
    print(scope_note, flush=True)
    return 0 if qualified else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("short", "idle-24h", "idle-48h"), required=True)
    parser.add_argument(
        "--hub",
        type=Path,
        default=Path(os.environ.get("XENEON_HUB", REPO / "build" / "xeneon-edge-hub")),
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    binary = arguments.hub.expanduser().resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        print(f"FAIL: Hub binary is missing or not executable: {binary}", file=sys.stderr)
        return 1
    try:
        return run(arguments.mode, binary, arguments.output_dir.expanduser().resolve())
    except BaseException as exc:
        print(f"FAIL: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
