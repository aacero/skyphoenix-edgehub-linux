#!/usr/bin/env python3
"""Refuse release builds that can consume source bytes outside the Git index."""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys


SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".cmake",
    ".cpp",
    ".css",
    ".desktop",
    ".h",
    ".hh",
    ".hpp",
    ".html",
    ".ico",
    ".in",
    ".install",
    ".jpeg",
    ".jpg",
    ".js",
    ".json",
    ".mjs",
    ".otf",
    ".png",
    ".pub",
    ".py",
    ".qml",
    ".qrc",
    ".rs",
    ".service",
    ".sh",
    ".svg",
    ".txt",
    ".toml",
    ".ttf",
    ".webp",
    ".xml",
    ".yaml",
    ".yml",
}
SOURCE_NAMES = {
    "Cargo.lock",
    "Cargo.toml",
    "CMakeLists.txt",
    "Dockerfile",
    "Makefile",
    "PKGBUILD",
}
EXCLUDED_TOP_LEVEL = {
    ".claude",
    ".git",
    ".idea",
    ".vscode",
    "artifacts",
    "build",
    "build-appimage",
    "build-cov-agent",
    "build-dir",
    "build-install",
    "build-qa",
    "captures",
    "coverage",
    "dist",
    "gui-evidence",
    "html",
    "logs",
    "out",
    "packages",
    "repo",
    "secrets",
    "temp",
    "tmp",
}
EXCLUDED_ANY_LEVEL = {
    "__pycache__",
    "node_modules",
    "pkg",
    "target",
}
EXCLUDED_PATH_PREFIXES = {
    pathlib.PurePosixPath("docs/book"),
    pathlib.PurePosixPath("docs/node_modules"),
    pathlib.PurePosixPath("docs/site"),
    pathlib.PurePosixPath("packaging/aur/pkg"),
    pathlib.PurePosixPath("packaging/aur/src"),
    pathlib.PurePosixPath("packaging/local/pkg"),
    pathlib.PurePosixPath("packaging/local/src"),
    pathlib.PurePosixPath("packages"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify that every source-like release input in the checkout is "
            "tracked, including files hidden by ignore rules."
        )
    )
    parser.add_argument(
        "--repo",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
        help="Git worktree to inspect (default: repository containing this script)",
    )
    return parser.parse_args()


def git_output(repo: pathlib.Path, *arguments: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", os.fspath(repo), *arguments],
        stderr=subprocess.PIPE,
    )


def is_excluded(relative: pathlib.PurePosixPath) -> bool:
    parts = relative.parts
    if not parts:
        return False
    if parts[0] in EXCLUDED_TOP_LEVEL or parts[0].startswith("cmake-build-"):
        return True
    if any(
        relative == prefix or prefix in relative.parents
        for prefix in EXCLUDED_PATH_PREFIXES
    ):
        return True
    return any(part in EXCLUDED_ANY_LEVEL for part in parts[:-1])


def is_source_input(relative: pathlib.PurePosixPath) -> bool:
    name = relative.name
    if name in SOURCE_NAMES or name.startswith("LICENSE"):
        return True
    if relative.suffix.lower() in SOURCE_SUFFIXES:
        return True
    # Qt UIC output is intentionally ignored only at the repository root.
    # It is generated, not a release input. A same-named header below a source
    # directory remains covered by the .h rule above.
    return False


def source_candidates(repo: pathlib.Path) -> list[str]:
    candidates: list[str] = []
    for root, directories, files in os.walk(repo, followlinks=False):
        root_path = pathlib.Path(root)
        root_relative = root_path.relative_to(repo)
        if root_relative == pathlib.Path("."):
            directories[:] = [
                name
                for name in directories
                if name not in EXCLUDED_TOP_LEVEL
                and not name.startswith("cmake-build-")
            ]
        else:
            directories[:] = [
                name
                for name in directories
                if name not in EXCLUDED_ANY_LEVEL
                and not is_excluded(
                    pathlib.PurePosixPath(
                        (root_path / name).relative_to(repo).as_posix()
                    )
                    / ".directory"
                )
            ]
        for name in files:
            path = root_path / name
            relative = pathlib.PurePosixPath(path.relative_to(repo).as_posix())
            if is_excluded(relative):
                continue
            if len(relative.parts) == 1 and name.startswith("ui_") and name.endswith(".h"):
                continue
            if is_source_input(relative):
                candidates.append(relative.as_posix())
    return sorted(candidates)


def main() -> int:
    arguments = parse_args()
    repo = arguments.repo.resolve()
    try:
        top_level = pathlib.Path(
            git_output(repo, "rev-parse", "--show-toplevel").decode().strip()
        ).resolve()
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as error:
        print(f"FAIL: cannot resolve Git worktree: {error}", file=sys.stderr)
        return 2
    if top_level != repo:
        print(
            f"FAIL: --repo must name the Git worktree root: {repo} != {top_level}",
            file=sys.stderr,
        )
        return 2

    try:
        tracked = {
            item.decode("utf-8", "surrogateescape")
            for item in git_output(repo, "ls-files", "-z").split(b"\0")
            if item
        }
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: cannot read the Git index: {error}", file=sys.stderr)
        return 2

    candidates = source_candidates(repo)
    untracked = [path for path in candidates if path not in tracked]
    if untracked:
        print(
            "FAIL: source-like release inputs exist outside the Git index. "
            "Ignored files are not release provenance:",
            file=sys.stderr,
        )
        for path in untracked:
            ignored = (
                subprocess.run(
                    ["git", "-C", os.fspath(repo), "check-ignore", "-q", "--", path],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                ).returncode
                == 0
            )
            suffix = " (ignored)" if ignored else ""
            print(f"  {path}{suffix}", file=sys.stderr)
        return 1

    print(f"PASS: {len(candidates)} source-like release inputs are tracked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
