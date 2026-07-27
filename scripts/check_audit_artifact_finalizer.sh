#!/usr/bin/env bash
# Focused execution-level contract for finalize_audit_artifacts.sh.
#
# The test uses a disposable Git repository so it can prove clean/dirty-tree
# behavior without mutating the developer's current worktree.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
finalizer="$project_dir/scripts/finalize_audit_artifacts.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/xeneon-audit-finalizer.XXXXXX")"
fixture_repo="$fixture_root/repo"
failures=0
writer_pid=""
finalizer_pid=""

cleanup() {
    if [ -n "$writer_pid" ] && kill -0 "$writer_pid" 2>/dev/null; then
        kill "$writer_pid" 2>/dev/null || true
        wait "$writer_pid" 2>/dev/null || true
    fi
    if [ -n "$finalizer_pid" ] && kill -0 "$finalizer_pid" 2>/dev/null; then
        kill "$finalizer_pid" 2>/dev/null || true
        wait "$finalizer_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT HUP INT TERM

pass() {
    printf '  ok   %s\n' "$1"
}

fail() {
    printf '  FAIL %s\n' "$1"
    failures=$((failures + 1))
}

expect_success() {
    local label="$1"
    shift
    if output="$("$@" 2>&1)"; then
        pass "$label"
    else
        fail "$label"
        printf '%s\n' "$output" | sed 's/^/       /'
    fi
}

expect_failure_containing() {
    local label="$1"
    local expected="$2"
    shift 2
    if output="$("$@" 2>&1)"; then
        fail "$label (unexpected success)"
    elif grep -Fq -- "$expected" <<< "$output"; then
        pass "$label"
    else
        fail "$label (wrong refusal)"
        printf '%s\n' "$output" | sed 's/^/       /'
    fi
}

echo "==> Audit artifact finalizer contract"

mkdir -p "$fixture_repo/scripts/lib"
cp -- "$finalizer" "$fixture_repo/scripts/finalize_audit_artifacts.sh"
cp -- "$project_dir/scripts/lib/audit_artifact_manifest.py" \
    "$fixture_repo/scripts/lib/audit_artifact_manifest.py"
cp -- "$project_dir/scripts/lib/audit_artifact_contract.py" \
    "$fixture_repo/scripts/lib/audit_artifact_contract.py"
cp -- "$project_dir/scripts/lib/manual_touch_result.py" \
    "$fixture_repo/scripts/lib/manual_touch_result.py"
cp -- "$project_dir/scripts/lib/release_origin.sh" \
    "$fixture_repo/scripts/lib/release_origin.sh"
printf 'artifacts/\n' > "$fixture_repo/.gitignore"
printf 'tracked anchor\n' > "$fixture_repo/tracked.txt"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name "Audit Contract"
git -C "$fixture_repo" config user.email "audit-contract@example.invalid"
git -C "$fixture_repo" remote add origin \
    https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
git -C "$fixture_repo" add \
    .gitignore \
    tracked.txt \
    scripts/finalize_audit_artifacts.sh \
    scripts/lib/audit_artifact_manifest.py \
    scripts/lib/audit_artifact_contract.py \
    scripts/lib/manual_touch_result.py \
    scripts/lib/release_origin.sh
git -C "$fixture_repo" commit -qm "test: create finalizer fixture"

fixture_gnupg="$fixture_root/gnupg"
mkdir -m 0700 "$fixture_gnupg"
GNUPGHOME="$fixture_gnupg" gpg --batch --quiet --passphrase '' \
    --quick-generate-key "Audit Contract <audit@example.invalid>" \
    ed25519 sign 1d
fixture_key="$(GNUPGHOME="$fixture_gnupg" gpg --with-colons --list-keys \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
[ "${#fixture_key}" -eq 40 ] || {
    echo "FAIL could not create the fixture signing key"
    exit 1
}
python3 - "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$fixture_key" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
if text.count(old) != 1:
    raise SystemExit("fixture could not pin its generated signing key")
path.write_text(text.replace(old, sys.argv[2]), encoding="utf-8")
PY
git -C "$fixture_repo" add scripts/finalize_audit_artifacts.sh
git -C "$fixture_repo" commit -qm "test: pin fixture audit key"

full_head="$(git -C "$fixture_repo" rev-parse HEAD)"
artifact_dir="$fixture_repo/artifacts/$full_head/audit-contract"
mkdir -p "$artifact_dir/nested"
printf 'alpha\n' > "$artifact_dir/a-first.txt"
printf 'middle\n' > "$artifact_dir/nested/middle.txt"
printf 'omega\n' > "$artifact_dir/z-last.txt"

optional_tool_stubs="$fixture_root/optional-tool-stubs"
mkdir -p "$optional_tool_stubs"
printf '#!/usr/bin/env bash\nexit 99\n' > "$optional_tool_stubs/lsof"
printf '#!/usr/bin/env bash\nexit 99\n' > "$optional_tool_stubs/fuser"
chmod +x "$optional_tool_stubs/lsof" "$optional_tool_stubs/fuser"

finalize_run() {
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$artifact_dir"
}

verify_run() {
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
            --verify --commit "$full_head" "$artifact_dir"
}

clear_seal() {
    rm -f -- \
        "$artifact_dir/MANIFEST.sha256" \
        "$artifact_dir/MANIFEST.sha256.asc" \
        "$artifact_dir/PROVENANCE.json"
}

git -C "$fixture_repo" remote set-url origin \
    "https://credential-that-must-not-leak@github.com/skyphoenix-it/skyphoenix-edgehub-linux.git"
if output="$(finalize_run 2>&1)"; then
    fail "credential-bearing origin is refused (unexpected success)"
elif grep -Fq "credential-that-must-not-leak" <<<"$output"; then
    fail "credential-bearing origin refusal leaked the raw remote URL"
elif grep -Fq "canonical GitHub repository" <<<"$output"; then
    pass "credential-bearing origin is refused without leaking the remote URL"
else
    fail "credential-bearing origin caused the wrong refusal"
    printf '%s\n' "$output" | sed 's/^/       /'
fi
git -C "$fixture_repo" remote set-url origin \
    https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git

if [ ! -e "$artifact_dir/PROVENANCE.json" ] \
        && [ ! -e "$artifact_dir/MANIFEST.sha256" ] \
        && [ ! -e "$artifact_dir/MANIFEST.sha256.asc" ]; then
    pass "fresh-finalize fixture starts without seal files"
else
    fail "fresh-finalize fixture unexpectedly contains seal files"
fi
expect_success "fresh evidence finalizes without optional lsof/fuser packages" \
    env PATH="$optional_tool_stubs:$PATH" GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$artifact_dir"
expect_success "freshly finalized evidence verifies" \
    verify_run

ln -s artifacts "$fixture_repo/artifacts-link"
expect_failure_containing "symlinked artifact-root path is refused" \
    "symlink component" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
            --verify --commit "$full_head" \
            "$fixture_repo/artifacts-link/$full_head/audit-contract"
rm -f -- "$fixture_repo/artifacts-link"

if grep -Fq 'os.fsync(descriptor)' \
        "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
        && grep -Fq 'sync_directory "$artifact_dir"' \
            "$fixture_repo/scripts/finalize_audit_artifacts.sh"; then
    pass "manifest publication fsyncs the artifact directory"
else
    fail "manifest publication is not directory-durable"
fi

manifest="$artifact_dir/MANIFEST.sha256"
signature="$artifact_dir/MANIFEST.sha256.asc"
provenance="$artifact_dir/PROVENANCE.json"
if python3 - "$provenance" "$full_head" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert document["schema"] == "skyphoenix-edgehub-audit-provenance/v2"
assert document["source_commit"] == sys.argv[2]
assert document["source"] == {
    "host": "github.com",
    "repository": "skyphoenix-it/skyphoenix-edgehub-linux",
}
assert "source_origin" not in document
assert "@" not in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
PY
then
    pass "provenance retains canonical source identity without a raw remote URL"
else
    fail "provenance source identity is not credential-safe and canonical"
fi
if [ -f "$manifest" ] && [ -f "$signature" ] \
        && [ "$(wc -l < "$manifest")" -eq 4 ]; then
    pass "manifest contains every evidence file"
else
    fail "signed manifest file count is not exactly four"
fi

manifest_paths="$(sed -nE 's/^[0-9a-f]{64}  //p' "$manifest")"
expected_paths="$(printf '%s\n' \
    './PROVENANCE.json' \
    './a-first.txt' \
    './nested/middle.txt' \
    './z-last.txt')"
if [ "$manifest_paths" = "$expected_paths" ]; then
    pass "manifest is stable and sorted by relative path"
else
    fail "manifest paths are not in stable relative-path order"
    printf '%s\n' "$manifest_paths" | sed 's/^/       /'
fi

provenance_backup="$fixture_root/PROVENANCE.json.saved"
cp -- "$provenance" "$provenance_backup"
python3 - "$provenance" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["schema"] = "skyphoenix-edgehub-audit-provenance/v999"
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_failure_containing "invalid provenance schema is rejected semantically" \
    "PROVENANCE.json schema must be exactly" \
    verify_run
cp -- "$provenance_backup" "$provenance"

python3 - "$provenance" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["artifact_path"] = "artifacts/0000000000000000000000000000000000000000/wrong"
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_failure_containing "wrong provenance artifact path is rejected semantically" \
    "artifact_path is not the exact artifact path" \
    verify_run
cp -- "$provenance_backup" "$provenance"
expect_success "restored provenance still verifies against the signed manifest" \
    verify_run

python3 - "$provenance" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["finalizer_sha256"] = "f" * 64
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_failure_containing "plausible but wrong finalizer digest is rejected" \
    "does not match the exact source commit finalizer" \
    verify_run
cp -- "$provenance_backup" "$provenance"
expect_success "provenance verifies after restoring the exact finalizer digest" \
    verify_run

if grep -Eq 'MANIFEST[.]sha256|audit-finalization[.]lock|audit-manifest[.]tmp|audit-signature[.]tmp' "$manifest"; then
    fail "manifest includes one of the finalizer's internal entries"
else
    pass "manifest excludes only its own manifest, lock, and temp entries"
fi

wrong_head="$full_head"
case "${wrong_head:0:1}" in
    0) wrong_head="1${wrong_head:1}" ;;
    *) wrong_head="0${wrong_head:1}" ;;
esac
mkdir -p "$fixture_repo/artifacts/$wrong_head/wrong-run"
expect_failure_containing "wrong commit-keyed directory is refused" \
    "artifact directory must be keyed by full commit" \
    bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
        "artifacts/$wrong_head/wrong-run"

printf 'dirty anchor\n' > "$fixture_repo/tracked.txt"
expect_failure_containing "dirty worktree is refused" \
    "working tree is not clean" \
    finalize_run
printf 'tracked anchor\n' > "$fixture_repo/tracked.txt"

clear_seal
writer_ready="$fixture_root/writer-ready"
bash -c '
    exec 9>>"$1"
    : > "$2"
    while :; do sleep 1 9>&-; done
' _ "$artifact_dir/a-first.txt" "$writer_ready" &
writer_pid=$!
for _ in $(seq 1 100); do
    [ -e "$writer_ready" ] && break
    sleep 0.02
done
if [ ! -e "$writer_ready" ]; then
    fail "open-writer fixture did not become ready"
else
    expect_failure_containing "evidence open for writing is refused" \
        "still open for writing" \
        finalize_run
fi
kill "$writer_pid" 2>/dev/null || true
wait "$writer_pid" 2>/dev/null || true
writer_pid=""

expect_success "finalization succeeds after the writer closes" \
    finalize_run
printf 'tampered\n' >> "$artifact_dir/nested/middle.txt"
expect_failure_containing "post-finalization tampering is detected" \
    "does not match the finalized SHA-256 manifest" \
    verify_run

printf 'middle\n' > "$artifact_dir/nested/middle.txt"
clear_seal
printf 'unfinished\n' > "$artifact_dir/capture.tmp"
expect_failure_containing "leftover user transient file is refused" \
    "leftover user transient file" \
    finalize_run
rm -f -- "$artifact_dir/capture.tmp"

chmod g+w "$artifact_dir/a-first.txt"
expect_failure_containing "group-writable evidence is refused" \
    "group/other-writable artifact entry" \
    finalize_run
chmod g-w "$artifact_dir/a-first.txt"

primary_group="$(id -g)"
alternative_group=""
if [ "$(id -u)" -eq 0 ]; then
    chown 1:"$primary_group" "$artifact_dir/a-first.txt"
    alternative_group="$primary_group"
else
    for candidate_group in $(id -G); do
        if [ "$candidate_group" != "$primary_group" ]; then
            alternative_group="$candidate_group"
            break
        fi
    done
    if [ -n "$alternative_group" ]; then
        chgrp "$alternative_group" "$artifact_dir/a-first.txt"
    fi
fi
if [ -n "$alternative_group" ]; then
    expect_failure_containing "unsafe evidence ownership is refused" \
        "unsafe ownership" \
        finalize_run
    if [ "$(id -u)" -eq 0 ]; then
        chown 0:"$primary_group" "$artifact_dir/a-first.txt"
    else
        chgrp "$primary_group" "$artifact_dir/a-first.txt"
    fi
else
    fail "test user has no alternate ownership identity for the unsafe-owner contract"
fi

ambiguous_name=$'bad\nname.txt'
printf 'ambiguous\n' > "$artifact_dir/$ambiguous_name"
expect_failure_containing "ambiguous evidence filename is refused" \
    "ambiguous control character" \
    finalize_run
rm -f -- "$artifact_dir/$ambiguous_name"

ln "$artifact_dir/a-first.txt" "$artifact_dir/hardlink.txt"
expect_failure_containing "multiply-linked evidence is refused" \
    "multiply-linked artifact file" \
    finalize_run
rm -f -- "$artifact_dir/hardlink.txt"

ln -s "a-first.txt" "$artifact_dir/symlink.txt"
expect_failure_containing "symlink evidence is refused" \
    "symlink or special artifact entry" \
    finalize_run
rm -f -- "$artifact_dir/symlink.txt"

release_run_id="release-gate-20260726T000000Z-123"
release_artifact="$fixture_repo/artifacts/$full_head/$release_run_id"
mkdir -p "$release_artifact"
printf 'release evidence\n' >"$release_artifact/evidence.txt"
expect_failure_containing "release evidence without mandatory records cannot seal" \
    "required release record is unavailable" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$release_artifact"

create_release_records() {
    PYTHONDONTWRITEBYTECODE=1 python3 \
        "$project_dir/tests/runtime/release_run_fixture.py" \
        --artifact-dir "$release_artifact" \
        --commit "$full_head" \
        --run-id "$release_run_id"
}

create_release_records
rm -f -- "$release_artifact/performance/rotation-frame/report.json"
expect_failure_containing "release evidence without rotation timing cannot seal" \
    "required retained release evidence is unavailable" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$release_artifact"
create_release_records
python3 - "$release_artifact/RUN.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["schema"] = "skyphoenix-edgehub-release-gate-run/v999"
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_failure_containing "release evidence with a wrong RUN schema cannot seal" \
    "RUN.json schema must be exactly" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$release_artifact"
create_release_records
expect_success "complete consistent release-gate records can seal" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$release_artifact"
expect_success "sealed release-gate records verify semantically" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
            --verify --commit "$full_head" "$release_artifact"

wait_for_read_lease() {
    python3 - "$1" <<'PY'
import os
import sys
import time

metadata = os.stat(sys.argv[1])
key = f"{os.major(metadata.st_dev):02x}:{os.minor(metadata.st_dev):02x}:{metadata.st_ino}"
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    with open("/proc/locks", encoding="ascii") as locks:
        if any(
            "LEASE" in line and " READ " in line and f" {key} " in line
            for line in locks
        ):
            sys.exit(0)
    time.sleep(0.005)
print(f"read lease did not appear for {key}", file=sys.stderr)
sys.exit(1)
PY
}

race_file="$artifact_dir/race.bin"
truncate -s 1G "$race_file"
race_log="$fixture_root/racing-writer.log"
finalize_run >"$race_log" 2>&1 &
finalizer_pid=$!
if wait_for_read_lease "$race_file"; then
    writer_ready="$fixture_root/race-writer-ready"
    bash -c '
        exec 9>>"$1"
        : > "$2"
        while :; do sleep 1 9>&-; done
    ' _ "$race_file" "$writer_ready" &
    writer_pid=$!
    if wait "$finalizer_pid"; then
        fail "writer racing lease-held hashing was accepted"
    elif grep -Eq 'writer raced|broke the hash lease' "$race_log"; then
        pass "writer racing lease-held hashing is refused"
    else
        fail "racing writer caused the wrong refusal"
        sed 's/^/       /' "$race_log"
    fi
    finalizer_pid=""
    kill "$writer_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
    writer_pid=""
else
    fail "could not observe the hash-time read lease"
    kill "$finalizer_pid" 2>/dev/null || true
    wait "$finalizer_pid" 2>/dev/null || true
    finalizer_pid=""
fi

clear_seal
replacement="$fixture_root/replacement.bin"
truncate -s 1G "$race_file"
printf 'replacement\n' > "$replacement"
replacement_log="$fixture_root/path-replacement.log"
finalize_run >"$replacement_log" 2>&1 &
finalizer_pid=$!
if wait_for_read_lease "$race_file"; then
    mv -f -- "$replacement" "$race_file"
    if wait "$finalizer_pid"; then
        fail "closed-writer path replacement during hashing was accepted"
    elif grep -Eq 'tree changed during hashing|inode metadata changed' \
            "$replacement_log"; then
        pass "closed-writer path replacement during hashing is refused"
    else
        fail "path replacement caused the wrong refusal"
        sed 's/^/       /' "$replacement_log"
    fi
    finalizer_pid=""
else
    fail "could not observe the replacement-race read lease"
    kill "$finalizer_pid" 2>/dev/null || true
    wait "$finalizer_pid" 2>/dev/null || true
    finalizer_pid=""
fi

clear_seal
expect_success "final evidence state can be signed after race refusals" finalize_run
printf 'historical verifier anchor\n' >>"$fixture_repo/tracked.txt"
git -C "$fixture_repo" add tracked.txt
git -C "$fixture_repo" commit -qm "test: move HEAD beyond evidence commit"
expect_success "historical signed evidence verifies independently of HEAD" \
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
            --verify --commit "$full_head" "$artifact_dir"

if [ "$failures" -ne 0 ]; then
    printf '\nRESULT: FAILURE (%d contract checks failed)\n' "$failures"
    exit 1
fi
printf '\nRESULT: PASS\n'
