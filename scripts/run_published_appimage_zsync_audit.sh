#!/usr/bin/env bash
# Prove a prior public AppImage can update to the exact staged candidate.
set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RELEASE_REPO="skyphoenix-it/skyphoenix-edgehub-linux"
readonly FINALIZER="$REPO_DIR/scripts/finalize_audit_artifacts.sh"
readonly CONTRACT="$REPO_DIR/scripts/lib/audit_artifact_contract.py"
readonly IMMUTABLE_RELEASE_POLICY="$REPO_DIR/scripts/lib/github_immutable_releases.sh"

# shellcheck source=lib/github_immutable_releases.sh
. "$IMMUTABLE_RELEASE_POLICY"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  scripts/run_published_appimage_zsync_audit.sh \
    --commit FULL_SHA \
    --version vMAJOR.MINOR.PATCH \
    --baseline-tag vMAJOR.MINOR.PATCH[-{alpha,beta,rc}.N] \
    --candidate-appimage PATH \
    [--result-file PATH]

The current version must already be a public GitHub prerelease with the exact
AppImage and .zsync assets uploaded. The baseline release must be public and
contain exactly one AppImage. The script runs the real zsync client, compares
the resulting bytes with the local candidate and public candidate, then seals a
commit-keyed receipt with the pinned release key.
EOF
}

source_commit=""
release_version=""
baseline_tag=""
candidate_appimage=""
result_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --commit)
            [ "$#" -ge 2 ] || die "--commit requires a full SHA"
            [ -z "$source_commit" ] || die "--commit was supplied more than once"
            source_commit="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || die "--version requires a stable version"
            [ -z "$release_version" ] || die "--version was supplied more than once"
            release_version="$2"
            shift 2
            ;;
        --baseline-tag)
            [ "$#" -ge 2 ] || die "--baseline-tag requires a release tag"
            [ -z "$baseline_tag" ] || die "--baseline-tag was supplied more than once"
            baseline_tag="$2"
            shift 2
            ;;
        --candidate-appimage)
            [ "$#" -ge 2 ] || die "--candidate-appimage requires a path"
            [ -z "$candidate_appimage" ] \
                || die "--candidate-appimage was supplied more than once"
            candidate_appimage="$2"
            shift 2
            ;;
        --result-file)
            [ "$#" -ge 2 ] || die "--result-file requires a path"
            [ -z "$result_file" ] || die "--result-file was supplied more than once"
            result_file="$2"
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

[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] \
    || die "--commit must be a full lowercase 40-character SHA"
[[ "$release_version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "--version must be stable vMAJOR.MINOR.PATCH"
[[ "$baseline_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$ ]] \
    || die "--baseline-tag is not a supported exact release tag"
[ "$baseline_tag" != "$release_version" ] \
    || die "baseline and candidate release tags must differ"
command -v python3 >/dev/null 2>&1 \
    || die "required tool is unavailable: python3"
python3 - "$baseline_tag" "$release_version" <<'PY' \
    || die "--baseline-tag must identify a release older than the candidate"
import re
import sys

pattern = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$"
)

def key(value):
    match = pattern.fullmatch(value)
    if match is None:
        raise SystemExit(1)
    base = tuple(int(match.group(index)) for index in (1, 2, 3))
    channel = match.group(4)
    number = int(match.group(5)) if match.group(5) is not None else 0
    suffix = (
        (1, 0, 0)
        if channel is None
        else (0, {"alpha": 0, "beta": 1, "rc": 2}[channel], number)
    )
    return (*base, suffix)

if key(sys.argv[1]) >= key(sys.argv[2]):
    raise SystemExit(1)
PY
[ -n "$candidate_appimage" ] || die "--candidate-appimage is required"

for required_tool in \
    cp curl date gh git gpg mkdir python3 realpath rm script sha256sum stat \
    timeout tr zsync; do
    command -v "$required_tool" >/dev/null 2>&1 \
        || die "required tool is unavailable: $required_tool"
done
[ -x "$FINALIZER" ] || die "audit finalizer is unavailable"
[ -f "$CONTRACT" ] && [ ! -L "$CONTRACT" ] \
    || die "audit record contract is unavailable"
zsync_version_output="$(zsync -V 2>&1)" \
    || die "zsync version could not be read"
python3 - "$zsync_version_output" <<'PY' \
    || die "zsync 0.6.5 is required for stable byte-statistics evidence"
import re
import sys

lines = sys.argv[1].splitlines()
if len(lines) != 3 or re.fullmatch(
    r"zsync v0\.6\.5 \(compiled [A-Z][a-z]{2} [ 0-9][0-9] "
    r"[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\)",
    lines[0],
) is None or lines[1:] != [
    "By Colin Phipps <cph@moria.org.uk>",
    "Published under the Artistic License v2, see the COPYING file for details.",
]:
    raise SystemExit(1)
PY
zsync_client="${zsync_version_output%%$'\n'*}"

case "$candidate_appimage" in
    /*) ;;
    *) candidate_appimage="$REPO_DIR/$candidate_appimage" ;;
esac
[ -f "$candidate_appimage" ] && [ ! -L "$candidate_appimage" ] \
    || die "candidate AppImage is unavailable or symlinked"
candidate_appimage="$(realpath -e -- "$candidate_appimage")"
candidate_asset_name="${candidate_appimage##*/}"
[[ "$candidate_asset_name" =~ ^xeneon-edge-hub-.+-x86_64\.AppImage$ ]] \
    || die "candidate AppImage name does not satisfy the updater contract"

head_commit="$(git -C "$REPO_DIR" rev-parse --verify 'HEAD^{commit}')" \
    || die "HEAD does not resolve to a commit"
[ "$head_commit" = "$source_commit" ] \
    || die "requested commit is not current HEAD"
tag_object="$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/$release_version")" \
    || die "stable release tag is unavailable locally"
[ "$(git -C "$REPO_DIR" cat-file -t "$tag_object")" = "tag" ] \
    || die "stable release tag is not an annotated tag object"
[ "$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/$release_version^{commit}")" = "$source_commit" ] \
    || die "stable release tag does not name the exact candidate commit"
worktree_status="$(git -C "$REPO_DIR" status --porcelain=v1 \
    --untracked-files=all --ignore-submodules=none)"
[ -z "$worktree_status" ] || {
    printf '%s\n' "$worktree_status" >&2
    die "working tree must be clean before recording zsync evidence"
}

current_json="$(mktemp "${TMPDIR:-/tmp}/edgehub-current-release.XXXXXX")"
baseline_json="$(mktemp "${TMPDIR:-/tmp}/edgehub-baseline-release.XXXXXX")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/edgehub-zsync-roundtrip.XXXXXX")"
cleanup() {
    rm -f -- "$current_json" "$baseline_json"
    rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

xeneon_require_mutable_release_metadata "$RELEASE_REPO" \
    || die "same-release candidate promotion is unavailable under the current GitHub immutable-release policy"
gh release view "$release_version" --repo "$RELEASE_REPO" \
    --json assets,databaseId,isDraft,isPrerelease,tagName >"$current_json" \
    || die "current public prerelease metadata is unavailable"
gh release view "$baseline_tag" --repo "$RELEASE_REPO" \
    --json assets,databaseId,isDraft,tagName >"$baseline_json" \
    || die "baseline public release metadata is unavailable"

metadata="$(python3 - "$current_json" "$baseline_json" \
    "$release_version" "$baseline_tag" "$candidate_asset_name" <<'PY'
import hashlib
import json
import pathlib
import sys

current = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
baseline = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
version, baseline_tag, candidate_name = sys.argv[3:]
if (
    current.get("tagName") != version
    or current.get("isDraft") is not False
    or current.get("isPrerelease") is not True
):
    raise SystemExit("candidate release is not a public prerelease")
current_names = [asset.get("name") for asset in current.get("assets", [])]
if current_names.count(candidate_name) != 1:
    raise SystemExit("candidate prerelease does not contain the exact AppImage once")
if current_names.count(candidate_name + ".zsync") != 1:
    raise SystemExit("candidate prerelease does not contain the exact zsync once")
if baseline.get("tagName") != baseline_tag or baseline.get("isDraft") is not False:
    raise SystemExit("baseline release is not public")
baseline_names = [
    asset.get("name")
    for asset in baseline.get("assets", [])
    if isinstance(asset.get("name"), str)
    and asset["name"].endswith(".AppImage")
]
if len(baseline_names) != 1:
    raise SystemExit("baseline release must contain exactly one AppImage")
current_release_id = current.get("databaseId")
baseline_release_id = baseline.get("databaseId")
if (
    not isinstance(current_release_id, int)
    or current_release_id <= 0
    or not isinstance(baseline_release_id, int)
    or baseline_release_id <= 0
    or current_release_id == baseline_release_id
):
    raise SystemExit("release database IDs are missing, invalid, or equal")

def one_asset(document, name):
    matches = [asset for asset in document.get("assets", []) if asset.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"asset identity is ambiguous: {name}")
    asset = matches[0]
    if (
        not isinstance(asset.get("id"), str)
        or not asset["id"]
        or not isinstance(asset.get("size"), int)
        or asset["size"] <= 0
        or not isinstance(asset.get("url"), str)
        or not asset["url"]
    ):
        raise SystemExit(f"asset metadata is incomplete: {name}")
    return asset

candidate_asset = one_asset(current, candidate_name)
zsync_asset = one_asset(current, candidate_name + ".zsync")
baseline_asset = one_asset(baseline, baseline_names[0])
expected_candidate_url = (
    "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/"
    f"{version}/{candidate_name}"
)
expected_baseline_url = (
    "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/"
    f"{baseline_tag}/{baseline_asset['name']}"
)
if (
    candidate_asset["url"] != expected_candidate_url
    or zsync_asset["url"] != expected_candidate_url + ".zsync"
    or baseline_asset["url"] != expected_baseline_url
):
    raise SystemExit("GitHub asset URL is not the exact versioned public URL")
ledger = sorted(
    [
        {
            "id": asset.get("id"),
            "name": asset.get("name"),
            "size": asset.get("size"),
            "url": asset.get("url"),
        }
        for asset in current.get("assets", [])
    ],
    key=lambda item: item["name"],
)
if any(
    not isinstance(item["id"], str)
    or not item["id"]
    or not isinstance(item["name"], str)
    or not item["name"]
    or not isinstance(item["size"], int)
    or item["size"] <= 0
    or not isinstance(item["url"], str)
    or not item["url"]
    for item in ledger
):
    raise SystemExit("candidate asset ledger contains incomplete metadata")
ledger_payload = json.dumps(
    ledger, sort_keys=True, separators=(",", ":")
).encode()
print(
    "\t".join(
        str(value)
        for value in (
            current_release_id,
            baseline_release_id,
            candidate_asset["id"],
            candidate_asset["size"],
            zsync_asset["id"],
            zsync_asset["size"],
            baseline_asset["name"],
            baseline_asset["id"],
            baseline_asset["size"],
            hashlib.sha256(ledger_payload).hexdigest(),
        )
    )
)
PY
)" || die "public release metadata does not satisfy the zsync staging contract"
IFS=$'\t' read -r candidate_release_id baseline_release_id \
    candidate_asset_id candidate_metadata_size zsync_asset_id \
    zsync_metadata_size baseline_asset_name baseline_asset_id \
    baseline_metadata_size candidate_asset_ledger_sha256 <<<"$metadata"

candidate_url="https://github.com/${RELEASE_REPO}/releases/download/${release_version}/${candidate_asset_name}"
zsync_url="${candidate_url}.zsync"
baseline_url="https://github.com/${RELEASE_REPO}/releases/download/${baseline_tag}/${baseline_asset_name}"
public_candidate="$work_dir/public-candidate.AppImage"
baseline_appimage="$work_dir/baseline.AppImage"
updated_appimage="$work_dir/updated.AppImage"
zsync_control="$work_dir/candidate.AppImage.zsync"

anonymous_download() {
    local url="$1" output="$2" headers="$3"
    curl -q --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --retry 10 --retry-all-errors --retry-delay 3 --max-time 300 \
        --dump-header "$headers" --output "$output" "$url"
}

anonymous_download "$candidate_url" "$public_candidate" \
    "$work_dir/candidate.headers" \
    || die "public versioned candidate AppImage could not be downloaded"
anonymous_download "$baseline_url" "$baseline_appimage" \
    "$work_dir/baseline.headers" \
    || die "public versioned baseline AppImage could not be downloaded"
anonymous_download "$zsync_url" "$zsync_control" "$work_dir/zsync.headers" \
    || die "public versioned zsync control file could not be downloaded"

candidate_sha256="$(sha256sum -- "$candidate_appimage")"
candidate_sha256="${candidate_sha256%% *}"
public_candidate_sha256="$(sha256sum -- "$public_candidate")"
public_candidate_sha256="${public_candidate_sha256%% *}"
[ "$public_candidate_sha256" = "$candidate_sha256" ] \
    || die "public candidate AppImage bytes differ from the exact local candidate"
candidate_size="$(stat -c %s -- "$candidate_appimage")"
public_candidate_size="$(stat -c %s -- "$public_candidate")"
[ "$public_candidate_size" = "$candidate_size" ] \
    || die "public candidate AppImage size differs from the exact local candidate"
[ "$public_candidate_size" = "$candidate_metadata_size" ] \
    || die "candidate AppImage bytes differ from GitHub asset metadata"
baseline_sha256="$(sha256sum -- "$baseline_appimage")"
baseline_sha256="${baseline_sha256%% *}"
baseline_size="$(stat -c %s -- "$baseline_appimage")"
[ "$baseline_sha256" != "$candidate_sha256" ] \
    || die "baseline AppImage bytes are identical to the candidate"
[ "$baseline_size" = "$baseline_metadata_size" ] \
    || die "baseline AppImage bytes differ from GitHub asset metadata"
zsync_control_sha256="$(sha256sum -- "$zsync_control")"
zsync_control_sha256="${zsync_control_sha256%% *}"
zsync_control_size="$(stat -c %s -- "$zsync_control")"
[ "$zsync_control_size" = "$zsync_metadata_size" ] \
    || die "zsync control bytes differ from GitHub asset metadata"
python3 - "$zsync_control" "$candidate_url" <<'PY' \
    || die "zsync control file does not embed the exact versioned candidate URL"
import pathlib
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
if f"URL: {sys.argv[2]}".encode() not in payload:
    raise SystemExit(1)
PY

audit_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="appimage-zsync-${audit_stamp}-$$"
audit_dir="$REPO_DIR/artifacts/$source_commit/$run_id"
evidence_dir="$audit_dir/evidence"
mkdir -m 0700 -p -- "$evidence_dir"
zsync_log="$evidence_dir/zsync.log"
http_headers="$evidence_dir/anonymous-http-headers.txt"
retained_zsync_control="$evidence_dir/candidate.AppImage.zsync"
cp -- "$zsync_control" "$retained_zsync_control"
python3 - "$http_headers" \
    "$candidate_url" "$work_dir/candidate.headers" \
    "$baseline_url" "$work_dir/baseline.headers" \
    "$zsync_url" "$work_dir/zsync.headers" <<'PY'
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
records = sys.argv[2:]
with output.open("x", encoding="utf-8", newline="\n") as handle:
    for index in range(0, len(records), 2):
        url = records[index]
        source = pathlib.Path(records[index + 1])
        headers = source.read_text(encoding="iso-8859-1")
        handle.write(f"url={url}\n")
        handle.write(headers.replace("\r\n", "\n"))
        if not headers.endswith(("\n", "\r")):
            handle.write("\n")
PY
{
    printf 'candidate_url=%s\n' "$candidate_url"
    printf 'zsync_url=%s\n' "$zsync_url"
    printf 'baseline_url=%s\n' "$baseline_url"
    printf 'baseline_sha256=%s\n' "$baseline_sha256"
    printf 'candidate_sha256=%s\n' "$candidate_sha256"
    printf 'zsync_client=%s\n' "$zsync_client"
    printf 'command=script --quiet --return --flush /dev/null -- zsync -i baseline.AppImage -o updated.AppImage VERSIONED_ZSYNC_URL\n'
} >"$zsync_log"
# zsync 0.6.5 emits its final "used N local, fetched M" statistics only when
# stdin is a terminal. util-linux script supplies a pseudo-terminal and, with
# argv after "--", does so without constructing a shell command string.
if ! timeout 600 script --quiet --return --flush /dev/null -- \
        zsync -i "$baseline_appimage" -o "$updated_appimage" \
        "$zsync_url" >>"$zsync_log" 2>&1; then
    die "real prior-version zsync update failed; candidate remains a prerelease"
fi
[ -f "$updated_appimage" ] && [ ! -L "$updated_appimage" ] \
    || die "zsync did not produce a regular output AppImage"
updated_sha256="$(sha256sum -- "$updated_appimage")"
updated_sha256="${updated_sha256%% *}"
updated_size="$(stat -c %s -- "$updated_appimage")"
[ "$updated_sha256" = "$candidate_sha256" ] \
    && [ "$updated_size" = "$candidate_size" ] \
    || die "zsync output does not match the exact candidate bytes"
zsync_metrics="$(python3 - "$zsync_log" "$candidate_size" \
    "$zsync_control_size" <<'PY'
import pathlib
import re
import sys

log_path = pathlib.Path(sys.argv[1])
candidate_size = int(sys.argv[2])
control_size = int(sys.argv[3])
try:
    transcript = log_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as exc:
    raise SystemExit(f"zsync transcript is unreadable: {exc}") from exc
matches = re.findall(
    r"(?:^|[\r\n])used ([0-9]+) local, fetched ([0-9]+)(?=[\r\n]|$)",
    transcript,
)
if len(matches) != 1:
    raise SystemExit("zsync 0.6.5 emitted no unique final byte-statistics line")
local_bytes, fetched_bytes = (int(value) for value in matches[0])
if local_bytes <= 0:
    raise SystemExit("zsync did not reuse any verified local seed blocks")
delta_payload_bytes = fetched_bytes + control_size
savings_bytes = candidate_size - delta_payload_bytes
if fetched_bytes >= candidate_size or savings_bytes <= 0:
    raise SystemExit(
        "zsync target ranges plus its control file did not save transfer bytes"
    )
savings_basis_points = (savings_bytes * 10000) // candidate_size
if savings_basis_points <= 0:
    raise SystemExit("zsync transfer saving rounds to zero basis points")
print(
    "\t".join(
        str(value)
        for value in (
            local_bytes,
            fetched_bytes,
            delta_payload_bytes,
            candidate_size,
            savings_bytes,
            savings_basis_points,
        )
    )
)
PY
)" || die "zsync reuse or measured transfer savings could not be established"
IFS=$'\t' read -r client_reported_local_bytes \
    client_reported_fetched_bytes measured_delta_payload_bytes \
    measured_full_payload_bytes measured_payload_savings_bytes \
    measured_payload_savings_basis_points <<<"$zsync_metrics"
printf 'updated_sha256=%s\nupdated_size=%s\n' \
    "$updated_sha256" "$updated_size" >>"$zsync_log"
printf 'client_reported_local_bytes=%s\nclient_reported_fetched_bytes=%s\n' \
    "$client_reported_local_bytes" "$client_reported_fetched_bytes" \
    >>"$zsync_log"
printf 'measured_delta_payload_bytes=%s\nmeasured_full_payload_bytes=%s\n' \
    "$measured_delta_payload_bytes" "$measured_full_payload_bytes" \
    >>"$zsync_log"
printf 'measured_payload_savings_bytes=%s\nmeasured_payload_savings_basis_points=%s\nresult=PASS\n' \
    "$measured_payload_savings_bytes" \
    "$measured_payload_savings_basis_points" >>"$zsync_log"
zsync_log_sha256="$(sha256sum -- "$zsync_log")"
zsync_log_sha256="${zsync_log_sha256%% *}"
http_headers_sha256="$(sha256sum -- "$http_headers")"
http_headers_sha256="${http_headers_sha256%% *}"

python3 - "$audit_dir/APPIMAGE_ZSYNC.json" "$source_commit" "$run_id" \
    "$release_version" "$baseline_tag" "$candidate_asset_name" \
    "$baseline_url" "$candidate_url" "$zsync_url" \
    "$baseline_sha256" "$candidate_sha256" "$updated_sha256" \
    "$baseline_size" "$candidate_size" "$updated_size" \
    "$zsync_client" "$zsync_log_sha256" "$tag_object" \
    "$candidate_release_id" "$baseline_release_id" \
    "$candidate_asset_id" "$baseline_asset_id" "$zsync_asset_id" \
    "$candidate_asset_ledger_sha256" "$zsync_control_sha256" \
    "$zsync_control_size" "$http_headers_sha256" \
    "$client_reported_local_bytes" "$client_reported_fetched_bytes" \
    "$measured_delta_payload_bytes" "$measured_full_payload_bytes" \
    "$measured_payload_savings_bytes" \
    "$measured_payload_savings_basis_points" <<'PY'
import datetime
import json
import pathlib
import sys

(
    output,
    commit,
    run_id,
    version,
    baseline_tag,
    candidate_name,
    baseline_url,
    candidate_url,
    zsync_url,
    baseline_hash,
    candidate_hash,
    updated_hash,
    baseline_size,
    candidate_size,
    updated_size,
    zsync_client,
    log_hash,
    tag_object,
    candidate_release_id,
    baseline_release_id,
    candidate_asset_id,
    baseline_asset_id,
    zsync_asset_id,
    candidate_asset_ledger_hash,
    zsync_control_hash,
    zsync_control_size,
    http_headers_hash,
    client_reported_local_bytes,
    client_reported_fetched_bytes,
    measured_delta_payload_bytes,
    measured_full_payload_bytes,
    measured_payload_savings_bytes,
    measured_payload_savings_basis_points,
) = sys.argv[1:]
document = {
    "schema": "skyphoenix-edgehub-appimage-zsync/v2",
    "source_commit": commit,
    "tag_object": tag_object,
    "repository": "skyphoenix-it/skyphoenix-edgehub-linux",
    "release_version": version,
    "run_id": run_id,
    "result": "PASS",
    "completed_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
    "baseline_tag": baseline_tag,
    "baseline_release_id": int(baseline_release_id),
    "candidate_release_id": int(candidate_release_id),
    "baseline_asset_id": baseline_asset_id,
    "candidate_asset_id": candidate_asset_id,
    "zsync_asset_id": zsync_asset_id,
    "candidate_asset_ledger_sha256": candidate_asset_ledger_hash,
    "candidate_asset_name": candidate_name,
    "baseline_asset_url": baseline_url,
    "candidate_asset_url": candidate_url,
    "zsync_url": zsync_url,
    "baseline_sha256": baseline_hash,
    "candidate_sha256": candidate_hash,
    "updated_sha256": updated_hash,
    "baseline_size": int(baseline_size),
    "candidate_size": int(candidate_size),
    "updated_size": int(updated_size),
    "client_reported_local_bytes": int(client_reported_local_bytes),
    "client_reported_fetched_bytes": int(client_reported_fetched_bytes),
    "measured_delta_payload_bytes": int(measured_delta_payload_bytes),
    "measured_full_payload_bytes": int(measured_full_payload_bytes),
    "measured_payload_savings_bytes": int(measured_payload_savings_bytes),
    "measured_payload_savings_basis_points": int(
        measured_payload_savings_basis_points
    ),
    "public_release_was_prerelease": True,
    "zsync_client": zsync_client,
    "log_path": "evidence/zsync.log",
    "log_sha256": log_hash,
    "http_headers_path": "evidence/anonymous-http-headers.txt",
    "http_headers_sha256": http_headers_hash,
    "zsync_control_path": "evidence/candidate.AppImage.zsync",
    "zsync_control_sha256": zsync_control_hash,
    "zsync_control_size": int(zsync_control_size),
}
path = pathlib.Path(output)
with path.open("x", encoding="utf-8", newline="\n") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

bash "$FINALIZER" "$audit_dir" \
    || die "zsync passed, but signed evidence finalization failed"

if [ -n "$result_file" ]; then
    umask 077
    result_payload="$work_dir/result.txt"
    {
        printf 'source_commit=%s\n' "$source_commit"
        printf 'release_version=%s\n' "$release_version"
        printf 'artifact_path=%s\n' "${audit_dir#"$REPO_DIR"/}"
        for name in APPIMAGE_ZSYNC.json MANIFEST.sha256 MANIFEST.sha256.asc PROVENANCE.json; do
            digest="$(sha256sum -- "$audit_dir/$name")"
            printf '%s_sha256=%s\n' \
                "$(printf '%s' "$name" | tr '[:upper:].' '[:lower:]_')" \
                "${digest%% *}"
        done
    } >"$result_payload"
    python3 - "$result_file" "$result_payload" <<'PY' \
        || die "result file already exists, is unsafe, or could not be created"
import os
import pathlib
import stat
import sys

destination = pathlib.Path(sys.argv[1])
payload = pathlib.Path(sys.argv[2]).read_bytes()
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(destination, flags, 0o600)
created = os.fstat(descriptor)

def remove_created_path() -> None:
    try:
        current = destination.lstat()
        if (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
            destination.unlink()
    except FileNotFoundError:
        pass

try:
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)
except BaseException:
    remove_created_path()
    raise
metadata = destination.lstat()
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 1
    or stat.S_IMODE(metadata.st_mode) != 0o600
    or (metadata.st_dev, metadata.st_ino) != (created.st_dev, created.st_ino)
):
    remove_created_path()
    raise SystemExit(1)
parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
parent_flags |= getattr(os, "O_CLOEXEC", 0)
parent = os.open(destination.parent or pathlib.Path("."), parent_flags)
try:
    os.fsync(parent)
finally:
    os.close(parent)
PY
fi

printf 'Signed AppImage zsync evidence: %s\n' "$audit_dir"
