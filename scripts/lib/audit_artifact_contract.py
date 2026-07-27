#!/usr/bin/env python3
"""Semantic contracts for signed audit provenance and release records."""

from __future__ import annotations

import csv
import datetime as dt
import binascii
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import statistics
import struct
import subprocess
import sys
import zlib
from typing import Any


PROVENANCE_SCHEMA = "skyphoenix-edgehub-audit-provenance/v2"
RUN_SCHEMA = "skyphoenix-edgehub-release-gate-run/v2"
CERTIFICATION_SCHEMA = "skyphoenix-edgehub-release-certification/v2"
DESKTOP_NOTIFICATION_SCHEMA = "skyphoenix-edgehub-desktop-notification/v2"
MPRIS_TRANSPORT_SCHEMA = "skyphoenix-edgehub-mpris-transport/v2"
NATIVE_LIFECYCLE_SCHEMA = "skyphoenix-edgehub-native-package-lifecycle/v2"
APPIMAGE_ZSYNC_SCHEMA = "skyphoenix-edgehub-appimage-zsync/v2"
CANONICAL_HOST = "github.com"
CANONICAL_REPOSITORY = "skyphoenix-it/skyphoenix-edgehub-linux"
CANONICAL_NATIVE_WORKFLOW_NAME = "Native Package Upgrade and Rollback"
LOWER_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RUN_ID_RE = re.compile(r"^release-gate-[0-9]{8}T[0-9]{6}Z-[0-9]+$")
CERTIFICATION_RUN_ID_RE = re.compile(
    r"^release-certification-[0-9]{8}T[0-9]{6}Z-[0-9]+$"
)
STABLE_VERSION_RE = re.compile(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
NATIVE_RELEASE_REF_RE = re.compile(
    r"^(?:refs/tags/)?v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)"
    r"\.(?:0|[1-9][0-9]*))?$"
)
PORTABLE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
DISPLAY_LIFECYCLE_SCHEMA = "skyphoenix-edgehub-display-lifecycle/v1"
PERFORMANCE_CANDIDATE_KEYS = {
    "source_commit",
    "cmake_cache",
    "cmake_build_type",
    "cmake_install_prefix",
    "test_targets",
    "coverage_instrumentation",
    "qa_hooks",
    "binary_sha256",
    "binary_version",
}
SHORT_PERFORMANCE_PROFILES = (
    "startup-first-render",
    "idle-5m",
    "active-10x5m",
)
SHORT_ACTIVE_WIDGET_TYPES = (
    "cpu",
    "gpu",
    "ram",
    "net",
    "disk",
    "sensors",
    "clock",
    "analog",
    "focus",
    "break",
)
AUDIT_14_WIDGET_TYPES = (
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
ROTATION_SLO = {
    "first_frame_max_ms": 100.0,
    "animation_span_min_ms": 400.0,
    "animation_span_max_ms": 680.0,
    "minimum_callback_rate_ratio": 0.70,
    "p95_interval_max_refresh_multiplier": 2.0,
    "maximum_missed_refresh_ratio": 0.20,
}

RELEASE_CERTIFICATION_ATTESTATION = (
    "I attest that every named gate was reviewed against the retained evidence "
    "and passed for this exact source commit and release version."
)
DESKTOP_NOTIFICATION_ATTESTATION = (
    "I observed this priority break notification on the real desktop and "
    "confirm it was visually distinct."
)
MPRIS_TRANSPORT_ATTESTATION = (
    "I observed the named real player change state after PlayPause and return "
    "to its original state."
)
NATIVE_IMPORTER_IDENTITY = "EdgeHub native lifecycle evidence importer"
NATIVE_IMPORTER_ATTESTATION = (
    "Automated import verified both package byte hashes, the exact PASS report, "
    "the exact lifecycle environment, the successful canonical workflow run, "
    "and separate GitHub build provenance for every retained subject; no human "
    "observation is asserted."
)
NATIVE_ENVIRONMENT_NAME = "container-lifecycle-environment.txt"
EXPECTED_NATIVE_ENVIRONMENTS = {
    "deb": (
        "requested_image=ubuntu:26.04",
        "resolved_image=ubuntu:26.04@sha256:"
        "7c2884fd32770fc6c173b78e0dc2278a2851d89f5447919edbc45475ac55dd6a",
        "platform=linux/amd64",
    ),
    "rpm": (
        "requested_image=fedora:43",
        "resolved_image=fedora:43@sha256:"
        "52cfb35e60823b691af7541b576c0fa49195628044b2c1a15b0ae775ec01048e",
        "platform=linux/amd64",
    ),
}
EXPECTED_CERTIFICATION_GATES = [
    ("physical_touch", "manual-touch", "ACTION_RESULTS.tsv"),
    (
        "desktop_notification",
        "desktop-notification",
        "DESKTOP_NOTIFICATION.json",
    ),
    ("mpris_transport", "mpris-transport", "MPRIS_TRANSPORT.json"),
    (
        "native_deb_lifecycle",
        "native-package-lifecycle-deb",
        "NATIVE_PACKAGE_LIFECYCLE.json",
    ),
    (
        "native_rpm_lifecycle",
        "native-package-lifecycle-rpm",
        "NATIVE_PACKAGE_LIFECYCLE.json",
    ),
]

EXPECTED_PREFLIGHT_CHECKS = [
    "protected owner licence is non-empty (owner-key attestation enabled)",
    "XENEON_HW_INPUT=1 (live Edge input explicitly authorised)",
    "XENEON_HW_INPUT_DESKTOP=1 (Manager input explicitly authorised)",
    "XENEON_HW_DISPLAY_LIFECYCLE=1 (temporary output changes explicitly authorised)",
    "live geometry verification is mandatory",
    "compositor suite is mandatory",
    "hardware Qt platform is not forced headless",
    "bash",
    "cargo",
    "cargo-llvm-cov",
    "git",
    "gitleaks",
    "ip",
    "kscreen-doctor",
    "rustup",
    "kwin_wayland",
    "python3",
    "readlink",
    "sha256sum",
    "spectacle",
    "stat",
    "tee",
    "timeout",
    "unshare",
    "busctl",
    "gpg",
    "llvm-tools-preview for pinned Rust 1.86.0",
    "cmake",
    "ctest",
    "gcovr",
    "no Hub or Manager process is running",
    "audit finalizer command prerequisites",
    "audit finalizer and semantic helpers",
    "canonical origin fetch and push identity",
    "pinned release signing key is present and signing-capable",
    "resource-aware QuickTest runner will be built from the candidate tree",
    "/dev/uinput is a readable/writable character device",
    None,
    "Python Pillow",
    "connected Edge geometry is detectable",
    "a non-Edge Manager target screen is available",
    "KWin session D-Bus service",
    "unprivileged network namespace (real no-egress attestation)",
]

EXPECTED_RELEASE_SUITES = [
    "Repository full-history secret scan",
    "Rust core format",
    "Rust core clippy",
    "Owner Pro key against shipped issuer",
    "license-tool format",
    "license-tool clippy",
    "license-tool tests",
    "license-webhook format",
    "license-webhook clippy",
    "license-webhook tests",
    "Strict complete developer/integration suite",
    "Real Edge comprehensive functional E2E",
    "Real Edge incremental build-up",
    "Real Edge widget render matrix",
    "Coverage gates",
    "Fresh non-instrumented performance candidate",
    "Real Edge disruptive display lifecycle",
    "Real Edge rotation smoothness SLO",
    "Hub startup + literal 5m idle/10-widget performance",
    "Hub literal 30m 14-widget performance observation",
]


class ContractError(ValueError):
    """Raised when evidence does not satisfy the signed-record contract."""


def _read_json_value(path: pathlib.Path) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
        return json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"{path.name} is not valid UTF-8 JSON: {exc}") from exc


def _read_json(path: pathlib.Path) -> dict[str, Any]:
    value = _read_json_value(path)
    if not isinstance(value, dict):
        raise ContractError(f"{path.name} must contain one JSON object")
    return value


def _require_exact_keys(
    document: dict[str, Any], expected: set[str], label: str
) -> None:
    actual = set(document)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ContractError(
            f"{label} keys differ from the contract; missing={missing}, extra={extra}"
        )


def _parse_utc_timestamp(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ContractError(f"{field} must be an ISO-8601 UTC timestamp ending in Z")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise ContractError(f"{field} is not a valid ISO-8601 timestamp") from exc
    if parsed.tzinfo != dt.timezone.utc:
        raise ContractError(f"{field} must identify UTC")
    return parsed


def _validate_utc_timestamp(value: Any, field: str) -> None:
    _parse_utc_timestamp(value, field)


def _validate_command(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ContractError(f"{field} must be a non-empty argument array")
    result: list[str] = []
    for index, argument in enumerate(value):
        if (
            not isinstance(argument, str)
            or not argument
            or any(character in argument for character in "\x00\r\n")
        ):
            raise ContractError(
                f"{field} argument {index} must be one non-empty line"
            )
        result.append(argument)
    return result


def _validate_command_map(
    value: Any, expected_keys: set[str], field: str
) -> dict[str, list[str]]:
    if not isinstance(value, dict):
        raise ContractError(f"{field} must be an object")
    _require_exact_keys(value, expected_keys, field)
    return {
        key: _validate_command(value[key], f"{field}.{key}")
        for key in sorted(expected_keys)
    }


def validate_provenance(
    path: pathlib.Path,
    expected_commit: str,
    expected_artifact_path: str,
    expected_key: str,
) -> None:
    document = _read_json(path)
    expected_keys = {
        "artifact_path",
        "finalized_at",
        "finalizer_sha256",
        "manifest_algorithm",
        "manifest_signing_key_fingerprint",
        "schema",
        "source",
        "source_commit",
    }
    _require_exact_keys(document, expected_keys, "PROVENANCE.json")

    if document["schema"] != PROVENANCE_SCHEMA:
        raise ContractError(
            f"PROVENANCE.json schema must be exactly {PROVENANCE_SCHEMA}"
        )
    if document["source"] != {
        "host": CANONICAL_HOST,
        "repository": CANONICAL_REPOSITORY,
    }:
        raise ContractError("PROVENANCE.json source identity is not canonical")
    if document["source_commit"] != expected_commit:
        raise ContractError("PROVENANCE.json source_commit does not match the artifact key")
    if not LOWER_SHA_RE.fullmatch(expected_commit):
        raise ContractError("expected source commit is not a lowercase full SHA")
    if document["artifact_path"] != expected_artifact_path:
        raise ContractError("PROVENANCE.json artifact_path is not the exact artifact path")

    artifact = document["artifact_path"]
    if not isinstance(artifact, str):
        raise ContractError("PROVENANCE.json artifact_path must be a string")
    pure_path = pathlib.PurePosixPath(artifact)
    expected_prefix = ("artifacts", expected_commit)
    if (
        pure_path.is_absolute()
        or pure_path.parts[:2] != expected_prefix
        or any(part in ("", ".", "..") for part in pure_path.parts)
        or str(pure_path) != artifact
    ):
        raise ContractError(
            "PROVENANCE.json artifact_path must stay below artifacts/<source_commit>"
        )
    if document["manifest_algorithm"] != "SHA-256":
        raise ContractError("PROVENANCE.json manifest algorithm must be SHA-256")
    if document["manifest_signing_key_fingerprint"] != expected_key:
        raise ContractError("PROVENANCE.json signing key fingerprint is not pinned")
    if not SHA256_RE.fullmatch(str(document["finalizer_sha256"])):
        raise ContractError("PROVENANCE.json finalizer_sha256 is not lowercase SHA-256")
    repository_root = pathlib.Path(__file__).resolve().parents[2]
    try:
        finalizer_blob = subprocess.run(
            [
                "git",
                "-C",
                str(repository_root),
                "show",
                f"{expected_commit}:scripts/finalize_audit_artifacts.sh",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ContractError(
            "the exact source commit finalizer blob is unavailable"
        ) from exc
    expected_finalizer_digest = hashlib.sha256(finalizer_blob).hexdigest()
    if document["finalizer_sha256"] != expected_finalizer_digest:
        raise ContractError(
            "PROVENANCE.json finalizer_sha256 does not match the exact "
            "source commit finalizer"
        )
    _validate_utc_timestamp(document["finalized_at"], "finalized_at")


def _require_regular_record(path: pathlib.Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ContractError(f"required release record is unavailable: {path.name}") from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise ContractError(f"required release record is not a regular file: {path.name}")


def _sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ContractError(
                f"retained evidence is not a single-linked regular file: {path.name}"
            )
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
    except OSError as exc:
        raise ContractError(f"could not hash retained evidence: {path.name}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def _read_tsv(
    path: pathlib.Path, expected_header: tuple[str, str]
) -> tuple[bytes, list[tuple[str, str]]]:
    _require_regular_record(path)
    try:
        payload = path.read_bytes()
        text = payload.decode("utf-8")
    except (OSError, UnicodeError) as exc:
        raise ContractError(f"{path.name} is not valid UTF-8: {exc}") from exc
    if not text.endswith("\n"):
        raise ContractError(f"{path.name} must end with a newline")
    try:
        parsed = list(csv.reader(text.splitlines(), delimiter="\t", strict=True))
    except csv.Error as exc:
        raise ContractError(f"{path.name} is not valid two-column TSV") from exc
    if not parsed or tuple(parsed[0]) != expected_header:
        raise ContractError(
            f"{path.name} header must be exactly {expected_header[0]}\\t{expected_header[1]}"
        )
    rows: list[tuple[str, str]] = []
    for index, row in enumerate(parsed[1:], start=2):
        if len(row) != 2 or not row[0] or not row[1]:
            raise ContractError(f"{path.name} row {index} is not two non-empty fields")
        rows.append((row[0], row[1]))
    if not rows:
        raise ContractError(f"{path.name} contains no result rows")
    labels = [label for _, label in rows]
    if len(labels) != len(set(labels)):
        raise ContractError(f"{path.name} contains duplicate result labels")
    return payload, rows


def _validate_preflight(rows: list[tuple[str, str]]) -> None:
    if any(result != "PASS" for result, _ in rows):
        raise ContractError("sealed PREFLIGHT.tsv may contain only PASS results")
    checks = [check for _, check in rows]
    if len(checks) != len(EXPECTED_PREFLIGHT_CHECKS):
        raise ContractError(
            "PREFLIGHT.tsv does not contain the exact release preflight check count"
        )
    for index, (actual, expected) in enumerate(
        zip(checks, EXPECTED_PREFLIGHT_CHECKS, strict=True), start=1
    ):
        if expected is None:
            if not actual.startswith("live Wayland socket (") or not actual.endswith(")"):
                raise ContractError(
                    f"PREFLIGHT.tsv check {index} is not a live Wayland socket result"
                )
        elif actual != expected:
            raise ContractError(
                f"PREFLIGHT.tsv check {index} differs from the release contract"
            )


def _validate_summary(rows: list[tuple[str, str]]) -> None:
    if any(result != "PASS" for result, _ in rows):
        raise ContractError("sealed SUMMARY.tsv may contain only PASS results")
    suites = [suite for _, suite in rows]
    if suites != EXPECTED_RELEASE_SUITES:
        raise ContractError("SUMMARY.tsv does not contain the exact release suite manifest")


def _retained_release_path(
    artifact_dir: pathlib.Path, relative_path: str
) -> pathlib.Path:
    pure = pathlib.PurePosixPath(relative_path)
    if (
        pure.is_absolute()
        or not pure.parts
        or any(part in ("", ".", "..") for part in pure.parts)
        or str(pure) != relative_path
    ):
        raise ContractError(f"release evidence path is not canonical: {relative_path}")
    path = artifact_dir
    for index, component in enumerate(pure.parts):
        path /= component
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise ContractError(
                f"required retained release evidence is unavailable: {relative_path}"
            ) from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise ContractError(
                f"required retained release evidence contains a symlink: {relative_path}"
            )
        if index < len(pure.parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
            raise ContractError(
                f"required retained release evidence parent is not a directory: "
                f"{relative_path}"
            )
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ContractError(
            f"required retained release evidence is not a single-linked regular file: "
            f"{relative_path}"
        )
    if metadata.st_size <= 0:
        raise ContractError(
            f"required retained release evidence is empty: {relative_path}"
        )
    return path


def _read_release_json(
    artifact_dir: pathlib.Path, relative_path: str
) -> dict[str, Any]:
    return _read_json(_retained_release_path(artifact_dir, relative_path))


def _read_release_json_lines(
    artifact_dir: pathlib.Path, relative_path: str
) -> list[dict[str, Any]]:
    path = _retained_release_path(artifact_dir, relative_path)
    try:
        payload = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ContractError(
            f"{relative_path} is not retained UTF-8 JSON Lines"
        ) from exc
    if not payload.endswith("\n"):
        raise ContractError(f"{relative_path} must end with a newline")
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(payload.splitlines(), start=1):
        if not line:
            raise ContractError(
                f"{relative_path} line {line_number} must not be empty"
            )
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ContractError(
                f"{relative_path} line {line_number} is not valid JSON"
            ) from exc
        if not isinstance(value, dict):
            raise ContractError(
                f"{relative_path} line {line_number} must be one JSON object"
            )
        rows.append(value)
    if not rows:
        raise ContractError(f"{relative_path} contains no observations")
    return rows


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"{field} must be a finite number")
    converted = float(value)
    if not math.isfinite(converted):
        raise ContractError(f"{field} must be a finite number")
    return converted


def _nonnegative_number(value: Any, field: str) -> float:
    converted = _finite_number(value, field)
    if converted < 0:
        raise ContractError(f"{field} must be non-negative")
    return converted


def _integer(value: Any, field: str, minimum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError(f"{field} must be an integer")
    if minimum is not None and value < minimum:
        raise ContractError(f"{field} must be at least {minimum}")
    return value


def _expect_number(value: Any, expected: float, field: str) -> float:
    converted = _finite_number(value, field)
    if not math.isclose(converted, expected, rel_tol=1e-9, abs_tol=1e-9):
        raise ContractError(f"{field} must be exactly {expected}")
    return converted


def _numbers_match(
    value: Any, expected: float, field: str, *, absolute_tolerance: float = 1e-6
) -> float:
    converted = _finite_number(value, field)
    if not math.isclose(
        converted,
        float(expected),
        rel_tol=1e-9,
        abs_tol=absolute_tolerance,
    ):
        raise ContractError(f"{field} does not match the retained observations")
    return converted


def _performance_timestamp(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str) or not value or value != value.strip():
        raise ContractError(f"{field} must be one ISO-8601 UTC timestamp")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ContractError(f"{field} is not a valid ISO-8601 timestamp") from exc
    if parsed.utcoffset() != dt.timedelta(0):
        raise ContractError(f"{field} must identify UTC")
    return parsed


def _validate_time_window(document: dict[str, Any], label: str) -> None:
    started = _performance_timestamp(document["started_utc"], f"{label}.started_utc")
    completed = _performance_timestamp(
        document["completed_utc"], f"{label}.completed_utc"
    )
    if completed < started:
        raise ContractError(f"{label} completed before it started")


def _one_line(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or any(character in value for character in "\x00\r\n")
    ):
        raise ContractError(f"{field} must be one non-empty trimmed line")
    return value


def _absolute_path(value: Any, field: str) -> pathlib.PurePosixPath:
    text = _one_line(value, field)
    path = pathlib.PurePosixPath(text)
    if not path.is_absolute() or str(path) != text or ".." in path.parts:
        raise ContractError(f"{field} must be one canonical absolute path")
    return path


def _validate_geometry(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{field} must be an object")
    _require_exact_keys(value, {"x", "y", "width", "height"}, field)
    _integer(value["x"], f"{field}.x")
    _integer(value["y"], f"{field}.y")
    _integer(value["width"], f"{field}.width", 1)
    _integer(value["height"], f"{field}.height", 1)
    return value


def _validate_candidate_build(
    value: Any,
    expected_commit: str,
    label: str,
    expected_candidate: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    _require_exact_keys(value, PERFORMANCE_CANDIDATE_KEYS, label)
    if value["source_commit"] != expected_commit:
        raise ContractError(f"{label}.source_commit does not match the artifact key")
    cache_path = _absolute_path(value["cmake_cache"], f"{label}.cmake_cache")
    if (
        cache_path.name != "CMakeCache.txt"
        or cache_path.parent.name != "cmake-build-release-performance"
    ):
        raise ContractError(
            f"{label}.cmake_cache is not the fixed performance candidate cache"
        )
    fixed_values = {
        "cmake_build_type": "Release",
        "cmake_install_prefix": "/usr",
        "test_targets": "OFF",
        "coverage_instrumentation": "OFF",
        "qa_hooks": "OFF",
    }
    for key, expected in fixed_values.items():
        if value[key] != expected:
            raise ContractError(f"{label}.{key} must be exactly {expected}")
    if not isinstance(value["binary_sha256"], str) or not SHA256_RE.fullmatch(
        value["binary_sha256"]
    ):
        raise ContractError(f"{label}.binary_sha256 must be lowercase hexadecimal")
    _one_line(value["binary_version"], f"{label}.binary_version")
    if expected_candidate is not None and value != expected_candidate:
        raise ContractError(
            f"{label} does not identify the exact display-lifecycle candidate"
        )
    return value


def _validate_candidate_binary_path(
    value: Any, candidate: dict[str, Any], field: str
) -> str:
    binary = _absolute_path(value, field)
    cache = pathlib.PurePosixPath(candidate["cmake_cache"])
    if binary.name != "xeneon-edge-hub" or binary.parent != cache.parent:
        raise ContractError(
            f"{field} is not the Hub from the fixed performance candidate tree"
        )
    return str(binary)


def _validate_display_lifecycle(
    artifact_dir: pathlib.Path, expected_commit: str
) -> tuple[dict[str, Any], str, str]:
    label = "display-lifecycle/RESULT.json"
    result = _read_release_json(artifact_dir, label)
    _require_exact_keys(
        result,
        {
            "schema",
            "source_commit",
            "status",
            "restore_verified",
            "edge_output",
            "hub",
            "checks",
            "error",
        },
        label,
    )
    if result["schema"] != DISPLAY_LIFECYCLE_SCHEMA:
        raise ContractError(f"{label} schema is not {DISPLAY_LIFECYCLE_SCHEMA}")
    if result["source_commit"] != expected_commit:
        raise ContractError(f"{label} source_commit does not match the artifact key")
    if result["status"] != "PASS":
        raise ContractError(f"{label} status must be PASS")
    if result["restore_verified"] is not True:
        raise ContractError(f"{label} must prove verified display restoration")
    if result["error"] is not False:
        raise ContractError(f"{label} records a runtime error")
    edge_output = _one_line(result["edge_output"], f"{label}.edge_output")

    hub = result["hub"]
    if not isinstance(hub, dict):
        raise ContractError(f"{label}.hub must be an object")
    _require_exact_keys(
        hub, {"path", "sha256", "version", "candidate_build"}, f"{label}.hub"
    )
    candidate = _validate_candidate_build(
        hub["candidate_build"], expected_commit, f"{label}.hub.candidate_build"
    )
    binary_path = _validate_candidate_binary_path(
        hub["path"], candidate, f"{label}.hub.path"
    )
    if hub["sha256"] != candidate["binary_sha256"]:
        raise ContractError(f"{label}.hub.sha256 differs from candidate_build")
    if hub["version"] != candidate["binary_version"]:
        raise ContractError(f"{label}.hub.version differs from candidate_build")

    checks = result["checks"]
    if not isinstance(checks, list) or not checks:
        raise ContractError(f"{label}.checks must contain observed checks")
    names: list[str] = []
    for index, check in enumerate(checks):
        check_label = f"{label}.checks[{index}]"
        if not isinstance(check, dict):
            raise ContractError(f"{check_label} must be an object")
        _require_exact_keys(check, {"name", "status", "detail"}, check_label)
        names.append(_one_line(check["name"], f"{check_label}.name"))
        _one_line(check["detail"], f"{check_label}.detail")
        if check["status"] != "PASS":
            raise ContractError(
                f"{check_label} is not PASS; FAIL and NOT TESTED cannot seal"
            )
    if len(names) != len(set(names)):
        raise ContractError(f"{label}.checks contains duplicate check names")
    return candidate, edge_output, binary_path


def _validate_first_render_report(
    report: dict[str, Any],
    expected_commit: str,
    expected_candidate: dict[str, Any],
    expected_binary: str,
    expected_edge_output: str,
    label: str,
    metadata_kind: str,
) -> None:
    _require_exact_keys(
        report,
        {
            "schema_version",
            "evidence_type",
            "profile",
            "status",
            "qualified",
            "failures",
            "started_utc",
            "completed_utc",
            "limits",
            "metrics",
            "metadata",
        },
        label,
    )
    fixed = {
        "schema_version": 1,
        "evidence_type": "wayland-non-null-buffer-commit",
        "profile": "startup-first-render",
        "status": "PASS",
        "qualified": True,
        "failures": [],
    }
    for key, expected in fixed.items():
        if report[key] != expected:
            raise ContractError(f"{label}.{key} differs from the PASS contract")
    _validate_time_window(report, label)
    limits = report["limits"]
    if not isinstance(limits, dict):
        raise ContractError(f"{label}.limits must be an object")
    _require_exact_keys(limits, {"maximum_first_render_seconds"}, f"{label}.limits")
    _expect_number(
        limits["maximum_first_render_seconds"],
        2.0,
        f"{label}.limits.maximum_first_render_seconds",
    )
    metrics = report["metrics"]
    if not isinstance(metrics, dict):
        raise ContractError(f"{label}.metrics must be an object")
    _require_exact_keys(
        metrics,
        {"first_render_upper_bound_seconds", "observer_timeout_seconds"},
        f"{label}.metrics",
    )
    first_frame = _nonnegative_number(
        metrics["first_render_upper_bound_seconds"],
        f"{label}.metrics.first_render_upper_bound_seconds",
    )
    if first_frame >= 2.0:
        raise ContractError(f"{label} does not meet the first-render SLO")
    _expect_number(
        metrics["observer_timeout_seconds"],
        10.0,
        f"{label}.metrics.observer_timeout_seconds",
    )

    metadata = report["metadata"]
    if not isinstance(metadata, dict):
        raise ContractError(f"{label}.metadata must be an object")
    base_keys = {"command", "log_path", "note"}
    if metadata_kind == "short":
        expected_keys = base_keys | {
            "application",
            "binary",
            "git_revision",
            "mode",
            "edge_output",
            "edge_geometry",
            "warmup_seconds",
            "active_widget_types",
            "candidate_build",
        }
        _require_exact_keys(metadata, expected_keys, f"{label}.metadata")
        candidate = _validate_candidate_build(
            metadata["candidate_build"],
            expected_commit,
            f"{label}.metadata.candidate_build",
            expected_candidate,
        )
        if metadata["application"] != "xeneon-edge-hub":
            raise ContractError(f"{label}.metadata.application is not the Hub")
        if metadata["mode"] != "startup":
            raise ContractError(f"{label}.metadata.mode must be startup")
        if metadata["edge_output"] != expected_edge_output:
            raise ContractError(f"{label}.metadata.edge_output differs from display evidence")
        _validate_geometry(metadata["edge_geometry"], f"{label}.metadata.edge_geometry")
        _expect_number(
            metadata["warmup_seconds"], 30.0, f"{label}.metadata.warmup_seconds"
        )
        if metadata["active_widget_types"] != []:
            raise ContractError(
                f"{label}.metadata.active_widget_types must be empty at startup"
            )
        _one_line(metadata["git_revision"], f"{label}.metadata.git_revision")
        if str(metadata["git_revision"]).endswith("-dirty"):
            raise ContractError(f"{label}.metadata.git_revision records a dirty tree")
        binary_value = metadata["binary"]
    elif metadata_kind == "audit-14":
        expected_keys = base_keys | {
            "candidate",
            "widget_count",
            "edge_output",
        }
        _require_exact_keys(metadata, expected_keys, f"{label}.metadata")
        candidate = _validate_candidate_build(
            metadata["candidate"],
            expected_commit,
            f"{label}.metadata.candidate",
            expected_candidate,
        )
        _integer(metadata["widget_count"], f"{label}.metadata.widget_count", 1)
        if metadata["widget_count"] != len(AUDIT_14_WIDGET_TYPES):
            raise ContractError(f"{label}.metadata.widget_count must be exactly 14")
        if metadata["edge_output"] != expected_edge_output:
            raise ContractError(f"{label}.metadata.edge_output differs from display evidence")
        command = metadata["command"]
        binary_value = command[0] if isinstance(command, list) and command else None
    else:
        raise ContractError(f"internal unknown first-render metadata kind: {metadata_kind}")
    if candidate != expected_candidate:
        raise ContractError(f"{label} does not identify the exact candidate")
    if metadata["command"] != [expected_binary]:
        raise ContractError(f"{label}.metadata.command does not launch the exact candidate")
    if binary_value != expected_binary:
        raise ContractError(f"{label}.metadata.binary differs from the exact candidate")
    _one_line(metadata["log_path"], f"{label}.metadata.log_path")
    if metadata["note"] != (
        "control-socket readiness is intentionally not accepted as first-render evidence"
    ):
        raise ContractError(f"{label}.metadata.note differs from the observer contract")


RESOURCE_METRIC_KEYS = {
    "requested_duration_seconds",
    "observed_duration_seconds",
    "sampling_interval_seconds",
    "sample_count",
    "maximum_sample_gap_seconds",
    "process_count",
    "process_identities",
    "average_cpu_percent",
    "maximum_interval_cpu_percent",
    "rss_final_mib",
    "rss_peak_mib",
    "threads_initial",
    "threads_final",
    "threads_peak",
    "threads_delta",
    "file_descriptors_initial",
    "file_descriptors_final",
    "file_descriptors_peak",
    "file_descriptors_delta",
    "socket_descriptors_initial",
    "socket_descriptors_final",
    "socket_descriptors_peak",
    "socket_descriptors_delta",
    "read_bytes_delta",
    "write_bytes_delta",
    "log_bytes_delta",
    "rss_trend",
    "duration_qualifications",
    "network_bytes",
    "network_measurement_note",
    "gpu_usage",
    "gpu_measurement_note",
}
RESOURCE_SAMPLE_KEYS = {
    "elapsed_seconds",
    "cpu_ticks",
    "rss_bytes",
    "threads",
    "file_descriptors",
    "socket_descriptors",
    "read_bytes",
    "write_bytes",
    "log_bytes",
}


def _validate_observation_sequence(
    observations: list[dict[str, Any]],
    expected_keys: set[str],
    label: str,
    *,
    gpu_required: bool = False,
) -> list[dict[str, Any]]:
    if len(observations) < 2:
        raise ContractError(f"{label} must contain at least two observations")
    normalized: list[dict[str, Any]] = []
    previous: dict[str, Any] | None = None
    for index, observation in enumerate(observations):
        entry_label = f"{label}[{index}]"
        if not isinstance(observation, dict):
            raise ContractError(f"{entry_label} must be an object")
        _require_exact_keys(observation, expected_keys, entry_label)
        normalized_entry = {
            "elapsed_seconds": _nonnegative_number(
                observation["elapsed_seconds"], f"{entry_label}.elapsed_seconds"
            ),
            "cpu_ticks": _integer(
                observation["cpu_ticks"], f"{entry_label}.cpu_ticks", 0
            ),
            "rss_bytes": _integer(
                observation["rss_bytes"], f"{entry_label}.rss_bytes", 1
            ),
            "threads": _integer(
                observation["threads"], f"{entry_label}.threads", 1
            ),
            "file_descriptors": _integer(
                observation["file_descriptors"],
                f"{entry_label}.file_descriptors",
                0,
            ),
        }
        for key in (
            "socket_descriptors",
            "read_bytes",
            "write_bytes",
        ):
            if key in observation:
                normalized_entry[key] = _integer(
                    observation[key], f"{entry_label}.{key}", 0
                )
        if "log_bytes" in observation:
            log_bytes = observation["log_bytes"]
            normalized_entry["log_bytes"] = (
                None
                if log_bytes is None
                else _integer(log_bytes, f"{entry_label}.log_bytes", 0)
            )
        if "gpu_memory_mib" in observation:
            gpu = observation["gpu_memory_mib"]
            if gpu_required and gpu is None:
                raise ContractError(f"{entry_label}.gpu_memory_mib is unavailable")
            normalized_entry["gpu_memory_mib"] = (
                None
                if gpu is None
                else _nonnegative_number(gpu, f"{entry_label}.gpu_memory_mib")
            )
        if previous is not None:
            if (
                normalized_entry["elapsed_seconds"]
                <= previous["elapsed_seconds"]
            ):
                raise ContractError(f"{label} elapsed time is not strictly increasing")
            for key in ("cpu_ticks", "read_bytes", "write_bytes"):
                if (
                    key in normalized_entry
                    and normalized_entry[key] < previous[key]
                ):
                    raise ContractError(f"{label} {key} moved backwards")
            if (
                normalized_entry.get("log_bytes") is not None
                and previous.get("log_bytes") is not None
                and normalized_entry["log_bytes"] < previous["log_bytes"]
            ):
                raise ContractError(f"{label} log_bytes moved backwards")
        previous = normalized_entry
        normalized.append(normalized_entry)
    if not math.isclose(
        normalized[0]["elapsed_seconds"], 0.0, rel_tol=0.0, abs_tol=1e-6
    ):
        raise ContractError(f"{label} must start at zero elapsed seconds")
    return normalized


def _linear_trend(xs: list[float], ys: list[float]) -> tuple[float, float]:
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    if denominator <= 0:
        raise ContractError("retained observations have no elapsed-time span")
    slope = sum(
        (x - x_mean) * (y - y_mean) for x, y in zip(xs, ys, strict=True)
    ) / denominator
    total = sum((y - y_mean) ** 2 for y in ys)
    residual = sum(
        (y - (y_mean + slope * (x - x_mean))) ** 2
        for x, y in zip(xs, ys, strict=True)
    )
    return slope * 3600.0, (
        1.0 if total == 0 else max(0.0, 1.0 - residual / total)
    )


def _validate_rss_trend(
    value: Any, observations: list[dict[str, Any]], label: str
) -> None:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    expected_keys = {
        "least_squares_mib_per_hour",
        "first_window_median_mib",
        "last_window_median_mib",
        "window_sample_count",
        "growth_percent",
    }
    _require_exact_keys(value, expected_keys, label)
    elapsed = [entry["elapsed_seconds"] for entry in observations]
    rss = [entry["rss_bytes"] / (1024.0 * 1024.0) for entry in observations]
    slope, _ = _linear_trend(elapsed, rss)
    window = max(1, len(rss) // 5)
    first_median = statistics.median(rss[:window])
    last_median = statistics.median(rss[-window:])
    growth = (last_median - first_median) / first_median * 100.0
    _numbers_match(
        value["least_squares_mib_per_hour"],
        slope,
        f"{label}.least_squares_mib_per_hour",
    )
    _numbers_match(
        value["first_window_median_mib"],
        first_median,
        f"{label}.first_window_median_mib",
    )
    _numbers_match(
        value["last_window_median_mib"],
        last_median,
        f"{label}.last_window_median_mib",
    )
    if value["window_sample_count"] != window:
        raise ContractError(f"{label}.window_sample_count does not match observations")
    _numbers_match(value["growth_percent"], growth, f"{label}.growth_percent")


def _validate_process_identities(value: Any, expected_count: int, field: str) -> None:
    if not isinstance(value, list) or len(value) != expected_count:
        raise ContractError(f"{field} must contain exactly {expected_count} identities")
    identities: list[tuple[int, int]] = []
    for index, identity in enumerate(value):
        if not isinstance(identity, list) or len(identity) != 2:
            raise ContractError(f"{field}[{index}] must be [pid, start_ticks]")
        identities.append(
            (
                _integer(identity[0], f"{field}[{index}][0]", 1),
                _integer(identity[1], f"{field}[{index}][1]", 1),
            )
        )
    if len(identities) != len(set(identities)):
        raise ContractError(f"{field} contains duplicate process identities")


def _validate_resource_metrics(
    metrics: Any,
    observations: list[dict[str, Any]],
    *,
    requested_duration: float,
    sampling_interval: float,
    maximum_average_cpu: float,
    maximum_rss_mib: float,
    label: str,
    clock_ticks_per_second: int | None,
    minimum_observed_duration: float | None = None,
) -> dict[str, Any]:
    if not isinstance(metrics, dict):
        raise ContractError(f"{label} must be an object")
    _require_exact_keys(metrics, RESOURCE_METRIC_KEYS, label)
    _expect_number(
        metrics["requested_duration_seconds"],
        requested_duration,
        f"{label}.requested_duration_seconds",
    )
    _expect_number(
        metrics["sampling_interval_seconds"],
        sampling_interval,
        f"{label}.sampling_interval_seconds",
    )
    if metrics["sample_count"] != len(observations):
        raise ContractError(f"{label}.sample_count differs from retained observations")
    elapsed = observations[-1]["elapsed_seconds"] - observations[0]["elapsed_seconds"]
    _numbers_match(
        metrics["observed_duration_seconds"],
        elapsed,
        f"{label}.observed_duration_seconds",
    )
    required_observed_duration = (
        requested_duration
        if minimum_observed_duration is None
        else minimum_observed_duration
    )
    if elapsed + 1e-6 < required_observed_duration:
        raise ContractError(f"{label} did not complete its required observation window")
    minimum_samples = math.ceil(
        (math.floor(requested_duration / sampling_interval) + 1) * 0.95
    )
    if len(observations) < minimum_samples:
        raise ContractError(
            f"{label} retained {len(observations)} samples; "
            f"at least {minimum_samples} are required"
        )
    gaps = [
        current["elapsed_seconds"] - previous["elapsed_seconds"]
        for previous, current in zip(observations, observations[1:])
    ]
    maximum_gap = max(gaps)
    _numbers_match(
        metrics["maximum_sample_gap_seconds"],
        maximum_gap,
        f"{label}.maximum_sample_gap_seconds",
    )
    if maximum_gap > max(sampling_interval * 3.0, sampling_interval + 0.25):
        raise ContractError(f"{label} contains an excessive sampling gap")

    process_count = _integer(
        metrics["process_count"], f"{label}.process_count", 1
    )
    _validate_process_identities(
        metrics["process_identities"],
        process_count,
        f"{label}.process_identities",
    )
    average_cpu = _nonnegative_number(
        metrics["average_cpu_percent"], f"{label}.average_cpu_percent"
    )
    if average_cpu >= maximum_average_cpu:
        raise ContractError(f"{label} exceeds its average CPU budget")
    maximum_interval_cpu = _nonnegative_number(
        metrics["maximum_interval_cpu_percent"],
        f"{label}.maximum_interval_cpu_percent",
    )
    if clock_ticks_per_second is not None:
        expected_average = (
            (observations[-1]["cpu_ticks"] - observations[0]["cpu_ticks"])
            / clock_ticks_per_second
            / elapsed
            * 100.0
        )
        _numbers_match(
            average_cpu, expected_average, f"{label}.average_cpu_percent"
        )
        expected_maximum = max(
            (
                current["cpu_ticks"] - previous["cpu_ticks"]
            )
            / clock_ticks_per_second
            / gap
            * 100.0
            for previous, current, gap in zip(
                observations[:-1], observations[1:], gaps, strict=True
            )
        )
        _numbers_match(
            maximum_interval_cpu,
            expected_maximum,
            f"{label}.maximum_interval_cpu_percent",
        )

    rss_final = observations[-1]["rss_bytes"] / (1024.0 * 1024.0)
    rss_peak = max(entry["rss_bytes"] for entry in observations) / (
        1024.0 * 1024.0
    )
    _numbers_match(metrics["rss_final_mib"], rss_final, f"{label}.rss_final_mib")
    _numbers_match(metrics["rss_peak_mib"], rss_peak, f"{label}.rss_peak_mib")
    if rss_peak >= maximum_rss_mib:
        raise ContractError(f"{label} exceeds its RSS budget")

    exact_series = {
        "threads": "threads",
        "file_descriptors": "file_descriptors",
        "socket_descriptors": "socket_descriptors",
    }
    for prefix, key in exact_series.items():
        initial = _integer(
            metrics[f"{prefix}_initial"], f"{label}.{prefix}_initial", 0
        )
        final = _integer(
            metrics[f"{prefix}_final"], f"{label}.{prefix}_final", 0
        )
        peak = _integer(metrics[f"{prefix}_peak"], f"{label}.{prefix}_peak", 0)
        delta = _integer(metrics[f"{prefix}_delta"], f"{label}.{prefix}_delta")
        if key in observations[0]:
            values = [entry[key] for entry in observations]
            if (
                initial != values[0]
                or final != values[-1]
                or peak != max(values)
                or delta != values[-1] - values[0]
            ):
                raise ContractError(
                    f"{label}.{prefix} metrics differ from retained observations"
                )

    for metric_key, observation_key in (
        ("read_bytes_delta", "read_bytes"),
        ("write_bytes_delta", "write_bytes"),
    ):
        reported = _integer(metrics[metric_key], f"{label}.{metric_key}", 0)
        if observation_key in observations[0]:
            expected_delta = (
                observations[-1][observation_key]
                - observations[0][observation_key]
            )
            if reported != expected_delta:
                raise ContractError(
                    f"{label}.{metric_key} differs from retained observations"
                )
    log_delta = metrics["log_bytes_delta"]
    if "log_bytes" not in observations[0]:
        if log_delta is not None:
            _integer(log_delta, f"{label}.log_bytes_delta", 0)
    elif observations[0]["log_bytes"] is None or observations[-1][
        "log_bytes"
    ] is None:
        if log_delta is not None:
            raise ContractError(f"{label}.log_bytes_delta must be null")
    else:
        expected_log_delta = (
            observations[-1]["log_bytes"] - observations[0]["log_bytes"]
        )
        if log_delta != expected_log_delta:
            raise ContractError(
                f"{label}.log_bytes_delta differs from retained observations"
            )

    _validate_rss_trend(metrics["rss_trend"], observations, f"{label}.rss_trend")
    qualifications = metrics["duration_qualifications"]
    if not isinstance(qualifications, dict):
        raise ContractError(f"{label}.duration_qualifications must be an object")
    _require_exact_keys(
        qualifications,
        {"five_minutes", "twenty_four_hours", "forty_eight_hours"},
        f"{label}.duration_qualifications",
    )
    expected_qualifications = {
        "five_minutes": elapsed >= 300.0,
        "twenty_four_hours": elapsed >= 24.0 * 60.0 * 60.0,
        "forty_eight_hours": elapsed >= 48.0 * 60.0 * 60.0,
    }
    if qualifications != expected_qualifications:
        raise ContractError(
            f"{label}.duration_qualifications differ from observed duration"
        )
    fixed_values = {
        "network_bytes": None,
        "network_measurement_note": (
            "not available from /proc; socket descriptors are recorded"
        ),
        "gpu_usage": None,
        "gpu_measurement_note": (
            "no portable per-process Linux counter is available"
        ),
    }
    for key, expected in fixed_values.items():
        if metrics[key] != expected:
            raise ContractError(f"{label}.{key} differs from the measurement contract")
    return metrics


def _validate_short_observed_load(
    value: Any, profile: str, label: str
) -> None:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    expected_keys = {
        "observed_page_count",
        "observed_widget_count",
        "observed_widget_types",
        "observed_tile_sizes",
        "observed_current_page",
        "live_state_verified",
    }
    _require_exact_keys(value, expected_keys, label)
    expected_types = (
        list(SHORT_ACTIVE_WIDGET_TYPES) if profile == "active-10x5m" else []
    )
    expected = {
        "observed_page_count": 1,
        "observed_widget_count": len(expected_types),
        "observed_widget_types": expected_types,
        "observed_tile_sizes": ["1x1"] * len(expected_types),
        "observed_current_page": 0,
        "live_state_verified": True,
    }
    if value != expected:
        raise ContractError(f"{label} differs from the fixed live profile")


def _validate_short_resource_report(
    report: dict[str, Any],
    profile: str,
    expected_commit: str,
    expected_candidate: dict[str, Any],
    expected_binary: str,
    expected_edge_output: str,
    label: str,
) -> None:
    expected_keys = {
        "schema_version",
        "evidence_type",
        "profile",
        "status",
        "qualified",
        "failures",
        "started_utc",
        "completed_utc",
        "host",
        "load",
        "limits",
        "metrics",
        "metadata",
        "samples",
    }
    _require_exact_keys(report, expected_keys, label)
    fixed = {
        "schema_version": 1,
        "evidence_type": "linux-proc-process-tree",
        "profile": profile,
        "status": "PASS",
        "qualified": True,
        "failures": [],
    }
    for key, expected in fixed.items():
        if report[key] != expected:
            raise ContractError(f"{label}.{key} differs from the PASS contract")
    _validate_time_window(report, label)

    if profile == "idle-5m":
        widget_count, max_cpu, max_rss, mode = 0, 1.0, 150.0, "idle"
        expected_types: list[str] = []
    elif profile == "active-10x5m":
        widget_count, max_cpu, max_rss, mode = (
            len(SHORT_ACTIVE_WIDGET_TYPES),
            5.0,
            250.0,
            "active",
        )
        expected_types = list(SHORT_ACTIVE_WIDGET_TYPES)
    else:
        raise ContractError(f"unknown short resource profile: {profile}")

    host = report["host"]
    if not isinstance(host, dict):
        raise ContractError(f"{label}.host must be an object")
    _require_exact_keys(
        host,
        {"platform", "logical_cpu_count", "clock_ticks_per_second"},
        f"{label}.host",
    )
    _one_line(host["platform"], f"{label}.host.platform")
    _integer(host["logical_cpu_count"], f"{label}.host.logical_cpu_count", 1)
    clock_ticks = _integer(
        host["clock_ticks_per_second"],
        f"{label}.host.clock_ticks_per_second",
        1,
    )
    if report["load"] != {"widget_count": widget_count}:
        raise ContractError(f"{label}.load differs from the fixed profile")
    expected_limits = {
        "name": profile,
        "minimum_duration_seconds": 300.0,
        "maximum_average_cpu_percent": max_cpu,
        "maximum_rss_mib": max_rss,
        "required_widget_count": widget_count,
        "maximum_rss_growth_percent": None,
    }
    if report["limits"] != expected_limits:
        raise ContractError(f"{label}.limits differs from the literal gate")

    samples = report["samples"]
    if not isinstance(samples, list):
        raise ContractError(f"{label}.samples must be a list")
    observations = _validate_observation_sequence(
        samples, RESOURCE_SAMPLE_KEYS, f"{label}.samples"
    )
    _validate_resource_metrics(
        report["metrics"],
        observations,
        requested_duration=300.0,
        sampling_interval=1.0,
        maximum_average_cpu=max_cpu,
        maximum_rss_mib=max_rss,
        label=f"{label}.metrics",
        clock_ticks_per_second=clock_ticks,
    )

    metadata = report["metadata"]
    if not isinstance(metadata, dict):
        raise ContractError(f"{label}.metadata must be an object")
    metadata_keys = {
        "application",
        "binary",
        "git_revision",
        "mode",
        "edge_output",
        "edge_geometry",
        "warmup_seconds",
        "active_widget_types",
        "candidate_build",
        "control_socket_ready_seconds_diagnostic_only",
        "control_socket_note",
        "observed_load",
    }
    _require_exact_keys(metadata, metadata_keys, f"{label}.metadata")
    if metadata["application"] != "xeneon-edge-hub":
        raise ContractError(f"{label}.metadata.application is not the Hub")
    if metadata["mode"] != mode:
        raise ContractError(f"{label}.metadata.mode differs from its profile")
    if metadata["edge_output"] != expected_edge_output:
        raise ContractError(f"{label}.metadata.edge_output differs from display evidence")
    if metadata["active_widget_types"] != expected_types:
        raise ContractError(f"{label}.metadata.active_widget_types differs")
    _validate_candidate_binary_path(
        metadata["binary"], expected_candidate, f"{label}.metadata.binary"
    )
    if metadata["binary"] != expected_binary:
        raise ContractError(f"{label}.metadata.binary differs from the exact candidate")
    _validate_candidate_build(
        metadata["candidate_build"],
        expected_commit,
        f"{label}.metadata.candidate_build",
        expected_candidate,
    )
    _validate_geometry(metadata["edge_geometry"], f"{label}.metadata.edge_geometry")
    _expect_number(
        metadata["warmup_seconds"], 30.0, f"{label}.metadata.warmup_seconds"
    )
    _nonnegative_number(
        metadata["control_socket_ready_seconds_diagnostic_only"],
        f"{label}.metadata.control_socket_ready_seconds_diagnostic_only",
    )
    if metadata["control_socket_note"] != (
        "not accepted as startup-to-first-render evidence"
    ):
        raise ContractError(f"{label}.metadata.control_socket_note differs")
    revision = _one_line(
        metadata["git_revision"], f"{label}.metadata.git_revision"
    )
    if revision.endswith("-dirty"):
        raise ContractError(f"{label}.metadata.git_revision records a dirty tree")
    _validate_short_observed_load(
        metadata["observed_load"], profile, f"{label}.metadata.observed_load"
    )


def _validate_short_performance(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_candidate: dict[str, Any],
    expected_binary: str,
    expected_edge_output: str,
) -> None:
    root = "performance/short"
    summary_label = f"{root}/summary.json"
    summary = _read_release_json(artifact_dir, summary_label)
    _require_exact_keys(
        summary,
        {
            "schema_version",
            "evidence_type",
            "mode",
            "status",
            "qualified",
            "started_utc",
            "completed_utc",
            "scope_note",
            "profiles",
        },
        summary_label,
    )
    fixed = {
        "schema_version": 1,
        "evidence_type": "xeneon-hub-performance-run",
        "mode": "short",
        "status": "PASS",
        "qualified": True,
        "scope_note": (
            "This run qualifies only startup and the two five-minute gates. "
            "It does not qualify either long-duration trend requirement."
        ),
    }
    for key, expected in fixed.items():
        if summary[key] != expected:
            raise ContractError(f"{summary_label}.{key} differs from the PASS contract")
    _validate_time_window(summary, summary_label)
    profiles = summary["profiles"]
    if not isinstance(profiles, list) or len(profiles) != len(
        SHORT_PERFORMANCE_PROFILES
    ):
        raise ContractError(
            f"{summary_label}.profiles must contain the exact three short gates"
        )
    for index, (entry, expected_profile) in enumerate(
        zip(profiles, SHORT_PERFORMANCE_PROFILES, strict=True)
    ):
        entry_label = f"{summary_label}.profiles[{index}]"
        if not isinstance(entry, dict):
            raise ContractError(f"{entry_label} must be an object")
        _require_exact_keys(
            entry, {"profile", "status", "qualified", "failures"}, entry_label
        )
        expected = {
            "profile": expected_profile,
            "status": "PASS",
            "qualified": True,
            "failures": [],
        }
        if entry != expected:
            raise ContractError(f"{entry_label} differs from the PASS contract")

    startup_label = f"{root}/startup-first-render.json"
    startup = _read_release_json(artifact_dir, startup_label)
    _validate_first_render_report(
        startup,
        expected_commit,
        expected_candidate,
        expected_binary,
        expected_edge_output,
        startup_label,
        "short",
    )
    for profile in ("idle-5m", "active-10x5m"):
        report_label = f"{root}/{profile}.json"
        _validate_short_resource_report(
            _read_release_json(artifact_dir, report_label),
            profile,
            expected_commit,
            expected_candidate,
            expected_binary,
            expected_edge_output,
            report_label,
        )


AUDIT_TRACE_KEYS = {
    "elapsed_seconds",
    "cpu_ticks",
    "rss_bytes",
    "threads",
    "file_descriptors",
    "gpu_memory_mib",
}


def _validate_trend(
    value: Any,
    observations: list[dict[str, Any]],
    observation_key: str | None,
    label: str,
) -> None:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    _require_exact_keys(value, {"per_hour", "r_squared"}, label)
    per_hour = _finite_number(value["per_hour"], f"{label}.per_hour")
    r_squared = _finite_number(value["r_squared"], f"{label}.r_squared")
    if r_squared < 0.0 or r_squared > 1.0:
        raise ContractError(f"{label}.r_squared must be between zero and one")
    if observation_key is None:
        return
    elapsed = [entry["elapsed_seconds"] for entry in observations]
    if observation_key == "rss_bytes":
        values = [
            entry[observation_key] / (1024.0 * 1024.0)
            for entry in observations
        ]
    else:
        values = [float(entry[observation_key]) for entry in observations]
    expected_per_hour, expected_r_squared = _linear_trend(elapsed, values)
    _numbers_match(per_hour, expected_per_hour, f"{label}.per_hour")
    _numbers_match(
        r_squared, expected_r_squared, f"{label}.r_squared"
    )


def _validate_audit_14_load(value: Any, label: str) -> None:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    expected = {
        "page_count": 1,
        "widget_count": len(AUDIT_14_WIDGET_TYPES),
        "widget_types": list(AUDIT_14_WIDGET_TYPES),
        "widget_sizes": ["0.5x0.5"] * len(AUDIT_14_WIDGET_TYPES),
        "current_page": 0,
        "verified": True,
    }
    _require_exact_keys(value, set(expected), label)
    if value != expected:
        raise ContractError(f"{label} differs from the fixed 14-widget live load")


def _validate_audit_14_performance(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_candidate: dict[str, Any],
    expected_binary: str,
    expected_edge_output: str,
) -> None:
    root = "performance/14-widget-30m"
    label = f"{root}/report.json"
    report = _read_release_json(artifact_dir, label)
    expected_keys = {
        "schema_version",
        "evidence_type",
        "status",
        "qualified",
        "failures",
        "qualification_note",
        "accepted_risk",
        "started_utc",
        "completed_utc",
        "candidate",
        "edge_output",
        "edge_geometry",
        "load",
        "warmup_seconds",
        "sample_interval_seconds",
        "startup",
        "metrics",
    }
    _require_exact_keys(report, expected_keys, label)
    fixed = {
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
    }
    for key, expected in fixed.items():
        if report[key] != expected:
            raise ContractError(f"{label}.{key} differs from the PASS contract")
    _validate_time_window(report, label)
    _validate_candidate_build(
        report["candidate"],
        expected_commit,
        f"{label}.candidate",
        expected_candidate,
    )
    if report["edge_output"] != expected_edge_output:
        raise ContractError(f"{label}.edge_output differs from display evidence")
    _validate_geometry(report["edge_geometry"], f"{label}.edge_geometry")
    _validate_audit_14_load(report["load"], f"{label}.load")
    _expect_number(report["warmup_seconds"], 30.0, f"{label}.warmup_seconds")
    _expect_number(
        report["sample_interval_seconds"],
        30.0,
        f"{label}.sample_interval_seconds",
    )

    startup_label = f"{root}/startup-first-render.json"
    retained_startup = _read_release_json(artifact_dir, startup_label)
    if report["startup"] != retained_startup:
        raise ContractError(f"{label}.startup differs from its retained report")
    _validate_first_render_report(
        retained_startup,
        expected_commit,
        expected_candidate,
        expected_binary,
        expected_edge_output,
        startup_label,
        "audit-14",
    )

    trace_label = f"{root}/samples.jsonl"
    trace = _validate_observation_sequence(
        _read_release_json_lines(artifact_dir, trace_label),
        AUDIT_TRACE_KEYS,
        trace_label,
        gpu_required=True,
    )
    metrics = report["metrics"]
    if not isinstance(metrics, dict):
        raise ContractError(f"{label}.metrics must be an object")
    _require_exact_keys(
        metrics,
        RESOURCE_METRIC_KEYS | {"slopes", "steady_state_last_20m", "gpu_memory"},
        f"{label}.metrics",
    )
    base_metrics = {
        key: metrics[key]
        for key in RESOURCE_METRIC_KEYS
    }
    _validate_resource_metrics(
        base_metrics,
        trace,
        requested_duration=1800.0,
        sampling_interval=30.0,
        maximum_average_cpu=5.0,
        maximum_rss_mib=250.0,
        label=f"{label}.metrics",
        clock_ticks_per_second=None,
    )

    steady_trace = [
        observation
        for observation in trace
        if observation["elapsed_seconds"] >= 600.0
    ]
    steady_metrics = _validate_resource_metrics(
        metrics["steady_state_last_20m"],
        steady_trace,
        requested_duration=1200.0,
        sampling_interval=30.0,
        maximum_average_cpu=5.0,
        maximum_rss_mib=250.0,
        label=f"{label}.metrics.steady_state_last_20m",
        clock_ticks_per_second=None,
        minimum_observed_duration=1170.0,
    )
    if _finite_number(
        steady_metrics["average_cpu_percent"],
        f"{label}.metrics.steady_state_last_20m.average_cpu_percent",
    ) >= 5.0:
        raise ContractError(f"{label} exceeds its steady-state CPU budget")

    slopes = metrics["slopes"]
    if not isinstance(slopes, dict):
        raise ContractError(f"{label}.metrics.slopes must be an object")
    _require_exact_keys(
        slopes,
        {
            "rss_mib",
            "file_descriptors",
            "threads",
            "cpu_percent",
            "gpu_memory_mib",
        },
        f"{label}.metrics.slopes",
    )
    trend_sources = {
        "rss_mib": "rss_bytes",
        "file_descriptors": "file_descriptors",
        "threads": "threads",
        "cpu_percent": None,
        "gpu_memory_mib": "gpu_memory_mib",
    }
    for key, source_key in trend_sources.items():
        _validate_trend(
            slopes[key],
            trace,
            source_key,
            f"{label}.metrics.slopes.{key}",
        )

    gpu = metrics["gpu_memory"]
    if not isinstance(gpu, dict):
        raise ContractError(f"{label}.metrics.gpu_memory must be an object")
    _require_exact_keys(
        gpu,
        {"available", "initial_mib", "final_mib", "peak_mib", "method"},
        f"{label}.metrics.gpu_memory",
    )
    gpu_values = [entry["gpu_memory_mib"] for entry in trace]
    if gpu["available"] is not True:
        raise ContractError(f"{label}.metrics.gpu_memory is not fully available")
    _numbers_match(
        gpu["initial_mib"],
        gpu_values[0],
        f"{label}.metrics.gpu_memory.initial_mib",
    )
    _numbers_match(
        gpu["final_mib"],
        gpu_values[-1],
        f"{label}.metrics.gpu_memory.final_mib",
    )
    _numbers_match(
        gpu["peak_mib"],
        max(gpu_values),
        f"{label}.metrics.gpu_memory.peak_mib",
    )
    if gpu["method"] != (
        "deduplicated DRM client resident VRAM plus GTT from /proc/PID/fdinfo"
    ):
        raise ContractError(f"{label}.metrics.gpu_memory.method differs")


def _nearest_rank_percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    rank = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[rank]


def _validate_rotation_transition(
    transition: Any,
    index: int,
    refresh_hz: float,
    nominal_interval: float,
    label: str,
) -> tuple[list[float], int, int]:
    transition_label = f"{label}.transitions[{index}]"
    if not isinstance(transition, dict):
        raise ContractError(f"{transition_label} must be an object")
    _require_exact_keys(
        transition,
        {
            "from",
            "to",
            "request_started_monotonic_ms",
            "acknowledged_monotonic_ms",
            "ack_latency_ms",
            "reported_rotation",
            "frames",
            "smoothness_slo",
        },
        transition_label,
    )
    expected_to = "landscape" if index % 2 == 0 else "portrait"
    expected_from = "portrait" if expected_to == "landscape" else "landscape"
    if transition["from"] != expected_from or transition["to"] != expected_to:
        raise ContractError(f"{transition_label} is not the expected quarter-turn")
    expected_rotation = 90 if expected_to == "landscape" else 0
    if transition["reported_rotation"] != expected_rotation:
        raise ContractError(f"{transition_label}.reported_rotation differs")
    requested = _nonnegative_number(
        transition["request_started_monotonic_ms"],
        f"{transition_label}.request_started_monotonic_ms",
    )
    acknowledged = _nonnegative_number(
        transition["acknowledged_monotonic_ms"],
        f"{transition_label}.acknowledged_monotonic_ms",
    )
    if acknowledged < requested:
        raise ContractError(f"{transition_label} was acknowledged before its request")
    _numbers_match(
        transition["ack_latency_ms"],
        acknowledged - requested,
        f"{transition_label}.ack_latency_ms",
    )

    frames = transition["frames"]
    if not isinstance(frames, dict):
        raise ContractError(f"{transition_label}.frames must be an object")
    _require_exact_keys(
        frames,
        {
            "surface",
            "frame_callback_count",
            "first_frame_after_request_ms",
            "observation_span_ms",
            "effective_callback_rate_hz",
            "interval_ms",
            "interval_count_over_1_5_refreshes",
            "estimated_missed_refreshes",
            "frame_callback_timestamps_ms",
        },
        f"{transition_label}.frames",
    )
    _one_line(frames["surface"], f"{transition_label}.frames.surface")
    timestamps_value = frames["frame_callback_timestamps_ms"]
    if not isinstance(timestamps_value, list):
        raise ContractError(
            f"{transition_label}.frames.frame_callback_timestamps_ms must be a list"
        )
    timestamps = [
        _nonnegative_number(
            value,
            f"{transition_label}.frames.frame_callback_timestamps_ms[{timestamp_index}]",
        )
        for timestamp_index, value in enumerate(timestamps_value)
    ]
    if len(timestamps) < 3 or any(
        later <= earlier
        for earlier, later in zip(timestamps, timestamps[1:])
    ):
        raise ContractError(
            f"{transition_label}.frames must contain at least three increasing callbacks"
        )
    if frames["frame_callback_count"] != len(timestamps):
        raise ContractError(f"{transition_label}.frames.frame_callback_count differs")
    if timestamps[0] < requested or timestamps[-1] > requested + 700.0 + 1e-6:
        raise ContractError(
            f"{transition_label}.frames fall outside the observation window"
        )
    intervals = [
        later - earlier for earlier, later in zip(timestamps, timestamps[1:])
    ]
    first_frame = timestamps[0] - requested
    span = timestamps[-1] - timestamps[0]
    callback_rate = (len(timestamps) - 1) * 1000.0 / span
    _numbers_match(
        frames["first_frame_after_request_ms"],
        first_frame,
        f"{transition_label}.frames.first_frame_after_request_ms",
    )
    _numbers_match(
        frames["observation_span_ms"],
        span,
        f"{transition_label}.frames.observation_span_ms",
    )
    _numbers_match(
        frames["effective_callback_rate_hz"],
        callback_rate,
        f"{transition_label}.frames.effective_callback_rate_hz",
    )
    interval_summary = frames["interval_ms"]
    if not isinstance(interval_summary, dict):
        raise ContractError(f"{transition_label}.frames.interval_ms must be an object")
    _require_exact_keys(
        interval_summary,
        {"minimum", "median", "p95", "maximum"},
        f"{transition_label}.frames.interval_ms",
    )
    interval_expected = {
        "minimum": min(intervals),
        "median": statistics.median(intervals),
        "p95": _nearest_rank_percentile(intervals, 0.95),
        "maximum": max(intervals),
    }
    for key, expected in interval_expected.items():
        _numbers_match(
            interval_summary[key],
            expected,
            f"{transition_label}.frames.interval_ms.{key}",
        )
    count_over = sum(
        interval > nominal_interval * 1.5 for interval in intervals
    )
    if frames["interval_count_over_1_5_refreshes"] != count_over:
        raise ContractError(
            f"{transition_label}.frames.interval_count_over_1_5_refreshes differs"
        )
    missed = sum(
        max(0, round(interval / nominal_interval) - 1)
        for interval in intervals
    )
    if frames["estimated_missed_refreshes"] != missed:
        raise ContractError(
            f"{transition_label}.frames.estimated_missed_refreshes differs"
        )

    refresh_opportunities = len(intervals) + missed
    missed_ratio = (
        missed / refresh_opportunities if refresh_opportunities > 0 else 1.0
    )
    expected_checks = (
        (
            "first-frame-latency",
            "maximum",
            first_frame,
            ROTATION_SLO["first_frame_max_ms"],
            first_frame <= ROTATION_SLO["first_frame_max_ms"],
        ),
        (
            "animation-span-minimum",
            "minimum",
            span,
            ROTATION_SLO["animation_span_min_ms"],
            span >= ROTATION_SLO["animation_span_min_ms"],
        ),
        (
            "animation-span-maximum",
            "maximum",
            span,
            ROTATION_SLO["animation_span_max_ms"],
            span <= ROTATION_SLO["animation_span_max_ms"],
        ),
        (
            "effective-callback-rate",
            "minimum",
            callback_rate,
            refresh_hz * ROTATION_SLO["minimum_callback_rate_ratio"],
            callback_rate
            >= refresh_hz * ROTATION_SLO["minimum_callback_rate_ratio"],
        ),
        (
            "p95-frame-interval",
            "maximum",
            interval_expected["p95"],
            nominal_interval
            * ROTATION_SLO["p95_interval_max_refresh_multiplier"],
            interval_expected["p95"]
            <= nominal_interval
            * ROTATION_SLO["p95_interval_max_refresh_multiplier"],
        ),
        (
            "missed-refresh-ratio",
            "maximum",
            missed_ratio,
            ROTATION_SLO["maximum_missed_refresh_ratio"],
            missed_ratio <= ROTATION_SLO["maximum_missed_refresh_ratio"],
        ),
    )
    smoothness = transition["smoothness_slo"]
    if not isinstance(smoothness, dict):
        raise ContractError(f"{transition_label}.smoothness_slo must be an object")
    _require_exact_keys(
        smoothness, {"passed", "checks"}, f"{transition_label}.smoothness_slo"
    )
    if smoothness["passed"] is not True:
        raise ContractError(f"{transition_label}.smoothness_slo did not pass")
    checks = smoothness["checks"]
    if not isinstance(checks, list) or len(checks) != len(expected_checks):
        raise ContractError(
            f"{transition_label}.smoothness_slo.checks differs from the exact SLO"
        )
    for check_index, (
        check,
        (
            expected_name,
            boundary_name,
            expected_observed,
            expected_boundary,
            expected_pass,
        ),
    ) in enumerate(zip(checks, expected_checks, strict=True)):
        check_label = (
            f"{transition_label}.smoothness_slo.checks[{check_index}]"
        )
        if not isinstance(check, dict):
            raise ContractError(f"{check_label} must be an object")
        _require_exact_keys(
            check, {"name", "observed", boundary_name, "passed"}, check_label
        )
        if check["name"] != expected_name:
            raise ContractError(f"{check_label}.name differs from the exact SLO")
        _numbers_match(
            check["observed"], expected_observed, f"{check_label}.observed"
        )
        _numbers_match(
            check[boundary_name],
            expected_boundary,
            f"{check_label}.{boundary_name}",
        )
        if expected_pass is not True or check["passed"] is not True:
            raise ContractError(f"{check_label} does not meet the exact SLO")
    return intervals, missed, len(timestamps)


def _validate_rotation_performance(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_candidate: dict[str, Any],
    expected_edge_output: str,
) -> None:
    label = "performance/rotation-frame/report.json"
    report = _read_release_json(artifact_dir, label)
    expected_keys = {
        "schema_version",
        "evidence_type",
        "status",
        "qualified",
        "qualification_note",
        "started_utc",
        "completed_utc",
        "candidate",
        "output",
        "rotation_observation_window_ms",
        "smoothness_slo",
        "load",
        "transition_count",
        "transitions",
        "aggregate",
    }
    _require_exact_keys(report, expected_keys, label)
    fixed = {
        "schema_version": 2,
        "evidence_type": "wayland-rotation-frame-callback-timing",
        "status": "PASS",
        "qualified": True,
        "qualification_note": (
            "Every observed quarter-turn must meet the recorded "
            "refresh-normalized response, duration, cadence, and missed-frame "
            "limits."
        ),
    }
    for key, expected in fixed.items():
        if report[key] != expected:
            raise ContractError(f"{label}.{key} differs from the PASS contract")
    _validate_time_window(report, label)
    _validate_candidate_build(
        report["candidate"],
        expected_commit,
        f"{label}.candidate",
        expected_candidate,
    )
    output = report["output"]
    if not isinstance(output, dict):
        raise ContractError(f"{label}.output must be an object")
    _require_exact_keys(
        output,
        {"name", "geometry", "refresh_hz", "nominal_refresh_interval_ms"},
        f"{label}.output",
    )
    if output["name"] != expected_edge_output:
        raise ContractError(f"{label}.output.name differs from display evidence")
    _validate_geometry(output["geometry"], f"{label}.output.geometry")
    refresh_hz = _finite_number(output["refresh_hz"], f"{label}.output.refresh_hz")
    if refresh_hz <= 0.0:
        raise ContractError(f"{label}.output.refresh_hz must be positive")
    nominal_interval = 1000.0 / refresh_hz
    _numbers_match(
        output["nominal_refresh_interval_ms"],
        nominal_interval,
        f"{label}.output.nominal_refresh_interval_ms",
    )
    _expect_number(
        report["rotation_observation_window_ms"],
        700.0,
        f"{label}.rotation_observation_window_ms",
    )
    smoothness = report["smoothness_slo"]
    if not isinstance(smoothness, dict):
        raise ContractError(f"{label}.smoothness_slo must be an object")
    _require_exact_keys(smoothness, set(ROTATION_SLO), f"{label}.smoothness_slo")
    for key, expected in ROTATION_SLO.items():
        _expect_number(smoothness[key], expected, f"{label}.smoothness_slo.{key}")
    _validate_audit_14_load(report["load"], f"{label}.load")

    transitions = report["transitions"]
    if not isinstance(transitions, list) or len(transitions) != 6:
        raise ContractError(f"{label}.transitions must contain exactly three cycles")
    if report["transition_count"] != len(transitions):
        raise ContractError(f"{label}.transition_count differs from transitions")
    all_intervals: list[float] = []
    total_missed = 0
    total_callbacks = 0
    previous_request = -1.0
    for index, transition in enumerate(transitions):
        intervals, missed, callbacks = _validate_rotation_transition(
            transition, index, refresh_hz, nominal_interval, label
        )
        request = float(transition["request_started_monotonic_ms"])
        if request <= previous_request:
            raise ContractError(f"{label}.transitions are not chronological")
        previous_request = request
        all_intervals.extend(intervals)
        total_missed += missed
        total_callbacks += callbacks

    aggregate = report["aggregate"]
    if not isinstance(aggregate, dict):
        raise ContractError(f"{label}.aggregate must be an object")
    _require_exact_keys(
        aggregate,
        {"interval_ms", "estimated_missed_refreshes", "frame_callback_count"},
        f"{label}.aggregate",
    )
    interval_summary = aggregate["interval_ms"]
    if not isinstance(interval_summary, dict):
        raise ContractError(f"{label}.aggregate.interval_ms must be an object")
    _require_exact_keys(
        interval_summary,
        {"minimum", "median", "p95", "maximum"},
        f"{label}.aggregate.interval_ms",
    )
    expected_intervals = {
        "minimum": min(all_intervals),
        "median": statistics.median(all_intervals),
        "p95": _nearest_rank_percentile(all_intervals, 0.95),
        "maximum": max(all_intervals),
    }
    for key, expected in expected_intervals.items():
        _numbers_match(
            interval_summary[key],
            expected,
            f"{label}.aggregate.interval_ms.{key}",
        )
    if aggregate["estimated_missed_refreshes"] != total_missed:
        raise ContractError(f"{label}.aggregate.estimated_missed_refreshes differs")
    if aggregate["frame_callback_count"] != total_callbacks:
        raise ContractError(f"{label}.aggregate.frame_callback_count differs")


def validate_release_run(
    artifact_dir: pathlib.Path, expected_commit: str, expected_run_id: str
) -> None:
    _validate_run_identity(
        artifact_dir, expected_commit, expected_run_id, "release-gate"
    )

    preflight_payload, preflight_rows = _read_tsv(
        artifact_dir / "PREFLIGHT.tsv", ("result", "check")
    )
    summary_payload, summary_rows = _read_tsv(
        artifact_dir / "SUMMARY.tsv", ("result", "suite")
    )
    _validate_preflight(preflight_rows)
    _validate_summary(summary_rows)

    run_path = artifact_dir / "RUN.json"
    _require_regular_record(run_path)
    run = _read_json(run_path)
    expected_keys = {
        "completed_at",
        "preflight_rows",
        "preflight_sha256",
        "result",
        "run_id",
        "schema",
        "source_commit",
        "summary_rows",
        "summary_sha256",
    }
    _require_exact_keys(run, expected_keys, "RUN.json")
    if run["schema"] != RUN_SCHEMA:
        raise ContractError(f"RUN.json schema must be exactly {RUN_SCHEMA}")
    if run["source_commit"] != expected_commit:
        raise ContractError("RUN.json source_commit does not match the artifact key")
    if run["run_id"] != expected_run_id:
        raise ContractError("RUN.json run_id does not match the artifact directory")
    if run["result"] != "PASS":
        raise ContractError("RUN.json result must be PASS before sealing")
    _validate_utc_timestamp(run["completed_at"], "completed_at")

    expected_values = {
        "preflight_rows": len(preflight_rows),
        "summary_rows": len(summary_rows),
        "preflight_sha256": hashlib.sha256(preflight_payload).hexdigest(),
        "summary_sha256": hashlib.sha256(summary_payload).hexdigest(),
    }
    for field, expected in expected_values.items():
        if run[field] != expected:
            raise ContractError(f"RUN.json {field} does not match its retained record")

    candidate, edge_output, binary_path = _validate_display_lifecycle(
        artifact_dir, expected_commit
    )
    _validate_rotation_performance(
        artifact_dir, expected_commit, candidate, edge_output
    )
    _validate_short_performance(
        artifact_dir,
        expected_commit,
        candidate,
        binary_path,
        edge_output,
    )
    _validate_audit_14_performance(
        artifact_dir,
        expected_commit,
        candidate,
        binary_path,
        edge_output,
    )


def _validate_one_line(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or value != value.strip()
        or any(character in value for character in "\t\r\n")
    ):
        raise ContractError(f"{field} must be one non-empty trimmed line")
    return value


def _validate_run_identity(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_run_id: str,
    prefix: str,
) -> None:
    if not LOWER_SHA_RE.fullmatch(expected_commit):
        raise ContractError("expected source commit is not a full lowercase SHA")
    run_pattern = re.compile(
        rf"^{re.escape(prefix)}-[0-9]{{8}}T[0-9]{{6}}Z-[0-9]+$"
    )
    if not run_pattern.fullmatch(expected_run_id):
        raise ContractError(f"{prefix} directory name is not a canonical run id")
    if artifact_dir.name != expected_run_id:
        raise ContractError(f"{prefix} run id does not match its directory")
    if artifact_dir.parent.name != expected_commit:
        raise ContractError(
            f"{prefix} directory is not keyed by the exact source commit"
        )


def _validate_common_pass_record(
    record: dict[str, Any],
    expected_schema: str,
    expected_commit: str,
    expected_run_id: str,
    label: str,
) -> None:
    if record["schema"] != expected_schema:
        raise ContractError(f"{label} schema must be exactly {expected_schema}")
    if record["source_commit"] != expected_commit:
        raise ContractError(f"{label} source_commit does not match the artifact key")
    if record["run_id"] != expected_run_id:
        raise ContractError(f"{label} run_id does not match the artifact directory")
    if record["result"] != "PASS":
        raise ContractError(f"{label} result must be PASS before sealing")
    _validate_utc_timestamp(record["completed_at"], f"{label} completed_at")


def _validate_evidence_path(
    artifact_dir: pathlib.Path,
    value: Any,
    expected_digest: Any,
    field: str,
) -> pathlib.Path:
    if not isinstance(value, str):
        raise ContractError(f"{field} must be a string")
    pure = pathlib.PurePosixPath(value)
    if (
        pure.is_absolute()
        or len(pure.parts) < 2
        or pure.parts[0] != "evidence"
        or any(
            part in ("", ".", "..") or not PORTABLE_COMPONENT_RE.fullmatch(part)
            for part in pure.parts
        )
        or str(pure) != value
    ):
        raise ContractError(
            f"{field} must be a canonical portable path below evidence/"
        )
    if not isinstance(expected_digest, str) or not SHA256_RE.fullmatch(
        expected_digest
    ):
        raise ContractError(f"{field} SHA-256 must be lowercase hexadecimal")

    path = artifact_dir
    for component in pure.parts:
        path /= component
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise ContractError(f"{field} is unavailable: {value}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise ContractError(f"{field} contains a symlink: {value}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size == 0:
        raise ContractError(f"{field} must be a non-empty regular file")
    if _sha256_file(path) != expected_digest:
        raise ContractError(f"{field} hash does not match the retained file")
    return path


def _validate_source_path(
    artifact_dir: pathlib.Path,
    value: Any,
    expected_digest: Any,
    field: str,
) -> pathlib.Path:
    if not isinstance(value, str):
        raise ContractError(f"{field} must be a string")
    pure = pathlib.PurePosixPath(value)
    if (
        pure.is_absolute()
        or len(pure.parts) != 2
        or pure.parts[0] != "source"
        or any(
            part in ("", ".", "..") or not PORTABLE_COMPONENT_RE.fullmatch(part)
            for part in pure.parts
        )
        or str(pure) != value
    ):
        raise ContractError(
            f"{field} must be one canonical portable file below source/"
        )
    if not isinstance(expected_digest, str) or not SHA256_RE.fullmatch(
        expected_digest
    ):
        raise ContractError(f"{field} SHA-256 must be lowercase hexadecimal")

    path = artifact_dir
    metadata = None
    for component in pure.parts:
        path /= component
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise ContractError(f"{field} is unavailable: {value}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise ContractError(f"{field} contains a symlink: {value}")
    if (
        metadata is None
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size == 0
        or metadata.st_nlink != 1
    ):
        raise ContractError(
            f"{field} must be a non-empty single-linked regular file"
        )
    if _sha256_file(path) != expected_digest:
        raise ContractError(f"{field} hash does not match the retained file")
    return path


def _validate_exact_evidence_tree(
    artifact_dir: pathlib.Path, expected_paths: set[str]
) -> None:
    evidence_root = artifact_dir / "evidence"
    try:
        root_metadata = evidence_root.lstat()
    except OSError as exc:
        raise ContractError("typed evidence directory is unavailable") from exc
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise ContractError("typed evidence root must be a real directory")

    actual_paths: set[str] = set()
    for path in evidence_root.rglob("*"):
        relative = path.relative_to(artifact_dir).as_posix()
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ContractError(f"typed evidence contains a symlink: {relative}")
        if stat.S_ISREG(metadata.st_mode):
            actual_paths.add(relative)
        elif not stat.S_ISDIR(metadata.st_mode):
            raise ContractError(
                f"typed evidence contains a special file: {relative}"
            )
    if actual_paths != expected_paths:
        raise ContractError(
            "typed evidence files differ from the exact structured receipt"
        )


def _validate_source_inventory(
    artifact_dir: pathlib.Path,
    source_files: Any,
    expected_paths: set[str],
) -> dict[str, tuple[pathlib.Path, str]]:
    if not isinstance(source_files, list) or not source_files:
        raise ContractError(
            "NATIVE_PACKAGE_LIFECYCLE.json source_files must be a non-empty list"
        )
    retained: dict[str, tuple[pathlib.Path, str]] = {}
    ordered_paths: list[str] = []
    for index, entry in enumerate(source_files):
        if not isinstance(entry, dict):
            raise ContractError(f"source_files entry {index} must be an object")
        _require_exact_keys(
            entry, {"path", "sha256"}, f"source_files entry {index}"
        )
        value = entry["path"]
        if not isinstance(value, str) or value in retained:
            raise ContractError(
                f"source_files entry {index} has a duplicate or invalid path"
            )
        path = _validate_source_path(
            artifact_dir,
            value,
            entry["sha256"],
            f"source_files entry {index}",
        )
        retained[value] = (path, entry["sha256"])
        ordered_paths.append(value)
    if ordered_paths != sorted(ordered_paths):
        raise ContractError("source_files must be ordered lexically by path")
    if set(retained) != expected_paths:
        raise ContractError(
            "source_files differ from the exact native lifecycle source contract"
        )

    source_root = artifact_dir / "source"
    try:
        root_metadata = source_root.lstat()
    except OSError as exc:
        raise ContractError("native lifecycle source directory is unavailable") from exc
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise ContractError("native lifecycle source root must be a real directory")
    actual_paths: set[str] = set()
    for path in source_root.rglob("*"):
        relative = path.relative_to(artifact_dir).as_posix()
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ContractError(
                f"native lifecycle source contains a symlink: {relative}"
            )
        if stat.S_ISREG(metadata.st_mode):
            if metadata.st_nlink != 1:
                raise ContractError(
                    f"native lifecycle source is hard-linked: {relative}"
                )
            actual_paths.add(relative)
        elif stat.S_ISDIR(metadata.st_mode):
            raise ContractError(
                f"native lifecycle source contains an unexpected directory: {relative}"
            )
        else:
            raise ContractError(
                f"native lifecycle source contains a special file: {relative}"
            )
    if actual_paths != expected_paths:
        raise ContractError(
            "native lifecycle source files differ from the exact receipt"
        )
    return retained


def _validate_native_sidecar(
    path: pathlib.Path,
    expected_name: str,
    expected_digest: str,
    label: str,
) -> None:
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ContractError(f"{label} could not be read") from exc
    expected = f"{expected_digest}  {expected_name}\n".encode("ascii")
    if payload != expected:
        raise ContractError(
            f"{label} must contain the exact SHA-256 and portable basename"
        )


def _validate_native_environment(path: pathlib.Path, kind: str) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ContractError(
            "native lifecycle environment is not valid UTF-8"
        ) from exc
    if not text.endswith("\n") or "\x00" in text:
        raise ContractError(
            "native lifecycle environment must be complete UTF-8 text"
        )
    lines = text.splitlines()
    if tuple(lines[:3]) != EXPECTED_NATIVE_ENVIRONMENTS[kind]:
        raise ContractError(
            "native lifecycle environment does not name the pinned distro and platform"
        )
    os_release = lines[3:]
    if not os_release or not any(line.startswith("ID=") for line in os_release):
        raise ContractError(
            "native lifecycle environment lacks the resolved container OS identity"
        )


def _native_attestation_binds(
    document: Any,
    subject_name: str,
    subject_digest: str,
    workflow_url: str,
) -> bool:
    if not isinstance(document, list) or not document:
        return False
    invocation_pattern = re.compile(
        rf"{re.escape(workflow_url)}(?:/attempts/[1-9][0-9]*)?"
    )
    for entry in document:
        if not isinstance(entry, dict):
            continue
        verification = entry.get("verificationResult")
        statement = (
            verification.get("statement")
            if isinstance(verification, dict)
            else None
        )
        predicate = (
            statement.get("predicate") if isinstance(statement, dict) else None
        )
        run_details = (
            predicate.get("runDetails") if isinstance(predicate, dict) else None
        )
        metadata = (
            run_details.get("metadata")
            if isinstance(run_details, dict)
            else None
        )
        invocation_id = (
            metadata.get("invocationId") if isinstance(metadata, dict) else None
        )
        if (
            not isinstance(invocation_id, str)
            or invocation_pattern.fullmatch(invocation_id) is None
        ):
            continue
        subjects = (
            statement.get("subject") if isinstance(statement, dict) else None
        )
        if not isinstance(subjects, list):
            continue
        for subject in subjects:
            if not isinstance(subject, dict):
                continue
            digest = subject.get("digest")
            if (
                subject.get("name") == subject_name
                and isinstance(digest, dict)
                and digest.get("sha256") == subject_digest
            ):
                return True
    return False


def _validate_png(path: pathlib.Path, label: str) -> None:
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ContractError(f"{label} could not be read") from exc
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ContractError(f"{label} is not a PNG")
    offset = 8
    chunks: list[tuple[bytes, bytes]] = []
    while offset < len(payload):
        if len(payload) - offset < 12:
            raise ContractError(f"{label} has a truncated PNG chunk")
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        chunk_type = payload[offset + 4 : offset + 8]
        end = offset + 12 + length
        if end > len(payload):
            raise ContractError(f"{label} has a truncated PNG payload")
        data = payload[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(
            ">I", payload[offset + 8 + length : end]
        )[0]
        actual_crc = binascii.crc32(chunk_type + data) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ContractError(f"{label} has an invalid PNG checksum")
        chunks.append((chunk_type, data))
        offset = end
        if chunk_type == b"IEND":
            break
    if offset != len(payload):
        raise ContractError(f"{label} has trailing data after PNG IEND")
    if not chunks or chunks[0][0] != b"IHDR" or len(chunks[0][1]) != 13:
        raise ContractError(f"{label} lacks a valid PNG IHDR")
    width, height = struct.unpack(">II", chunks[0][1][:8])
    if width < 320 or height < 200 or width > 32768 or height > 32768:
        raise ContractError(
            f"{label} dimensions are not a plausible full desktop observation"
        )
    compressed = b"".join(data for kind, data in chunks if kind == b"IDAT")
    if not compressed or not chunks or chunks[-1][0] != b"IEND":
        raise ContractError(f"{label} lacks PNG image data or IEND")
    try:
        decompressor = zlib.decompressobj()
        decoded = decompressor.decompress(compressed, 512 * 1024 * 1024)
        if not decoded or not decompressor.eof or decompressor.unconsumed_tail:
            raise ContractError(f"{label} decompresses to no image data")
    except zlib.error as exc:
        raise ContractError(f"{label} has invalid compressed image data") from exc


def _read_prefixed_json_events(
    path: pathlib.Path, prefix: str, label: str
) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ContractError(f"{label} is not valid UTF-8") from exc
    events: list[dict[str, Any]] = []
    for line in lines:
        if not line.startswith(prefix):
            continue
        try:
            event = json.loads(line[len(prefix) :])
        except json.JSONDecodeError as exc:
            raise ContractError(f"{label} contains invalid evidence JSON") from exc
        if not isinstance(event, dict):
            raise ContractError(f"{label} evidence entry must be an object")
        events.append(event)
    if not events:
        raise ContractError(f"{label} contains no machine evidence events")
    return events


def _validate_event(
    event: dict[str, Any],
    expected_keys: set[str],
    expected_name: str,
    expected_commit: str,
    label: str,
) -> dt.datetime:
    _require_exact_keys(event, expected_keys, label)
    if event["event"] != expected_name:
        raise ContractError(f"{label} event must be exactly {expected_name}")
    if event["source_commit"] != expected_commit:
        raise ContractError(f"{label} is not bound to the exact source commit")
    return _parse_utc_timestamp(event["timestamp"], f"{label} timestamp")


def _validate_nondecreasing_timestamps(
    timestamps: list[dt.datetime], label: str
) -> None:
    if any(
        current < previous
        for previous, current in zip(timestamps, timestamps[1:])
    ):
        raise ContractError(f"{label} timestamps are not ordered")


def _validate_notification_process_log(
    path: pathlib.Path,
    expected_commit: str,
    expected_summary: str,
    expected_body: str,
) -> tuple[str, str]:
    events = _read_prefixed_json_events(
        path, "EDGEHUB_NOTIFICATION_EVIDENCE ", "notification process log"
    )
    if len(events) != 2:
        raise ContractError(
            "notification process log must contain exactly request and confirmation"
        )
    request, confirmation = events
    request_time = _validate_event(
        request,
        {
            "body",
            "event",
            "method",
            "profile",
            "resident",
            "service",
            "source_commit",
            "summary",
            "timeout_ms",
            "timestamp",
            "transient",
            "urgency",
        },
        "request",
        expected_commit,
        "notification request",
    )
    confirmation_time = _validate_event(
        confirmation,
        {
            "event",
            "method",
            "notification_id",
            "service",
            "source_commit",
            "timestamp",
        },
        "confirmed",
        expected_commit,
        "notification confirmation",
    )
    if (
        request["service"] != "org.freedesktop.Notifications"
        or confirmation["service"] != request["service"]
        or request["method"] != "Notify"
        or confirmation["method"] != request["method"]
    ):
        raise ContractError(
            "notification process log does not prove the desktop Notify service"
        )
    if request["summary"] != expected_summary or request["body"] != expected_body:
        raise ContractError(
            "notification process log content differs from the receipt"
        )
    if (
        request["profile"] != "priority"
        or request["urgency"] != 2
        or request["resident"] is not True
        or request["transient"] is not False
        or request["timeout_ms"] != 0
    ):
        raise ContractError(
            "notification process log does not prove the priority profile"
        )
    notification_id = confirmation["notification_id"]
    if (
        not isinstance(notification_id, int)
        or isinstance(notification_id, bool)
        or notification_id < 0
    ):
        raise ContractError(
            "notification confirmation lacks a valid daemon notification id"
        )
    _validate_nondecreasing_timestamps(
        [request_time, confirmation_time], "notification process log"
    )
    return request["timestamp"], confirmation["timestamp"]


def _validate_notification_transport_log(
    path: pathlib.Path, summary: str, body: str
) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ContractError(
            "desktop notification transport log is not valid UTF-8"
        ) from exc
    for required in (
        "destination=org.freedesktop.Notifications",
        "interface=org.freedesktop.Notifications",
        "member=Notify",
        summary,
        body,
    ):
        if required not in text:
            raise ContractError(
                "desktop notification transport log lacks the exact Notify call"
            )


def _validate_mpris_process_log(
    path: pathlib.Path, expected_commit: str
) -> dict[str, str]:
    events = _read_prefixed_json_events(
        path, "EDGEHUB_MPRIS_EVIDENCE ", "MPRIS process log"
    )
    expected_names = [
        "selected",
        "action_sent",
        "intermediate_observed",
        "restore_sent",
        "restored_observed",
        "complete",
    ]
    if [event.get("event") for event in events] != expected_names:
        raise ContractError(
            "MPRIS process log must prove selection, action, change, restore, "
            "restoration, and completion in order"
        )

    common_keys = {
        "action",
        "event",
        "player_bus_name",
        "source_commit",
        "state",
        "timestamp",
    }
    selected_time = _validate_event(
        events[0],
        common_keys | {"player_name"},
        "selected",
        expected_commit,
        "MPRIS selected",
    )
    action_time = _validate_event(
        events[1],
        common_keys,
        "action_sent",
        expected_commit,
        "MPRIS action",
    )
    intermediate_time = _validate_event(
        events[2],
        common_keys,
        "intermediate_observed",
        expected_commit,
        "MPRIS intermediate",
    )
    restore_time = _validate_event(
        events[3],
        common_keys,
        "restore_sent",
        expected_commit,
        "MPRIS restore",
    )
    restored_time = _validate_event(
        events[4],
        common_keys,
        "restored_observed",
        expected_commit,
        "MPRIS restored",
    )
    complete_time = _validate_event(
        events[5],
        {
            "action",
            "before_state",
            "current_state",
            "event",
            "intermediate_state",
            "player_bus_name",
            "reason",
            "source_commit",
            "timestamp",
        },
        "complete",
        expected_commit,
        "MPRIS complete",
    )
    _validate_nondecreasing_timestamps(
        [
            selected_time,
            action_time,
            intermediate_time,
            restore_time,
            restored_time,
            complete_time,
        ],
        "MPRIS process log",
    )

    service = events[0]["player_bus_name"]
    if (
        not isinstance(service, str)
        or not service.startswith("org.mpris.MediaPlayer2.")
        or service == "org.mpris.MediaPlayer2."
    ):
        raise ContractError("MPRIS process log lacks an exact player bus name")
    _validate_one_line(events[0]["player_name"], "MPRIS process player name")
    if any(
        event["player_bus_name"] != service or event["action"] != "PlayPause"
        for event in events
    ):
        raise ContractError(
            "MPRIS process log changed player identity or transport action"
        )
    before = events[0]["state"]
    intermediate = events[2]["state"]
    restored = events[4]["state"]
    if (
        before not in {"Playing", "Paused"}
        or intermediate not in {"Playing", "Paused"}
        or intermediate == before
        or restored != before
    ):
        raise ContractError(
            "MPRIS process log does not prove a restorable state transition"
        )
    if (
        events[1]["state"] != before
        or events[3]["state"] != intermediate
        or events[5]["before_state"] != before
        or events[5]["intermediate_state"] != intermediate
        or events[5]["current_state"] != restored
        or events[5]["reason"] != "state changed and was restored"
    ):
        raise ContractError(
            "MPRIS process log state evidence is internally inconsistent"
        )
    return {
        "player_bus_name": service,
        "player_name": events[0]["player_name"],
        "before_state": before,
        "intermediate_state": intermediate,
        "restored_state": restored,
        "action_sent_at": events[1]["timestamp"],
        "intermediate_observed_at": events[2]["timestamp"],
        "restore_sent_at": events[3]["timestamp"],
        "restored_at": events[4]["timestamp"],
    }


def _validate_mpris_transport_log(
    path: pathlib.Path, player_bus_name: str
) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ContractError("MPRIS transport log is not valid UTF-8") from exc
    if (
        text.count("member=PlayPause") != 2
        or text.count(f"destination={player_bus_name}") != 2
        or text.count("interface=org.mpris.MediaPlayer2.Player") != 2
    ):
        raise ContractError(
            "MPRIS transport log does not prove action and restoration calls"
        )


def validate_desktop_notification(
    artifact_dir: pathlib.Path, expected_commit: str, expected_run_id: str
) -> None:
    _validate_run_identity(
        artifact_dir, expected_commit, expected_run_id, "desktop-notification"
    )
    path = artifact_dir / "DESKTOP_NOTIFICATION.json"
    _require_regular_record(path)
    record = _read_json(path)
    _require_exact_keys(
        record,
        {
            "attestation",
            "attested_by",
            "body",
            "commands",
            "completed_at",
            "delivery_confirmed_at",
            "desktop_service",
            "method",
            "observed_on_real_desktop",
            "priority_profile",
            "process_log_path",
            "process_log_sha256",
            "request_sent_at",
            "result",
            "run_id",
            "schema",
            "screenshot_path",
            "screenshot_captured_at",
            "screenshot_sha256",
            "smoke_binary_path",
            "smoke_binary_sha256",
            "source_commit",
            "summary",
            "transport_log_path",
            "transport_log_sha256",
            "visually_distinct",
        },
        "DESKTOP_NOTIFICATION.json",
    )
    _validate_common_pass_record(
        record,
        DESKTOP_NOTIFICATION_SCHEMA,
        expected_commit,
        expected_run_id,
        "DESKTOP_NOTIFICATION.json",
    )
    if record["desktop_service"] != "org.freedesktop.Notifications":
        raise ContractError("desktop notification did not use the desktop service")
    if record["method"] != "Notify":
        raise ContractError("desktop notification did not use Notify")
    summary = _validate_one_line(record["summary"], "desktop notification summary")
    body = _validate_one_line(record["body"], "desktop notification body")
    priority = record["priority_profile"]
    if not isinstance(priority, dict):
        raise ContractError("desktop notification priority_profile must be an object")
    _require_exact_keys(
        priority,
        {"category", "resident", "timeout_ms", "transient", "urgency"},
        "desktop notification priority_profile",
    )
    if priority != {
        "category": "x-edgehub.reminder",
        "resident": True,
        "timeout_ms": 0,
        "transient": False,
        "urgency": 2,
    }:
        raise ContractError(
            "desktop notification receipt does not use the exact priority profile"
        )
    _validate_command_map(
        record["commands"],
        {"build", "configure", "screenshot", "smoke", "transport_monitor"},
        "desktop notification commands",
    )
    commands = record["commands"]
    if (
        f"-DXENEON_EVIDENCE_SOURCE_COMMIT={expected_commit}"
        not in commands["configure"]
        or "notification_desktop_smoke" not in commands["build"]
        or not any(
            argument.endswith("/notification_desktop_smoke")
            for argument in commands["smoke"]
        )
        or "org.freedesktop.Notifications"
        not in " ".join(commands["transport_monitor"])
        or "Notify" not in " ".join(commands["transport_monitor"])
        or not any(
            argument.endswith("/notification.png")
            for argument in commands["screenshot"]
        )
    ):
        raise ContractError(
            "desktop notification commands are not bound to the exact recorder path"
        )
    if record["observed_on_real_desktop"] is not True:
        raise ContractError("desktop notification was not observed on a real desktop")
    if record["visually_distinct"] is not True:
        raise ContractError("desktop notification was not observed as visually distinct")
    _validate_one_line(record["attested_by"], "desktop notification attested_by")
    if record["attestation"] != DESKTOP_NOTIFICATION_ATTESTATION:
        raise ContractError(
            "desktop notification lacks the exact human attestation"
        )
    screenshot = _validate_evidence_path(
        artifact_dir,
        record["screenshot_path"],
        record["screenshot_sha256"],
        "desktop notification screenshot",
    )
    _validate_png(screenshot, "desktop notification screenshot")
    transport_log = _validate_evidence_path(
        artifact_dir,
        record["transport_log_path"],
        record["transport_log_sha256"],
        "desktop notification transport log",
    )
    process_log = _validate_evidence_path(
        artifact_dir,
        record["process_log_path"],
        record["process_log_sha256"],
        "desktop notification process log",
    )
    smoke_binary = _validate_evidence_path(
        artifact_dir,
        record["smoke_binary_path"],
        record["smoke_binary_sha256"],
        "desktop notification smoke binary",
    )
    try:
        smoke_payload = smoke_binary.read_bytes()
        if smoke_payload[:4] != b"\x7fELF":
            raise ContractError("desktop notification smoke binary is not ELF")
        if expected_commit.encode("ascii") not in smoke_payload:
            raise ContractError(
                "desktop notification smoke binary lacks the exact source commit"
            )
    except OSError as exc:
        raise ContractError(
            "desktop notification smoke binary could not be read"
        ) from exc
    request_time, confirmation_time = _validate_notification_process_log(
        process_log, expected_commit, summary, body
    )
    if record["request_sent_at"] != request_time:
        raise ContractError(
            "desktop notification request timestamp differs from the process log"
        )
    if record["delivery_confirmed_at"] != confirmation_time:
        raise ContractError(
            "desktop notification confirmation timestamp differs from the process log"
        )
    capture_time = _parse_utc_timestamp(
        record["screenshot_captured_at"],
        "desktop notification screenshot_captured_at",
    )
    completed_time = _parse_utc_timestamp(
        record["completed_at"], "desktop notification completed_at"
    )
    if (
        capture_time < _parse_utc_timestamp(confirmation_time, "confirmation")
        or completed_time < capture_time
    ):
        raise ContractError(
            "desktop notification capture and completion timestamps are not ordered"
        )
    _validate_notification_transport_log(transport_log, summary, body)
    _validate_exact_evidence_tree(
        artifact_dir,
        {
            record["process_log_path"],
            record["screenshot_path"],
            record["smoke_binary_path"],
            record["transport_log_path"],
        },
    )


def validate_mpris_transport(
    artifact_dir: pathlib.Path, expected_commit: str, expected_run_id: str
) -> None:
    _validate_run_identity(
        artifact_dir, expected_commit, expected_run_id, "mpris-transport"
    )
    path = artifact_dir / "MPRIS_TRANSPORT.json"
    _require_regular_record(path)
    record = _read_json(path)
    _require_exact_keys(
        record,
        {
            "action",
            "action_sent_at",
            "attestation",
            "attested_by",
            "before_state",
            "commands",
            "completed_at",
            "intermediate_observed_at",
            "intermediate_state",
            "player_bus_name",
            "player_requested",
            "process_log_path",
            "process_log_sha256",
            "result",
            "restore_sent_at",
            "restored_at",
            "restored_state",
            "run_id",
            "schema",
            "smoke_binary_path",
            "smoke_binary_sha256",
            "source_commit",
            "state_changed",
            "state_restored",
            "transport_log_path",
            "transport_log_sha256",
        },
        "MPRIS_TRANSPORT.json",
    )
    _validate_common_pass_record(
        record,
        MPRIS_TRANSPORT_SCHEMA,
        expected_commit,
        expected_run_id,
        "MPRIS_TRANSPORT.json",
    )
    bus_name = _validate_one_line(record["player_bus_name"], "MPRIS player_bus_name")
    if not bus_name.startswith("org.mpris.MediaPlayer2."):
        raise ContractError("MPRIS player bus name is not a player service")
    if record["action"] not in {"PlayPause", "Next", "Previous"}:
        raise ContractError("MPRIS action is not an allowed real transport action")
    if record["action"] != "PlayPause":
        raise ContractError("MPRIS restoration receipt must use PlayPause")
    requested_player = _validate_one_line(
        record["player_requested"], "MPRIS player_requested"
    )
    before = _validate_one_line(record["before_state"], "MPRIS before_state")
    intermediate = _validate_one_line(
        record["intermediate_state"], "MPRIS intermediate_state"
    )
    restored = _validate_one_line(
        record["restored_state"], "MPRIS restored_state"
    )
    if (
        record["state_changed"] is not True
        or record["state_restored"] is not True
        or before == intermediate
        or restored != before
    ):
        raise ContractError("MPRIS receipt does not prove an observed state change")
    _validate_command_map(
        record["commands"],
        {"build", "configure", "smoke", "transport_monitor"},
        "MPRIS commands",
    )
    commands = record["commands"]
    if (
        f"-DXENEON_EVIDENCE_SOURCE_COMMIT={expected_commit}"
        not in commands["configure"]
        or "mpris_desktop_smoke" not in commands["build"]
        or not any(
            argument.endswith("/mpris_desktop_smoke")
            for argument in commands["smoke"]
        )
        or commands["smoke"][-1] != requested_player
        or "org.mpris.MediaPlayer2.Player"
        not in " ".join(commands["transport_monitor"])
        or "PlayPause" not in " ".join(commands["transport_monitor"])
    ):
        raise ContractError(
            "MPRIS commands are not bound to the exact recorder path"
        )
    _validate_one_line(record["attested_by"], "MPRIS attested_by")
    if record["attestation"] != MPRIS_TRANSPORT_ATTESTATION:
        raise ContractError("MPRIS receipt lacks the exact human attestation")
    transport_log = _validate_evidence_path(
        artifact_dir,
        record["transport_log_path"],
        record["transport_log_sha256"],
        "MPRIS transport log",
    )
    process_log = _validate_evidence_path(
        artifact_dir,
        record["process_log_path"],
        record["process_log_sha256"],
        "MPRIS process log",
    )
    smoke_binary = _validate_evidence_path(
        artifact_dir,
        record["smoke_binary_path"],
        record["smoke_binary_sha256"],
        "MPRIS smoke binary",
    )
    try:
        smoke_payload = smoke_binary.read_bytes()
        if smoke_payload[:4] != b"\x7fELF":
            raise ContractError("MPRIS smoke binary is not ELF")
        if expected_commit.encode("ascii") not in smoke_payload:
            raise ContractError(
                "MPRIS smoke binary lacks the exact source commit"
            )
    except OSError as exc:
        raise ContractError("MPRIS smoke binary could not be read") from exc
    transcript = _validate_mpris_process_log(process_log, expected_commit)
    if requested_player.startswith("org.mpris.MediaPlayer2."):
        request_matches = (
            requested_player.casefold()
            == transcript["player_bus_name"].casefold()
        )
    else:
        request_matches = (
            requested_player.casefold() == transcript["player_name"].casefold()
        )
    if not request_matches:
        raise ContractError(
            "MPRIS requested player differs from the observed real player"
        )
    expected_transcript = {
        "player_bus_name": bus_name,
        "before_state": before,
        "intermediate_state": intermediate,
        "restored_state": restored,
        "action_sent_at": record["action_sent_at"],
        "intermediate_observed_at": record["intermediate_observed_at"],
        "restore_sent_at": record["restore_sent_at"],
        "restored_at": record["restored_at"],
    }
    if any(
        transcript[key] != value
        for key, value in expected_transcript.items()
    ):
        raise ContractError("MPRIS receipt differs from the process transcript")
    completed = _parse_utc_timestamp(
        record["completed_at"], "MPRIS completed_at"
    )
    restored_time = _parse_utc_timestamp(record["restored_at"], "MPRIS restored_at")
    if completed < restored_time:
        raise ContractError("MPRIS completion predates observed restoration")
    _validate_mpris_transport_log(transport_log, bus_name)
    _validate_exact_evidence_tree(
        artifact_dir,
        {
            record["process_log_path"],
            record["smoke_binary_path"],
            record["transport_log_path"],
        },
    )


NATIVE_PASS_FIELDS = (
    "clean_install",
    "exact_artifact_reinstall",
    "upgrade",
    "upgrade_retired_paths_removed",
    "candidate_notices_and_autostart",
    "rollback",
    "rollback_retired_paths_removed",
    "rollback_baseline_payload_restored",
    "removal",
    "candidate_and_baseline_payload_removal",
)


def _read_key_value_report(path: pathlib.Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ContractError(f"{path.name} is not valid UTF-8") from exc
    if not text.endswith("\n"):
        raise ContractError(f"{path.name} must end with a newline")
    result: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        if "=" not in line:
            raise ContractError(f"{path.name} line {number} is not key=value")
        key, value = line.split("=", 1)
        if (
            not PORTABLE_COMPONENT_RE.fullmatch(key)
            or not value
            or key in result
        ):
            raise ContractError(f"{path.name} line {number} is invalid or duplicated")
        result[key] = value
    return result


def validate_native_lifecycle(
    artifact_dir: pathlib.Path, expected_commit: str, expected_run_id: str
) -> None:
    match = re.fullmatch(
        r"native-package-lifecycle-(deb|rpm)-[0-9]{8}T[0-9]{6}Z-[0-9]+",
        expected_run_id,
    )
    if match is None:
        raise ContractError("native lifecycle directory name is not canonical")
    kind = match.group(1)
    _validate_run_identity(
        artifact_dir,
        expected_commit,
        expected_run_id,
        f"native-package-lifecycle-{kind}",
    )
    path = artifact_dir / "NATIVE_PACKAGE_LIFECYCLE.json"
    _require_regular_record(path)
    record = _read_json(path)
    _require_exact_keys(
        record,
        {
            "attestation",
            "attested_by",
            "baseline_sha",
            "candidate_package_sha256",
            "candidate_sha",
            "completed_at",
            "github_provenance_verified",
            "package_kind",
            "report_path",
            "report_sha256",
            "result",
            "run_id",
            "schema",
            "source_files",
            "source_commit",
            "workflow_url",
        },
        "NATIVE_PACKAGE_LIFECYCLE.json",
    )
    _validate_common_pass_record(
        record,
        NATIVE_LIFECYCLE_SCHEMA,
        expected_commit,
        expected_run_id,
        "NATIVE_PACKAGE_LIFECYCLE.json",
    )
    if record["package_kind"] != kind:
        raise ContractError("native lifecycle package kind differs from its run id")
    if not LOWER_SHA_RE.fullmatch(str(record["baseline_sha"])):
        raise ContractError("native lifecycle baseline_sha is not a full lowercase SHA")
    if record["candidate_sha"] != expected_commit:
        raise ContractError("native lifecycle candidate_sha is not the exact candidate")
    if record["baseline_sha"] == expected_commit:
        raise ContractError(
            "native lifecycle baseline and candidate commits must differ"
        )
    if not SHA256_RE.fullmatch(str(record["candidate_package_sha256"])):
        raise ContractError("native lifecycle candidate package hash is invalid")
    workflow_url = _validate_one_line(
        record["workflow_url"], "native lifecycle workflow_url"
    )
    if not re.fullmatch(
        rf"https://github\.com/{re.escape(CANONICAL_REPOSITORY)}/actions/runs/[1-9][0-9]*",
        workflow_url,
    ):
        raise ContractError("native lifecycle workflow URL is not canonical")
    if record["github_provenance_verified"] is not True:
        raise ContractError("native lifecycle package provenance was not verified")
    if record["attested_by"] != NATIVE_IMPORTER_IDENTITY:
        raise ContractError("native lifecycle importer identity is not canonical")
    if record["attestation"] != NATIVE_IMPORTER_ATTESTATION:
        raise ContractError("native lifecycle importer attestation is not canonical")
    expected_report_path = f"evidence/native-upgrade-rollback-{kind}.txt"
    if record["report_path"] != expected_report_path:
        raise ContractError("native lifecycle report path is not canonical")
    report_path = _validate_evidence_path(
        artifact_dir,
        record["report_path"],
        record["report_sha256"],
        "native lifecycle report",
    )
    report = _read_key_value_report(report_path)
    expected_report_keys = {
        "result",
        "package_kind",
        "baseline_ref",
        "baseline_sha",
        "baseline_app_version",
        "baseline_native_version",
        "baseline_version_source",
        "baseline_package",
        "baseline_package_sha256",
        "candidate_ref",
        "candidate_sha",
        "candidate_app_version",
        "candidate_native_version",
        "candidate_package",
        "candidate_package_sha256",
        "config_sha256",
        "autostart_sha256",
        *NATIVE_PASS_FIELDS,
    }
    _require_exact_keys(
        report, expected_report_keys, "native lifecycle report"
    )
    required_values = {
        "result": "PASS",
        "package_kind": kind,
        "baseline_sha": record["baseline_sha"],
        "candidate_sha": expected_commit,
        "candidate_package_sha256": record["candidate_package_sha256"],
    }
    required_values.update({field: "PASS" for field in NATIVE_PASS_FIELDS})
    for field, expected in required_values.items():
        if report.get(field) != expected:
            raise ContractError(
                f"native lifecycle report field {field} does not match the receipt"
            )
    for field in (
        "baseline_ref",
        "baseline_app_version",
        "baseline_native_version",
        "candidate_ref",
        "candidate_app_version",
        "candidate_native_version",
    ):
        _validate_one_line(report[field], f"native lifecycle report {field}")
    for field in ("baseline_ref", "candidate_ref"):
        value = report[field]
        if (
            LOWER_SHA_RE.fullmatch(value) is None
            and NATIVE_RELEASE_REF_RE.fullmatch(value) is None
        ):
            raise ContractError(
                f"native lifecycle report {field} is not a canonical release ref"
            )
    if report["baseline_version_source"] not in {
        "cmake-contract",
        "historical-observed",
    }:
        raise ContractError(
            "native lifecycle baseline_version_source is unsupported"
        )
    for field in (
        "baseline_package_sha256",
        "candidate_package_sha256",
        "config_sha256",
        "autostart_sha256",
    ):
        if not SHA256_RE.fullmatch(report[field]):
            raise ContractError(
                f"native lifecycle report {field} is not lowercase SHA-256"
            )

    package_names: dict[str, str] = {}
    package_digests: dict[str, str] = {}
    for label in ("baseline", "candidate"):
        name = report[f"{label}_package"]
        if (
            not PORTABLE_COMPONENT_RE.fullmatch(name)
            or pathlib.PurePosixPath(name).name != name
            or not name.endswith(f".{kind}")
        ):
            raise ContractError(
                f"native lifecycle {label} package is not a portable .{kind} basename"
            )
        package_names[label] = name
        package_digests[label] = report[f"{label}_package_sha256"]
    if package_names["baseline"] == package_names["candidate"]:
        raise ContractError(
            "native lifecycle baseline and candidate package names must differ"
        )

    report_name = report_path.name
    fixed_source_names = {
        f"{report_name}.sha256",
        NATIVE_ENVIRONMENT_NAME,
        f"{NATIVE_ENVIRONMENT_NAME}.sha256",
        "GITHUB_WORKFLOW_RUN.json",
        "GITHUB_PACKAGE_ATTESTATION_VERIFICATION.json",
        "GITHUB_REPORT_ATTESTATION_VERIFICATION.json",
        "GITHUB_ENVIRONMENT_ATTESTATION_VERIFICATION.json",
    }
    for name in package_names.values():
        fixed_source_names.add(name)
        fixed_source_names.add(f"{name}.sha256")
    expected_source_paths = {
        f"source/{name}" for name in fixed_source_names
    }
    retained = _validate_source_inventory(
        artifact_dir, record["source_files"], expected_source_paths
    )

    def source(name: str) -> pathlib.Path:
        return retained[f"source/{name}"][0]

    _validate_native_sidecar(
        source(f"{report_name}.sha256"),
        report_name,
        record["report_sha256"],
        "native lifecycle report sidecar",
    )
    for label in ("baseline", "candidate"):
        name = package_names[label]
        digest = package_digests[label]
        retained_digest = retained[f"source/{name}"][1]
        if retained_digest != digest:
            raise ContractError(
                f"native lifecycle {label} package differs from the PASS report"
            )
        _validate_native_sidecar(
            source(f"{name}.sha256"),
            name,
            digest,
            f"native lifecycle {label} package sidecar",
        )

    environment_path = source(NATIVE_ENVIRONMENT_NAME)
    environment_digest = retained[f"source/{NATIVE_ENVIRONMENT_NAME}"][1]
    _validate_native_environment(environment_path, kind)
    _validate_native_sidecar(
        source(f"{NATIVE_ENVIRONMENT_NAME}.sha256"),
        NATIVE_ENVIRONMENT_NAME,
        environment_digest,
        "native lifecycle environment sidecar",
    )

    workflow_document = _read_json(source("GITHUB_WORKFLOW_RUN.json"))
    _require_exact_keys(
        workflow_document,
        {
            "url",
            "headSha",
            "event",
            "status",
            "conclusion",
            "workflowName",
        },
        "GITHUB_WORKFLOW_RUN.json",
    )
    expected_workflow = {
        "url": workflow_url,
        "headSha": expected_commit,
        "event": "workflow_dispatch",
        "status": "completed",
        "conclusion": "success",
        "workflowName": CANONICAL_NATIVE_WORKFLOW_NAME,
    }
    if any(
        workflow_document.get(field) != expected
        for field, expected in expected_workflow.items()
    ):
        raise ContractError(
            "retained GitHub workflow record is not the successful canonical "
            "native lifecycle run"
        )

    attestation_subjects = (
        (
            "GITHUB_PACKAGE_ATTESTATION_VERIFICATION.json",
            package_names["candidate"],
            package_digests["candidate"],
        ),
        (
            "GITHUB_REPORT_ATTESTATION_VERIFICATION.json",
            report_name,
            record["report_sha256"],
        ),
        (
            "GITHUB_ENVIRONMENT_ATTESTATION_VERIFICATION.json",
            NATIVE_ENVIRONMENT_NAME,
            environment_digest,
        ),
    )
    for verification_name, subject_name, subject_digest in attestation_subjects:
        document = _read_json_value(source(verification_name))
        if not _native_attestation_binds(
            document, subject_name, subject_digest, workflow_url
        ):
            raise ContractError(
                f"{verification_name} does not bind the exact subject and workflow run"
            )
    _validate_exact_evidence_tree(artifact_dir, {record["report_path"]})


def validate_appimage_zsync(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_run_id: str,
    expected_version: str | None = None,
) -> None:
    _validate_run_identity(
        artifact_dir, expected_commit, expected_run_id, "appimage-zsync"
    )
    path = artifact_dir / "APPIMAGE_ZSYNC.json"
    _require_regular_record(path)
    record = _read_json(path)
    _require_exact_keys(
        record,
        {
            "baseline_asset_id",
            "baseline_asset_url",
            "baseline_sha256",
            "baseline_size",
            "baseline_tag",
            "baseline_release_id",
            "candidate_asset_id",
            "candidate_asset_ledger_sha256",
            "candidate_asset_name",
            "candidate_asset_url",
            "candidate_sha256",
            "candidate_size",
            "candidate_release_id",
            "client_reported_fetched_bytes",
            "client_reported_local_bytes",
            "completed_at",
            "http_headers_path",
            "http_headers_sha256",
            "log_path",
            "log_sha256",
            "measured_delta_payload_bytes",
            "measured_full_payload_bytes",
            "measured_payload_savings_basis_points",
            "measured_payload_savings_bytes",
            "public_release_was_prerelease",
            "release_version",
            "repository",
            "result",
            "run_id",
            "schema",
            "source_commit",
            "tag_object",
            "updated_sha256",
            "updated_size",
            "zsync_client",
            "zsync_control_path",
            "zsync_control_sha256",
            "zsync_control_size",
            "zsync_asset_id",
            "zsync_url",
        },
        "APPIMAGE_ZSYNC.json",
    )
    _validate_common_pass_record(
        record,
        APPIMAGE_ZSYNC_SCHEMA,
        expected_commit,
        expected_run_id,
        "APPIMAGE_ZSYNC.json",
    )
    version = record["release_version"]
    if not isinstance(version, str) or not STABLE_VERSION_RE.fullmatch(version):
        raise ContractError("AppImage zsync release version is not stable SemVer")
    if expected_version is not None and version != expected_version:
        raise ContractError("AppImage zsync release version differs from the request")
    if record["repository"] != CANONICAL_REPOSITORY:
        raise ContractError("AppImage zsync repository identity is not canonical")
    if not LOWER_SHA_RE.fullmatch(str(record["tag_object"])):
        raise ContractError("AppImage zsync tag_object is not a full lowercase SHA")
    for field in ("baseline_release_id", "candidate_release_id"):
        value = record[field]
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise ContractError(f"AppImage zsync {field} must be a positive integer")
    if record["baseline_release_id"] == record["candidate_release_id"]:
        raise ContractError("AppImage zsync baseline and candidate release IDs are equal")
    for field in ("baseline_asset_id", "candidate_asset_id", "zsync_asset_id"):
        _validate_one_line(record[field], f"AppImage zsync {field}")
    if len(
        {
            record["baseline_asset_id"],
            record["candidate_asset_id"],
            record["zsync_asset_id"],
        }
    ) != 3:
        raise ContractError("AppImage zsync asset IDs are not distinct")
    if not SHA256_RE.fullmatch(str(record["candidate_asset_ledger_sha256"])):
        raise ContractError("AppImage zsync candidate asset ledger hash is invalid")
    baseline_tag = record["baseline_tag"]
    version_pattern = re.compile(
        r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
        r"(?:-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$"
    )

    def version_key(value: Any) -> tuple[int, int, int, tuple[int, int, int]]:
        if not isinstance(value, str):
            raise ContractError("AppImage zsync release tag is not a string")
        match = version_pattern.fullmatch(value)
        if match is None:
            raise ContractError("AppImage zsync release tag is invalid")
        major, minor, patch = (int(match.group(index)) for index in (1, 2, 3))
        channel = match.group(4)
        number = int(match.group(5)) if match.group(5) is not None else 0
        prerelease = (
            (1, 0, 0)
            if channel is None
            else (0, {"alpha": 0, "beta": 1, "rc": 2}[channel], number)
        )
        return (major, minor, patch, prerelease)

    if version_key(baseline_tag) >= version_key(version):
        raise ContractError("AppImage zsync baseline is not older than the candidate")
    asset_name = _validate_one_line(
        record["candidate_asset_name"], "AppImage candidate asset name"
    )
    if not re.fullmatch(r"xeneon-edge-hub-.+-x86_64\.AppImage", asset_name):
        raise ContractError("AppImage zsync candidate asset name is invalid")
    expected_candidate_url = (
        f"https://github.com/{CANONICAL_REPOSITORY}/releases/download/"
        f"{version}/{asset_name}"
    )
    if record["candidate_asset_url"] != expected_candidate_url:
        raise ContractError("AppImage candidate URL is not exact and versioned")
    if record["zsync_url"] != expected_candidate_url + ".zsync":
        raise ContractError("AppImage zsync URL is not exact and versioned")
    baseline_url = record["baseline_asset_url"]
    if (
        not isinstance(baseline_url, str)
        or not baseline_url.startswith(
            f"https://github.com/{CANONICAL_REPOSITORY}/releases/download/"
            f"{baseline_tag}/"
        )
        or not baseline_url.endswith(".AppImage")
    ):
        raise ContractError("AppImage baseline URL is not exact and versioned")
    for field in (
        "baseline_sha256",
        "candidate_sha256",
        "updated_sha256",
        "zsync_control_sha256",
    ):
        if not SHA256_RE.fullmatch(str(record[field])):
            raise ContractError(f"AppImage zsync {field} is invalid")
    if record["candidate_sha256"] != record["updated_sha256"]:
        raise ContractError("zsync output bytes do not match the exact candidate")
    if record["baseline_sha256"] == record["candidate_sha256"]:
        raise ContractError("zsync baseline bytes are identical to the candidate")
    for field in (
        "baseline_size",
        "candidate_size",
        "updated_size",
        "zsync_control_size",
    ):
        value = record[field]
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise ContractError(f"AppImage zsync {field} must be a positive integer")
    if record["candidate_size"] != record["updated_size"]:
        raise ContractError("zsync output size does not match the exact candidate")
    if record["public_release_was_prerelease"] is not True:
        raise ContractError("zsync was not run while the candidate was a prerelease")
    zsync_client = _validate_one_line(
        record["zsync_client"], "zsync client version"
    )
    if re.fullmatch(
        r"zsync v0\.6\.5 \(compiled [A-Z][a-z]{2} [ 0-9][0-9] "
        r"[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\)",
        zsync_client,
    ) is None:
        raise ContractError(
            "AppImage zsync client must be the audited zsync 0.6.5 build"
        )
    for field in (
        "client_reported_local_bytes",
        "client_reported_fetched_bytes",
        "measured_delta_payload_bytes",
        "measured_full_payload_bytes",
        "measured_payload_savings_bytes",
        "measured_payload_savings_basis_points",
    ):
        value = record[field]
        if not isinstance(value, int) or isinstance(value, bool):
            raise ContractError(f"AppImage zsync {field} must be an integer")
    local_bytes = record["client_reported_local_bytes"]
    fetched_bytes = record["client_reported_fetched_bytes"]
    delta_bytes = record["measured_delta_payload_bytes"]
    full_bytes = record["measured_full_payload_bytes"]
    savings_bytes = record["measured_payload_savings_bytes"]
    savings_basis_points = record["measured_payload_savings_basis_points"]
    if local_bytes <= 0:
        raise ContractError("AppImage zsync reused no verified local seed blocks")
    if fetched_bytes < 0:
        raise ContractError("AppImage zsync reported a negative target fetch")
    if full_bytes != record["candidate_size"]:
        raise ContractError(
            "AppImage zsync full payload differs from candidate size"
        )
    if delta_bytes != fetched_bytes + record["zsync_control_size"]:
        raise ContractError(
            "AppImage zsync delta payload is not target fetch plus control bytes"
        )
    if savings_bytes != full_bytes - delta_bytes:
        raise ContractError("AppImage zsync payload savings are inconsistent")
    if fetched_bytes >= full_bytes or delta_bytes >= full_bytes or savings_bytes <= 0:
        raise ContractError("AppImage zsync established no payload-byte saving")
    expected_basis_points = (savings_bytes * 10000) // full_bytes
    if (
        savings_basis_points != expected_basis_points
        or savings_basis_points <= 0
        or savings_basis_points > 10000
    ):
        raise ContractError(
            "AppImage zsync payload-savings basis points are inconsistent"
        )
    log = _validate_evidence_path(
        artifact_dir,
        record["log_path"],
        record["log_sha256"],
        "AppImage zsync log",
    )
    headers = _validate_evidence_path(
        artifact_dir,
        record["http_headers_path"],
        record["http_headers_sha256"],
        "AppImage anonymous HTTP headers",
    )
    control = _validate_evidence_path(
        artifact_dir,
        record["zsync_control_path"],
        record["zsync_control_sha256"],
        "AppImage zsync control file",
    )
    if control.stat().st_size != record["zsync_control_size"]:
        raise ContractError("AppImage zsync control size differs from its receipt")
    try:
        log_text = log.read_text(encoding="utf-8")
        header_text = headers.read_text(encoding="utf-8")
        control_bytes = control.read_bytes()
    except (OSError, UnicodeError) as exc:
        raise ContractError("AppImage zsync retained text evidence is invalid") from exc
    statistics = re.findall(
        r"(?:^|[\r\n])used ([0-9]+) local, fetched ([0-9]+)(?=[\r\n]|$)",
        log_text,
    )
    if len(statistics) != 1:
        raise ContractError(
            "AppImage zsync log lacks one unique final byte-statistics line"
        )
    reported_local, reported_fetched = (
        int(value) for value in statistics[0]
    )
    if (
        reported_local != local_bytes
        or reported_fetched != fetched_bytes
    ):
        raise ContractError(
            "AppImage zsync receipt differs from the raw client statistics"
        )
    if (
        record["zsync_url"] not in log_text
        or "result=PASS" not in log_text
        or record["candidate_asset_url"] not in header_text
        or record["baseline_asset_url"] not in header_text
        or record["zsync_url"] not in header_text
        or f"URL: {record['candidate_asset_url']}".encode() not in control_bytes
    ):
        raise ContractError("AppImage zsync retained evidence lacks required identities")
    _validate_exact_evidence_tree(
        artifact_dir,
        {
            record["log_path"],
            record["http_headers_path"],
            record["zsync_control_path"],
        },
    )


def _validate_certification_reference(
    value: Any,
    expected_commit: str,
    expected_prefix: str,
    expected_record_name: str,
) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ContractError("certification gate receipt must be an object")
    _require_exact_keys(
        value,
        {
            "artifact_path",
            "manifest_sha256",
            "provenance_sha256",
            "record_name",
            "record_sha256",
            "signature_sha256",
        },
        "certification gate receipt",
    )
    artifact_path = value["artifact_path"]
    if not isinstance(artifact_path, str):
        raise ContractError("certification artifact_path must be a string")
    pure = pathlib.PurePosixPath(artifact_path)
    if (
        pure.is_absolute()
        or pure.parts[:2] != ("artifacts", expected_commit)
        or any(
            part in ("", ".", "..") or not PORTABLE_COMPONENT_RE.fullmatch(part)
            for part in pure.parts
        )
        or str(pure) != artifact_path
    ):
        raise ContractError(
            "certification artifact_path must be canonical and commit-keyed"
        )
    suffix = pure.parts[2:]
    if expected_prefix == "manual-touch":
        if len(suffix) != 2 or suffix[0] != "manual-touch" or not re.fullmatch(
            r"[0-9]{8}T[0-9]{6}Z", suffix[1]
        ):
            raise ContractError("physical-touch artifact path is not canonical")
    elif len(suffix) != 1 or not re.fullmatch(
        rf"{re.escape(expected_prefix)}-[0-9]{{8}}T[0-9]{{6}}Z-[0-9]+",
        suffix[0],
    ):
        raise ContractError(
            f"{expected_prefix} certification artifact path is not canonical"
        )
    if value["record_name"] != expected_record_name:
        raise ContractError(
            f"{expected_prefix} certification record name differs from the contract"
        )
    for field in (
        "record_sha256",
        "manifest_sha256",
        "signature_sha256",
        "provenance_sha256",
    ):
        if not isinstance(value[field], str) or not SHA256_RE.fullmatch(value[field]):
            raise ContractError(f"certification receipt {field} is invalid")
    return value


def validate_release_certification(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_run_id: str,
    expected_version: str | None = None,
) -> None:
    if not LOWER_SHA_RE.fullmatch(expected_commit):
        raise ContractError("expected certification commit is not a full lowercase SHA")
    if not CERTIFICATION_RUN_ID_RE.fullmatch(expected_run_id):
        raise ContractError(
            "release-certification directory name is not a canonical run id"
        )
    if artifact_dir.name != expected_run_id:
        raise ContractError(
            "release-certification run id does not match its directory"
        )
    if artifact_dir.parent.name != expected_commit:
        raise ContractError(
            "release-certification directory is not keyed by the exact source commit"
        )

    receipt_path = artifact_dir / "RELEASE_CERTIFICATION.json"
    _require_regular_record(receipt_path)
    receipt = _read_json(receipt_path)
    _require_exact_keys(
        receipt,
        {
            "attestation",
            "attested_by",
            "completed_at",
            "gates",
            "release_version",
            "result",
            "run_id",
            "schema",
            "source_commit",
        },
        "RELEASE_CERTIFICATION.json",
    )
    if receipt["schema"] != CERTIFICATION_SCHEMA:
        raise ContractError(
            f"RELEASE_CERTIFICATION.json schema must be exactly {CERTIFICATION_SCHEMA}"
        )
    if receipt["source_commit"] != expected_commit:
        raise ContractError(
            "RELEASE_CERTIFICATION.json source_commit does not match the artifact key"
        )
    if receipt["run_id"] != expected_run_id:
        raise ContractError(
            "RELEASE_CERTIFICATION.json run_id does not match the artifact directory"
        )
    version = receipt["release_version"]
    if not isinstance(version, str) or not STABLE_VERSION_RE.fullmatch(version):
        raise ContractError(
            "RELEASE_CERTIFICATION.json release_version must be a stable vMAJOR.MINOR.PATCH"
        )
    if expected_version is not None and version != expected_version:
        raise ContractError(
            "RELEASE_CERTIFICATION.json release_version does not match the requested release"
        )
    if receipt["result"] != "PASS":
        raise ContractError(
            "RELEASE_CERTIFICATION.json result must be PASS before sealing or publication"
        )
    if receipt["attestation"] != RELEASE_CERTIFICATION_ATTESTATION:
        raise ContractError(
            "RELEASE_CERTIFICATION.json lacks the exact release-owner attestation"
        )
    attested_by = receipt["attested_by"]
    if (
        not isinstance(attested_by, str)
        or not attested_by.strip()
        or attested_by != attested_by.strip()
        or any(character in attested_by for character in "\t\r\n")
    ):
        raise ContractError(
            "RELEASE_CERTIFICATION.json attested_by must be one non-empty line"
        )
    _validate_utc_timestamp(receipt["completed_at"], "completed_at")

    gates = receipt["gates"]
    if not isinstance(gates, list) or len(gates) != len(
        EXPECTED_CERTIFICATION_GATES
    ):
        raise ContractError(
            "RELEASE_CERTIFICATION.json must contain the exact publication gate count"
        )

    referenced_paths: set[str] = set()
    for index, ((expected_gate_id, expected_prefix, record_name), gate) in enumerate(
        zip(EXPECTED_CERTIFICATION_GATES, gates, strict=True), start=1
    ):
        if not isinstance(gate, dict):
            raise ContractError(f"certification gate {index} must be an object")
        _require_exact_keys(
            gate,
            {"id", "receipt", "result"},
            f"certification gate {index}",
        )
        if gate["id"] != expected_gate_id:
            raise ContractError(
                f"certification gate {index} must be exactly {expected_gate_id}"
            )
        if gate["result"] != "PASS":
            raise ContractError(
                f"certification gate {expected_gate_id} must be PASS"
            )
        reference = _validate_certification_reference(
            gate["receipt"], expected_commit, expected_prefix, record_name
        )
        relative = reference["artifact_path"]
        if relative in referenced_paths:
            raise ContractError(
                f"certification artifact path is referenced more than once: {relative}"
            )
        referenced_paths.add(relative)


def print_release_certification_references(
    artifact_dir: pathlib.Path,
    expected_commit: str,
    expected_run_id: str,
    expected_version: str,
) -> None:
    validate_release_certification(
        artifact_dir, expected_commit, expected_run_id, expected_version
    )
    receipt = _read_json(artifact_dir / "RELEASE_CERTIFICATION.json")
    for gate in receipt["gates"]:
        reference = gate["receipt"]
        print(
            "\t".join(
                (
                    gate["id"],
                    reference["artifact_path"],
                    reference["record_name"],
                    reference["record_sha256"],
                    reference["manifest_sha256"],
                    reference["signature_sha256"],
                    reference["provenance_sha256"],
                )
            )
        )


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 6 and argv[1] == "provenance":
            validate_provenance(
                pathlib.Path(argv[2]), argv[3], argv[4], argv[5]
            )
        elif len(argv) == 5 and argv[1] == "release-run":
            validate_release_run(pathlib.Path(argv[2]), argv[3], argv[4])
        elif (
            len(argv) in (5, 6)
            and argv[1] == "release-certification"
        ):
            validate_release_certification(
                pathlib.Path(argv[2]),
                argv[3],
                argv[4],
                argv[5] if len(argv) == 6 else None,
            )
        elif len(argv) == 6 and argv[1] == "release-certification-references":
            print_release_certification_references(
                pathlib.Path(argv[2]), argv[3], argv[4], argv[5]
            )
        elif len(argv) == 5 and argv[1] == "desktop-notification":
            validate_desktop_notification(
                pathlib.Path(argv[2]), argv[3], argv[4]
            )
        elif len(argv) == 5 and argv[1] == "mpris-transport":
            validate_mpris_transport(pathlib.Path(argv[2]), argv[3], argv[4])
        elif len(argv) == 5 and argv[1] == "native-lifecycle":
            validate_native_lifecycle(pathlib.Path(argv[2]), argv[3], argv[4])
        elif (
            len(argv) in (5, 6)
            and argv[1] == "appimage-zsync"
        ):
            validate_appimage_zsync(
                pathlib.Path(argv[2]),
                argv[3],
                argv[4],
                argv[5] if len(argv) == 6 else None,
            )
        else:
            print(
                "usage: audit_artifact_contract.py "
                "provenance PATH COMMIT ARTIFACT_PATH KEY | "
                "release-run ARTIFACT_DIR COMMIT RUN_ID | "
                "release-certification ARTIFACT_DIR COMMIT RUN_ID [VERSION] | "
                "release-certification-references ARTIFACT_DIR COMMIT RUN_ID VERSION | "
                "desktop-notification ARTIFACT_DIR COMMIT RUN_ID | "
                "mpris-transport ARTIFACT_DIR COMMIT RUN_ID | "
                "native-lifecycle ARTIFACT_DIR COMMIT RUN_ID | "
                "appimage-zsync ARTIFACT_DIR COMMIT RUN_ID [VERSION]",
                file=sys.stderr,
            )
            return 2
    except ContractError as exc:
        print(f"audit record contract failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
