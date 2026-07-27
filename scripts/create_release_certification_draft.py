#!/usr/bin/env python3
"""Create an unsigned stable-release certification draft from five sealed gates."""

from __future__ import annotations

import argparse
import pathlib
import sys

from lib.release_evidence_drafts import (
    EvidenceDraftError,
    build_release_certification_draft,
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify five finalized and signed exact-commit typed gates, then "
            "create an unsigned RELEASE_CERTIFICATION.json draft. This command "
            "never signs or finalizes the draft."
        )
    )
    parser.add_argument(
        "--commit",
        required=True,
        help="exact lowercase 40-character candidate commit",
    )
    parser.add_argument(
        "--version",
        required=True,
        help="stable release version in vMAJOR.MINOR.PATCH form",
    )
    parser.add_argument(
        "--attested-by",
        required=True,
        help=(
            "one-line name of the person who reviewed all five retained gates; "
            "supplying it explicitly records the certification attestation"
        ),
    )
    parser.add_argument("--physical-touch", required=True, type=pathlib.Path)
    parser.add_argument(
        "--desktop-notification", required=True, type=pathlib.Path
    )
    parser.add_argument("--mpris-transport", required=True, type=pathlib.Path)
    parser.add_argument(
        "--native-deb-lifecycle", required=True, type=pathlib.Path
    )
    parser.add_argument(
        "--native-rpm-lifecycle", required=True, type=pathlib.Path
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository_root = pathlib.Path(__file__).resolve().parents[1]
    gates = {
        "physical_touch": arguments.physical_touch,
        "desktop_notification": arguments.desktop_notification,
        "mpris_transport": arguments.mpris_transport,
        "native_deb_lifecycle": arguments.native_deb_lifecycle,
        "native_rpm_lifecycle": arguments.native_rpm_lifecycle,
    }
    try:
        destination = build_release_certification_draft(
            repository_root=repository_root,
            expected_commit=arguments.commit,
            release_version=arguments.version,
            attested_by=arguments.attested_by,
            gate_paths=gates,
        )
    except EvidenceDraftError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Created unsigned release certification draft: {destination}")
    print("No signature or finalization was created.")
    print(
        "The named attester must inspect the draft and every referenced gate "
        "before separately finalizing it."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
