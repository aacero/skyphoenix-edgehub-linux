#!/usr/bin/env bash
# Fast semantic and sequencing controls for staged stable AppImage promotion.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
contract="$repo/scripts/lib/audit_artifact_contract.py"
release_script="$repo/scripts/release.sh"
runner="$repo/scripts/run_published_appimage_zsync_audit.sh"
promoter="$repo/scripts/promote_stable_release.sh"
immutable_policy="$repo/scripts/lib/github_immutable_releases.sh"
checker="$repo/ui/qml/widgets/UpdateChecker.qml"
checker_test="$repo/tests/ui/tst_update_checker.qml"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/edgehub-zsync-contract.XXXXXX")"

cleanup() {
    case "$fixture" in
        "${TMPDIR:-/tmp}"/edgehub-zsync-contract.*)
            find "$fixture" -depth -delete
            ;;
        *) printf 'REFUSING unsafe cleanup path: %s\n' "$fixture" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_rejected() {
    local label="$1"
    shift
    if "$@" >"$fixture/rejected.log" 2>&1; then
        fail "$label"
    fi
    printf '  ok  %s\n' "$label"
}

for subject in \
    "$contract" "$release_script" "$runner" "$promoter" "$immutable_policy" \
    "$checker" "$checker_test"; do
    [ -f "$subject" ] || fail "missing zsync/promotion contract subject: $subject"
done

fake_bin="$fixture/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
    [ "${FAKE_GH_AUTH:-ok}" = "ok" ]
    exit
fi
if [ "${1:-}" != "api" ]; then
    printf 'unexpected fake gh command\n' >&2
    exit 9
fi
case " $* " in
    *"/immutable-releases "*)
        case "${FAKE_IMMUTABLE_MODE:-observed-disabled}" in
            documented-disabled)
                printf 'HTTP/2.0 404 Not Found\nContent-Type: application/json\r\n\r\n{"message":"Not Found"}'
                printf 'gh: Not Found (HTTP 404)\n' >&2
                exit 1
                ;;
            observed-disabled)
                printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n\r\n{"enabled":false,"enforced_by_owner":false}'
                ;;
            enabled)
                printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n\r\n{"enabled":true,"enforced_by_owner":false}'
                ;;
            owner-enforced)
                printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n\r\n{"enabled":false,"enforced_by_owner":true}'
                ;;
            missing-field)
                printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n\r\n{"enabled":false}'
                ;;
            non-boolean)
                printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n\r\n{"enabled":"false","enforced_by_owner":false}'
                ;;
            malformed)
                printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n\r\nnot-json'
                ;;
            server-error)
                printf 'HTTP/2.0 500 Internal Server Error\nContent-Type: application/json\r\n\r\n{"message":"failed"}'
                exit 1
                ;;
            transport-error)
                printf 'transport failed\n' >&2
                exit 1
                ;;
            *)
                exit 9
                ;;
        esac
        ;;
    *)
        printf '%s\n' \
            "${FAKE_REPOSITORY_IDENTITY:-skyphoenix-it/skyphoenix-edgehub-linux}"
        ;;
esac
SH
chmod 0755 "$fake_bin/gh"

run_immutable_policy() {
    env PATH="$fake_bin:$PATH" TMPDIR="$fixture" "$@" \
        bash -c '. "$1"; xeneon_require_mutable_release_metadata "$2"' \
        _ "$immutable_policy" skyphoenix-it/skyphoenix-edgehub-linux
}

echo "==> GitHub immutable-release policy contract"
run_immutable_policy env FAKE_IMMUTABLE_MODE=documented-disabled
printf '  ok  documented authenticated 404 is accepted as disabled\n'
run_immutable_policy env FAKE_IMMUTABLE_MODE=observed-disabled
printf '  ok  observed exact 200 false/false response is accepted as disabled\n'
expect_rejected "enabled immutable releases are rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=enabled
expect_rejected "owner-enforced immutable releases are rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=owner-enforced
expect_rejected "missing immutable-release fields are rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=missing-field
expect_rejected "non-boolean immutable-release fields are rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=non-boolean
expect_rejected "malformed immutable-release JSON is rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=malformed
expect_rejected "immutable-release server errors are rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=server-error
expect_rejected "immutable-release transport errors are rejected" \
    run_immutable_policy env FAKE_IMMUTABLE_MODE=transport-error
expect_rejected "GitHub authentication failures are rejected" \
    run_immutable_policy env FAKE_GH_AUTH=fail
expect_rejected "a non-canonical repository identity is rejected" \
    run_immutable_policy env FAKE_REPOSITORY_IDENTITY=attacker/example

for consumer in "$release_script" "$runner" "$promoter"; do
    grep -Fq 'lib/github_immutable_releases.sh' "$consumer" \
        || fail "${consumer#$repo/} does not source the shared immutable-release policy"
    grep -Fq 'xeneon_require_mutable_release_metadata "$RELEASE_REPO"' "$consumer" \
        || fail "${consumer#$repo/} does not enforce the shared immutable-release policy"
    if grep -Fq 'repos/$RELEASE_REPO/immutable-releases' "$consumer"; then
        fail "${consumer#$repo/} still contains a divergent inline immutable-release probe"
    fi
done
[ "$(grep -Fc 'xeneon_require_mutable_release_metadata "$RELEASE_REPO"' \
        "$release_script")" -eq 2 ] \
    || fail "release staging does not probe immutable policy at preflight and publication"
[ "$(grep -Fc 'xeneon_require_mutable_release_metadata "$RELEASE_REPO"' \
        "$promoter")" -eq 2 ] \
    || fail "stable promotion does not re-probe immutable policy before mutation"
printf '  ok  staging, zsync audit, and promotion share one fail-closed policy\n'

commit="0123456789abcdef0123456789abcdef01234567"
run_id="appimage-zsync-20260726T130000Z-50"
run_dir="$fixture/artifacts/$commit/$run_id"
mkdir -p "$run_dir/evidence"
python3 - "$run_dir" "$commit" "$run_id" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
run_id = sys.argv[3]
candidate_url = (
    "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/"
    "download/v1.0.0/xeneon-edge-hub-1.0.0-x86_64.AppImage"
)
baseline_url = (
    "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/"
    "download/v1.0.0-rc.1/xeneon-edge-hub-1.0.0-rc.1-x86_64.AppImage"
)
log = root / "evidence" / "zsync.log"
headers = root / "evidence" / "anonymous-http-headers.txt"
control = root / "evidence" / "candidate.AppImage.zsync"
headers.write_text(
    f"url={candidate_url}\nHTTP/2 200\n"
    f"url={baseline_url}\nHTTP/2 200\n"
    f"url={candidate_url}.zsync\nHTTP/2 200\n",
    encoding="utf-8",
)
control.write_bytes(
    f"zsync: 0.6.2\nURL: {candidate_url}\n\n".encode() + b"\x00checksums"
)
local_bytes = 800
fetched_bytes = 200
candidate_size = 1200
delta_bytes = fetched_bytes + control.stat().st_size
savings_bytes = candidate_size - delta_bytes
savings_basis_points = (savings_bytes * 10000) // candidate_size
log.write_text(
    "zsync_client=zsync v0.6.5 (compiled Jun 21 2026 04:36:17)\n"
    f"zsync_url={candidate_url}.zsync\n"
    f"used {local_bytes} local, fetched {fetched_bytes}\n"
    f"client_reported_local_bytes={local_bytes}\n"
    f"client_reported_fetched_bytes={fetched_bytes}\n"
    f"measured_delta_payload_bytes={delta_bytes}\n"
    f"measured_full_payload_bytes={candidate_size}\n"
    f"measured_payload_savings_bytes={savings_bytes}\n"
    f"measured_payload_savings_basis_points={savings_basis_points}\n"
    "result=PASS\n",
    encoding="utf-8",
)
candidate_hash = "a" * 64
document = {
    "schema": "skyphoenix-edgehub-appimage-zsync/v2",
    "source_commit": commit,
    "tag_object": "1" * 40,
    "repository": "skyphoenix-it/skyphoenix-edgehub-linux",
    "release_version": "v1.0.0",
    "run_id": run_id,
    "result": "PASS",
    "completed_at": "2026-07-26T13:00:00Z",
    "baseline_tag": "v1.0.0-rc.1",
    "baseline_release_id": 100,
    "candidate_release_id": 101,
    "baseline_asset_id": "RA_baseline",
    "candidate_asset_id": "RA_candidate",
    "zsync_asset_id": "RA_zsync",
    "candidate_asset_ledger_sha256": "2" * 64,
    "candidate_asset_name": "xeneon-edge-hub-1.0.0-x86_64.AppImage",
    "baseline_asset_url": baseline_url,
    "candidate_asset_url": candidate_url,
    "zsync_url": candidate_url + ".zsync",
    "baseline_sha256": "b" * 64,
    "candidate_sha256": candidate_hash,
    "updated_sha256": candidate_hash,
    "baseline_size": 1000,
    "candidate_size": candidate_size,
    "updated_size": candidate_size,
    "client_reported_local_bytes": local_bytes,
    "client_reported_fetched_bytes": fetched_bytes,
    "measured_delta_payload_bytes": delta_bytes,
    "measured_full_payload_bytes": candidate_size,
    "measured_payload_savings_bytes": savings_bytes,
    "measured_payload_savings_basis_points": savings_basis_points,
    "public_release_was_prerelease": True,
    "zsync_client": "zsync v0.6.5 (compiled Jun 21 2026 04:36:17)",
    "log_path": "evidence/zsync.log",
    "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
    "http_headers_path": "evidence/anonymous-http-headers.txt",
    "http_headers_sha256": hashlib.sha256(headers.read_bytes()).hexdigest(),
    "zsync_control_path": "evidence/candidate.AppImage.zsync",
    "zsync_control_sha256": hashlib.sha256(control.read_bytes()).hexdigest(),
    "zsync_control_size": control.stat().st_size,
}
(root / "APPIMAGE_ZSYNC.json").write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "==> Published AppImage zsync semantic contract"
PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
    "$run_dir" "$commit" "$run_id" v1.0.0
printf '  ok  exact public prior-to-candidate receipt is accepted\n'

cp -- "$run_dir/APPIMAGE_ZSYNC.json" "$fixture/valid.json"
cp -- "$run_dir/evidence/zsync.log" "$fixture/valid-zsync.log"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["client_reported_local_bytes"] += 1
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "receipt metrics that differ from raw zsync statistics are rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" "$run_dir/evidence/zsync.log" <<'PY'
import hashlib
import json
import pathlib
import sys

record_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])
document = json.loads(record_path.read_text(encoding="utf-8"))
log_text = log_path.read_text(encoding="utf-8").replace(
    "used 800 local, fetched 200",
    "used 0 local, fetched 200",
)
log_text = log_text.replace(
    "client_reported_local_bytes=800",
    "client_reported_local_bytes=0",
)
log_path.write_text(log_text, encoding="utf-8")
document["client_reported_local_bytes"] = 0
document["log_sha256"] = hashlib.sha256(log_path.read_bytes()).hexdigest()
record_path.write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
expect_rejected "a real update with zero local seed-block reuse is rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"
cp -- "$fixture/valid-zsync.log" "$run_dir/evidence/zsync.log"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" "$run_dir/evidence/zsync.log" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

record_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])
document = json.loads(record_path.read_text(encoding="utf-8"))
fetched_bytes = document["candidate_size"]
delta_bytes = fetched_bytes + document["zsync_control_size"]
savings_bytes = document["candidate_size"] - delta_bytes
savings_basis_points = (
    savings_bytes * 10000
) // document["candidate_size"]
log_text = log_path.read_text(encoding="utf-8")
replacements = {
    r"used 800 local, fetched 200": (
        f"used 800 local, fetched {fetched_bytes}"
    ),
    r"client_reported_fetched_bytes=200": (
        f"client_reported_fetched_bytes={fetched_bytes}"
    ),
    r"measured_delta_payload_bytes=[0-9]+": (
        f"measured_delta_payload_bytes={delta_bytes}"
    ),
    r"measured_payload_savings_bytes=[0-9]+": (
        f"measured_payload_savings_bytes={savings_bytes}"
    ),
    r"measured_payload_savings_basis_points=[0-9]+": (
        "measured_payload_savings_basis_points="
        f"{savings_basis_points}"
    ),
}
for pattern, replacement in replacements.items():
    log_text, count = re.subn(pattern, replacement, log_text)
    if count != 1:
        raise SystemExit(f"fixture replacement failed: {pattern}")
log_path.write_text(log_text, encoding="utf-8")
document["client_reported_fetched_bytes"] = fetched_bytes
document["measured_delta_payload_bytes"] = delta_bytes
document["measured_payload_savings_bytes"] = savings_bytes
document["measured_payload_savings_basis_points"] = savings_basis_points
document["log_sha256"] = hashlib.sha256(log_path.read_bytes()).hexdigest()
record_path.write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
expect_rejected "a zsync run without measured payload savings is rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"
cp -- "$fixture/valid-zsync.log" "$run_dir/evidence/zsync.log"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" "$run_dir/evidence/zsync.log" <<'PY'
import hashlib
import json
import pathlib
import sys

record_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])
document = json.loads(record_path.read_text(encoding="utf-8"))
with log_path.open("a", encoding="utf-8") as handle:
    handle.write("used 800 local, fetched 200\n")
document["log_sha256"] = hashlib.sha256(log_path.read_bytes()).hexdigest()
record_path.write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
expect_rejected "ambiguous duplicate zsync statistics are rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"
cp -- "$fixture/valid-zsync.log" "$run_dir/evidence/zsync.log"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["zsync_client"] = "zsync v0.6.4 (compiled Jun 21 2026 04:36:17)"
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "a zsync client outside the audited 0.6.5 contract is rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["updated_sha256"] = "c" * 64
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "wrong zsync output bytes are rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["baseline_tag"] = "v2.0.0"
document["baseline_asset_url"] = (
    "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/"
    "download/v2.0.0/xeneon-edge-hub-2.0.0-x86_64.AppImage"
)
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "a baseline newer than the candidate is rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["baseline_sha256"] = document["candidate_sha256"]
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "identical baseline and candidate bytes are rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["public_release_was_prerelease"] = False
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "a non-prerelease staging claim is rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0
cp -- "$fixture/valid.json" "$run_dir/APPIMAGE_ZSYNC.json"

python3 - "$run_dir/APPIMAGE_ZSYNC.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["zsync_url"] = (
    "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/"
    "releases/latest/download/xeneon-edge-hub.AppImage.zsync"
)
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_rejected "a mutable latest zsync URL is rejected" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$contract" appimage-zsync \
        "$run_dir" "$commit" "$run_id" v1.0.0

echo "==> Stable stage and promotion sequencing"
grep -Fq "direct stable publication is forbidden" "$release_script" \
    || fail "direct stable publication is not refused"
grep -Fq -- "--stage-candidate" "$release_script" \
    || fail "explicit stable candidate staging is absent"
grep -Fq -- "--promote" "$release_script" \
    || fail "explicit stable promotion is absent"
grep -Fq "candidate remains a non-latest prerelease and was not promoted" \
    "$release_script" \
    && fail "staging still performs post-publication certification inline"
grep -Fq "stable candidate staged as public prerelease" "$release_script" \
    || fail "staging does not stop at the public prerelease"
grep -Fq 'gh release view "$ZSYNC_BASELINE_TAG"' "$release_script" \
    && grep -Fq 'len(appimages) != 1' "$release_script" \
    && grep -Fq 'key(baseline_tag) >= key(candidate_tag)' "$release_script" \
    || fail "staging does not reject a missing, ambiguous, or non-prior AppImage seed"
printf '  ok  stable staging and promotion are separate commands\n'

grep -Fq 'timeout 600 script --quiet --return --flush /dev/null --' "$runner" \
    && grep -Fq 'zsync -i "$baseline_appimage" -o "$updated_appimage"' "$runner" \
    || fail "zsync audit does not retain client byte statistics through a PTY"
grep -Fq 'zsync -V 2>&1' "$runner" \
    || fail "zsync audit does not use the 0.6.5 version-reporting interface"
if grep -Fq 'zsync --version' "$runner"; then
    fail "zsync audit uses the unsupported zsync 0.6.5 --version option"
fi
for metric in \
    client_reported_local_bytes \
    client_reported_fetched_bytes \
    measured_delta_payload_bytes \
    measured_full_payload_bytes \
    measured_payload_savings_bytes \
    measured_payload_savings_basis_points; do
    grep -Fq "$metric" "$runner" \
        || fail "zsync audit does not retain metric: $metric"
done
grep -Fq 'skyphoenix-edgehub-appimage-zsync/v2' "$runner" \
    || fail "zsync audit does not emit the measured-reuse v2 receipt"
grep -Fq 'public_release_was_prerelease' "$runner" \
    || fail "zsync audit does not bind the staged prerelease state"
grep -Fq 'candidate_asset_ledger_sha256' "$runner" \
    || fail "zsync audit does not bind the exact GitHub asset ledger"
grep -Fq 'os.O_WRONLY | os.O_CREAT | os.O_EXCL' "$runner" \
    && grep -Fq 'getattr(os, "O_NOFOLLOW", 0)' "$runner" \
    || fail "zsync result receipt can overwrite an existing path"
printf '  ok  post-publication audit binds and executes the real zsync round trip\n'

certification_line="$(grep -nF 'bash "$CERTIFICATION_VERIFIER"' "$promoter" \
    | tail -1 | cut -d: -f1)"
zsync_line="$(grep -nF 'bash "$ZSYNC_VERIFIER"' "$promoter" \
    | tail -1 | cut -d: -f1)"
promotion_line="$(grep -nF \
    'repos/$RELEASE_REPO/releases/$release_id" \' "$promoter" \
    | head -1 | cut -d: -f1)"
[ -n "$certification_line" ] && [ -n "$zsync_line" ] \
    && [ -n "$promotion_line" ] \
    && [ "$certification_line" -lt "$promotion_line" ] \
    && [ "$zsync_line" -lt "$promotion_line" ] \
    || fail "promotion can mutate metadata before both signed receipts verify"
if grep -Eq \
    'gh[[:space:]]+release[[:space:]]+(upload|delete)|cmake|run_release_tests|zsyncmake' \
    "$promoter"; then
    fail "promotion helper can build, test, upload, delete, or replace assets"
fi
grep -Fq -- '-F prerelease=false -f make_latest=true' "$promoter" \
    || fail "promotion helper lacks the stable/latest metadata transition"
grep -Fq -- '--json assets,body,databaseId,isDraft,isPrerelease,name,tagName' \
    "$promoter" \
    && grep -Fq -- '--json body,databaseId,isDraft,isPrerelease,name,tagName' \
        "$promoter" \
    && grep -Fq 'remote.get("body") != notes' "$promoter" \
    && grep -Fq 'release.get("body") != notes' "$promoter" \
    || fail "promotion does not preserve signed release notes before and after mutation"
[ "$(grep -Fc 'xeneon_verify_origin_tag_exact' "$promoter")" -eq 3 ] \
    || fail "promotion does not reverify the exact remote tag after mutation"
grep -Fq 'verify_release_gate_unchanged()' "$release_script" \
    && [ "$(grep -Fc 'verify_release_gate_unchanged' "$release_script")" -ge 4 ] \
    || fail "release publication does not reverify retained strict-gate evidence"
grep -Fq 'verify_release_checkout_unchanged()' "$release_script" \
    && [ "$(grep -Fc 'verify_release_checkout_unchanged' "$release_script")" -ge 4 ] \
    || fail "release publication does not reverify its checkout control plane"
printf '  ok  promotion is receipt-gated and metadata-only\n'

grep -Fq \
    'if (r.prerelease === true && !checker._isPrerelease(t)) continue' \
    "$checker" \
    || fail "update checker exposes a staged stable tag"
grep -Fq 'test_staged_stable_tag_is_never_offered_before_promotion' \
    "$checker_test" \
    || fail "staged stable tag filtering has no behavior test"
printf '  ok  staged stable tags are hidden from every update channel\n'

printf 'RESULT: SUCCESS\n'
