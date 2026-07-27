#!/usr/bin/env python3
"""Generate deterministic notices for Rust code linked into the native binaries."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
from collections import defaultdict

TARGET = "x86_64-unknown-linux-gnu"
NOTICE_PREFIXES = ("license", "copying", "notice", "unlicense")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cargo_metadata(manifest: pathlib.Path) -> dict:
    command = [
        "cargo",
        "metadata",
        "--locked",
        "--format-version",
        "1",
        "--filter-platform",
        TARGET,
        "--manifest-path",
        str(manifest),
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        fail("cargo metadata failed")
    return json.loads(result.stdout)


def runtime_package_ids(metadata: dict) -> set[str]:
    resolve = metadata.get("resolve")
    if not resolve or not resolve.get("root"):
        fail("Cargo metadata has no resolved root package")
    nodes = {node["id"]: node for node in resolve["nodes"]}
    root = resolve["root"]
    reached = {root}
    pending = [root]
    while pending:
        node = nodes[pending.pop()]
        for dependency in node.get("deps", []):
            kinds = dependency.get("dep_kinds", [])
            # Normal, build, and proc-macro dependencies can contribute code to
            # the shipped library. Development-only dependencies cannot.
            if not any(kind.get("kind") != "dev" for kind in kinds):
                continue
            package_id = dependency["pkg"]
            if package_id not in reached:
                reached.add(package_id)
                pending.append(package_id)
    reached.remove(root)
    return reached


def notice_files(package: dict) -> list[pathlib.Path]:
    root = pathlib.Path(package["manifest_path"]).resolve().parent
    candidates: set[pathlib.Path] = set()
    license_file = package.get("license_file")
    if license_file:
        candidates.add((root / license_file).resolve())
    for path in root.iterdir():
        if path.is_file() and path.name.lower().startswith(NOTICE_PREFIXES):
            candidates.add(path.resolve())
    files = sorted(candidates, key=lambda path: path.name.lower())
    if not files:
        fail(f"{package['name']} {package['version']} has no distributable notice file")
    for path in files:
        try:
            path.relative_to(root)
        except ValueError:
            fail(f"notice escapes crate source directory: {path}")
    return files


def generate(repo: pathlib.Path) -> str:
    manifest = repo / "core" / "Cargo.toml"
    lockfile = repo / "core" / "Cargo.lock"
    metadata = cargo_metadata(manifest)
    packages_by_id = {package["id"]: package for package in metadata["packages"]}
    packages = [
        packages_by_id[package_id]
        for package_id in runtime_package_ids(metadata)
    ]
    packages.sort(key=lambda package: (package["name"], package["version"], package["id"]))

    texts: dict[str, str] = {}
    text_names: dict[str, set[str]] = defaultdict(set)
    package_rows: list[tuple[dict, list[str]]] = []
    for package in packages:
        digests: list[str] = []
        for path in notice_files(package):
            data = path.read_bytes()
            try:
                decoded = data.decode("utf-8")
            except UnicodeDecodeError:
                fail(f"notice is not UTF-8 text: {package['name']}/{path.name}")
            digest = sha256(data)
            # Preserve the exact upstream byte hash while rendering a
            # repository-safe text copy. CRLF and trailing horizontal
            # whitespace have no legal meaning and otherwise make Git report
            # every imported line as a whitespace error.
            normalized = decoded.replace("\r\n", "\n").replace("\r", "\n")
            normalized = "\n".join(
                line.rstrip(" \t") for line in normalized.splitlines()
            )
            texts.setdefault(digest, normalized)
            text_names[digest].add(f"{package['name']} {package['version']}/{path.name}")
            digests.append(digest)
        package_rows.append((package, sorted(set(digests))))

    lines = [
        "EdgeHub Rust third-party notices",
        "================================",
        "",
        "This file inventories non-development Rust dependencies reachable from",
        f"core/Cargo.lock for target {TARGET}. These crates contribute to, or are",
        "linked into, the Hub and Manager through libxeneon_core.a.",
        "",
        f"Cargo.lock SHA-256: {sha256(lockfile.read_bytes())}",
        f"Package count: {len(package_rows)}",
        "Notice hashes identify the exact upstream bytes. Rendered copies",
        "normalize line endings and trailing horizontal whitespace only.",
        "",
        "Package inventory",
        "-----------------",
        "",
    ]
    for package, digests in package_rows:
        source_url = package.get("repository") or str(package.get("source") or "unknown")
        lines.extend(
            [
                f"{package['name']} {package['version']}",
                f"  SPDX expression: {package.get('license') or 'license-file'}",
                f"  Source: {source_url}",
                f"  Notice SHA-256: {', '.join(digests)}",
            ]
        )
        if "MPL-2.0" in (package.get("license") or ""):
            lines.extend(
                [
                    "  MPL-2.0 source code form:",
                    f"    https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download",
                    "  EdgeHub does not modify this crate. The exact upstream source",
                    "  remains available at the URL above.",
                ]
            )
        lines.append("")

    lines.extend(["Upstream notice texts", "---------------------", ""])
    for digest in sorted(texts):
        labels = sorted(text_names[digest])
        lines.extend(
            [
                f"SHA-256: {digest}",
                "Used by:",
                *[f"  - {label}" for label in labels],
                "",
                texts[digest].rstrip(),
                "",
                f"END NOTICE {digest}",
                "",
            ]
        )
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--check", type=pathlib.Path)
    args = parser.parse_args()
    if bool(args.output) == bool(args.check):
        parser.error("choose exactly one of --output or --check")
    repo = pathlib.Path(__file__).resolve().parent.parent
    rendered = generate(repo)
    destination = args.output or args.check
    assert destination is not None
    rendered_bytes = rendered.encode("utf-8")
    if args.check:
        if not destination.is_file():
            fail(f"notice bundle is missing: {destination}")
        # Some upstream notices deliberately use CRLF. Text-mode reads
        # normalize those bytes and would report an identical generated file as
        # stale, so freshness is a byte-for-byte comparison.
        if destination.read_bytes() != rendered_bytes:
            fail(f"notice bundle is stale: {destination}")
        print(f"Rust third-party notices are current: {destination}")
        return 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(rendered_bytes)
    print(f"Wrote Rust third-party notices: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
