#!/usr/bin/env bash
# Fast execution-level contracts for release provenance, SBOM, and exact sets.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$PROJECT_DIR/scripts/generate_release_sbom.sh"
MERGER="$PROJECT_DIR/scripts/lib/merge_release_sbom.py"
ORIGIN_LIB="$PROJECT_DIR/scripts/lib/release_origin.sh"
PATH_TOOL="$PROJECT_DIR/scripts/lib/release_paths.py"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/release.sh"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

for subject in \
    "$GENERATOR" "$MERGER" "$ORIGIN_LIB" "$PATH_TOOL" "$RELEASE_SCRIPT"; do
    [ -f "$subject" ] || fail "missing contract subject: ${subject#$PROJECT_DIR/}"
done
[ "$failures" -eq 0 ] || exit 1

# shellcheck source=lib/release_origin.sh
. "$ORIGIN_LIB"

contract_dir="$(mktemp -d -t xeneon-release-provenance-XXXXXX)"
cleanup() {
    rm -rf -- "$contract_dir"
}
trap cleanup EXIT HUP INT TERM

source_dir="$contract_dir/source"
fake_bin="$contract_dir/bin"
mkdir -p "$source_dir/core" "$source_dir/scripts/lib" "$fake_bin"
cp -- "$MERGER" "$source_dir/scripts/lib/merge_release_sbom.py"
cp -- "$PROJECT_DIR/scripts/safe_extract_appimage.sh" \
    "$source_dir/scripts/safe_extract_appimage.sh"
printf '[package]\nname = "fixture"\nversion = "1.0.0"\n' \
    >"$source_dir/core/Cargo.toml"

cat >"$fake_bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")" && pwd)"
[ ! -e "$state_dir/cargo-fail" ] || exit 19
if [ "${1:-}" = "cyclonedx" ] && [ "${2:-}" = "--version" ]; then
    echo "cargo-cyclonedx-cyclonedx 0.5.9"
    exit 0
fi
name=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --override-filename) name="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$name" ]
python3 - "$name" "$state_dir" <<'PY'
import json
import os
import pathlib
import sys

state = pathlib.Path(sys.argv[2])
count = 1 if (state / "cargo-vacuous").exists() else 10
components = [
    {
        "type": "library",
        "bom-ref": f"cargo-dependency-{index}",
        "name": "serde" if index == 0 else f"dependency-{index}",
        "version": "1.0.0",
    }
    for index in range(count)
]
targets = [item["bom-ref"] for item in components]
if (state / "cargo-bad-graph").exists():
    targets.append("missing-reference")
document = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "metadata": {
        "tools": [{"name": "cargo-cyclonedx", "version": "0.5.9"}],
        "component": {
            "type": "library",
            "bom-ref": "cargo-root",
            "name": "fixture-core",
            "version": "1.0.0",
        },
    },
    "components": components,
    "dependencies": [{"ref": "cargo-root", "dependsOn": targets}],
}
pathlib.Path(f"{sys.argv[1]}.json").write_text(
    json.dumps(document), encoding="utf-8"
)
PY
EOF
chmod 0755 "$fake_bin/cargo"

cat >"$fake_bin/syft" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")" && pwd)"
[ ! -e "$state_dir/syft-fail" ] || exit 23
if [ "${1:-}" = "version" ]; then
    echo "syft 1.46.0"
    exit 0
fi
[ "${SYFT_CONFIG+x}" = "x" ] && [ -z "$SYFT_CONFIG" ]
[ "${SYFT_CHECK_FOR_APP_UPDATE:-}" = "false" ]
[ -z "${SYFT_ENRICH:-}" ]
[ "${SYFT_GOLANG_SEARCH_REMOTE_LICENSES:-}" = "false" ]
[ "${SYFT_GOLANG_USE_PACKAGES_LIB:-}" = "false" ]
[ "${SYFT_JAVA_USE_NETWORK:-}" = "false" ]
[ "${SYFT_JAVASCRIPT_SEARCH_REMOTE_LICENSES:-}" = "false" ]
[ "${SYFT_PYTHON_SEARCH_REMOTE_LICENSES:-}" = "false" ]
case "$HOME" in *xeneon-release-sbom-*/home) ;; *) exit 28 ;; esac
case "$XDG_CONFIG_HOME" in *xeneon-release-sbom-*/config) ;; *) exit 29 ;; esac
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            case "$2" in cyclonedx-json@1.5=*) output="${2#cyclonedx-json@1.5=}" ;;
                *) exit 31 ;;
            esac
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "$output" ]
cat >"$output" <<'JSON'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "metadata": {
    "tools": [{"name": "syft", "version": "1.46.0"}],
    "component": {
      "type": "file",
      "bom-ref": "syft-root",
      "name": "scanned-artifact"
    }
  },
  "components": [
    {
      "type": "library",
      "bom-ref": "native-dependency",
      "name": "Qt6Core",
      "version": "6.fixture"
    }
  ],
  "dependencies": []
}
JSON
EOF
chmod 0755 "$fake_bin/syft"

artifact="$contract_dir/payload.tar.gz"
printf 'exact release payload\n' >"$artifact"
artifact_digest="$(sha256sum "$artifact")"
artifact_digest="${artifact_digest%% *}"
artifact_size="$(stat -c %s "$artifact")"
epoch=1785024000
commit=0123456789abcdef0123456789abcdef01234567
tag_object=89abcdef0123456789abcdef0123456789abcdef
signing_key=2F0CAD36DC1D46F3347B7EF293CDC77EACF98990

run_generator() {
    local mode="$1" output="$2" digest="${3:-$artifact_digest}"
    PATH="$fake_bin:$PATH" bash "$GENERATOR" \
        --version 1.0.0 \
        --source-dir "$source_dir" \
        --source-date-epoch "$epoch" \
        --mode "$mode" \
        --source-commit "$commit" \
        --release-tag v1.0.0 \
        --tag-object "$tag_object" \
        --signing-key "$signing_key" \
        --output "$output" \
        --artifact "$artifact" "$digest" "$artifact_size"
}

echo "==> Release SBOM execution contract"
complete_bom="$contract_dir/complete.cdx.json"
if run_generator complete "$complete_bom" >/dev/null; then
    if python3 - "$complete_bom" "$artifact" "$commit" "$tag_object" <<'PY'
import hashlib
import json
import pathlib
import sys

bom = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
artifact = pathlib.Path(sys.argv[2])
components = bom["components"]
names = {item.get("name") for item in components}
assert bom["$schema"] == "http://cyclonedx.org/schema/bom-1.5.schema.json"
assert bom["bomFormat"] == "CycloneDX"
assert bom["specVersion"] == "1.5"
assert {"payload.tar.gz", "serde", "Qt6Core"} <= names
payload = next(item for item in components if item.get("name") == "payload.tar.gz")
expected = hashlib.sha256(artifact.read_bytes()).hexdigest()
assert payload["hashes"] == [{"alg": "SHA-256", "content": expected}]
properties = {
    item["name"]: item["value"]
    for item in bom["metadata"]["component"]["properties"]
}
assert properties["edgehub:release:source-commit"] == sys.argv[3]
assert properties["edgehub:release:tag-object"] == sys.argv[4]
assert properties["edgehub:sbom:cargo-cyclonedx-version"] == "0.5.9"
assert properties["edgehub:sbom:syft-version"] == "1.46.0"
assert properties["edgehub:sbom:scan-mode"] == "complete"
tool_components = bom["metadata"]["tools"]["components"]
assert {item["name"] for item in tool_components} == {"cargo-cyclonedx", "syft"}
assert all(item["type"] == "application" for item in tool_components)
refs = {bom["metadata"]["component"]["bom-ref"]}
refs.update(item["bom-ref"] for item in components)
assert all(
    dep["ref"] in refs and all(target in refs for target in dep.get("dependsOn", []))
    for dep in bom["dependencies"]
)
PY
    then
        pass "complete mode is pinned, provenance-rich, resolved, and non-vacuous"
    else
        fail "complete mode output violates its CycloneDX release profile"
    fi
else
    fail "complete mode failed with working pinned tool fixtures"
fi

fallback_bom="$contract_dir/fallback.cdx.json"
if run_generator fallback "$fallback_bom" >/dev/null \
        && python3 - "$fallback_bom" <<'PY'
import json
import pathlib
import sys

bom = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
names = {item.get("name") for item in bom["components"]}
properties = {
    item["name"]: item["value"]
    for item in bom["metadata"]["component"]["properties"]
}
assert "serde" in names and "Qt6Core" not in names
assert properties["edgehub:sbom:scan-mode"] == "fallback"
assert properties["edgehub:sbom:syft-version"] == "not-installed"
PY
then
    pass "fallback remains explicit while retaining Cargo and exact-byte inventory"
else
    fail "fallback mode is not explicit or lost required inventory"
fi

if run_generator fallback "$contract_dir/wrong-digest.cdx.json" \
        0000000000000000000000000000000000000000000000000000000000000000 \
        >/dev/null 2>&1; then
    fail "generator accepted a path that differed from its immutable digest"
else
    pass "generator rejects artifact identity mismatch before scanning"
fi

touch "$fake_bin/cargo-vacuous"
if run_generator fallback "$contract_dir/vacuous.cdx.json" >/dev/null 2>&1; then
    fail "generator accepted a vacuous Cargo inventory"
else
    pass "Cargo inventory anti-vacuity floor is enforced"
fi
rm -f "$fake_bin/cargo-vacuous"

touch "$fake_bin/cargo-bad-graph"
if run_generator fallback "$contract_dir/bad-graph.cdx.json" >/dev/null 2>&1; then
    fail "generator accepted an unresolved CycloneDX graph"
else
    pass "unresolved CycloneDX graph references are rejected"
fi
rm -f "$fake_bin/cargo-bad-graph"

touch "$fake_bin/syft-fail"
if run_generator complete "$contract_dir/syft-failure.cdx.json" >/dev/null 2>&1; then
    fail "complete mode accepted a failed Syft inventory"
else
    pass "complete mode fails closed when Syft fails"
fi
rm -f "$fake_bin/syft-fail"

touch "$fake_bin/cargo-fail"
if run_generator fallback "$contract_dir/cargo-failure.cdx.json" >/dev/null 2>&1; then
    fail "fallback accepted a failed Cargo inventory"
else
    pass "all modes fail closed when Cargo inventory fails"
fi
rm -f "$fake_bin/cargo-fail"

echo "==> Exact publication path contract"
exact_dir="$contract_dir/exact"
mkdir "$exact_dir"
printf 'one\n' >"$exact_dir/one.tar.gz"
printf 'two\n' >"$exact_dir/two.deb"
if python3 "$PATH_TOOL" assert-directory "$exact_dir" \
        one.tar.gz two.deb; then
    pass "exact regular publication set is accepted"
else
    fail "exact regular publication set was rejected"
fi
printf 'injected\n' >"$exact_dir/injected.rpm"
if python3 "$PATH_TOOL" assert-directory "$exact_dir" \
        one.tar.gz two.deb >/dev/null 2>&1; then
    fail "unexpected injected publication file was accepted"
else
    pass "unexpected publication file is rejected"
fi
rm "$exact_dir/injected.rpm"
ln -s one.tar.gz "$exact_dir/link.AppImage"
if python3 "$PATH_TOOL" assert-directory "$exact_dir" \
        one.tar.gz two.deb link.AppImage >/dev/null 2>&1; then
    fail "symlinked publication entry was accepted"
else
    pass "symlinked publication entry is rejected"
fi

echo "==> Exact origin annotated-tag contract"
remote_repo="$contract_dir/remote.git"
local_repo="$contract_dir/local"
git init --bare -q "$remote_repo"
git init -q "$local_repo"
git -C "$local_repo" config user.name "Release Contract"
git -C "$local_repo" config user.email "release-contract@example.invalid"
printf 'candidate\n' >"$local_repo/candidate.txt"
git -C "$local_repo" add candidate.txt
git -C "$local_repo" commit -qm "candidate"
candidate_commit="$(git -C "$local_repo" rev-parse HEAD)"
git -C "$local_repo" -c tag.gpgSign=false tag -a v1.0.0 -m v1.0.0
pinned_tag_object="$(git -C "$local_repo" rev-parse refs/tags/v1.0.0)"
git -C "$local_repo" remote add origin "$remote_repo"
git -C "$local_repo" push -q origin refs/tags/v1.0.0

if xeneon_verify_origin_tag_exact \
        "$local_repo" v1.0.0 "$candidate_commit" "$pinned_tag_object"; then
    pass "pinned annotated tag object and peeled commit are accepted"
else
    fail "exact pinned annotated origin tag was rejected"
fi

git -C "$local_repo" -c tag.gpgSign=false \
    tag -a replacement -m replacement "$candidate_commit"
git -C "$local_repo" push -q --force origin \
    refs/tags/replacement:refs/tags/v1.0.0
if xeneon_verify_origin_tag_exact \
        "$local_repo" v1.0.0 "$candidate_commit" "$pinned_tag_object" \
        >/dev/null 2>&1; then
    fail "remote tag-object substitution pointing to the same commit was accepted"
else
    pass "remote tag-object substitution is rejected"
fi

git -C "$remote_repo" update-ref refs/tags/v1.0.0 "$pinned_tag_object"
git -C "$local_repo" -c tag.gpgSign=false \
    tag -f -a v1.0.0 -m moved "$candidate_commit" >/dev/null
if xeneon_verify_origin_tag_exact \
        "$local_repo" v1.0.0 "$candidate_commit" "$pinned_tag_object" \
        >/dev/null 2>&1; then
    fail "moved local tag was accepted against a pinned remote object"
else
    pass "local tag movement after signer verification is rejected"
fi

git -C "$local_repo" remote set-url origin \
    git@github.com:skyphoenix-it/skyphoenix-edgehub-linux.git
git -C "$local_repo" remote set-url --push origin \
    git@github.com:skyphoenix-it/skyphoenix-edgehub-linux.git
if xeneon_origin_matches_github_repo "$local_repo" \
        skyphoenix-it/skyphoenix-edgehub-linux; then
    pass "pinned GitHub fetch and push origin is accepted"
else
    fail "pinned GitHub origin was rejected"
fi

credential_sentinel="credential-sentinel-must-not-leak"
git -C "$local_repo" remote set-url origin \
    "https://${credential_sentinel}@github.com/skyphoenix-it/skyphoenix-edgehub-linux.git"
git -C "$local_repo" remote set-url --push origin \
    git@github.com:skyphoenix-it/skyphoenix-edgehub-linux.git
if origin_output="$(xeneon_origin_matches_github_repo "$local_repo" \
        skyphoenix-it/skyphoenix-edgehub-linux 2>&1)"; then
    fail "credential-bearing fetch origin was accepted"
elif grep -Fq "$credential_sentinel" <<<"$origin_output"; then
    fail "fetch-origin refusal leaked credential-bearing URL text"
else
    pass "credential-bearing fetch origin is rejected without echoing it"
fi

git -C "$local_repo" remote set-url origin \
    git@github.com:skyphoenix-it/skyphoenix-edgehub-linux.git
git -C "$local_repo" remote set-url --push origin \
    "https://${credential_sentinel}@github.com/skyphoenix-it/skyphoenix-edgehub-linux.git"
if origin_output="$(xeneon_origin_matches_github_repo "$local_repo" \
        skyphoenix-it/skyphoenix-edgehub-linux 2>&1)"; then
    fail "credential-bearing push origin was accepted"
elif grep -Fq "$credential_sentinel" <<<"$origin_output"; then
    fail "push-origin refusal leaked credential-bearing URL text"
else
    pass "credential-bearing push origin is rejected without echoing it"
fi

echo "==> release.sh exact signed-set contract"
if grep -Fq 'assert_dist_exact "${PUBLICATION_NAMES[@]}"' "$RELEASE_SCRIPT" \
        && grep -Fq 'release_files+=("dist/$(basename -- "$publication_path")")' \
            "$RELEASE_SCRIPT" \
        && ! grep -Eq 'sha256sum[[:space:]]+[.]/[*]|release_files.*find' \
            "$RELEASE_SCRIPT"; then
    pass "checksums and uploads derive from exact ledgers, never directory globs"
else
    fail "release publication still admits files outside the exact ledger"
fi

if grep -Fq 'git -C "$REPO_DIR" cat-file blob "$release_notes_blob"' \
        "$RELEASE_SCRIPT" \
        && grep -Fq -- '--notes-file dist/RELEASE_NOTES.md' "$RELEASE_SCRIPT"; then
    pass "GitHub notes are materialized from and tied to the signed tag blob"
else
    fail "mutable checkout notes can reach the GitHub release"
fi

if grep -Fq 'RELEASE_CERTIFICATION_EVIDENCE.json' "$RELEASE_SCRIPT" \
        && grep -Fq 'skyphoenix-edgehub-release-certification-pointer/v1' \
            "$RELEASE_SCRIPT" \
        && grep -Fq 'RELEASE_CERTIFICATION_RECEIPT_SHA256' "$RELEASE_SCRIPT" \
        && grep -Fq '"release_certification": (' "$RELEASE_SCRIPT"; then
    pass "stable signed set and provenance bind the exact certification receipt"
else
    fail "stable release provenance omits the signed publication-gate receipt"
fi

if [ "$(grep -Fc 'verify_release_tag_identity "$VERSION" "$tag_object"' \
        "$RELEASE_SCRIPT")" -ge 3 ] \
        && [ "$(grep -Fc '"$REPO_DIR" "$VERSION" "$head_commit" "$tag_object"' \
            "$RELEASE_SCRIPT")" -ge 3 ]; then
    pass "tag object and pinned signer are rechecked through publication"
else
    fail "tag object or signer is not repeatedly pinned through publication"
fi

if grep -Fq 'gh attestation verify "$artifact"' "$RELEASE_SCRIPT" \
        && grep -Fq -- '--source-digest "$head_commit"' "$RELEASE_SCRIPT" \
        && grep -Fq 'validate_release_extra.sh' "$RELEASE_SCRIPT"; then
    pass "extra parsers execute only behind exact-commit workflow provenance"
else
    fail "extra artifact parser boundary is missing exact native provenance"
fi

if grep -Fq 'gh run view "${run_url##*/}"' "$RELEASE_SCRIPT" \
        && grep -Fq '"AppImage smoke (bare container, no Qt)"' "$RELEASE_SCRIPT" \
        && grep -Fq '"appimage_runtime_smoke_required": kind == "appimage"' \
            "$RELEASE_SCRIPT" \
        && grep -Fq 'skyphoenix-edgehub-release-provenance/v5' \
            "$RELEASE_SCRIPT" \
        && grep -Fq 'appimage_attestation.get("sha256") != candidate_hash' \
            "$PROJECT_DIR/scripts/promote_stable_release.sh"; then
    pass "AppImage publication is bound to a successful exact-commit runtime-smoke job"
else
    fail "AppImage provenance does not bind the exact runtime-smoke job"
fi

if grep -Fq 'cyclonedx-json@1.5=' "$GENERATOR" \
        && grep -Fq 'EXPECTED_CARGO_CYCLONEDX_VERSION="0.5.9"' "$GENERATOR" \
        && grep -Fq 'EXPECTED_SYFT_VERSION="1.46.0"' "$GENERATOR" \
        && grep -Fq 'timeout 300 syft scan' "$GENERATOR"; then
    pass "SBOM format, toolchain, and scanner timeout are pinned"
else
    fail "SBOM generation is not version and time bounded"
fi

echo
if [ "$failures" -ne 0 ]; then
    printf 'RESULT: FAILURE (%d release provenance contract check(s))\n' "$failures"
    exit 1
fi
echo "RESULT: SUCCESS"
