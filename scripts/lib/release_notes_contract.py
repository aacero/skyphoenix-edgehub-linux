#!/usr/bin/env python3
"""Validate release notes against one exact version and publication ledger."""

from __future__ import annotations

import pathlib
import re
import sys


VERSION_RE = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-(?:alpha|beta|rc)\.(?:0|[1-9][0-9]*))?$"
)
ASSET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
START_MARKER = "<!-- release-assets:start -->"
END_MARKER = "<!-- release-assets:end -->"
REQUIRED_SECTIONS = (
    "## Highlights",
    "## Verification summary",
    "## Artifacts",
    "## Known limitations",
    "## Verification",
)


class NotesError(ValueError):
    pass


def release_stage(version: str) -> str:
    return "prerelease" if "-" in version else "stable"


def validate_inputs(version: str, assets: list[str]) -> None:
    if not VERSION_RE.fullmatch(version):
        raise NotesError(f"invalid release version: {version}")
    if not assets:
        raise NotesError("publication asset ledger is empty")
    if len(set(assets)) != len(assets):
        raise NotesError("publication asset ledger contains a duplicate")
    for asset in assets:
        if not ASSET_RE.fullmatch(asset):
            raise NotesError(f"unsafe publication asset name: {asset}")


def expected_block(assets: list[str]) -> list[str]:
    return [START_MARKER, *(f"- `{asset}`" for asset in assets), END_MARKER]


def validate(path: pathlib.Path, version: str, assets: list[str]) -> None:
    validate_inputs(version, assets)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise NotesError(f"release notes are not readable UTF-8: {error}") from error
    if not text.endswith("\n"):
        raise NotesError("release notes must end with one newline")
    lines = text.splitlines()
    expected_heading = f"# EdgeHub {version}"
    if not lines or lines[0] != expected_heading:
        raise NotesError(
            f"first heading must be exactly {expected_heading!r}"
        )
    version_line = f"Release version: `{version}`"
    if lines.count(version_line) != 1:
        raise NotesError(
            f"body must contain exactly one {version_line!r} line"
        )
    stage_line = f"Release stage: {release_stage(version)}"
    if lines.count(stage_line) != 1:
        raise NotesError(
            f"body must contain exactly one {stage_line!r} line"
        )
    for section in REQUIRED_SECTIONS:
        if lines.count(section) != 1:
            raise NotesError(
                f"release notes must contain exactly one {section!r} section"
            )
    if lines.count(START_MARKER) != 1 or lines.count(END_MARKER) != 1:
        raise NotesError("release asset ledger markers must each occur once")
    start = lines.index(START_MARKER)
    end = lines.index(END_MARKER)
    if end <= start:
        raise NotesError("release asset ledger markers are reversed")
    actual_block = lines[start : end + 1]
    required_block = expected_block(assets)
    if actual_block != required_block:
        raise NotesError(
            "release asset ledger differs from the exact publication set"
        )


def usage() -> None:
    print(
        "Usage:\n"
        "  release_notes_contract.py check PATH VERSION ASSET...\n"
        "  release_notes_contract.py template VERSION ASSET...",
        file=sys.stderr,
    )


def main(arguments: list[str]) -> int:
    if not arguments:
        usage()
        return 2
    command, *values = arguments
    try:
        if command == "check" and len(values) >= 3:
            path = pathlib.Path(values[0])
            version = values[1]
            assets = values[2:]
            validate(path, version, assets)
            return 0
        if command == "template" and len(values) >= 2:
            version = values[0]
            assets = values[1:]
            validate_inputs(version, assets)
            print(f"# EdgeHub {version}")
            print()
            print(f"Release version: `{version}`")
            print(f"Release stage: {release_stage(version)}")
            print()
            print("## Artifacts")
            print()
            print("\n".join(expected_block(assets)))
            return 0
        usage()
        return 2
    except NotesError as error:
        print(f"release notes contract failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
