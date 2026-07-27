#!/usr/bin/env python3
"""Import one verified DEB or RPM lifecycle CI artifact as an unsigned draft."""

from __future__ import annotations

import argparse
import pathlib
import sys

from lib.release_evidence_drafts import (
    EvidenceDraftError,
    import_native_lifecycle,
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify a downloaded native-upgrade-rollback CI artifact, retain "
            "its package bytes and GitHub provenance, and create an unsigned "
            "typed lifecycle draft. This command never signs or finalizes."
        )
    )
    parser.add_argument(
        "--kind",
        required=True,
        choices=("deb", "rpm"),
        help="native package kind represented by the downloaded artifact",
    )
    parser.add_argument(
        "--commit",
        required=True,
        help="exact lowercase 40-character candidate commit",
    )
    parser.add_argument(
        "--baseline-ref",
        required=True,
        help=(
            "owner-selected prior supported release tag or exact lowercase "
            "commit used as the workflow baseline"
        ),
    )
    parser.add_argument(
        "--workflow-url",
        required=True,
        help=(
            "canonical successful GitHub Actions run URL that produced the "
            "download"
        ),
    )
    parser.add_argument(
        "artifact_dir",
        type=pathlib.Path,
        help=(
            "download directory containing native-upgrade-rollback-KIND.txt "
            "and both package artifacts"
        ),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository_root = pathlib.Path(__file__).resolve().parents[1]
    try:
        destination = import_native_lifecycle(
            repository_root=repository_root,
            downloaded_artifact=arguments.artifact_dir,
            kind=arguments.kind,
            expected_commit=arguments.commit,
            expected_baseline_ref=arguments.baseline_ref,
            workflow_url=arguments.workflow_url,
        )
    except EvidenceDraftError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Created unsigned native lifecycle draft: {destination}")
    print("No signature, owner attestation, or finalization was created.")
    print(
        "Review the retained report, packages, workflow result, and "
        "attestation verification before separately finalizing it."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
