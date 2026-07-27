#!/usr/bin/env python3
"""Validate the complete physical-touch result set before audit sealing."""

from __future__ import annotations

import csv
import hashlib
import pathlib
import re
import stat
import sys


EXPECTED_IDS = [
    "01-focus",
    "02-hydration",
    "03-task-toggle",
    "04-page-swipe",
    "05-widget-settings",
    "06-edit-gestures",
]
EXPECTED_HEADER = [
    "id",
    "action",
    "result",
    "started",
    "ended",
    "screenshot",
    "physical_evidence",
    "notes",
]
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_SIGNATURE = b"\xff\xd8\xff"
WEBM_SIGNATURE = b"\x1a\x45\xdf\xa3"


def fail(message: str) -> None:
    raise ValueError(message)


LOWER_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
AUDIT_STAMP_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")


def validate(audit_dir: pathlib.Path, expected_commit: str | None = None) -> None:
    results_path = audit_dir / "ACTION_RESULTS.tsv"
    try:
        payload = results_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail(f"ACTION_RESULTS.tsv is unavailable or invalid UTF-8: {exc}")
    if not payload.endswith("\n"):
        fail("ACTION_RESULTS.tsv must end with a newline")
    try:
        rows = list(csv.reader(payload.splitlines(), delimiter="\t", strict=True))
    except csv.Error as exc:
        fail(f"ACTION_RESULTS.tsv is malformed: {exc}")
    if not rows or rows[0] != EXPECTED_HEADER:
        fail("ACTION_RESULTS.tsv header differs from the eight-column contract")
    if len(rows) != len(EXPECTED_IDS) + 1:
        fail("ACTION_RESULTS.tsv must contain exactly six action rows")

    actual_ids: list[str] = []
    expected_captures: set[str] = set()
    expected_physical_evidence: set[str] = set()
    physical_hashes: set[str] = set()
    for number, row in enumerate(rows[1:], start=2):
        if len(row) != len(EXPECTED_HEADER) or any(not field for field in row):
            fail(f"ACTION_RESULTS.tsv row {number} has empty or extra fields")
        (
            action_id,
            _title,
            result,
            started,
            ended,
            screenshot,
            physical_evidence,
            _notes,
        ) = row
        actual_ids.append(action_id)
        if result != "PASS":
            fail(f"{action_id} is {result}, not PASS")
        if not started or not ended:
            fail(f"{action_id} has no bounded observation timestamps")
        expected_evidence = f"{action_id}.png"
        if screenshot != expected_evidence:
            fail(f"{action_id} screenshot must be exactly {expected_evidence}")
        expected_captures.add(expected_evidence)

        capture = audit_dir / expected_evidence
        try:
            metadata = capture.lstat()
        except OSError as exc:
            fail(f"{action_id} capture is unavailable: {exc}")
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"{action_id} capture is not a regular non-symlink file")
        if metadata.st_size <= len(PNG_SIGNATURE):
            fail(f"{action_id} capture is empty or truncated")
        try:
            if capture.read_bytes()[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
                fail(f"{action_id} capture is not a PNG file")
        except OSError as exc:
            fail(f"{action_id} capture could not be read: {exc}")

        physical_pattern = re.compile(
            rf"^{re.escape(action_id)}-physical\.(png|jpg|mp4|mov|webm)$"
        )
        if physical_pattern.fullmatch(physical_evidence) is None:
            fail(f"{action_id} physical evidence has an invalid canonical name")
        expected_physical_evidence.add(physical_evidence)
        physical_path = audit_dir / physical_evidence
        try:
            physical_metadata = physical_path.lstat()
        except OSError as exc:
            fail(f"{action_id} physical evidence is unavailable: {exc}")
        if not stat.S_ISREG(physical_metadata.st_mode):
            fail(f"{action_id} physical evidence is not a regular non-symlink file")
        if physical_metadata.st_size < 32 or physical_metadata.st_size > 536_870_912:
            fail(f"{action_id} physical evidence size is outside the audit bounds")
        digest = hashlib.sha256()
        try:
            with physical_path.open("rb") as handle:
                physical_header = handle.read(16)
                digest.update(physical_header)
                while chunk := handle.read(1024 * 1024):
                    digest.update(chunk)
        except OSError as exc:
            fail(f"{action_id} physical evidence could not be read: {exc}")
        suffix = physical_path.suffix.lower()
        signature_ok = (
            (suffix == ".png" and physical_header.startswith(PNG_SIGNATURE))
            or (suffix == ".jpg" and physical_header.startswith(JPEG_SIGNATURE))
            or (suffix == ".webm" and physical_header.startswith(WEBM_SIGNATURE))
            or (
                suffix in {".mp4", ".mov"}
                and len(physical_header) >= 12
                and physical_header[4:8] == b"ftyp"
            )
        )
        if not signature_ok:
            fail(f"{action_id} physical evidence signature differs from its type")
        physical_digest = digest.hexdigest()
        if physical_digest in physical_hashes:
            fail("the same physical evidence file cannot prove two touch actions")
        physical_hashes.add(physical_digest)

    if actual_ids != EXPECTED_IDS:
        fail("touch actions are missing, duplicated, or out of canonical order")
    actual_captures = {
        path.name
        for path in audit_dir.glob("*.png")
        if not path.name.endswith("-physical.png")
    }
    if actual_captures != expected_captures:
        fail("audit directory must contain exactly the six action PNG captures")
    actual_physical_evidence = {
        path.name
        for path in audit_dir.iterdir()
        if "-physical." in path.name
    }
    if actual_physical_evidence != expected_physical_evidence:
        fail("audit directory must contain exactly six named physical evidence files")

    if expected_commit is None:
        return
    if not LOWER_SHA_RE.fullmatch(expected_commit):
        fail("expected source commit is not a full lowercase SHA")
    if (
        audit_dir.name == ""
        or not AUDIT_STAMP_RE.fullmatch(audit_dir.name)
        or audit_dir.parent.name != "manual-touch"
        or audit_dir.parent.parent.name != expected_commit
    ):
        fail("manual touch evidence is not in its exact commit-keyed path")

    environment_path = audit_dir / "ENVIRONMENT.txt"
    report_path = audit_dir / "REPORT.md"
    for path in (environment_path, report_path):
        try:
            metadata = path.lstat()
        except OSError as exc:
            fail(f"{path.name} is unavailable: {exc}")
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size == 0:
            fail(f"{path.name} must be a non-empty regular non-symlink file")
    try:
        environment = environment_path.read_text(encoding="utf-8")
        report = report_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail(f"manual touch metadata is not valid UTF-8: {exc}")
    environment_fields: dict[str, str] = {}
    for number, line in enumerate(environment.splitlines(), start=1):
        if "=" not in line:
            fail(f"ENVIRONMENT.txt line {number} is not key=value")
        key, value = line.split("=", 1)
        if not key or not value or key in environment_fields:
            fail(f"ENVIRONMENT.txt line {number} is empty or duplicated")
        environment_fields[key] = value
    if environment_fields.get("source_sha") != expected_commit:
        fail("ENVIRONMENT.txt source_sha does not match the exact candidate")
    required_environment_fields = {
        "running_hub_pid",
        "running_hub_executable",
        "running_hub_sha256",
        "running_hub_identity",
        "expected_hub_identity",
        "installed_package",
    }
    missing_environment_fields = sorted(
        required_environment_fields - environment_fields.keys()
    )
    if missing_environment_fields:
        fail(
            "ENVIRONMENT.txt lacks running-candidate fields: "
            + ", ".join(missing_environment_fields)
        )
    if re.fullmatch(r"[1-9][0-9]*", environment_fields["running_hub_pid"]) is None:
        fail("ENVIRONMENT.txt running_hub_pid is invalid")
    if (
        re.fullmatch(r"[0-9a-f]{64}", environment_fields["running_hub_sha256"])
        is None
    ):
        fail("ENVIRONMENT.txt running_hub_sha256 is invalid")
    if not environment_fields["running_hub_executable"].startswith("/"):
        fail("ENVIRONMENT.txt running_hub_executable is not absolute")
    if (
        environment_fields["running_hub_identity"]
        != environment_fields["expected_hub_identity"]
        or not environment_fields["running_hub_identity"].startswith(
            "Xeneon Edge Linux Hub "
        )
    ):
        fail("ENVIRONMENT.txt running Hub identity differs from the expected candidate")
    if not environment_fields["installed_package"].startswith("xeneon-edge-hub "):
        fail("ENVIRONMENT.txt installed package identity is invalid")
    if f"- Overall result: **PASS**" not in report:
        fail("REPORT.md does not record an overall PASS")
    if f"- Source SHA: `{expected_commit}`" not in report:
        fail("REPORT.md does not name the exact candidate")
    if (
        f"- Running Hub identity: `{environment_fields['running_hub_identity']}`"
        not in report
        or (
            f"- Running Hub SHA-256: `{environment_fields['running_hub_sha256']}`"
            not in report
        )
        or (
            f"- Installed package: `{environment_fields['installed_package']}`"
            not in report
        )
    ):
        fail("REPORT.md does not bind the running candidate and installed package")
    signature_match = re.search(
        r"^Electronic signature: \*\*(.+)\*\*$", report, flags=re.MULTILINE
    )
    if signature_match is None or not signature_match.group(1).strip():
        fail("REPORT.md has no auditor electronic signature")


def main(argv: list[str]) -> int:
    if len(argv) == 2:
        expected_commit = None
        audit_dir = pathlib.Path(argv[1])
    elif len(argv) == 4 and argv[1] == "--release":
        expected_commit = argv[2]
        audit_dir = pathlib.Path(argv[3])
    else:
        print(
            "usage: manual_touch_result.py [--release COMMIT] AUDIT_DIR",
            file=sys.stderr,
        )
        return 2
    try:
        validate(audit_dir, expected_commit)
    except ValueError as exc:
        print(f"manual touch result contract failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
