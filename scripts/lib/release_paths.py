#!/usr/bin/env python3
"""Fail-closed path and publication-set checks for the local release helper."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import stat
import sys


CONSERVATIVE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")


def fail(message: str) -> None:
    raise ValueError(message)


def conservative_name(name: str) -> None:
    if (
        not CONSERVATIVE_NAME.fullmatch(name)
        or name.startswith(".")
        or name.endswith(".")
        or ".." in name
        or "#" in name
    ):
        fail(f"non-portable release basename: {name!r}")


def reject_symlink_components(path: pathlib.Path) -> pathlib.Path:
    absolute = pathlib.Path(os.path.abspath(path))
    current = pathlib.Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        try:
            metadata = os.lstat(current)
        except OSError as error:
            fail(f"could not inspect path component {current}: {error}")
        if stat.S_ISLNK(metadata.st_mode):
            fail(f"release path contains a symlink component: {current}")
    return absolute


def check_extra(path_text: str, cleanup_roots: list[str]) -> None:
    path = reject_symlink_components(pathlib.Path(path_text))
    metadata = os.lstat(path)
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"extra artifact is not a regular file: {path}")
    if metadata.st_nlink != 1:
        fail(f"extra artifact has multiple hard links: {path}")
    conservative_name(path.name)
    for root_text in cleanup_roots:
        root = pathlib.Path(os.path.abspath(root_text))
        try:
            path.relative_to(root)
        except ValueError:
            continue
        fail(f"extra artifact is under a release cleanup root: {root}")
    print(path)


def assert_directory(directory_text: str, expected: list[str]) -> None:
    directory = reject_symlink_components(pathlib.Path(directory_text))
    if not directory.is_dir():
        fail(f"release directory does not exist: {directory}")
    if len(expected) != len(set(expected)):
        fail("expected publication set contains duplicate basenames")
    for name in expected:
        conservative_name(name)

    actual: list[str] = []
    with os.scandir(directory) as entries:
        for entry in entries:
            conservative_name(entry.name)
            metadata = entry.stat(follow_symlinks=False)
            if not stat.S_ISREG(metadata.st_mode):
                fail(f"release directory contains a non-regular entry: {entry.name}")
            if metadata.st_nlink != 1:
                fail(f"release directory contains a multiply-linked file: {entry.name}")
            actual.append(entry.name)
    if sorted(actual) != sorted(expected):
        missing = sorted(set(expected) - set(actual))
        unexpected = sorted(set(actual) - set(expected))
        fail(
            "release directory differs from exact ledger; "
            f"missing={missing!r}, unexpected={unexpected!r}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    extra = subparsers.add_parser("check-extra")
    extra.add_argument("path")
    extra.add_argument("cleanup_root", nargs="+")

    name = subparsers.add_parser("check-name")
    name.add_argument("name")

    exact = subparsers.add_parser("assert-directory")
    exact.add_argument("directory")
    exact.add_argument("expected", nargs="+")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "check-extra":
        check_extra(arguments.path, arguments.cleanup_root)
    elif arguments.command == "check-name":
        conservative_name(arguments.name)
    else:
        assert_directory(arguments.directory, arguments.expected)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
