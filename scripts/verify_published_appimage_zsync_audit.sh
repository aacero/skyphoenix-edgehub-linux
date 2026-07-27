#!/usr/bin/env bash
# Verify the signed post-publication AppImage zsync round-trip receipt.
set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FINALIZER="$REPO_DIR/scripts/finalize_audit_artifacts.sh"
readonly CONTRACT="$REPO_DIR/scripts/lib/audit_artifact_contract.py"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  scripts/verify_published_appimage_zsync_audit.sh \
    --commit FULL_SHA --version vMAJOR.MINOR.PATCH ARTIFACT_RUN_DIR
EOF
}

source_commit=""
release_version=""
artifact_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --commit)
            [ "$#" -ge 2 ] || die "--commit requires a full SHA"
            [ -z "$source_commit" ] || die "--commit was supplied more than once"
            source_commit="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || die "--version requires vMAJOR.MINOR.PATCH"
            [ -z "$release_version" ] || die "--version was supplied more than once"
            release_version="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            [ -z "$artifact_dir" ] \
                || die "only one ARTIFACT_RUN_DIR may be supplied"
            artifact_dir="$1"
            shift
            ;;
    esac
done

[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] \
    || die "--commit must be a full lowercase 40-character SHA"
[[ "$release_version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "--version must be stable vMAJOR.MINOR.PATCH"
[ -n "$artifact_dir" ] || die "ARTIFACT_RUN_DIR is required"

case "$artifact_dir" in
    /*) ;;
    *) artifact_dir="$REPO_DIR/$artifact_dir" ;;
esac
[ -d "$artifact_dir" ] || die "AppImage zsync audit directory is unavailable"
run_id="${artifact_dir%/}"
run_id="${run_id##*/}"

bash "$FINALIZER" --verify --commit "$source_commit" "$artifact_dir" \
    || die "AppImage zsync audit manifest or pinned signature is invalid"
python3 "$CONTRACT" appimage-zsync \
    "$artifact_dir" "$source_commit" "$run_id" "$release_version" \
    || die "AppImage zsync audit does not prove the exact public round trip"

printf 'Verified published AppImage zsync round trip for %s at %s\n' \
    "$source_commit" "$artifact_dir"
