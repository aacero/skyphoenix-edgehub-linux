#!/usr/bin/env python3
"""Build unsigned, commit-keyed release evidence drafts safely."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
from dataclasses import dataclass
from typing import Any, Callable, Sequence


CANONICAL_REPOSITORY = "skyphoenix-it/skyphoenix-edgehub-linux"
CANONICAL_WORKFLOW_NAME = "Native Package Upgrade and Rollback"
CANONICAL_WORKFLOW_SIGNER = (
    "github.com/skyphoenix-it/skyphoenix-edgehub-linux/"
    ".github/workflows/native-upgrade-rollback.yml"
)
NATIVE_SCHEMA = "skyphoenix-edgehub-native-package-lifecycle/v2"
CERTIFICATION_SCHEMA = "skyphoenix-edgehub-release-certification/v2"
RELEASE_CERTIFICATION_ATTESTATION = (
    "I attest that every named gate was reviewed against the retained evidence "
    "and passed for this exact source commit and release version."
)
NATIVE_IMPORTER_IDENTITY = "EdgeHub native lifecycle evidence importer"
NATIVE_IMPORTER_ATTESTATION = (
    "Automated import verified both package byte hashes, the exact PASS report, "
    "the exact lifecycle environment, the successful canonical workflow run, "
    "and separate GitHub build provenance for every retained subject; no human "
    "observation is asserted."
)
LIFECYCLE_ENVIRONMENT_NAME = "container-lifecycle-environment.txt"
EXPECTED_LIFECYCLE_ENVIRONMENTS = {
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
LOWER_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PORTABLE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
STABLE_VERSION_RE = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$"
)
BASELINE_REF_RE = re.compile(
    r"^(?:refs/tags/)?v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)"
    r"\.(?:0|[1-9][0-9]*))?$"
)
WORKFLOW_URL_RE = re.compile(
    r"^https://github\.com/skyphoenix-it/skyphoenix-edgehub-linux/"
    r"actions/runs/([1-9][0-9]*)$"
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


class EvidenceDraftError(RuntimeError):
    """A condition that makes an evidence draft unsafe or unsupported."""


Runner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


def run_command(arguments: Sequence[str]) -> subprocess.CompletedProcess[str]:
    """Run one command without a shell and retain its bounded text output."""

    try:
        return subprocess.run(
            list(arguments),
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
        )
    except FileNotFoundError as exc:
        raise EvidenceDraftError(
            f"required command is unavailable: {arguments[0]}"
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise EvidenceDraftError(
            f"command did not finish within 120 seconds: {arguments[0]}"
        ) from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        if len(detail) > 2000:
            detail = detail[:2000] + "..."
        suffix = f": {detail}" if detail else ""
        raise EvidenceDraftError(
            f"command failed: {arguments[0]}{suffix}"
        ) from exc


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def _format_timestamp(moment: dt.datetime) -> tuple[str, str]:
    if moment.tzinfo is None:
        raise EvidenceDraftError("evidence timestamp must be timezone-aware")
    utc = moment.astimezone(dt.timezone.utc).replace(microsecond=0)
    return (
        utc.strftime("%Y%m%dT%H%M%SZ"),
        utc.isoformat().replace("+00:00", "Z"),
    )


def _validate_one_line(value: str, label: str) -> str:
    if (
        not value
        or value != value.strip()
        or any(character in value for character in "\t\r\n")
    ):
        raise EvidenceDraftError(f"{label} must be one non-empty trimmed line")
    return value


def _validate_commit(value: str, label: str) -> str:
    if not LOWER_SHA_RE.fullmatch(value):
        raise EvidenceDraftError(f"{label} must be a full lowercase commit SHA")
    return value


def _assert_commit_available(
    repository_root: pathlib.Path,
    commit: str,
    runner: Runner,
) -> None:
    result = runner(
        [
            "git",
            "-C",
            str(repository_root),
            "rev-parse",
            "--verify",
            f"{commit}^{{commit}}",
        ]
    )
    if result.stdout.strip() != commit:
        raise EvidenceDraftError(
            f"local Git object does not resolve to the exact commit {commit}"
        )


def _assert_clean_exact_candidate(
    repository_root: pathlib.Path,
    commit: str,
    runner: Runner,
) -> None:
    head = runner(
        [
            "git",
            "-C",
            str(repository_root),
            "rev-parse",
            "--verify",
            "HEAD^{commit}",
        ]
    ).stdout.strip()
    if head != commit:
        raise EvidenceDraftError(
            "candidate commit must be the exact current HEAD"
        )
    state = runner(
        [
            "git",
            "-C",
            str(repository_root),
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignore-submodules=none",
        ]
    ).stdout
    if state:
        raise EvidenceDraftError(
            "working tree must be clean before release evidence is created"
        )


def _resolve_expected_baseline(
    repository_root: pathlib.Path,
    baseline_ref: str,
    runner: Runner,
) -> str:
    baseline_ref = _validate_one_line(baseline_ref, "baseline-ref")
    if LOWER_SHA_RE.fullmatch(baseline_ref):
        revision = baseline_ref
    elif BASELINE_REF_RE.fullmatch(baseline_ref):
        revision = (
            baseline_ref
            if baseline_ref.startswith("refs/tags/")
            else f"refs/tags/{baseline_ref}"
        )
    else:
        raise EvidenceDraftError(
            "baseline-ref must be a full lowercase commit or exact release tag"
        )
    result = runner(
        [
            "git",
            "-C",
            str(repository_root),
            "rev-parse",
            "--verify",
            f"{revision}^{{commit}}",
        ]
    ).stdout.strip()
    return _validate_commit(result, "resolved baseline commit")


def _ensure_safe_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    absolute = pathlib.Path(os.path.abspath(path))
    try:
        metadata = absolute.lstat()
    except OSError as exc:
        raise EvidenceDraftError(f"{label} is unavailable: {absolute}") from exc
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise EvidenceDraftError(f"{label} must be a real directory: {absolute}")
    if metadata.st_mode & 0o022:
        raise EvidenceDraftError(
            f"{label} must not be group/other writable: {absolute}"
        )
    return absolute


def _ensure_artifact_parent(
    repository_root: pathlib.Path, commit: str
) -> pathlib.Path:
    repository_root = _ensure_safe_directory(repository_root, "repository root")
    artifacts = repository_root / "artifacts"
    commit_root = artifacts / commit
    for path in (artifacts, commit_root):
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        path = _ensure_safe_directory(path, "artifact parent")
        try:
            path.relative_to(repository_root)
        except ValueError as exc:
            raise EvidenceDraftError(
                "artifact parent escaped the repository"
            ) from exc
    return commit_root


def _open_regular(path: pathlib.Path, label: str) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
    except OSError as exc:
        if descriptor >= 0:
            os.close(descriptor)
        raise EvidenceDraftError(f"{label} is unavailable: {path}") from exc
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        os.close(descriptor)
        raise EvidenceDraftError(
            f"{label} must be a single-linked regular file: {path}"
        )
    return descriptor, metadata


def _read_regular_bytes(
    path: pathlib.Path, label: str, maximum_size: int
) -> bytes:
    descriptor, metadata = _open_regular(path, label)
    try:
        if metadata.st_size <= 0 or metadata.st_size > maximum_size:
            raise EvidenceDraftError(
                f"{label} size must be between 1 and {maximum_size} bytes"
            )
        chunks: list[bytes] = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise EvidenceDraftError(f"{label} ended before its stated size")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise EvidenceDraftError(f"{label} changed while it was read")
        after = os.fstat(descriptor)
        if (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ) != (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        ):
            raise EvidenceDraftError(f"{label} changed while it was read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _sha256_regular(path: pathlib.Path, label: str) -> str:
    descriptor, before = _open_regular(path, label)
    digest = hashlib.sha256()
    try:
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ) != (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ):
            raise EvidenceDraftError(f"{label} changed while it was hashed")
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def _copy_regular(
    source: pathlib.Path, destination: pathlib.Path, label: str
) -> str:
    source_descriptor, before = _open_regular(source, label)
    destination_descriptor = -1
    digest = hashlib.sha256()
    try:
        destination_descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        while chunk := os.read(source_descriptor, 1024 * 1024):
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_descriptor, view)
                if written <= 0:
                    raise EvidenceDraftError(
                        f"short write while copying {label}"
                    )
                view = view[written:]
        os.fsync(destination_descriptor)
        after = os.fstat(source_descriptor)
        if (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ) != (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ):
            raise EvidenceDraftError(f"{label} changed while it was copied")
    except OSError as exc:
        raise EvidenceDraftError(f"could not copy {label}") from exc
    finally:
        os.close(source_descriptor)
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
    return digest.hexdigest()


def _write_json(path: pathlib.Path, document: Any) -> None:
    payload = (
        json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EvidenceDraftError(f"short write while creating {path.name}")
            view = view[written:]
        os.fsync(descriptor)
    except OSError as exc:
        raise EvidenceDraftError(f"could not create {path}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _sync_directory(path: pathlib.Path) -> None:
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_DIRECTORY", 0),
        )
        os.fsync(descriptor)
    except OSError as exc:
        raise EvidenceDraftError(
            f"could not make evidence directory durable: {path}"
        ) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _parse_json_output(output: str, label: str) -> Any:
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise EvidenceDraftError(f"{label} did not return valid JSON") from exc


def _parse_report(payload: bytes, report_name: str) -> dict[str, str]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise EvidenceDraftError(f"{report_name} is not valid UTF-8") from exc
    if not text.endswith("\n"):
        raise EvidenceDraftError(f"{report_name} must end with a newline")
    result: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        if "=" not in line:
            raise EvidenceDraftError(
                f"{report_name} line {number} is not key=value"
            )
        key, value = line.split("=", 1)
        if (
            not PORTABLE_COMPONENT_RE.fullmatch(key)
            or not value
            or key in result
            or any(character in value for character in "\r\n\x00")
        ):
            raise EvidenceDraftError(
                f"{report_name} line {number} is invalid or duplicated"
            )
        result[key] = value
    return result


def _validate_sidecar(
    payload: bytes, expected_name: str, expected_digest: str, label: str
) -> None:
    expected = f"{expected_digest}  {expected_name}\n".encode("ascii")
    if payload != expected:
        raise EvidenceDraftError(
            f"{label} must contain the exact SHA-256 and portable basename"
        )


def _validate_lifecycle_environment(payload: bytes, kind: str) -> None:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise EvidenceDraftError(
            "lifecycle environment record is not valid UTF-8"
        ) from exc
    if not text.endswith("\n") or "\x00" in text:
        raise EvidenceDraftError(
            "lifecycle environment record must be complete UTF-8 text"
        )
    lines = text.splitlines()
    expected_prefix = EXPECTED_LIFECYCLE_ENVIRONMENTS[kind]
    if tuple(lines[:3]) != expected_prefix:
        raise EvidenceDraftError(
            "lifecycle environment does not name the pinned distro and platform"
        )
    os_release = lines[3:]
    if not os_release or not any(line.startswith("ID=") for line in os_release):
        raise EvidenceDraftError(
            "lifecycle environment lacks the resolved container OS identity"
        )


def _validate_package_name(name: str, kind: str, label: str) -> str:
    if (
        not PORTABLE_COMPONENT_RE.fullmatch(name)
        or pathlib.PurePosixPath(name).name != name
        or not name.endswith(f".{kind}")
    ):
        raise EvidenceDraftError(
            f"{label} must be one portable .{kind} basename"
        )
    return name


def _assert_attestation_subject(
    document: Any,
    subject_name: str,
    subject_digest: str,
    workflow_url: str,
) -> None:
    if not isinstance(document, list) or not document:
        raise EvidenceDraftError(
            "gh attestation verify returned no verified attestations"
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
        subjects = statement.get("subject") if isinstance(statement, dict) else None
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
        if not isinstance(invocation_id, str) or re.fullmatch(
            rf"{re.escape(workflow_url)}(?:/attempts/[1-9][0-9]*)?",
            invocation_id,
        ) is None:
            continue
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
                return
    raise EvidenceDraftError(
        "verified attestation output does not bind the exact retained subject "
        "hash to the requested workflow run"
    )


def _cleanup_private_tree(path: pathlib.Path, expected_parent: pathlib.Path) -> None:
    try:
        path.relative_to(expected_parent)
    except ValueError:
        return
    if path.name.startswith(".evidence-draft-") and path.is_dir():
        shutil.rmtree(path)


def import_native_lifecycle(
    *,
    repository_root: pathlib.Path,
    downloaded_artifact: pathlib.Path,
    kind: str,
    expected_commit: str,
    expected_baseline_ref: str,
    workflow_url: str,
    gh_command: str = "gh",
    contract_path: pathlib.Path | None = None,
    runner: Runner = run_command,
    now: dt.datetime | None = None,
    process_id: int | None = None,
) -> pathlib.Path:
    """Verify and import one downloaded native lifecycle CI artifact."""

    if kind not in {"deb", "rpm"}:
        raise EvidenceDraftError("package kind must be exactly deb or rpm")
    expected_commit = _validate_commit(expected_commit, "candidate commit")
    workflow_match = WORKFLOW_URL_RE.fullmatch(workflow_url)
    if workflow_match is None:
        raise EvidenceDraftError(
            "workflow URL must name one canonical GitHub Actions run"
        )
    workflow_run_id = workflow_match.group(1)
    repository_root = _ensure_safe_directory(repository_root, "repository root")
    downloaded_artifact = _ensure_safe_directory(
        downloaded_artifact, "downloaded CI artifact"
    )
    _assert_commit_available(repository_root, expected_commit, runner)
    _assert_clean_exact_candidate(repository_root, expected_commit, runner)
    expected_baseline_sha = _resolve_expected_baseline(
        repository_root, expected_baseline_ref, runner
    )

    report_name = f"native-upgrade-rollback-{kind}.txt"
    report_source = downloaded_artifact / report_name
    report_payload = _read_regular_bytes(
        report_source, "native lifecycle report", 1024 * 1024
    )
    report = _parse_report(report_payload, report_name)
    report_digest = hashlib.sha256(report_payload).hexdigest()
    report_sidecar_source = downloaded_artifact / f"{report_name}.sha256"
    report_sidecar_payload = _read_regular_bytes(
        report_sidecar_source, "native lifecycle report sidecar", 4096
    )
    _validate_sidecar(
        report_sidecar_payload,
        report_name,
        report_digest,
        "native lifecycle report sidecar",
    )
    environment_source = downloaded_artifact / LIFECYCLE_ENVIRONMENT_NAME
    environment_payload = _read_regular_bytes(
        environment_source, "lifecycle environment record", 1024 * 1024
    )
    _validate_lifecycle_environment(environment_payload, kind)
    environment_digest = hashlib.sha256(environment_payload).hexdigest()
    environment_sidecar_source = downloaded_artifact / (
        f"{LIFECYCLE_ENVIRONMENT_NAME}.sha256"
    )
    environment_sidecar_payload = _read_regular_bytes(
        environment_sidecar_source, "lifecycle environment sidecar", 4096
    )
    _validate_sidecar(
        environment_sidecar_payload,
        LIFECYCLE_ENVIRONMENT_NAME,
        environment_digest,
        "lifecycle environment sidecar",
    )

    required_report_values = {
        "result": "PASS",
        "package_kind": kind,
        "candidate_sha": expected_commit,
    }
    required_report_values.update({field: "PASS" for field in NATIVE_PASS_FIELDS})
    for field, expected in required_report_values.items():
        if report.get(field) != expected:
            raise EvidenceDraftError(
                f"native lifecycle report field {field} must be {expected}"
            )
    baseline_sha = _validate_commit(
        report.get("baseline_sha", ""), "reported baseline commit"
    )
    if report.get("baseline_ref") != expected_baseline_ref:
        raise EvidenceDraftError(
            "reported baseline ref differs from the explicit owner selection"
        )
    if baseline_sha != expected_baseline_sha:
        raise EvidenceDraftError(
            "reported baseline commit differs from the explicit owner selection"
        )
    if baseline_sha == expected_commit:
        raise EvidenceDraftError(
            "reported baseline and candidate commits must be different"
        )
    runner(
        [
            "git",
            "-C",
            str(repository_root),
            "merge-base",
            "--is-ancestor",
            baseline_sha,
            expected_commit,
        ]
    )

    package_entries: list[tuple[str, pathlib.Path, pathlib.Path, str]] = []
    for label in ("baseline", "candidate"):
        package_name = _validate_package_name(
            report.get(f"{label}_package", ""), kind, f"{label} package"
        )
        package_digest = report.get(f"{label}_package_sha256", "")
        if not SHA256_RE.fullmatch(package_digest):
            raise EvidenceDraftError(
                f"reported {label} package SHA-256 is invalid"
            )
        package_source = downloaded_artifact / package_name
        sidecar_source = downloaded_artifact / f"{package_name}.sha256"
        sidecar_payload = _read_regular_bytes(
            sidecar_source, f"{label} package sidecar", 4096
        )
        _validate_sidecar(
            sidecar_payload,
            package_name,
            package_digest,
            f"{label} package sidecar",
        )
        package_entries.append(
            (label, package_source, sidecar_source, package_digest)
        )
    if package_entries[0][1].name == package_entries[1][1].name:
        raise EvidenceDraftError(
            "baseline and candidate package basenames must be distinct"
        )

    stamp, completed_at = _format_timestamp(now or _utc_now())
    pid = process_id if process_id is not None else os.getpid()
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise EvidenceDraftError("process id must be a positive integer")
    run_id = f"native-package-lifecycle-{kind}-{stamp}-{pid}"
    artifact_parent = _ensure_artifact_parent(repository_root, expected_commit)
    destination = artifact_parent / run_id
    if destination.exists() or destination.is_symlink():
        raise EvidenceDraftError(f"artifact destination already exists: {destination}")
    temporary: pathlib.Path | None = (
        artifact_parent / f".evidence-draft-{run_id}"
    )
    try:
        os.mkdir(temporary, 0o700)
    except OSError as exc:
        raise EvidenceDraftError(
            f"could not create private draft directory: {temporary}"
        ) from exc

    try:
        evidence_dir = temporary / "evidence"
        source_dir = temporary / "source"
        os.mkdir(evidence_dir, 0o700)
        os.mkdir(source_dir, 0o700)

        copied_report_digest = _copy_regular(
            report_source,
            evidence_dir / report_name,
            "native lifecycle report",
        )
        if copied_report_digest != report_digest:
            raise EvidenceDraftError(
                "native lifecycle report changed before it was retained"
            )
        _copy_regular(
            report_sidecar_source,
            source_dir / f"{report_name}.sha256",
            "native lifecycle report sidecar",
        )
        retained_environment = source_dir / LIFECYCLE_ENVIRONMENT_NAME
        copied_environment_digest = _copy_regular(
            environment_source,
            retained_environment,
            "lifecycle environment record",
        )
        if copied_environment_digest != environment_digest:
            raise EvidenceDraftError(
                "lifecycle environment changed before it was retained"
            )
        _copy_regular(
            environment_sidecar_source,
            source_dir / f"{LIFECYCLE_ENVIRONMENT_NAME}.sha256",
            "lifecycle environment sidecar",
        )

        retained_packages: dict[str, pathlib.Path] = {}
        for label, package_source, sidecar_source, expected_digest in package_entries:
            retained = source_dir / package_source.name
            actual_digest = _copy_regular(
                package_source, retained, f"{label} package"
            )
            if actual_digest != expected_digest:
                raise EvidenceDraftError(
                    f"{label} package bytes do not match the report and sidecar"
                )
            _copy_regular(
                sidecar_source,
                source_dir / sidecar_source.name,
                f"{label} package sidecar",
            )
            retained_packages[label] = retained

        workflow_result = runner(
            [
                gh_command,
                "run",
                "view",
                workflow_run_id,
                "--repo",
                CANONICAL_REPOSITORY,
                "--json",
                "url,headSha,event,status,conclusion,workflowName",
            ]
        )
        workflow_document = _parse_json_output(
            workflow_result.stdout, "gh run view"
        )
        expected_workflow_values = {
            "url": workflow_url,
            "headSha": expected_commit,
            "event": "workflow_dispatch",
            "status": "completed",
            "conclusion": "success",
            "workflowName": CANONICAL_WORKFLOW_NAME,
        }
        if not isinstance(workflow_document, dict) or any(
            workflow_document.get(field) != expected
            for field, expected in expected_workflow_values.items()
        ):
            raise EvidenceDraftError(
                "GitHub workflow run is not the successful canonical lifecycle "
                "run for the exact candidate commit"
            )

        candidate_package = retained_packages["candidate"]
        attestation_subjects = (
            (
                "PACKAGE",
                candidate_package,
                report["candidate_package_sha256"],
            ),
            ("REPORT", evidence_dir / report_name, report_digest),
            ("ENVIRONMENT", retained_environment, environment_digest),
        )
        _write_json(
            source_dir / "GITHUB_WORKFLOW_RUN.json", workflow_document
        )
        for subject_label, subject_path, subject_digest in attestation_subjects:
            attestation_result = runner(
                [
                    gh_command,
                    "attestation",
                    "verify",
                    str(subject_path),
                    "--repo",
                    CANONICAL_REPOSITORY,
                    "--signer-workflow",
                    CANONICAL_WORKFLOW_SIGNER,
                    "--source-digest",
                    expected_commit,
                    "--deny-self-hosted-runners",
                    "--format",
                    "json",
                ]
            )
            attestation_document = _parse_json_output(
                attestation_result.stdout,
                f"gh attestation verify for {subject_label.lower()}",
            )
            _assert_attestation_subject(
                attestation_document,
                subject_path.name,
                subject_digest,
                workflow_url,
            )
            _write_json(
                source_dir
                / f"GITHUB_{subject_label}_ATTESTATION_VERIFICATION.json",
                attestation_document,
            )

        retained_source_files = []
        for source_path in sorted(source_dir.iterdir(), key=lambda path: path.name):
            metadata = source_path.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_ISLNK(metadata.st_mode)
                or metadata.st_nlink != 1
            ):
                raise EvidenceDraftError(
                    "native lifecycle source inventory contains an unsafe entry"
                )
            retained_source_files.append(
                {
                    "path": f"source/{source_path.name}",
                    "sha256": _sha256_regular(
                        source_path, f"retained source {source_path.name}"
                    ),
                }
            )

        record = {
            "schema": NATIVE_SCHEMA,
            "source_commit": expected_commit,
            "run_id": run_id,
            "result": "PASS",
            "completed_at": completed_at,
            "package_kind": kind,
            "baseline_sha": baseline_sha,
            "candidate_sha": expected_commit,
            "candidate_package_sha256": report["candidate_package_sha256"],
            "workflow_url": workflow_url,
            "github_provenance_verified": True,
            "report_path": f"evidence/{report_name}",
            "report_sha256": report_digest,
            "source_files": retained_source_files,
            "attested_by": NATIVE_IMPORTER_IDENTITY,
            "attestation": NATIVE_IMPORTER_ATTESTATION,
        }
        _write_json(temporary / "NATIVE_PACKAGE_LIFECYCLE.json", record)

        _sync_directory(evidence_dir)
        _sync_directory(source_dir)
        _sync_directory(temporary)
        os.replace(temporary, destination)
        temporary = None
        _sync_directory(artifact_parent)
        contract = contract_path or (
            repository_root / "scripts/lib/audit_artifact_contract.py"
        )
        runner(
            [
                "python3",
                str(contract),
                "native-lifecycle",
                str(destination),
                expected_commit,
                run_id,
            ]
        )
        return destination
    except Exception:
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        if temporary is not None:
            _cleanup_private_tree(temporary, artifact_parent)
        raise


@dataclass(frozen=True)
class CertificationGate:
    gate_id: str
    prefix: str
    record_name: str
    contract_command: str


CERTIFICATION_GATES = (
    CertificationGate(
        "physical_touch", "manual-touch", "ACTION_RESULTS.tsv", "manual-touch"
    ),
    CertificationGate(
        "desktop_notification",
        "desktop-notification",
        "DESKTOP_NOTIFICATION.json",
        "desktop-notification",
    ),
    CertificationGate(
        "mpris_transport",
        "mpris-transport",
        "MPRIS_TRANSPORT.json",
        "mpris-transport",
    ),
    CertificationGate(
        "native_deb_lifecycle",
        "native-package-lifecycle-deb",
        "NATIVE_PACKAGE_LIFECYCLE.json",
        "native-lifecycle",
    ),
    CertificationGate(
        "native_rpm_lifecycle",
        "native-package-lifecycle-rpm",
        "NATIVE_PACKAGE_LIFECYCLE.json",
        "native-lifecycle",
    ),
)


def _assert_no_symlink_components(
    repository_root: pathlib.Path, target: pathlib.Path, label: str
) -> None:
    try:
        relative = target.relative_to(repository_root)
    except ValueError as exc:
        raise EvidenceDraftError(f"{label} is outside the repository") from exc
    current = repository_root
    for component in relative.parts:
        current /= component
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise EvidenceDraftError(f"{label} is unavailable: {target}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise EvidenceDraftError(f"{label} contains a symlink: {target}")


def _resolve_gate_path(
    repository_root: pathlib.Path,
    argument: pathlib.Path,
    commit: str,
    gate: CertificationGate,
) -> pathlib.Path:
    target = (
        argument
        if argument.is_absolute()
        else repository_root / argument
    )
    target = pathlib.Path(os.path.abspath(target))
    _assert_no_symlink_components(repository_root, target, gate.gate_id)
    target = _ensure_safe_directory(target, gate.gate_id)
    expected_root = repository_root / "artifacts" / commit
    try:
        suffix = target.relative_to(expected_root).parts
    except ValueError as exc:
        raise EvidenceDraftError(
            f"{gate.gate_id} must be below artifacts/{commit}"
        ) from exc
    if gate.prefix == "manual-touch":
        valid = (
            len(suffix) == 2
            and suffix[0] == "manual-touch"
            and re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", suffix[1]) is not None
        )
    else:
        valid = (
            len(suffix) == 1
            and re.fullmatch(
                rf"{re.escape(gate.prefix)}-[0-9]{{8}}T[0-9]{{6}}Z-[0-9]+",
                suffix[0],
            )
            is not None
        )
    if not valid:
        raise EvidenceDraftError(
            f"{gate.gate_id} path does not match its canonical typed gate"
        )
    return target


def _verify_typed_gate(
    *,
    commit: str,
    gate: CertificationGate,
    path: pathlib.Path,
    finalizer_path: pathlib.Path,
    contract_path: pathlib.Path,
    manual_touch_contract_path: pathlib.Path,
    runner: Runner,
) -> None:
    runner(
        [
            "bash",
            str(finalizer_path),
            "--verify",
            "--commit",
            commit,
            str(path),
        ]
    )
    if gate.contract_command == "manual-touch":
        runner(
            [
                "python3",
                str(manual_touch_contract_path),
                "--release",
                commit,
                str(path),
            ]
        )
    else:
        runner(
            [
                "python3",
                str(contract_path),
                gate.contract_command,
                str(path),
                commit,
                path.name,
            ]
        )


def build_release_certification_draft(
    *,
    repository_root: pathlib.Path,
    expected_commit: str,
    release_version: str,
    attested_by: str,
    gate_paths: dict[str, pathlib.Path],
    finalizer_path: pathlib.Path | None = None,
    contract_path: pathlib.Path | None = None,
    manual_touch_contract_path: pathlib.Path | None = None,
    runner: Runner = run_command,
    now: dt.datetime | None = None,
    process_id: int | None = None,
) -> pathlib.Path:
    """Build, but never sign or finalize, a release certification draft."""

    expected_commit = _validate_commit(expected_commit, "candidate commit")
    if not STABLE_VERSION_RE.fullmatch(release_version):
        raise EvidenceDraftError(
            "release version must be stable vMAJOR.MINOR.PATCH"
        )
    attested_by = _validate_one_line(attested_by, "attested-by")
    expected_gate_ids = {gate.gate_id for gate in CERTIFICATION_GATES}
    if set(gate_paths) != expected_gate_ids:
        raise EvidenceDraftError(
            "gate paths must name exactly the five stable certification gates"
        )
    repository_root = _ensure_safe_directory(repository_root, "repository root")
    _assert_commit_available(repository_root, expected_commit, runner)
    _assert_clean_exact_candidate(repository_root, expected_commit, runner)
    finalizer = finalizer_path or (
        repository_root / "scripts/finalize_audit_artifacts.sh"
    )
    contract = contract_path or (
        repository_root / "scripts/lib/audit_artifact_contract.py"
    )
    manual_contract = manual_touch_contract_path or (
        repository_root / "scripts/lib/manual_touch_result.py"
    )

    resolved: list[tuple[CertificationGate, pathlib.Path]] = []
    seen_paths: set[pathlib.Path] = set()
    for gate in CERTIFICATION_GATES:
        path = _resolve_gate_path(
            repository_root, gate_paths[gate.gate_id], expected_commit, gate
        )
        if path in seen_paths:
            raise EvidenceDraftError("a typed gate path was supplied more than once")
        seen_paths.add(path)
        _verify_typed_gate(
            commit=expected_commit,
            gate=gate,
            path=path,
            finalizer_path=finalizer,
            contract_path=contract,
            manual_touch_contract_path=manual_contract,
            runner=runner,
        )
        resolved.append((gate, path))

    gate_documents: list[dict[str, Any]] = []
    for gate, path in resolved:
        names = {
            "record_sha256": gate.record_name,
            "manifest_sha256": "MANIFEST.sha256",
            "signature_sha256": "MANIFEST.sha256.asc",
            "provenance_sha256": "PROVENANCE.json",
        }
        hashes = {
            field: _sha256_regular(path / name, f"{gate.gate_id} {name}")
            for field, name in names.items()
        }
        _verify_typed_gate(
            commit=expected_commit,
            gate=gate,
            path=path,
            finalizer_path=finalizer,
            contract_path=contract,
            manual_touch_contract_path=manual_contract,
            runner=runner,
        )
        gate_documents.append(
            {
                "id": gate.gate_id,
                "result": "PASS",
                "receipt": {
                    "artifact_path": path.relative_to(repository_root).as_posix(),
                    "record_name": gate.record_name,
                    **hashes,
                },
            }
        )

    stamp, completed_at = _format_timestamp(now or _utc_now())
    pid = process_id if process_id is not None else os.getpid()
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise EvidenceDraftError("process id must be a positive integer")
    run_id = f"release-certification-{stamp}-{pid}"
    artifact_parent = _ensure_artifact_parent(repository_root, expected_commit)
    destination = artifact_parent / run_id
    if destination.exists() or destination.is_symlink():
        raise EvidenceDraftError(f"artifact destination already exists: {destination}")
    temporary: pathlib.Path | None = (
        artifact_parent / f".evidence-draft-{run_id}"
    )
    try:
        os.mkdir(temporary, 0o700)
    except OSError as exc:
        raise EvidenceDraftError(
            f"could not create private draft directory: {temporary}"
        ) from exc

    receipt = {
        "schema": CERTIFICATION_SCHEMA,
        "source_commit": expected_commit,
        "release_version": release_version,
        "run_id": run_id,
        "result": "PASS",
        "completed_at": completed_at,
        "attested_by": attested_by,
        "attestation": RELEASE_CERTIFICATION_ATTESTATION,
        "gates": gate_documents,
    }
    try:
        _write_json(temporary / "RELEASE_CERTIFICATION.json", receipt)
        _sync_directory(temporary)
        os.replace(temporary, destination)
        temporary = None
        _sync_directory(artifact_parent)
        runner(
            [
                "python3",
                str(contract),
                "release-certification",
                str(destination),
                expected_commit,
                run_id,
                release_version,
            ]
        )
        return destination
    except Exception:
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        if temporary is not None:
            _cleanup_private_tree(temporary, artifact_parent)
        raise
