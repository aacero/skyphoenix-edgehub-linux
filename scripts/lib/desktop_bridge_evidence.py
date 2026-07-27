#!/usr/bin/env python3
"""Create strict typed receipts from real desktop bridge evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import stat
import sys
import tempfile
from typing import Any

import audit_artifact_contract as contract


def fail(message: str) -> None:
    raise contract.ContractError(message)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def evidence_file(
    artifact_dir: pathlib.Path, value: str, field: str
) -> tuple[pathlib.Path, str]:
    relative = pathlib.PurePosixPath(value)
    if (
        relative.is_absolute()
        or len(relative.parts) < 2
        or relative.parts[0] != "evidence"
        or any(part in {"", ".", ".."} for part in relative.parts)
        or str(relative) != value
    ):
        fail(f"{field} must be a canonical path below evidence/")
    path = artifact_dir
    for component in relative.parts:
        path /= component
        try:
            metadata = path.lstat()
        except OSError as exc:
            fail(f"{field} is unavailable: {exc}")
        if stat.S_ISLNK(metadata.st_mode):
            fail(f"{field} contains a symlink")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size == 0:
        fail(f"{field} must be a non-empty regular file")
    return path, sha256_file(path)


def validate_identity(
    artifact_dir: pathlib.Path, source_commit: str, run_id: str, prefix: str
) -> None:
    contract._validate_run_identity(
        artifact_dir, source_commit, run_id, prefix
    )
    if artifact_dir.is_symlink() or artifact_dir.parent.is_symlink():
        fail("artifact path must not contain a symlink")


def validate_human(
    attested_by: str, attestation: str, expected_attestation: str
) -> None:
    contract._validate_one_line(attested_by, "attested_by")
    if attestation != expected_attestation:
        fail("the exact human attestation was not supplied")


def command_map(arguments: argparse.Namespace, keys: tuple[str, ...]) -> dict[str, Any]:
    result = {key: getattr(arguments, f"{key}_command") for key in keys}
    contract._validate_command_map(result, set(keys), "commands")
    return result


def publish_json(path: pathlib.Path, document: dict[str, Any]) -> None:
    if path.exists() or path.is_symlink():
        fail(f"{path.name} already exists and will not be replaced")
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("short write")
            remaining = remaining[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(temporary, path)
        directory = os.open(
            path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        )
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def create_notification(arguments: argparse.Namespace) -> None:
    artifact_dir = arguments.artifact_dir.resolve(strict=True)
    validate_identity(
        artifact_dir,
        arguments.source_commit,
        arguments.run_id,
        "desktop-notification",
    )
    validate_human(
        arguments.attested_by,
        arguments.attestation,
        contract.DESKTOP_NOTIFICATION_ATTESTATION,
    )
    process_log, process_digest = evidence_file(
        artifact_dir, arguments.process_log, "notification process log"
    )
    transport_log, transport_digest = evidence_file(
        artifact_dir, arguments.transport_log, "notification transport log"
    )
    screenshot, screenshot_digest = evidence_file(
        artifact_dir, arguments.screenshot, "notification screenshot"
    )
    smoke_binary, binary_digest = evidence_file(
        artifact_dir, arguments.smoke_binary, "notification smoke binary"
    )
    contract._validate_png(screenshot, "notification screenshot")
    if smoke_binary.read_bytes()[:4] != b"\x7fELF":
        fail("notification smoke binary is not ELF")

    request_time, confirmation_time = (
        contract._validate_notification_process_log(
            process_log,
            arguments.source_commit,
            arguments.summary,
            arguments.body,
        )
    )
    contract._validate_notification_transport_log(
        transport_log, arguments.summary, arguments.body
    )
    capture_time = contract._parse_utc_timestamp(
        arguments.screenshot_captured_at, "screenshot_captured_at"
    )
    if capture_time < contract._parse_utc_timestamp(
        confirmation_time, "delivery_confirmed_at"
    ):
        fail("screenshot was captured before delivery confirmation")

    record = {
        "schema": contract.DESKTOP_NOTIFICATION_SCHEMA,
        "source_commit": arguments.source_commit,
        "run_id": arguments.run_id,
        "result": "PASS",
        "request_sent_at": request_time,
        "delivery_confirmed_at": confirmation_time,
        "screenshot_captured_at": arguments.screenshot_captured_at,
        "completed_at": utc_now(),
        "desktop_service": "org.freedesktop.Notifications",
        "method": "Notify",
        "summary": arguments.summary,
        "body": arguments.body,
        "priority_profile": {
            "category": "x-edgehub.reminder",
            "resident": True,
            "timeout_ms": 0,
            "transient": False,
            "urgency": 2,
        },
        "commands": command_map(
            arguments,
            ("configure", "build", "transport_monitor", "smoke", "screenshot"),
        ),
        "observed_on_real_desktop": True,
        "visually_distinct": True,
        "screenshot_path": arguments.screenshot,
        "screenshot_sha256": screenshot_digest,
        "transport_log_path": arguments.transport_log,
        "transport_log_sha256": transport_digest,
        "process_log_path": arguments.process_log,
        "process_log_sha256": process_digest,
        "smoke_binary_path": arguments.smoke_binary,
        "smoke_binary_sha256": binary_digest,
        "attested_by": arguments.attested_by,
        "attestation": arguments.attestation,
    }
    output = artifact_dir / "DESKTOP_NOTIFICATION.json"
    publish_json(output, record)
    contract.validate_desktop_notification(
        artifact_dir, arguments.source_commit, arguments.run_id
    )


def create_mpris(arguments: argparse.Namespace) -> None:
    artifact_dir = arguments.artifact_dir.resolve(strict=True)
    validate_identity(
        artifact_dir,
        arguments.source_commit,
        arguments.run_id,
        "mpris-transport",
    )
    validate_human(
        arguments.attested_by,
        arguments.attestation,
        contract.MPRIS_TRANSPORT_ATTESTATION,
    )
    process_log, process_digest = evidence_file(
        artifact_dir, arguments.process_log, "MPRIS process log"
    )
    transport_log, transport_digest = evidence_file(
        artifact_dir, arguments.transport_log, "MPRIS transport log"
    )
    smoke_binary, binary_digest = evidence_file(
        artifact_dir, arguments.smoke_binary, "MPRIS smoke binary"
    )
    if smoke_binary.read_bytes()[:4] != b"\x7fELF":
        fail("MPRIS smoke binary is not ELF")

    transcript = contract._validate_mpris_process_log(
        process_log, arguments.source_commit
    )
    contract._validate_mpris_transport_log(
        transport_log, transcript["player_bus_name"]
    )
    record = {
        "schema": contract.MPRIS_TRANSPORT_SCHEMA,
        "source_commit": arguments.source_commit,
        "run_id": arguments.run_id,
        "result": "PASS",
        "completed_at": utc_now(),
        "player_requested": arguments.player,
        "player_bus_name": transcript["player_bus_name"],
        "action": "PlayPause",
        "before_state": transcript["before_state"],
        "intermediate_state": transcript["intermediate_state"],
        "restored_state": transcript["restored_state"],
        "state_changed": True,
        "state_restored": True,
        "action_sent_at": transcript["action_sent_at"],
        "intermediate_observed_at": transcript["intermediate_observed_at"],
        "restore_sent_at": transcript["restore_sent_at"],
        "restored_at": transcript["restored_at"],
        "commands": command_map(
            arguments, ("configure", "build", "transport_monitor", "smoke")
        ),
        "transport_log_path": arguments.transport_log,
        "transport_log_sha256": transport_digest,
        "process_log_path": arguments.process_log,
        "process_log_sha256": process_digest,
        "smoke_binary_path": arguments.smoke_binary,
        "smoke_binary_sha256": binary_digest,
        "attested_by": arguments.attested_by,
        "attestation": arguments.attestation,
    }
    output = artifact_dir / "MPRIS_TRANSPORT.json"
    publish_json(output, record)
    contract.validate_mpris_transport(
        artifact_dir, arguments.source_commit, arguments.run_id
    )


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--artifact-dir", type=pathlib.Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attested-by", required=True)
    parser.add_argument("--attestation", required=True)
    parser.add_argument("--process-log", required=True)
    parser.add_argument("--transport-log", required=True)
    parser.add_argument("--smoke-binary", required=True)
    parser.add_argument("--configure-command", action="append", required=True)
    parser.add_argument("--build-command", action="append", required=True)
    parser.add_argument("--transport-monitor-command", action="append", required=True)
    parser.add_argument("--smoke-command", action="append", required=True)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="kind", required=True)
    notification = subparsers.add_parser("notification")
    add_common(notification)
    notification.add_argument("--summary", required=True)
    notification.add_argument("--body", required=True)
    notification.add_argument("--screenshot", required=True)
    notification.add_argument("--screenshot-captured-at", required=True)
    notification.add_argument("--screenshot-command", action="append", required=True)
    mpris = subparsers.add_parser("mpris")
    add_common(mpris)
    mpris.add_argument("--player", required=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    try:
        arguments = parse_arguments(argv[1:])
        if arguments.kind == "notification":
            create_notification(arguments)
        else:
            create_mpris(arguments)
    except contract.ContractError as exc:
        print(f"desktop bridge evidence failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
