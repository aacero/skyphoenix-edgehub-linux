#!/usr/bin/env bash
# Promote an already staged, externally certified candidate by metadata only.
set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RELEASE_REPO="skyphoenix-it/skyphoenix-edgehub-linux"
readonly RELEASE_KEY="2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
readonly CERTIFICATION_VERIFIER="$REPO_DIR/scripts/verify_release_certification.sh"
readonly ZSYNC_VERIFIER="$REPO_DIR/scripts/verify_published_appimage_zsync_audit.sh"
readonly PATH_TOOL="$REPO_DIR/scripts/lib/release_paths.py"
readonly IMMUTABLE_RELEASE_POLICY="$REPO_DIR/scripts/lib/github_immutable_releases.sh"

# shellcheck source=lib/release_origin.sh
. "$REPO_DIR/scripts/lib/release_origin.sh"
# shellcheck source=lib/release_sequence.sh
. "$REPO_DIR/scripts/lib/release_sequence.sh"
# shellcheck source=lib/github_immutable_releases.sh
. "$IMMUTABLE_RELEASE_POLICY"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  scripts/promote_stable_release.sh \
    --version vMAJOR.MINOR.PATCH \
    --certification artifacts/<sha>/release-certification-<UTC>-<pid> \
    --zsync-certification artifacts/<sha>/appimage-zsync-<UTC>-<pid>

This command does not build, test, sign release payloads, upload, replace, or
delete assets. It re-verifies the staged public prerelease and both signed
receipts, changes release metadata to stable/latest, then re-verifies it.
EOF
}

version=""
certification_dir=""
zsync_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || die "--version requires a value"
            [ -z "$version" ] || die "--version was supplied more than once"
            version="$2"
            shift 2
            ;;
        --certification)
            [ "$#" -ge 2 ] || die "--certification requires a directory"
            [ -z "$certification_dir" ] \
                || die "--certification was supplied more than once"
            certification_dir="$2"
            shift 2
            ;;
        --zsync-certification)
            [ "$#" -ge 2 ] || die "--zsync-certification requires a directory"
            [ -z "$zsync_dir" ] \
                || die "--zsync-certification was supplied more than once"
            zsync_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "--version must be stable vMAJOR.MINOR.PATCH"
[ -n "$certification_dir" ] || die "--certification is required"
[ -n "$zsync_dir" ] || die "--zsync-certification is required"
for tool in \
    awk find gh git gpg mkdir python3 realpath rm sha256sum stat timeout; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "required tool is unavailable: $tool"
done

head_commit="$(git -C "$REPO_DIR" rev-parse --verify 'HEAD^{commit}')" \
    || die "HEAD does not resolve to a commit"
worktree_status="$(git -C "$REPO_DIR" status --porcelain=v1 \
    --untracked-files=all --ignore-submodules=none)"
[ -z "$worktree_status" ] || {
    printf '%s\n' "$worktree_status" >&2
    die "working tree must be clean before stable promotion"
}
xeneon_origin_matches_github_repo "$REPO_DIR" "$RELEASE_REPO" \
    || die "origin is not the canonical GitHub repository"
tag_object="$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/$version")" \
    || die "stable tag is unavailable"
[ "$(git -C "$REPO_DIR" cat-file -t "$tag_object")" = "tag" ] \
    || die "stable tag is not annotated"
[ "$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/$version^{commit}")" = "$head_commit" ] \
    || die "stable tag does not name exact HEAD"
tag_status="$(git -C "$REPO_DIR" verify-tag --raw "$version" 2>&1)" \
    || die "stable tag signature is invalid"
printf '%s\n' "$tag_status" \
    | xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY" \
    || die "stable tag is not signed by the pinned release key"
xeneon_verify_origin_tag_exact \
    "$REPO_DIR" "$version" "$head_commit" "$tag_object" \
    || die "origin tag differs from the exact signed local tag"

resolve_receipt_dir() {
    local value="$1"
    case "$value" in
        /*) ;;
        *) value="$REPO_DIR/$value" ;;
    esac
    realpath -e -- "$value"
}
certification_dir="$(resolve_receipt_dir "$certification_dir")" \
    || die "prepublication certification directory is unavailable"
zsync_dir="$(resolve_receipt_dir "$zsync_dir")" \
    || die "zsync certification directory is unavailable"
case "$certification_dir" in
    "$REPO_DIR/artifacts/$head_commit"/release-certification-*) ;;
    *) die "prepublication certification is not keyed by exact HEAD" ;;
esac
case "$zsync_dir" in
    "$REPO_DIR/artifacts/$head_commit"/appimage-zsync-*) ;;
    *) die "zsync certification is not keyed by exact HEAD" ;;
esac
bash "$CERTIFICATION_VERIFIER" \
    --commit "$head_commit" --version "$version" "$certification_dir" \
    || die "prepublication signed certification no longer verifies"
bash "$ZSYNC_VERIFIER" \
    --commit "$head_commit" --version "$version" "$zsync_dir" \
    || die "post-publication signed zsync certification does not verify"

certification_receipt_hash="$(sha256sum -- "$certification_dir/RELEASE_CERTIFICATION.json")"
certification_receipt_hash="${certification_receipt_hash%% *}"
certification_manifest_hash="$(sha256sum -- "$certification_dir/MANIFEST.sha256")"
certification_manifest_hash="${certification_manifest_hash%% *}"
certification_signature_hash="$(sha256sum -- "$certification_dir/MANIFEST.sha256.asc")"
certification_signature_hash="${certification_signature_hash%% *}"
certification_provenance_hash="$(sha256sum -- "$certification_dir/PROVENANCE.json")"
certification_provenance_hash="${certification_provenance_hash%% *}"
certification_artifact_path="${certification_dir#"$REPO_DIR"/}"

verify_root="$(mktemp -d "${TMPDIR:-/tmp}/edgehub-stable-promotion.XXXXXX")"
cleanup() {
    rm -rf -- "$verify_root"
}
trap cleanup EXIT HUP INT TERM

remote_json="$verify_root/staged-release.json"
xeneon_require_mutable_release_metadata "$RELEASE_REPO" \
    || die "same-release stable promotion is unavailable under the current GitHub immutable-release policy"
gh release view "$version" --repo "$RELEASE_REPO" \
    --json assets,body,databaseId,isDraft,isPrerelease,name,tagName \
    >"$remote_json" \
    || die "staged candidate metadata is unavailable"

python3 - "$remote_json" "$zsync_dir/APPIMAGE_ZSYNC.json" \
    "$version" "$head_commit" "$tag_object" <<'PY' \
    || die "staged candidate differs from the signed zsync receipt"
import hashlib
import json
import pathlib
import sys

remote = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
receipt = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
ledger = sorted(
    [
        {
            "id": asset.get("id"),
            "name": asset.get("name"),
            "size": asset.get("size"),
            "url": asset.get("url"),
        }
        for asset in remote.get("assets", [])
    ],
    key=lambda item: item["name"],
)
ledger_hash = hashlib.sha256(
    json.dumps(ledger, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if (
    remote.get("tagName") != sys.argv[3]
    or remote.get("name") != f"EdgeHub {sys.argv[3]} certification candidate"
    or remote.get("isDraft") is not False
    or remote.get("isPrerelease") is not True
    or remote.get("databaseId") != receipt.get("candidate_release_id")
    or receipt.get("source_commit") != sys.argv[4]
    or receipt.get("tag_object") != sys.argv[5]
    or ledger_hash != receipt.get("candidate_asset_ledger_sha256")
):
    raise SystemExit(1)
PY
release_id="$(python3 - "$remote_json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get(
    "databaseId"
)
if not isinstance(value, int) or value <= 0:
    raise SystemExit(1)
print(value)
PY
)" || die "staged candidate has no valid release database ID"

downloads="$verify_root/downloads"
mkdir -m 0700 -- "$downloads"
timeout 300 gh release download "$version" \
    --repo "$RELEASE_REPO" --dir "$downloads" \
    || die "staged candidate assets could not be downloaded"
[ -s "$downloads/SHA256SUMS" ] && [ ! -L "$downloads/SHA256SUMS" ] \
    || die "staged candidate has no checksum manifest"
[ -s "$downloads/SHA256SUMS.asc" ] && [ ! -L "$downloads/SHA256SUMS.asc" ] \
    || die "staged candidate has no checksum signature"
checksum_status="$(gpg --status-fd 1 --verify \
    "$downloads/SHA256SUMS.asc" "$downloads/SHA256SUMS" 2>/dev/null)" \
    || die "staged candidate checksum signature is invalid"
printf '%s\n' "$checksum_status" \
    | xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY" \
    || die "staged checksum manifest is not signed by the pinned release key"

python3 - "$downloads" <<'PY' \
    || die "staged candidate asset set differs from its signed checksum ledger"
import pathlib
import re
import stat
import sys

root = pathlib.Path(sys.argv[1])
lines = (root / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
names = []
for line in lines:
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
    if match is None:
        raise SystemExit(1)
    names.append(match.group(2))
if len(names) != len(set(names)) or not names:
    raise SystemExit(1)
source_names = [
    name
    for name in names
    if re.fullmatch(r"xeneon-edge-hub-.+\.tar\.gz", name)
]
if len(source_names) != 1:
    raise SystemExit(1)
expected = set(names) | {
    "SHA256SUMS",
    "SHA256SUMS.asc",
    source_names[0] + ".sig",
}
actual = set()
for path in root.iterdir():
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
    actual.add(path.name)
if actual != expected:
    raise SystemExit(1)
PY
( cd "$downloads" && sha256sum -c SHA256SUMS ) \
    || die "staged candidate asset hashes differ from the signed manifest"
source_tarball="$(awk \
    '$2 ~ /^xeneon-edge-hub-.+\\.tar\\.gz$/ { if (++count == 1) name=$2 } END { if (count == 1) print name; else exit 1 }' \
    "$downloads/SHA256SUMS")" \
    || die "signed manifest does not identify one source tarball"
source_status="$(gpg --status-fd 1 --verify \
    "$downloads/${source_tarball}.sig" "$downloads/$source_tarball" 2>/dev/null)" \
    || die "source tarball signature is invalid"
printf '%s\n' "$source_status" \
    | xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY" \
    || die "source tarball is not signed by the pinned release key"

python3 - "$downloads/PROVENANCE.json" \
    "$downloads/RELEASE_CERTIFICATION_EVIDENCE.json" \
    "$downloads/RELEASE_NOTES.md" "$remote_json" \
    "$version" "$head_commit" "$tag_object" \
    "$certification_artifact_path" \
    "$certification_receipt_hash" "$certification_manifest_hash" \
    "$certification_signature_hash" "$certification_provenance_hash" \
    "$zsync_dir/APPIMAGE_ZSYNC.json" "$downloads" <<'PY' \
    || die "signed release payloads do not bind both exact certification phases"
import hashlib
import json
import pathlib
import sys

(
    provenance_path,
    pointer_path,
    notes_path,
    remote_path,
    version,
    commit,
    tag_object,
    certification_path,
    certification_receipt_hash,
    certification_manifest_hash,
    certification_signature_hash,
    certification_provenance_hash,
    zsync_path,
    downloads_path,
) = sys.argv[1:]
provenance = json.loads(pathlib.Path(provenance_path).read_text(encoding="utf-8"))
pointer = json.loads(pathlib.Path(pointer_path).read_text(encoding="utf-8"))
remote = json.loads(pathlib.Path(remote_path).read_text(encoding="utf-8"))
zsync = json.loads(pathlib.Path(zsync_path).read_text(encoding="utf-8"))
downloads = pathlib.Path(downloads_path)
certification_hashes = {
    "artifact_path": certification_path,
    "receipt_sha256": certification_receipt_hash,
    "manifest_sha256": certification_manifest_hash,
    "signature_sha256": certification_signature_hash,
    "provenance_sha256": certification_provenance_hash,
}
if (
    provenance.get("schema") != "skyphoenix-edgehub-release-provenance/v4"
    or provenance.get("source_commit") != commit
    or provenance.get("release_tag") != version
    or provenance.get("annotated_tag_object") != tag_object
    or any(
        provenance.get("release_certification", {}).get(key) != value
        for key, value in certification_hashes.items()
    )
    or any(pointer.get(key) != value for key, value in certification_hashes.items())
    or provenance.get("post_publication_appimage_zsync", {}).get(
        "required_before_stable_promotion"
    )
    is not True
    or provenance.get("post_publication_appimage_zsync", {}).get("baseline_tag")
    != zsync.get("baseline_tag")
    or remote.get("body")
    != pathlib.Path(notes_path).read_text(encoding="utf-8")
):
    raise SystemExit(1)
appimages = list(downloads.glob("*.AppImage"))
if len(appimages) != 1:
    raise SystemExit(1)
candidate_hash = hashlib.sha256(appimages[0].read_bytes()).hexdigest()
if candidate_hash != zsync.get("candidate_sha256"):
    raise SystemExit(1)
PY

# Last read-only checks immediately before the only mutation.
xeneon_verify_origin_tag_exact \
    "$REPO_DIR" "$version" "$head_commit" "$tag_object" \
    || die "origin tag changed immediately before promotion"
bash "$CERTIFICATION_VERIFIER" \
    --commit "$head_commit" --version "$version" "$certification_dir" \
    >/dev/null \
    || die "prepublication certification changed before promotion"
bash "$ZSYNC_VERIFIER" \
    --commit "$head_commit" --version "$version" "$zsync_dir" \
    >/dev/null \
    || die "zsync certification changed before promotion"
pre_mutation_json="$verify_root/pre-mutation-release.json"
gh release view "$version" --repo "$RELEASE_REPO" \
    --json assets,body,databaseId,isDraft,isPrerelease,name,tagName \
    >"$pre_mutation_json" \
    || die "candidate metadata became unavailable immediately before promotion"
python3 - "$pre_mutation_json" "$zsync_dir/APPIMAGE_ZSYNC.json" \
    "$downloads/RELEASE_NOTES.md" "$release_id" "$version" <<'PY' \
    || die "candidate identity or asset ledger changed immediately before promotion"
import hashlib
import json
import pathlib
import sys

remote = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
receipt = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
notes = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
ledger = sorted(
    [
        {
            "id": asset.get("id"),
            "name": asset.get("name"),
            "size": asset.get("size"),
            "url": asset.get("url"),
        }
        for asset in remote.get("assets", [])
    ],
    key=lambda item: item["name"],
)
ledger_hash = hashlib.sha256(
    json.dumps(ledger, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if (
    str(remote.get("databaseId")) != sys.argv[4]
    or remote.get("tagName") != sys.argv[5]
    or remote.get("name") != f"EdgeHub {sys.argv[5]} certification candidate"
    or remote.get("isDraft") is not False
    or remote.get("isPrerelease") is not True
    or remote.get("body") != notes
    or ledger_hash != receipt.get("candidate_asset_ledger_sha256")
):
    raise SystemExit(1)
PY
xeneon_require_mutable_release_metadata "$RELEASE_REPO" \
    || die "immutable-release policy changed immediately before promotion"

if ! gh api --method PATCH "repos/$RELEASE_REPO/releases/$release_id" \
        -F draft=false -F prerelease=false -f make_latest=true \
        -f name="EdgeHub $version" >"$verify_root/promotion-response.json"; then
    die "GitHub refused stable metadata promotion; candidate remains a prerelease"
fi

rollback_to_draft() {
    local rollback_json
    if gh api --method PATCH "repos/$RELEASE_REPO/releases/$release_id" \
            -F draft=true -F prerelease=true -f make_latest=false \
            -f name="EdgeHub $version certification candidate" >/dev/null; then
        rollback_json="$verify_root/rollback.json"
        if gh release view "$version" --repo "$RELEASE_REPO" \
                --json databaseId,isDraft,isPrerelease >"$rollback_json" \
                && python3 - "$rollback_json" "$release_id" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if (
    str(record.get("databaseId")) != sys.argv[2]
    or record.get("isDraft") is not True
    or record.get("isPrerelease") is not True
):
    raise SystemExit(1)
PY
        then
            printf 'Candidate returned to draft after failed promotion verification.\n' >&2
        else
            printf 'CRITICAL: GitHub accepted rollback but the release is not a verified draft.\n' >&2
        fi
    else
        printf 'CRITICAL: GitHub refused to return the failed promotion to draft.\n' >&2
    fi
}

post_root="$verify_root/post"
mkdir -m 0700 -- "$post_root"
post_ok=1
mapfile -t staged_names < <(
    find "$downloads" -maxdepth 1 -type f -printf '%f\n' | sort
)
if ! timeout 300 gh release download "$version" \
        --repo "$RELEASE_REPO" --dir "$post_root"; then
    post_ok=0
elif ! python3 "$PATH_TOOL" assert-directory "$post_root" \
        "${staged_names[@]}"; then
    post_ok=0
fi
if [ "$post_ok" -eq 1 ]; then
    for name in "${staged_names[@]}"; do
        [ "$(sha256sum -- "$post_root/$name" | awk '{print $1}')" = \
            "$(sha256sum -- "$downloads/$name" | awk '{print $1}')" ] \
            || { post_ok=0; break; }
    done
fi
post_json="$verify_root/post-release.json"
latest_json="$verify_root/latest.json"
if [ "$post_ok" -eq 1 ]; then
    gh release view "$version" --repo "$RELEASE_REPO" \
        --json body,databaseId,isDraft,isPrerelease,name,tagName >"$post_json" \
        || post_ok=0
    gh api "repos/$RELEASE_REPO/releases/latest" >"$latest_json" \
        || post_ok=0
fi
if [ "$post_ok" -eq 1 ]; then
    python3 - "$post_json" "$latest_json" "$downloads/RELEASE_NOTES.md" \
        "$release_id" "$version" <<'PY' \
        || post_ok=0
import json
import pathlib
import sys

release = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
latest = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
notes = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
if (
    str(release.get("databaseId")) != sys.argv[4]
    or release.get("tagName") != sys.argv[5]
    or release.get("name") != f"EdgeHub {sys.argv[5]}"
    or release.get("isDraft") is not False
    or release.get("isPrerelease") is not False
    or release.get("body") != notes
    or str(latest.get("id")) != sys.argv[4]
    or latest.get("tag_name") != sys.argv[5]
    or latest.get("draft") is not False
    or latest.get("prerelease") is not False
):
    raise SystemExit(1)
PY
fi
if [ "$post_ok" -eq 1 ] \
        && ! xeneon_verify_origin_tag_exact \
            "$REPO_DIR" "$version" "$head_commit" "$tag_object"; then
    post_ok=0
fi
if [ "$post_ok" -ne 1 ]; then
    rollback_to_draft
    die "stable promotion post-verification failed"
fi

printf 'Stable promotion verified for %s at release ID %s.\n' \
    "$version" "$release_id"
