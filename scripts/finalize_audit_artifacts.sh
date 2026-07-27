#!/usr/bin/env bash
# Finalize or verify signed audit evidence for one exact source commit.
set -euo pipefail

# The helpers are release verifiers, not build inputs. Never let Python create
# an ignored __pycache__ that dirties the source tree during finalization.
export PYTHONDONTWRITEBYTECODE=1

readonly MANIFEST_NAME="MANIFEST.sha256"
readonly SIGNATURE_NAME="MANIFEST.sha256.asc"
readonly PROVENANCE_NAME="PROVENANCE.json"
readonly LOCK_NAME=".audit-finalization.lock"
readonly RELEASE_KEY="2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
readonly CANONICAL_SOURCE_HOST="github.com"
readonly CANONICAL_SOURCE_REPOSITORY="skyphoenix-it/skyphoenix-edgehub-linux"

usage() {
    cat <<'EOF'
Usage:
  scripts/finalize_audit_artifacts.sh ARTIFACT_RUN_DIR
  scripts/finalize_audit_artifacts.sh --verify [--commit FULL_SHA] ARTIFACT_RUN_DIR

ARTIFACT_RUN_DIR must be artifacts/<full-40-character-sha>/<run-id>, or the
full-SHA directory itself. Finalization requires that SHA to be clean HEAD.
Historical verification accepts --commit and is independent of current HEAD.

Finalization refuses open writers, unsafe names, symlink path components,
special files, mutable permissions, and stale temporary files. It writes
PROVENANCE.json, a stable SHA-256 manifest, and an interactive detached
signature made by the pinned release key. Existing seals are never replaced.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

mode="finalize"
artifact_argument=""
requested_commit=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --verify)
            [ "$mode" = "finalize" ] || die "--verify was supplied more than once"
            mode="verify"
            ;;
        --commit)
            [ "$#" -ge 2 ] || die "--commit requires a full SHA"
            [ -z "$requested_commit" ] || die "--commit was supplied more than once"
            requested_commit="$2"
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
            [ -z "$artifact_argument" ] || die "only one ARTIFACT_RUN_DIR may be supplied"
            artifact_argument="$1"
            ;;
    esac
    shift
done
[ -n "$artifact_argument" ] || die "ARTIFACT_RUN_DIR is required"
[ "$mode" = "verify" ] || [ -z "$requested_commit" ] \
    || die "--commit is valid only with --verify"

for required_tool in \
    awk cat chmod dirname git gpg ln mkdir mktemp python3 realpath rm rmdir \
    sha256sum wc; do
    command -v "$required_tool" >/dev/null 2>&1 \
        || die "required tool is unavailable: $required_tool"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest_tool="$script_dir/lib/audit_artifact_manifest.py"
[ -f "$manifest_tool" ] \
    || die "manifest helper is unavailable: $manifest_tool"
record_contract_tool="$script_dir/lib/audit_artifact_contract.py"
[ -f "$record_contract_tool" ] \
    || die "audit record contract helper is unavailable: $record_contract_tool"
manual_touch_contract_tool="$script_dir/lib/manual_touch_result.py"
[ -f "$manual_touch_contract_tool" ] \
    || die "manual touch contract helper is unavailable: $manual_touch_contract_tool"
origin_policy="$script_dir/lib/release_origin.sh"
[ -f "$origin_policy" ] \
    || die "release origin policy is unavailable: $origin_policy"
# shellcheck source=lib/release_origin.sh
. "$origin_policy"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "the finalizer is not inside a Git worktree"
repo_root="$(realpath -e -- "$repo_root")"

head_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || die "HEAD does not resolve to a commit"
if [ -n "$requested_commit" ]; then
    case "$requested_commit" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) die "--commit must be a full lowercase 40-character SHA" ;;
    esac
    source_commit="$(git -C "$repo_root" rev-parse --verify "${requested_commit}^{commit}")" \
        || die "requested historical commit is unavailable: $requested_commit"
    [ "$source_commit" = "$requested_commit" ] \
        || die "requested historical object is not the exact commit $requested_commit"
else
    source_commit="$head_commit"
fi

if [ "$mode" = "finalize" ]; then
    [ "$source_commit" = "$head_commit" ] \
        || die "finalization is allowed only for current HEAD"
    git_state="$(git -C "$repo_root" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none)"
    [ -z "$git_state" ] || {
        printf '%s\n' "$git_state" >&2
        die "working tree is not clean; commit or remove every change before finalizing evidence"
    }
fi

case "$artifact_argument" in
    /*) requested_dir="$artifact_argument" ;;
    *) requested_dir="$repo_root/$artifact_argument" ;;
esac

# realpath would silently hide symlink path components. Refuse them first,
# including a symlinked artifacts/ root or run directory.
python3 - "$repo_root" "$requested_dir" <<'PY' \
    || die "artifact path is outside the repository or contains a symlink component"
import os
import pathlib
import stat
import sys

root = pathlib.Path(os.path.abspath(sys.argv[1]))
target = pathlib.Path(os.path.abspath(sys.argv[2]))
try:
    target.relative_to(root)
except ValueError:
    raise SystemExit(1)
current = pathlib.Path(target.anchor)
for component in target.parts[1:]:
    current /= component
    metadata = os.lstat(current)
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
PY

[ -d "$requested_dir" ] || die "artifact directory does not exist: $requested_dir"
artifact_dir="$(realpath -e -- "$requested_dir")"
commit_root="$repo_root/artifacts/$source_commit"
case "$artifact_dir" in
    "$commit_root"|"$commit_root"/*) ;;
    *) die "artifact directory must be keyed by full commit $source_commit under $commit_root" ;;
esac
artifact_relative="${artifact_dir#"$repo_root"/}"
artifact_run_id="${artifact_dir##*/}"

manifest_path="$artifact_dir/$MANIFEST_NAME"
signature_path="$artifact_dir/$SIGNATURE_NAME"
provenance_path="$artifact_dir/$PROVENANCE_NAME"
lock_path="$artifact_dir/$LOCK_NAME"
temporary_manifest=""
temporary_signature=""
temporary_provenance=""
created_provenance=0

cleanup() {
    status=$?
    for temporary in \
        "$temporary_manifest" "$temporary_signature" "$temporary_provenance"; do
        if [ -n "$temporary" ] && [ -e "$temporary" ]; then
            rm -f -- "$temporary"
        fi
    done
    if [ "$created_provenance" -eq 1 ] && [ ! -e "$manifest_path" ]; then
        rm -f -- "$provenance_path"
    fi
    if [ -d "$lock_path" ]; then
        rmdir -- "$lock_path" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

mkdir -m 0700 -- "$lock_path" 2>/dev/null \
    || die "artifact directory is already being finalized or has a stale lock: $lock_path"

assert_repository_unchanged() {
    local current_head current_state
    [ "$mode" = "finalize" ] || return 0
    current_head="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
    [ "$current_head" = "$source_commit" ] \
        || die "HEAD changed during artifact finalization"
    current_state="$(git -C "$repo_root" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none)"
    [ -z "$current_state" ] \
        || die "working tree changed during artifact finalization"
}

sync_directory() {
    python3 - "$1" <<'PY'
import os
import sys

flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_CLOEXEC
descriptor = os.open(sys.argv[1], flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

verify_pinned_signature() {
    local status
    status="$(gpg --status-fd 1 --verify \
        "$signature_path" "$manifest_path" 2>/dev/null)" \
        || die "audit manifest signature is invalid"
    printf '%s\n' "$status" | awk -v expected="$RELEASE_KEY" '
        $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
            for (i = 3; i <= NF; i++) {
                if (toupper($i) == expected) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' || die "audit manifest was not signed by pinned key $RELEASE_KEY"
}

validate_canonical_origin() {
    local fetch_url push_url
    [ "$mode" = "finalize" ] || return 0
    fetch_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null)" \
        || die "origin fetch URL is unavailable"
    push_url="$(git -C "$repo_root" remote get-url --push origin 2>/dev/null)" \
        || die "origin push URL is unavailable"
    _xeneon_url_matches_github_repo \
        "$fetch_url" "$CANONICAL_SOURCE_REPOSITORY" \
        || die "origin fetch URL does not match the canonical GitHub repository"
    _xeneon_url_matches_github_repo \
        "$push_url" "$CANONICAL_SOURCE_REPOSITORY" \
        || die "origin push URL does not match the canonical GitHub repository"
}

validate_release_records() {
    case "$artifact_relative" in
        "artifacts/$source_commit/manual-touch/"*)
            python3 "$manual_touch_contract_tool" --release \
                "$source_commit" "$artifact_dir" \
                || die "manual physical-touch records are incomplete or inconsistent"
            return
            ;;
    esac
    case "$artifact_run_id" in
        release-gate-*)
            python3 "$record_contract_tool" release-run \
                "$artifact_dir" "$source_commit" "$artifact_run_id" \
                || die "release-gate records are incomplete or inconsistent"
            ;;
        release-certification-*)
            python3 "$record_contract_tool" release-certification \
                "$artifact_dir" "$source_commit" "$artifact_run_id" \
                || die "release-certification receipt is incomplete or inconsistent"
            ;;
        desktop-notification-*)
            python3 "$record_contract_tool" desktop-notification \
                "$artifact_dir" "$source_commit" "$artifact_run_id" \
                || die "desktop-notification receipt is incomplete or inconsistent"
            ;;
        mpris-transport-*)
            python3 "$record_contract_tool" mpris-transport \
                "$artifact_dir" "$source_commit" "$artifact_run_id" \
                || die "MPRIS transport receipt is incomplete or inconsistent"
            ;;
        native-package-lifecycle-deb-*|native-package-lifecycle-rpm-*)
            python3 "$record_contract_tool" native-lifecycle \
                "$artifact_dir" "$source_commit" "$artifact_run_id" \
                || die "native package lifecycle receipt is incomplete or inconsistent"
            ;;
        appimage-zsync-*)
            python3 "$record_contract_tool" appimage-zsync \
                "$artifact_dir" "$source_commit" "$artifact_run_id" \
                || die "AppImage zsync receipt is incomplete or inconsistent"
            ;;
    esac
}

verify_provenance() {
    python3 "$record_contract_tool" provenance \
        "$provenance_path" "$source_commit" "$artifact_relative" "$RELEASE_KEY" \
        || die "audit provenance is invalid"
}

verify_seal() {
    validate_release_records
    verify_provenance
    python3 "$manifest_tool" verify "$artifact_dir"
    verify_pinned_signature
    assert_repository_unchanged
}

if [ "$mode" = "verify" ]; then
    verify_seal
    count="$(wc -l < "$manifest_path")"
    printf 'Verified %s evidence files for commit %s\n' "$count" "$source_commit"
    printf 'Manifest: %s\n' "$manifest_path"
    printf 'Signature: %s\n' "$signature_path"
    exit 0
fi

[ ! -e "$manifest_path" ] && [ ! -e "$signature_path" ] \
    || die "manifest or signature already exists and will not be replaced; use --verify"
[ ! -e "$provenance_path" ] \
    || die "PROVENANCE.json already exists and will not be replaced"
gpg --list-secret-keys "$RELEASE_KEY" >/dev/null 2>&1 \
    || die "pinned audit signing key is unavailable: $RELEASE_KEY"
validate_canonical_origin
validate_release_records

temporary_provenance="$(mktemp "$artifact_dir/.audit-provenance.tmp.XXXXXX")"
chmod 0600 "$temporary_provenance"
finalizer_digest_line="$(sha256sum -- "$0")"
python3 - "$temporary_provenance" "$source_commit" "$artifact_relative" \
    "$CANONICAL_SOURCE_HOST" "$CANONICAL_SOURCE_REPOSITORY" \
    "$RELEASE_KEY" "${finalizer_digest_line%% *}" <<'PY'
import datetime
import json
import os
import sys

(
    output,
    commit,
    artifact_path,
    source_host,
    source_repository,
    key,
    finalizer_digest,
) = sys.argv[1:]
document = {
    "schema": "skyphoenix-edgehub-audit-provenance/v2",
    "source_commit": commit,
    "artifact_path": artifact_path,
    "source": {
        "host": source_host,
        "repository": source_repository,
    },
    "manifest_algorithm": "SHA-256",
    "manifest_signing_key_fingerprint": key,
    "finalizer_sha256": finalizer_digest,
    "finalized_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
}
descriptor = os.open(output, os.O_WRONLY | os.O_TRUNC | os.O_CLOEXEC)
try:
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("short write while publishing PROVENANCE.json")
        remaining = remaining[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
ln -- "$temporary_provenance" "$provenance_path" \
    || die "PROVENANCE.json appeared concurrently"
rm -f -- "$temporary_provenance"
temporary_provenance=""
created_provenance=1
sync_directory "$artifact_dir"

temporary_manifest="$(mktemp "$artifact_dir/.audit-manifest.tmp.XXXXXX")"
python3 "$manifest_tool" generate "$artifact_dir" "$temporary_manifest"
assert_repository_unchanged

temporary_signature="$(mktemp "$artifact_dir/.audit-signature.tmp.XXXXXX")"
rm -f -- "$temporary_signature"
printf '\nSigning audit evidence for commit %s.\n' "$source_commit"
gpg --local-user "$RELEASE_KEY" --armor --detach-sign \
    --output "$temporary_signature" "$temporary_manifest" \
    || die "audit manifest signing failed"
chmod 0600 "$temporary_signature"

ln -- "$temporary_manifest" "$manifest_path" \
    || die "manifest appeared concurrently and was not replaced"
if ! ln -- "$temporary_signature" "$signature_path"; then
    rm -f -- "$manifest_path"
    die "manifest signature appeared concurrently and was not replaced"
fi
rm -f -- "$temporary_manifest" "$temporary_signature"
temporary_manifest=""
temporary_signature=""
sync_directory "$artifact_dir"

verify_seal
count="$(wc -l < "$manifest_path")"
printf 'Finalized %s evidence files for commit %s\n' "$count" "$source_commit"
printf 'Manifest: %s\n' "$manifest_path"
printf 'Signature: %s\n' "$signature_path"
