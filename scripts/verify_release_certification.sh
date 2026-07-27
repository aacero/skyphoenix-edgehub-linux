#!/usr/bin/env bash
# Verify the signed exact-candidate receipt required before stable publication.
set -euo pipefail

readonly RELEASE_KEY="2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FINALIZER="$REPO_DIR/scripts/finalize_audit_artifacts.sh"
readonly CONTRACT="$REPO_DIR/scripts/lib/audit_artifact_contract.py"
readonly MANUAL_TOUCH_CONTRACT="$REPO_DIR/scripts/lib/manual_touch_result.py"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  scripts/verify_release_certification.sh \
    --commit FULL_SHA --version vMAJOR.MINOR.PATCH \
    [--print-native-package-hashes] ARTIFACT_RUN_DIR

ARTIFACT_RUN_DIR must be a finalized, signed
artifacts/<FULL_SHA>/release-certification-<UTC>-<pid>/ directory. Its receipt
must contain PASS evidence for physical touch, a real desktop notification, a
real MPRIS transport action, and separate DEB and RPM two-version lifecycles.
Each gate must reference its own finalized, signed typed audit directory.

The published AppImage zsync round trip is deliberately not accepted here. It
can only run after the exact candidate is publicly available as a prerelease and
is enforced by release.sh before that candidate is promoted to stable.
EOF
}

source_commit=""
release_version=""
artifact_dir=""
print_native_package_hashes=0
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
        --print-native-package-hashes)
            [ "$print_native_package_hashes" -eq 0 ] \
                || die "--print-native-package-hashes was supplied more than once"
            print_native_package_hashes=1
            shift
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

case "$source_commit" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "--commit must be a full lowercase 40-character SHA" ;;
esac
if [[ ! "$release_version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    die "--version must be stable vMAJOR.MINOR.PATCH with no leading zeroes"
fi
[ -n "$artifact_dir" ] || die "ARTIFACT_RUN_DIR is required"
[ -f "$FINALIZER" ] && [ ! -L "$FINALIZER" ] \
    || die "audit finalizer is unavailable or symlinked"
[ -f "$CONTRACT" ] && [ ! -L "$CONTRACT" ] \
    || die "audit record contract is unavailable or symlinked"
[ -f "$MANUAL_TOUCH_CONTRACT" ] && [ ! -L "$MANUAL_TOUCH_CONTRACT" ] \
    || die "manual touch contract is unavailable or symlinked"

case "$artifact_dir" in
    /*) ;;
    *) artifact_dir="$REPO_DIR/$artifact_dir" ;;
esac
[ -d "$artifact_dir" ] || die "release certification directory is unavailable"
run_id="${artifact_dir%/}"
run_id="${run_id##*/}"

bash "$FINALIZER" --verify --commit "$source_commit" "$artifact_dir" \
    >/dev/null \
    || die "release certification manifest or pinned signature is invalid"
python3 "$CONTRACT" release-certification \
    "$artifact_dir" "$source_commit" "$run_id" "$release_version" \
    || die "release certification receipt does not satisfy every publication gate"
references="$(python3 "$CONTRACT" release-certification-references \
    "$artifact_dir" "$source_commit" "$run_id" "$release_version")" \
    || die "release certification references could not be read"
[ -n "$references" ] || die "release certification contains no typed gate references"

for required_file in \
    RELEASE_CERTIFICATION.json MANIFEST.sha256 MANIFEST.sha256.asc \
    PROVENANCE.json; do
    [ -s "$artifact_dir/$required_file" ] && [ ! -L "$artifact_dir/$required_file" ] \
        || die "release certification record is unavailable: $required_file"
done

signature_status="$(gpg --status-fd 1 --verify \
    "$artifact_dir/MANIFEST.sha256.asc" \
    "$artifact_dir/MANIFEST.sha256" 2>/dev/null)" \
    || die "release certification signature cannot be re-read"
printf '%s\n' "$signature_status" | awk -v expected="$RELEASE_KEY" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
        for (i = 3; i <= NF; i++) {
            if (toupper($i) == expected) found = 1
        }
    }
    END { exit(found ? 0 : 1) }
' || die "release certification is not signed by the pinned release key"

verified_gate_count=0
native_deb_package_sha256=""
native_rpm_package_sha256=""
while IFS=$'\t' read -r gate_id artifact_path record_name record_sha256 \
        manifest_sha256 signature_sha256 provenance_sha256; do
    [ -n "$gate_id" ] && [ -n "$artifact_path" ] && [ -n "$record_name" ] \
        || die "release certification emitted an incomplete gate reference"
    gate_dir="$REPO_DIR/$artifact_path"
    [ -d "$gate_dir" ] \
        || die "referenced typed gate directory is unavailable: $artifact_path"
    bash "$FINALIZER" --verify --commit "$source_commit" "$gate_dir" \
        >/dev/null \
        || die "referenced typed gate is unsigned or invalid: $gate_id"
    for hash_entry in \
        "$record_name:$record_sha256" \
        "MANIFEST.sha256:$manifest_sha256" \
        "MANIFEST.sha256.asc:$signature_sha256" \
        "PROVENANCE.json:$provenance_sha256"; do
        hash_name="${hash_entry%%:*}"
        expected_hash="${hash_entry#*:}"
        [ -s "$gate_dir/$hash_name" ] && [ ! -L "$gate_dir/$hash_name" ] \
            || die "referenced typed gate file is unavailable: $gate_id/$hash_name"
        digest_line="$(sha256sum -- "$gate_dir/$hash_name")" \
            || die "could not hash referenced typed gate file: $gate_id/$hash_name"
        [ "${digest_line%% *}" = "$expected_hash" ] \
            || die "referenced typed gate hash changed: $gate_id/$hash_name"
    done
    gate_run_id="${gate_dir##*/}"
    case "$gate_id" in
        physical_touch)
            python3 "$MANUAL_TOUCH_CONTRACT" --release \
                "$source_commit" "$gate_dir" \
                || die "physical touch gate is not a signed six-action PASS"
            ;;
        desktop_notification)
            python3 "$CONTRACT" desktop-notification \
                "$gate_dir" "$source_commit" "$gate_run_id" \
                || die "desktop notification gate is not a typed real-desktop PASS"
            ;;
        mpris_transport)
            python3 "$CONTRACT" mpris-transport \
                "$gate_dir" "$source_commit" "$gate_run_id" \
                || die "MPRIS gate is not a typed real-transport PASS"
            ;;
        native_deb_lifecycle|native_rpm_lifecycle)
            python3 "$CONTRACT" native-lifecycle \
                "$gate_dir" "$source_commit" "$gate_run_id" \
                || die "native package lifecycle gate is not a typed PASS: $gate_id"
            candidate_package_sha256="$(python3 - \
                "$gate_dir/NATIVE_PACKAGE_LIFECYCLE.json" "$gate_id" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_kind = {
    "native_deb_lifecycle": "deb",
    "native_rpm_lifecycle": "rpm",
}[sys.argv[2]]
if record["package_kind"] != expected_kind:
    raise SystemExit("native lifecycle kind differs from its gate")
print(record["candidate_package_sha256"])
PY
            )" || die "could not read the certified native package hash: $gate_id"
            if [[ ! "$candidate_package_sha256" =~ ^[0-9a-f]{64}$ ]]; then
                die "certified native package hash is invalid: $gate_id"
            fi
            case "$gate_id" in
                native_deb_lifecycle)
                    [ -z "$native_deb_package_sha256" ] \
                        || die "release certification contains duplicate DEB lifecycle evidence"
                    native_deb_package_sha256="$candidate_package_sha256"
                    ;;
                native_rpm_lifecycle)
                    [ -z "$native_rpm_package_sha256" ] \
                        || die "release certification contains duplicate RPM lifecycle evidence"
                    native_rpm_package_sha256="$candidate_package_sha256"
                    ;;
            esac
            ;;
        *)
            die "release certification contains an unknown gate: $gate_id"
            ;;
    esac
    verified_gate_count=$((verified_gate_count + 1))
done <<<"$references"
[ "$verified_gate_count" -eq 5 ] \
    || die "release certification did not verify exactly five typed gate receipts"
[ -n "$native_deb_package_sha256" ] && [ -n "$native_rpm_package_sha256" ] \
    || die "release certification did not yield both native package hashes"

if [ "$print_native_package_hashes" -eq 1 ]; then
    printf 'deb\t%s\nrpm\t%s\n' \
        "$native_deb_package_sha256" "$native_rpm_package_sha256"
else
    printf 'Verified stable release certification for %s at %s\n' \
        "$source_commit" "$artifact_dir"
fi
