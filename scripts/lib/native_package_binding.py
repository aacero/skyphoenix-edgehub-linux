#!/usr/bin/env python3
"""Bind stable release DEB/RPM bytes to their signed lifecycle receipts."""

from __future__ import annotations

import argparse
import re
import sys

SHA256_RE = re.compile(r"[0-9a-f]{64}")


class BindingError(ValueError):
    """The native release artifact set is not the certified byte set."""


def _sha256(value: str, label: str) -> str:
    if not SHA256_RE.fullmatch(value):
        raise BindingError(f"{label} is not a lowercase SHA-256 digest")
    return value


def validate_binding(
    certified: dict[str, str], extras: list[tuple[str, str, str]]
) -> None:
    expected_kinds = {"deb", "rpm"}
    if set(certified) != expected_kinds:
        raise BindingError("certification must provide exactly DEB and RPM hashes")
    for kind, digest in certified.items():
        _sha256(digest, f"certified {kind} hash")

    observed: dict[str, tuple[str, str]] = {}
    for kind, digest, name in extras:
        if kind not in expected_kinds:
            raise BindingError(f"unsupported native package kind: {kind}")
        if kind in observed:
            raise BindingError(f"stable release has more than one {kind.upper()} extra")
        if not name or "/" in name or "\x00" in name:
            raise BindingError(f"{kind.upper()} extra has an invalid basename")
        observed[kind] = (_sha256(digest, f"{kind.upper()} extra hash"), name)

    missing = sorted(expected_kinds - set(observed))
    if missing:
        labels = ", ".join(kind.upper() for kind in missing)
        raise BindingError(f"stable release is missing certified native extra: {labels}")

    for kind in sorted(expected_kinds):
        digest, name = observed[kind]
        if digest != certified[kind]:
            raise BindingError(
                f"{kind.upper()} extra {name} is not the exact package bytes "
                "named by its signed lifecycle receipt"
            )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certified-deb", required=True)
    parser.add_argument("--certified-rpm", required=True)
    parser.add_argument(
        "--extra",
        nargs=3,
        action="append",
        default=[],
        metavar=("KIND", "SHA256", "BASENAME"),
    )
    args = parser.parse_args(argv)
    try:
        validate_binding(
            {"deb": args.certified_deb, "rpm": args.certified_rpm},
            [tuple(extra) for extra in args.extra],
        )
    except BindingError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
