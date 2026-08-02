#!/usr/bin/env python3
"""Generate the self-contained Debian machine-readable copyright record."""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_notice_module(repo: pathlib.Path):
    source = repo / "scripts" / "generate_rust_third_party_notices.py"
    spec = importlib.util.spec_from_file_location("rust_notices", source)
    if spec is None or spec.loader is None:
        fail(f"cannot load {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def exact_package(packages: list[dict], name: str) -> dict:
    matches = [package for package in packages if package["name"] == name]
    if len(matches) != 1:
        fail(f"expected exactly one reachable Rust package named {name}")
    return matches[0]


def exact_notice(module, package: dict, filename: str) -> str:
    matches = [
        path
        for path in module.notice_files(package)
        if path.name == filename
    ]
    if len(matches) != 1:
        fail(
            f"expected {package['name']} {package['version']} to contain "
            f"exactly one {filename}"
        )
    return matches[0].read_text(encoding="utf-8")


def dep5_body(text: str) -> str:
    lines = []
    for line in text.replace("\r\n", "\n").strip().splitlines():
        lines.append(" ." if not line else f" {line.rstrip()}")
    return "\n".join(lines)


def generate(repo: pathlib.Path) -> str:
    module = load_notice_module(repo)
    metadata = module.cargo_metadata(repo / "core" / "Cargo.toml")
    packages_by_id = {
        package["id"]: package for package in metadata["packages"]
    }
    packages = [
        packages_by_id[package_id]
        for package_id in module.runtime_package_ids(metadata)
    ]

    license_texts = [
        ("Expat", (repo / "LICENSE-MIT").read_text(encoding="utf-8")),
        ("Apache-2.0", (repo / "LICENSE-APACHE").read_text(encoding="utf-8")),
        (
            "OFL-1.1",
            (
                repo
                / "assets"
                / "fonts"
                / "LICENSE-OFL-AtkinsonHyperlegible.txt"
            ).read_text(encoding="utf-8"),
        ),
        (
            "BSD-3-Clause",
            exact_notice(
                module,
                exact_package(packages, "curve25519-dalek"),
                "LICENSE",
            ),
        ),
        (
            "Unicode-3.0",
            exact_notice(
                module,
                exact_package(packages, "unicode-ident"),
                "LICENSE-UNICODE",
            ),
        ),
        (
            "MPL-2.0",
            exact_notice(
                module,
                exact_package(packages, "option-ext"),
                "LICENSE.txt",
            ),
        ),
        (
            "Unlicense",
            exact_notice(
                module,
                exact_package(packages, "aho-corasick"),
                "UNLICENSE",
            ),
        ),
    ]

    header = """Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: EdgeHub
Upstream-Contact: Simon Kreitmayer <simon.kreitmayer@skyphoenix-it.com>
Source: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux
Disclaimer:
 Corsair and Xeneon Edge are trademarks of their respective owner.
 EdgeHub is an independent product and is not affiliated with, endorsed by,
 or supported by Corsair.
Comment:
 The Rust build and linked component use dependencies under Expat, Apache-2.0,
 BSD-3-Clause, Unicode-3.0, MPL-2.0 and optional Unlicense terms.
 The exact lockfile-derived package inventory, copyright notices, licence
 texts and MPL source availability are installed as
 /usr/share/licenses/xeneon-edge-hub/THIRD_PARTY_NOTICES-RUST.txt.

Files: *
Copyright: 2026 SKYPhoenix IT and EdgeHub contributors
License: Expat or Apache-2.0

Files: assets/icons/*
Copyright: 2023 Phosphor Icons
License: Expat

Files: assets/fonts/AtkinsonHyperlegible-*.ttf
Copyright: 2020 Braille Institute of America, Inc.
License: OFL-1.1

Files: assets/fonts/ChakraPetch-*.ttf
Copyright: 2018 The Chakra Petch Project Authors
License: OFL-1.1

Files: assets/fonts/JetBrainsMono-*.ttf
Copyright: 2020 The JetBrains Mono Project Authors
License: OFL-1.1

Files: assets/fonts/Lexend-*.ttf
Copyright: 2018 The Lexend Project Authors
License: OFL-1.1
"""
    stanzas = [
        f"License: {identifier}\n{dep5_body(text)}"
        for identifier, text in license_texts
    ]
    return header.rstrip() + "\n\n" + "\n\n".join(stanzas) + "\n"


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
    destination = destination.resolve()
    if args.check:
        if not destination.is_file():
            fail(f"missing generated file: {destination}")
        if destination.read_text(encoding="utf-8") != rendered:
            fail(f"generated file is stale: {destination}")
        print(f"OK: {destination} is current")
        return 0

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(rendered, encoding="utf-8")
    print(f"Wrote {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
