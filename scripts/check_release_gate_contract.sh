#!/usr/bin/env bash
# Fast, execution-level contract tests for the release gate itself. This never
# launches a GUI, compositor, hardware injector, build, or coverage process.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OWNER_RUNNER="$PROJECT_DIR/scripts/run_owner_key_release_test.sh"
CPP_RUNNER="$PROJECT_DIR/scripts/run_cpp_tests.sh"
COVERAGE_RUNNER="$PROJECT_DIR/scripts/coverage.sh"
MANAGER_RUNNER="$PROJECT_DIR/scripts/run_manager_tests.sh"
HARDWARE_PYTHON_RUNNER="$PROJECT_DIR/scripts/run_hardware_python.py"
QML_DIAGNOSTIC_CHECKER="$PROJECT_DIR/scripts/check_qml_diagnostics.sh"
GUI_RUNNER="$PROJECT_DIR/tests/gui/run_gui_tests.sh"
BUILDUP_RUNNER="$PROJECT_DIR/tests/hardware/e2e_buildup.py"
PERFORMANCE_RUNNER="$PROJECT_DIR/tests/performance/run_hub_profiles.py"
PERFORMANCE_AUDIT="$PROJECT_DIR/tests/performance/run_audit_14_widget_30m.py"
PERFORMANCE_PREPARE="$PROJECT_DIR/tests/performance/prepare_release_candidate.sh"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/release.sh"
STRICT_RUNNER="$PROJECT_DIR/scripts/run_release_tests.sh"
SOURCE_TRACKER="$PROJECT_DIR/scripts/check_tracked_source_inputs.py"
RELEASE_MANIFEST_CHECKER="$PROJECT_DIR/scripts/check_release_manifest_contract.py"
OWNER_LICENSE_READER="$PROJECT_DIR/scripts/lib/owner_license_file.py"
RELEASE_RUST_TOOLCHAIN_HELPER="$PROJECT_DIR/scripts/lib/release_rust_toolchain.sh"
RELEASE_NOTES_CHECKER="$PROJECT_DIR/scripts/lib/release_notes_contract.py"
RELEASE_CERTIFICATION_VERIFIER="$PROJECT_DIR/scripts/verify_release_certification.sh"
RELEASE_CERTIFICATION_CONTRACT="$PROJECT_DIR/scripts/check_release_certification_contract.sh"
# shellcheck source=lib/release_gate.sh
. "$PROJECT_DIR/scripts/lib/release_gate.sh"
# shellcheck source=lib/release_sequence.sh
. "$PROJECT_DIR/scripts/lib/release_sequence.sh"
# shellcheck source=lib/qml_test_result.sh
. "$PROJECT_DIR/scripts/lib/qml_test_result.sh"

fail=0
check() {
    local label="$1"; shift
    if "$@"; then
        printf '  ok   %s\n' "$label"
    else
        printf '  FAIL %s\n' "$label"
        fail=$((fail + 1))
    fi
}

accepts() { XENEON_RELEASE_GATE="$1" xeneon_gate_accepts_result "$2"; }
rejects() { ! accepts "$1" "$2"; }
rejects_release_version() { ! xeneon_release_version_is_valid "$1"; }

echo "==> Release-gate result policy"
check "developer pass accepted" accepts 0 PASS
check "developer optional result accepted" accepts 0 SKIP
check "developer compatibility result accepted" accepts 0 KNOWN-RED
check "developer failure rejected" rejects 0 FAIL
check "release pass accepted" accepts 1 PASS
check "release optional result rejected" rejects 1 SKIP
check "release compatibility result rejected" rejects 1 KNOWN-RED
check "release failure rejected" rejects 1 FAIL
check "unknown result rejected" rejects 1 UNRECOGNISED
if XENEON_RELEASE_GATE=invalid xeneon_release_gate_init >/dev/null 2>&1; then
    echo "  FAIL invalid gate mode was accepted"; fail=$((fail + 1))
else
    echo "  ok   invalid gate mode is rejected"
fi

echo "==> Release version grammar"
for valid_version in v0.1.0 v1.0.0 v1.0.0-alpha.2 v2.3.4-beta.10 v9.8.7-rc.1; do
    check "valid release version accepted: $valid_version" \
        xeneon_release_version_is_valid "$valid_version"
done
for invalid_version in 1.0.0 v1 v1.0 v01.0.0 v1.00.0 v1.0.00 \
        v1.0.0-alpha v1.0.0-alpha.01 v1.0.0-preview.1 vgarbage \
        v1.0.0-alpha.1-extra; do
    check "invalid release version rejected: $invalid_version" \
        rejects_release_version "$invalid_version"
done
if grep -Fq 'xeneon_release_version_is_valid "$VERSION"' "$RELEASE_SCRIPT"; then
    echo "  ok   release.sh enforces the tested anchored version grammar"
else
    echo "  FAIL release.sh does not call the tested version validator"
    fail=$((fail + 1))
fi

echo "==> Tracked release-source inputs"
source_fixture="$(mktemp -d "${TMPDIR:-/tmp}/xe-source-input.XXXXXX")"
source_clone="${source_fixture}-clone"
mkdir -p "$source_fixture/app/src"
printf 'app/src/ui_hidden.h\n' >"$source_fixture/.gitignore"
printf 'add_executable(fixture app/src/ui_hidden.h)\n' \
    >"$source_fixture/CMakeLists.txt"
git -C "$source_fixture" init -q
git -C "$source_fixture" config user.name "Source Input Contract"
git -C "$source_fixture" config user.email "source-input@example.invalid"
git -C "$source_fixture" add .gitignore CMakeLists.txt
git -C "$source_fixture" -c commit.gpgSign=false commit -qm fixture
printf '#pragma once\n' >"$source_fixture/app/src/ui_hidden.h"
if [ -n "$(git -C "$source_fixture" status --porcelain=v1 --untracked-files=all)" ]; then
    echo "  FAIL fixture did not hide the ignored source input"
    fail=$((fail + 1))
elif env PYTHONDONTWRITEBYTECODE=1 python3 "$SOURCE_TRACKER" \
        --repo "$source_fixture" >/dev/null 2>&1; then
    echo "  FAIL ignored CMake-listed source input was accepted"
    fail=$((fail + 1))
else
    echo "  ok   ignored CMake-listed source input is rejected"
fi
git -C "$source_fixture" add -f app/src/ui_hidden.h
git -C "$source_fixture" -c commit.gpgSign=false commit -qm "track source"
git clone -q "$source_fixture" "$source_clone"
check "clean clone contains only tracked source inputs" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$SOURCE_TRACKER" \
        --repo "$source_clone"
rm -rf -- "$source_fixture" "$source_clone"
for release_entry in "$RELEASE_SCRIPT" "$STRICT_RUNNER"; do
    if grep -Fq 'check_tracked_source_inputs.py' "$release_entry"; then
        echo "  ok   $(basename "$release_entry") enforces tracked source inputs"
    else
        echo "  FAIL $(basename "$release_entry") does not enforce tracked source inputs"
        fail=$((fail + 1))
    fi
done

echo "==> Exact release-notes contract"
notes_fixture="$(mktemp "${TMPDIR:-/tmp}/xe-release-notes.XXXXXX")"
{
    printf '# EdgeHub v9.8.7\n\n'
    printf 'Release version: `v9.8.7`\n'
    printf 'Release stage: stable\n\n'
    printf '## Highlights\n\nExact candidate.\n\n'
    printf '## Verification summary\n\nPending exact-candidate execution.\n\n'
    printf '## Artifacts\n\n'
    printf '<!-- release-assets:start -->\n'
    printf '%s\n' '- `one.tar.gz`' '- `SHA256SUMS`'
    printf '<!-- release-assets:end -->\n\n'
    printf '## Known limitations\n\nNo endurance claim.\n\n'
    printf '## Verification\n\nVerify the signed checksum file.\n'
} >"$notes_fixture"
check "exact notes version, stage, and asset ledger are accepted" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$RELEASE_NOTES_CHECKER" \
        check "$notes_fixture" v9.8.7 one.tar.gz SHA256SUMS
sed -i '1s/v9.8.7/v9.8.6/' "$notes_fixture"
if env PYTHONDONTWRITEBYTECODE=1 python3 "$RELEASE_NOTES_CHECKER" \
        check "$notes_fixture" v9.8.7 one.tar.gz SHA256SUMS \
        >/dev/null 2>&1; then
    echo "  FAIL stale release heading was accepted"
    fail=$((fail + 1))
else
    echo "  ok   stale release heading is rejected"
fi
sed -i '1s/v9.8.6/v9.8.7/' "$notes_fixture"
if env PYTHONDONTWRITEBYTECODE=1 python3 "$RELEASE_NOTES_CHECKER" \
        check "$notes_fixture" v9.8.7 one.tar.gz SHA256SUMS extra.rpm \
        >/dev/null 2>&1; then
    echo "  FAIL stale release asset ledger was accepted"
    fail=$((fail + 1))
else
    echo "  ok   stale release asset ledger is rejected"
fi
rm -- "$notes_fixture"
notes_contract_line="$(grep -nF \
    'check "$REPO_DIR/RELEASE_NOTES.md" "$VERSION"' "$RELEASE_SCRIPT" \
    | head -1 | cut -d: -f1)"
strict_gate_line="$(grep -nF \
    'bash "$STRICT_RELEASE_GATE" 3<<<"$RELEASE_OWNER_TEST_LICENSE_KEY"' \
    "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$notes_contract_line" ] && [ -n "$strict_gate_line" ] \
        && [ "$notes_contract_line" -lt "$strict_gate_line" ] \
        && grep -Fq 'EXPECTED_NOTES_ASSETS=(' "$RELEASE_SCRIPT"; then
    echo "  ok   release.sh binds final notes to the exact asset ledger before the strict gate"
else
    echo "  FAIL release.sh can run the strict gate with stale version or artifact notes"
    fail=$((fail + 1))
fi
if grep -Fq 'XENEON_RELEASE_METADATA_STAGE=candidate' "$RELEASE_SCRIPT" \
        && grep -Fq 'XENEON_RELEASE_VERSION="$VERSION"' "$RELEASE_SCRIPT" \
        && grep -Fq 'release_metadata_args+=(--stage "$XENEON_RELEASE_METADATA_STAGE")' \
            "$PROJECT_DIR/scripts/run_all_tests.sh" \
        && grep -Fq 'release_metadata_args+=(--target-version "$XENEON_RELEASE_VERSION")' \
            "$PROJECT_DIR/scripts/run_all_tests.sh"; then
    echo "  ok   strict gate binds metadata validation to the exact release version"
else
    echo "  FAIL strict gate can validate development or stale release metadata"
    fail=$((fail + 1))
fi

echo "==> QML result anti-vacuity"
qml_contract_dir="$(mktemp -d "${TMPDIR:-/tmp}/xe-qml-result.XXXXXX")"
: > "$qml_contract_dir/empty.log"
printf 'Totals: 4 passed, 0 failed, 0 skipped, 0 blacklisted, 10ms\n' \
    > "$qml_contract_dir/pass.log"
printf 'Totals: 0 passed, 0 failed, 0 skipped, 0 blacklisted, 1ms\n' \
    > "$qml_contract_dir/zero.log"
check "live QML totals are accepted" xeneon_qml_require_live_totals \
    "$qml_contract_dir/pass.log" contract
if xeneon_qml_require_live_totals "$qml_contract_dir/empty.log" contract >/dev/null 2>&1; then
    echo "  FAIL empty QML output was accepted"; fail=$((fail + 1))
else
    echo "  ok   empty QML output is rejected"
fi
if xeneon_qml_require_live_totals "$qml_contract_dir/zero.log" contract >/dev/null 2>&1; then
    echo "  FAIL zero-pass QML totals were accepted"; fail=$((fail + 1))
else
    echo "  ok   zero-pass QML totals are rejected"
fi
rm -rf "$qml_contract_dir"

echo "==> QML diagnostic classifier"
diagnostic_log="$(mktemp "${TMPDIR:-/tmp}/xe-qml-diagnostic.XXXXXX")"
printf '%s\n' 'file:///tmp/Test.qml:4: TypeError: bad call' > "$diagnostic_log"
if "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier compiled >/dev/null 2>&1; then
    echo "  FAIL unprefixed TypeError was accepted"; fail=$((fail + 1))
else
    echo "  ok   unprefixed TypeError is rejected"
fi
printf '%s\n' \
    'file:///tmp/Test.qml:4: QML Connections: Detected function "onMissingChanged"' \
    > "$diagnostic_log"
if "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier compiled >/dev/null 2>&1; then
    echo "  FAIL unprefixed QML warning was accepted"; fail=$((fail + 1))
else
    echo "  ok   unprefixed QML warning is rejected"
fi
printf '%s\n' \
    'QWARN  : suite::case() qt.qml.propertyCache.append: Member contentWidth of the object PopupList_QMLTYPE_26 overrides a member of the base object. Consider renaming it or adding final or override specifier' \
    > "$diagnostic_log"
if "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier compiled >/dev/null 2>&1; then
    echo "  FAIL removed dependency warning was still allowlisted"; fail=$((fail + 1))
else
    echo "  ok   removed dependency warning is rejected"
fi
printf '%s\n' \
    'QWARN  : suite::case() QUnifiedTimer::stopAnimationDriver: driver is not running' \
    > "$diagnostic_log"
check "exact Qt animation-driver dependency warning is separately dispositioned" \
    "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier compiled

# The Qt < 6.9 SwipeView currentIndex binding loop is dispositioned, but only on
# the versions that have the defect, only for Qt's OWN copy of SwipeView.qml, and
# only when the log says which version produced it. Each of those three limits is
# asserted here, because a disposition nobody can see expiring is how a gate goes
# quietly inert.
swipeview_loop='QWARN  : suite::case() qrc:/qt-project.org/imports/QtQuick/Controls/Basic/SwipeView.qml:15:18: QML ListView: Binding loop detected for property "currentIndex":'
printf '%s\n' \
    'Config: Using QtTest library 6.7.3, Qt 6.7.3 (x86_64-little_endian-lp64)' \
    "$swipeview_loop" > "$diagnostic_log"
check "Qt 6.7 SwipeView currentIndex loop is dispositioned as external" \
    "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier composed
printf '%s\n' \
    'Config: Using QtTest library 6.11.1, Qt 6.11.1 (x86_64-little_endian-lp64)' \
    "$swipeview_loop" > "$diagnostic_log"
if "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier composed >/dev/null 2>&1; then
    echo "  FAIL SwipeView disposition outlived the Qt release that needed it"; fail=$((fail + 1))
else
    echo "  ok   SwipeView disposition expires on Qt 6.9+"
fi
printf '%s\n' \
    'Config: Using QtTest library 6.7.3, Qt 6.7.3 (x86_64-little_endian-lp64)' \
    'QWARN  : suite::case() qrc:/qml/Dashboard.qml:1124:9: QML ListView: Binding loop detected for property "currentIndex":' \
    > "$diagnostic_log"
if "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier composed >/dev/null 2>&1; then
    echo "  FAIL a product-file currentIndex binding loop was excused"; fail=$((fail + 1))
else
    echo "  ok   a product-file currentIndex binding loop still fails"
fi
printf '%s\n' "$swipeview_loop" > "$diagnostic_log"
if "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier composed >/dev/null 2>&1; then
    echo "  FAIL SwipeView loop was excused without a Qt version to justify it"; fail=$((fail + 1))
else
    echo "  ok   SwipeView disposition needs a Qt version in the log"
fi
rm -f "$diagnostic_log"

echo "==> Nested-runner skip detection"
check "zero skipped is accepted" xeneon_run_rejecting_skips \
    bash -c 'echo "Totals: 4 passed, 0 failed, 0 skipped"' >/dev/null 2>&1
if xeneon_run_rejecting_skips bash -c 'echo "SKIP: prerequisite absent"' >/dev/null 2>&1; then
    echo "  FAIL textual omission marker was accepted"; fail=$((fail + 1))
else
    echo "  ok   textual omission marker is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'echo "skipped: prerequisite absent"' >/dev/null 2>&1; then
    echo "  FAIL lowercase omission marker was accepted"; fail=$((fail + 1))
else
    echo "  ok   lowercase omission marker is rejected"
fi
check "benign application wording is accepted" xeneon_run_rejecting_skips \
    bash -c 'echo "Skipped items: none (application message)"' >/dev/null 2>&1
if xeneon_run_rejecting_skips bash -c 'echo "Totals: 3 passed, 0 failed, 1 skipped"' >/dev/null 2>&1; then
    echo "  FAIL QtTest skip count was accepted"; fail=$((fail + 1))
else
    echo "  ok   QtTest skip count is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'echo "test result: ok. 3 passed; 0 failed; 1 ignored"' >/dev/null 2>&1; then
    echo "  FAIL Cargo ignored count was accepted"; fail=$((fail + 1))
else
    echo "  ok   Cargo ignored count is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'echo "The following tests did not run:"' >/dev/null 2>&1; then
    echo "  FAIL CTest non-execution was accepted"; fail=$((fail + 1))
else
    echo "  ok   CTest non-execution is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'echo "Totals: 3 passed, 0 failed, 0 skipped, 1 blacklisted"' >/dev/null 2>&1; then
    echo "  FAIL QtTest blacklist count was accepted"; fail=$((fail + 1))
else
    echo "  ok   QtTest blacklist count is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'echo "XFAIL : known defect"; echo "Totals: 3 passed, 0 failed, 0 skipped"' >/dev/null 2>&1; then
    echo "  FAIL expected failure was accepted"; fail=$((fail + 1))
else
    echo "  ok   expected failure is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'echo "OK (expected failures=1)"' >/dev/null 2>&1; then
    echo "  FAIL unittest expected failure was accepted"; fail=$((fail + 1))
else
    echo "  ok   unittest expected failure is rejected"
fi
if xeneon_run_rejecting_skips bash -c 'exit 7' >/dev/null 2>&1; then
    echo "  FAIL non-zero child status was accepted"; fail=$((fail + 1))
else
    echo "  ok   non-zero child status is preserved"
fi
if XENEON_REAL_CTEST=true "$PROJECT_DIR/scripts/lib/ctest_release_gate.sh" \
        --test-dir /definitely/not/a/build >/dev/null 2>&1; then
    echo "  FAIL non-CTest command override was accepted"; fail=$((fail + 1))
else
    echo "  ok   non-CTest command override is rejected"
fi

echo "==> Release-suite manifest"
check "strict runner and signed audit contract have identical ordered manifests" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$RELEASE_MANIFEST_CHECKER" \
        --repo "$PROJECT_DIR"
manifest_drift_fixture="$(mktemp -d "${TMPDIR:-/tmp}/xe-release-manifest.XXXXXX")"
mkdir -p "$manifest_drift_fixture/scripts/lib"
cp "$STRICT_RUNNER" \
    "$manifest_drift_fixture/scripts/run_release_tests.sh"
cp "$RELEASE_MANIFEST_CHECKER" \
    "$manifest_drift_fixture/scripts/check_release_manifest_contract.py"
cp "$PROJECT_DIR/scripts/lib/audit_artifact_contract.py" \
    "$manifest_drift_fixture/scripts/lib/audit_artifact_contract.py"
sed -i \
    '/run_release_suite "Coverage gates"/i run_release_suite "Undeclared contract suite" 1 true' \
    "$manifest_drift_fixture/scripts/run_release_tests.sh"
if env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$manifest_drift_fixture/scripts/check_release_manifest_contract.py" \
        --repo "$manifest_drift_fixture" >/dev/null 2>&1; then
    echo "  FAIL release manifest checker accepted a runner-only suite"
    fail=$((fail + 1))
else
    echo "  ok   release manifest checker rejects runner-only suite drift"
fi
cp "$STRICT_RUNNER" \
    "$manifest_drift_fixture/scripts/run_release_tests.sh"
sed -i \
    '/preflight_ok "resource-aware QuickTest runner/i preflight_ok "Undeclared preflight row"' \
    "$manifest_drift_fixture/scripts/run_release_tests.sh"
if env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$manifest_drift_fixture/scripts/check_release_manifest_contract.py" \
        --repo "$manifest_drift_fixture" >/dev/null 2>&1; then
    echo "  FAIL release manifest checker accepted a runner-only preflight row"
    fail=$((fail + 1))
else
    echo "  ok   release manifest checker rejects runner-only preflight drift"
fi
rm -rf -- "$manifest_drift_fixture"
release_list="$(bash "$STRICT_RUNNER" --list)" || {
    echo "  FAIL run_release_tests.sh --list failed"
    fail=$((fail + 1))
    release_list=""
}
release_execution="$(sed -n '/^names=()/,$p' "$STRICT_RUNNER" | sed '/^[[:space:]]*#/d')"
release_preflight="$(sed -n '1,/^names=()/p' "$STRICT_RUNNER" | sed '/^[[:space:]]*#/d')"
run_all_execution="$(sed '/^[[:space:]]*#/d' "$PROJECT_DIR/scripts/run_all_tests.sh")"
for required in \
    tests/hardware/edge_e2e.py \
    tests/hardware/e2e_buildup.py \
    tests/hardware/widget_render_matrix.py \
    tests/performance/prepare_release_candidate.sh \
    tests/performance/run_hub_profiles.py \
    tests/performance/run_audit_14_widget_30m.py \
    tools/license-tool/Cargo.toml \
    tools/license-webhook/Cargo.toml \
    scripts/coverage.sh; do
    if printf '%s\n' "$release_list" | grep -Fq "$required"; then
        echo "  ok   $required is release-gated"
    else
        echo "  FAIL $required is absent from the release manifest"
        fail=$((fail + 1))
    fi
done

for required in \
    tests/hardware/edge_e2e.py \
    tests/hardware/e2e_buildup.py \
    tests/hardware/widget_render_matrix.py \
    tests/performance/prepare_release_candidate.sh \
    tests/performance/run_hub_profiles.py \
    tests/performance/run_audit_14_widget_30m.py \
    scripts/run_all_tests.sh \
    scripts/coverage.sh; do
    if printf '%s\n' "$release_execution" | grep -Fq "$required"; then
        echo "  ok   $required has an executable release invocation"
    else
        echo "  FAIL $required is listed but not executed"
        fail=$((fail + 1))
    fi
done
if printf '%s\n' "$release_execution" | grep -Eq 'for tool in license-tool license-webhook'; then
    echo "  ok   both Rust tool crates have executable release invocations"
else
    echo "  FAIL Rust tool execution loop is absent"
    fail=$((fail + 1))
fi

folded_release_runner="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' \
    "$STRICT_RUNNER")"
for critical_guard in \
    'mkdir -m 0700 -p "$AUDIT_ROOT/logs" "$AUDIT_ROOT/work"     || release_die' \
    'printf '\''result\tcheck\n'\'' >"$preflight_record"     || release_die' \
    'cp -a -- "$PROJECT_DIR/gui-evidence" "$AUDIT_ROOT/gui-evidence"         || release_die' \
    'mkdir -m 0700 "$performance_evidence_root"     || release_die' \
    'printf '\''result\tsuite\n'\'' >"$summary_path"     || release_die' \
    '|| release_die "could not publish the complete RUN.json record"' \
    '|| release_die "could not write the machine-readable release-gate result"'; do
    if ! grep -Fq "$critical_guard" <<<"$folded_release_runner"; then
        echo "  FAIL strict runner lacks critical-operation guard: $critical_guard"
        fail=$((fail + 1))
    fi
done

if grep -Fq \
        'release_tmp_root="$(mktemp -d "/tmp/xe-release-${evidence_commit:0:8}.XXXXXX")"' \
        "$STRICT_RUNNER" \
        && grep -Fq 'export TMPDIR="$release_tmp_root"' "$STRICT_RUNNER" \
        && grep -Fq 'trap cleanup_release_tmp_root EXIT' "$STRICT_RUNNER" \
        && ! grep -Fq 'export TMPDIR="$AUDIT_ROOT/work"' "$STRICT_RUNNER"; then
    echo "  ok   strict transient sandboxes use a private short socket-safe path"
else
    echo "  FAIL strict transient sandboxes can exceed the Unix socket path limit"
    fail=$((fail + 1))
fi
if [ "$(grep -Fc 'ffmpeg -nostdin' "$GUI_RUNNER")" -eq 2 ]; then
    echo "  ok   GUI evidence encoding never reads the release terminal"
else
    echo "  FAIL a GUI evidence ffmpeg process can stop on background terminal input"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_preflight" \
        | grep -Fq 'rustup component list --toolchain "$RUSTUP_TOOLCHAIN" --installed' \
        && printf '%s\n' "$release_preflight" \
        | grep -Fq "grep -Eq '^llvm-tools(-|$)'" \
        && printf '%s\n' "$release_preflight" \
        | grep -Fq 'llvm-tools-preview is missing for pinned Rust'; then
    echo "  ok   release preflight rejects missing pinned llvm-tools before long suites"
else
    echo "  FAIL release can reach coverage before discovering missing llvm-tools"
    fail=$((fail + 1))
fi
if grep -Fq 'RENDER_GRID = 32' "$BUILDUP_RUNNER" \
        && grep -Fq 'MIN_RENDER_DELTA = 25.0' "$BUILDUP_RUNNER" \
        && grep -Fq '"bgStyle": "none"' "$BUILDUP_RUNNER" \
        && grep -Fq '"animatedBg": False' "$BUILDUP_RUNNER" \
        && grep -Fq 'return max(' "$BUILDUP_RUNNER"; then
    echo "  ok   incremental widget rendering uses a static localized pixel proof"
else
    echo "  FAIL incremental widget rendering can be diluted or satisfied by background motion"
    fail=$((fail + 1))
fi

release_io_repo="$(mktemp -d "${TMPDIR:-/tmp}/xe-release-io.XXXXXX")"
mkdir -p "$release_io_repo/scripts/lib" "$release_io_repo/fail-bin"
cp "$STRICT_RUNNER" "$release_io_repo/scripts/run_release_tests.sh"
cp "$SOURCE_TRACKER" "$release_io_repo/scripts/check_tracked_source_inputs.py"
cp "$RELEASE_MANIFEST_CHECKER" \
    "$release_io_repo/scripts/check_release_manifest_contract.py"
cp "$PROJECT_DIR/scripts/finalize_audit_artifacts.sh" \
    "$release_io_repo/scripts/finalize_audit_artifacts.sh"
cp "$PROJECT_DIR/scripts/lib/release_gate.sh" \
    "$release_io_repo/scripts/lib/release_gate.sh"
cp "$PROJECT_DIR/scripts/lib/audit_artifact_manifest.py" \
    "$PROJECT_DIR/scripts/lib/audit_artifact_contract.py" \
    "$OWNER_LICENSE_READER" \
    "$RELEASE_RUST_TOOLCHAIN_HELPER" \
    "$PROJECT_DIR/scripts/lib/release_origin.sh" \
    "$release_io_repo/scripts/lib/"
printf 'artifacts/\nfail-bin/\n*.log\n' >"$release_io_repo/.gitignore"
printf 'fixture\n' >"$release_io_repo/tracked.txt"
git -C "$release_io_repo" init -q
git -C "$release_io_repo" config user.name "Release IO Contract"
git -C "$release_io_repo" config user.email "release-io@example.invalid"
git -C "$release_io_repo" remote add origin \
    https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
git -C "$release_io_repo" add .
git -C "$release_io_repo" -c commit.gpgSign=false commit -qm fixture

real_mkdir="$(command -v mkdir)"
cat >"$release_io_repo/fail-bin/mkdir" <<'EOF'
#!/usr/bin/env bash
exit 91
EOF
chmod +x "$release_io_repo/fail-bin/mkdir"
if PATH="$release_io_repo/fail-bin:$PATH" XENEON_OWNER_KEY_FD=3 \
    bash "$release_io_repo/scripts/run_release_tests.sh" \
    3<<<'contract-owner-key' \
    >"$release_io_repo/mkdir-failure.log" 2>&1; then
    echo "  FAIL strict runner continued after audit-directory creation failed"
    fail=$((fail + 1))
elif grep -Fq "could not create the release evidence directory" \
        "$release_io_repo/mkdir-failure.log"; then
    echo "  ok   failed audit-directory creation terminates the strict runner"
else
    echo "  FAIL strict runner reported the wrong mkdir failure"
    sed -n '1,20p' "$release_io_repo/mkdir-failure.log"
    fail=$((fail + 1))
fi

cat >"$release_io_repo/fail-bin/mkdir" <<EOF
#!/usr/bin/env bash
set -e
"$real_mkdir" "\$@"
for argument in "\$@"; do
    case "\$argument" in
        */logs)
            root="\${argument%/logs}"
            ln -s /dev/full "\$root/PREFLIGHT.tsv"
            ;;
    esac
done
EOF
chmod +x "$release_io_repo/fail-bin/mkdir"
if PATH="$release_io_repo/fail-bin:$PATH" XENEON_OWNER_KEY_FD=3 \
    bash "$release_io_repo/scripts/run_release_tests.sh" \
    3<<<'contract-owner-key' \
    >"$release_io_repo/preflight-write-failure.log" 2>&1; then
    echo "  FAIL strict runner continued after PREFLIGHT.tsv initialization failed"
    fail=$((fail + 1))
elif grep -Fq "could not initialize PREFLIGHT.tsv" \
        "$release_io_repo/preflight-write-failure.log"; then
    echo "  ok   failed preflight record creation terminates the strict runner"
else
    echo "  FAIL strict runner reported the wrong preflight-write failure"
    sed -n '1,20p' "$release_io_repo/preflight-write-failure.log"
    fail=$((fail + 1))
fi

cat >"$release_io_repo/fail-bin/mkdir" <<EOF
#!/usr/bin/env bash
exec "$real_mkdir" "\$@"
EOF
cat >"$release_io_repo/fail-bin/gpg" <<'EOF'
#!/usr/bin/env bash
exit 92
EOF
chmod +x "$release_io_repo/fail-bin/mkdir" "$release_io_repo/fail-bin/gpg"
if PATH="$release_io_repo/fail-bin:$PATH" XENEON_OWNER_KEY_FD=3 \
        bash "$release_io_repo/scripts/run_release_tests.sh" \
        3<<<'contract-owner-key' \
        >"$release_io_repo/signing-key-preflight.log" 2>&1; then
    echo "  FAIL strict runner accepted an unavailable pinned signing key"
    fail=$((fail + 1))
elif grep -Fq \
        "pinned release signing key is unavailable, expired, revoked, or not signing-capable" \
        "$release_io_repo/signing-key-preflight.log" \
        && ! grep -Fq "==> Rust core format" \
            "$release_io_repo/signing-key-preflight.log"; then
    echo "  ok   direct strict entry fails before suites when the signing key is unavailable"
else
    echo "  FAIL direct strict entry deferred or misreported signing-key preflight"
    fail=$((fail + 1))
fi

git -C "$release_io_repo" remote set-url origin \
    https://example.invalid/not-the-release-repository.git
if PATH="$release_io_repo/fail-bin:$PATH" XENEON_OWNER_KEY_FD=3 \
        bash "$release_io_repo/scripts/run_release_tests.sh" \
        3<<<'contract-owner-key' \
        >"$release_io_repo/origin-preflight.log" 2>&1; then
    echo "  FAIL strict runner accepted a noncanonical origin"
    fail=$((fail + 1))
elif grep -Fq \
        "origin fetch and push URLs must identify the canonical GitHub repository" \
        "$release_io_repo/origin-preflight.log" \
        && ! grep -Fq "==> Rust core format" \
            "$release_io_repo/origin-preflight.log"; then
    echo "  ok   direct strict entry fails before suites for a noncanonical origin"
else
    echo "  FAIL direct strict entry deferred or misreported origin preflight"
    fail=$((fail + 1))
fi
git -C "$release_io_repo" remote set-url origin \
    https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git

git -C "$release_io_repo" rm -q scripts/lib/audit_artifact_manifest.py
git -C "$release_io_repo" -c commit.gpgSign=false commit -qm \
    "test: remove finalizer helper"
if PATH="$release_io_repo/fail-bin:$PATH" XENEON_OWNER_KEY_FD=3 \
        bash "$release_io_repo/scripts/run_release_tests.sh" \
        3<<<'contract-owner-key' \
        >"$release_io_repo/finalizer-helper-preflight.log" 2>&1; then
    echo "  FAIL strict runner accepted a missing finalizer helper"
    fail=$((fail + 1))
elif grep -Fq \
        "audit finalizer or semantic helper is missing, empty, or symlinked" \
        "$release_io_repo/finalizer-helper-preflight.log" \
        && ! grep -Fq "==> Rust core format" \
            "$release_io_repo/finalizer-helper-preflight.log"; then
    echo "  ok   direct strict entry fails before suites for missing finalizer helpers"
else
    echo "  FAIL direct strict entry deferred or misreported finalizer-helper preflight"
    fail=$((fail + 1))
fi
rm -rf -- "$release_io_repo"

if grep -Fq 'skyphoenix-edgehub-release-gate-result/v1' "$STRICT_RUNNER" \
        && grep -Fq 'XENEON_RELEASE_GATE_RESULT_FILE' "$STRICT_RUNNER" \
        && grep -Fq 'RELEASE_GATE_EVIDENCE.json' "$RELEASE_SCRIPT" \
        && grep -Fq 'skyphoenix-edgehub-release-provenance/v5' "$RELEASE_SCRIPT" \
        && grep -Fq -- '--verify --commit "$head_commit" "$RELEASE_GATE_ARTIFACT_DIR"' \
            "$RELEASE_SCRIPT"; then
    echo "  ok   release binds a machine-reported signed gate run into public provenance"
else
    echo "  FAIL release provenance is not bound to the exact signed gate run"
    fail=$((fail + 1))
fi
if [ -x "$RELEASE_CERTIFICATION_VERIFIER" ] \
        && [ -x "$RELEASE_CERTIFICATION_CONTRACT" ] \
        && grep -Fq 'stable release requires --certification' "$RELEASE_SCRIPT" \
        && grep -Fq 'RELEASE_CERTIFICATION_EVIDENCE.json' "$RELEASE_SCRIPT" \
        && grep -Fq '"release_certification": (' "$RELEASE_SCRIPT" \
        && [ "$(grep -Fc 'verify_release_certification_unchanged' \
            "$RELEASE_SCRIPT")" -ge 4 ] \
        && grep -Fq 'check_release_certification_contract.sh' \
            "$PROJECT_DIR/scripts/run_all_tests.sh" \
        && grep -Fq 'check_published_zsync_contract.sh' \
            "$PROJECT_DIR/scripts/run_all_tests.sh" \
        && grep -Fq 'direct stable publication is forbidden' "$RELEASE_SCRIPT" \
        && grep -Fq -- '--stage-candidate' "$RELEASE_SCRIPT" \
        && grep -Fq -- '--promote' "$RELEASE_SCRIPT"; then
    echo "  ok   stable staging and promotion require both signed certification phases"
else
    echo "  FAIL stable publication can bypass a missing or changed certification receipt"
    fail=$((fail + 1))
fi
if [ "$(grep -Fc 'gh release download "$VERSION"' "$RELEASE_SCRIPT")" -ge 2 ] \
        && grep -Fq 'record.get("isDraft") is not False' "$RELEASE_SCRIPT" \
        && grep -Fq 'gh release edit "$VERSION" --repo "$RELEASE_REPO" --draft=true' \
            "$RELEASE_SCRIPT"; then
    echo "  ok   public release is freshly re-downloaded and returned to draft on mismatch"
else
    echo "  FAIL public release lacks post-publication exact verification or rollback"
    fail=$((fail + 1))
fi

owner_test="owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key"
if printf '%s\n' "$release_list" | grep -Fq "$owner_test"; then
    echo "  ok   owner-issued Pro key attestation is in the release manifest"
else
    echo "  FAIL owner-issued Pro key attestation is absent from the release manifest"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_preflight" | grep -Fq '[[ -v XENEON_TEST_LICENSE_KEY ]]' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'XENEON_TEST_LICENSE_KEY_FILE' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'owner_license_file.py' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'case "$OWNER_TEST_LICENSE_KEY" in' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'preflight_bad "provide a real owner-issued Pro key through XENEON_TEST_LICENSE_KEY_FILE"'; then
    echo "  ok   release preflight rejects raw environment keys and requires the protected licence file or internal descriptor"
else
    echo "  FAIL release preflight does not enforce protected owner-licence ingress"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_preflight" | grep -Fq 'export XENEON_CONTRACT_REPO="$PROJECT_DIR"'; then
    echo "  ok   release contracts are pinned to the signed candidate tree"
else
    echo "  FAIL release contracts can be redirected to a caller-chosen tree"
    fail=$((fail + 1))
fi

if printf '%s\n' "$release_preflight" | grep -Fq 'unset QMLTESTRUNNER' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'resource-aware QuickTest runner will be built from the candidate tree' \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'QML GUI (compiled resources)' \
        && grep -Fq 'QMLTESTRUNNER="$TEST_BUILD_DIR/xeneon-qmltestrunner"' "$PROJECT_DIR/scripts/run_ui_tests.sh" \
        && grep -Fq -- '--tier compiled' "$PROJECT_DIR/scripts/run_ui_tests.sh" \
        && grep -Fq '${CMAKE_SOURCE_DIR}/ui/qml.qrc' "$PROJECT_DIR/CMakeLists.txt" \
        && grep -Fq '${CMAKE_SOURCE_DIR}/manager/manager.qrc' "$PROJECT_DIR/CMakeLists.txt" \
        && grep -Fq 'xeneon_qml_require_live_totals' "$PROJECT_DIR/scripts/run_ui_tests.sh"; then
    echo "  ok   strict QML uses the candidate resource runner and every file requires live Totals"
else
    echo "  FAIL strict QML tests can use an override, miss resources, or pass vacuously"
    fail=$((fail + 1))
fi

if printf '%s\n' "$release_preflight" | grep -Fq 'export XENEON_TEST_BUILD_DIR="$PROJECT_DIR/cmake-build-release-tests"' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'export XENEON_HUB="$XENEON_TEST_BUILD_DIR/xeneon-edge-hub"' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'export XENEON_MANAGER="$XENEON_TEST_BUILD_DIR/xeneon-edge-manager"' \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'strict_build_dir="$PROJECT_DIR/cmake-build-release-tests"' \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'bash "$PROJECT_DIR/scripts/run_cpp_tests.sh" "$test_build_dir"' \
        && grep -Fq 'STRICT_BUILD_DIR="$REPO_ROOT/cmake-build-release-tests"' "$CPP_RUNNER" \
        && grep -Fq 'rm -rf -- "$STRICT_BUILD_DIR"' "$CPP_RUNNER" \
        && grep -Fq 'touch "$BUILD_DIR/.xeneon-release-coverage-reset"' "$CPP_RUNNER" \
        && grep -Fq 'STRICT_BUILD_DIR="$PROJECT_DIR/cmake-build-release-tests"' "$COVERAGE_RUNNER" \
        && grep -Fq 'CPP_BUILD_DIR="${XENEON_TEST_BUILD_DIR:-$STRICT_BUILD_DIR}"' "$COVERAGE_RUNNER" \
        && grep -Fq 'TEST_BUILD_DIR="${XENEON_TEST_BUILD_DIR:-$ROOT/build}"' "$GUI_RUNNER" \
        && grep -Fq 'QT="$TEST_BUILD_DIR/xeneon-qmltestrunner"' "$GUI_RUNNER" \
        && grep -Fq 'strict release candidate runner is missing: $QT' "$GUI_RUNNER" \
        && printf '%s\n' "$run_all_execution" | grep -Fq '[ ! -x "$XENEON_HUB" ]'; then
    echo "  ok   strict C++, GUI, real-binary, and coverage tiers share one clean dedicated tree"
else
    echo "  FAIL strict release tests can reuse or disagree about the mutable build/ tree"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_preflight" | grep -Fq 'network namespace (real no-egress attestation)' \
        && ! printf '%s\n' "$release_preflight" | grep -Eq '(^|[[:space:]])strace([[:space:]]|$)' \
        && grep -Fq 'packaging/ci/netns-containment.sh' "$PROJECT_DIR/tests/runtime/run_03_update_check_off.sh" \
        && grep -Fq 'strict release gate requires real network namespace containment' "$PROJECT_DIR/tests/runtime/run_03_update_check_off.sh"; then
    echo "  ok   strict local no-egress gate requires netns containment without requiring strace"
else
    echo "  FAIL strict local no-egress gate still depends on strace or lacks containment"
    fail=$((fail + 1))
fi
if grep -Fq 'DEVELOPER_BUILD_DIR="$REPO_ROOT/build"' "$CPP_RUNNER" \
        && grep -Fq 'DEVELOPER_BUILD_DIR="$PROJECT_DIR/build"' "$COVERAGE_RUNNER" \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'developer_build_dir="$PROJECT_DIR/build"'; then
    echo "  ok   normal developer runs retain the build/ default"
else
    echo "  FAIL dedicated release build plumbing changed the developer default"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_execution" | grep -Fq 'scripts/run_hardware_python.py' \
        && grep -Fq 'scripts/run_hardware_python.py' "$MANAGER_RUNNER" \
        && [ -f "$HARDWARE_PYTHON_RUNNER" ]; then
    echo "  ok   real-hardware and Manager suites receive the selected candidate binaries"
else
    echo "  FAIL a real-binary release tier still hard-codes mutable build/ binaries"
    fail=$((fail + 1))
fi

gui_run_one="$(sed -n '/^run_one()/,/^}/p' "$GUI_RUNNER")"
if printf '%s\n' "$gui_run_one" | grep -Fq 'run_bounded SLOT_F="$f"' \
        && printf '%s\n' "$gui_run_one" | grep -Fq 'bash "$SELF" __slot' \
        && ! printf '%s\n' "$gui_run_one" | grep -Fq 'if [ "$J" -gt 1 ]' \
        && grep -Fq 'run_one "$f" "$slot"' "$GUI_RUNNER"; then
    echo "  ok   every compositor job, including J=1, keeps KWin inside run_bounded"
else
    echo "  FAIL the J=1 GUI path can leave KWin outside the memory/time boundary"
    fail=$((fail + 1))
fi

echo "==> Performance release boundary"
if printf '%s\n' "$release_preflight" \
        | grep -Fq 'PERFORMANCE_BUILD_DIR="$PROJECT_DIR/cmake-build-release-performance"' \
        && printf '%s\n' "$release_preflight" \
        | grep -Fq 'PERFORMANCE_HUB="$PERFORMANCE_BUILD_DIR/xeneon-edge-hub"' \
        && grep -Fq 'PERFORMANCE_BUILD_DIR="$PROJECT_DIR/cmake-build-release-performance"' "$PERFORMANCE_PREPARE" \
        && grep -Fq -- '-DCMAKE_BUILD_TYPE=Release' "$PERFORMANCE_PREPARE" \
        && grep -Fq -- '-DCMAKE_INSTALL_PREFIX=/usr' "$PERFORMANCE_PREPARE" \
        && grep -Fq -- '-DXENEON_BUILD_TESTS=OFF' "$PERFORMANCE_PREPARE" \
        && grep -Fq -- '-DXENEON_COVERAGE=OFF' "$PERFORMANCE_PREPARE" \
        && grep -Fq -- '-DXENEON_QA_HOOKS=OFF' "$PERFORMANCE_PREPARE" \
        && grep -Fq -- '--target clean' "$PERFORMANCE_PREPARE"; then
    echo "  ok   performance uses a fixed fresh non-instrumented Release candidate"
else
    echo "  FAIL performance can use a mutable, instrumented, or QA-enabled binary"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_execution" \
        | grep -Fq 'run_release_suite "Hub startup + literal 5m idle/10-widget performance" 1200' \
        && printf '%s\n' "$release_execution" \
        | grep -Fq -- '--mode short --hub "$PERFORMANCE_HUB"' \
        && printf '%s\n' "$release_execution" \
        | grep -Fq 'run_release_suite "Hub literal 30m 14-widget performance observation" 2400' \
        && printf '%s\n' "$release_execution" \
        | grep -Fq 'tests/performance/run_audit_14_widget_30m.py' \
        && printf '%s\n' "$release_execution" \
        | grep -Fq -- '--output-dir "$performance_evidence_root/14-widget-30m"' \
        && ! printf '%s\n' "$release_execution" \
        | grep -Fq -- '--mode idle-48h'; then
    echo "  ok   strict release executes the short budgets and owner-approved 30-minute substitute"
else
    echo "  FAIL strict release omits or shortens the accepted performance gates"
    fail=$((fail + 1))
fi
if ! grep -Fq -- '--duration' "$PERFORMANCE_AUDIT" \
        && ! grep -Fq 'XENEON_PERF_DURATION' "$PERFORMANCE_AUDIT" \
        && grep -Fq 'AUDIT_DURATION_SECONDS = 1800.0' "$PERFORMANCE_AUDIT" \
        && grep -Fq 'AUDIT_INTERVAL_SECONDS = 30.0' "$PERFORMANCE_AUDIT" \
        && grep -Fq '"qualified": not failures' "$PERFORMANCE_AUDIT" \
        && grep -Fq 'explicitly waived the historical 48-hour' "$PERFORMANCE_AUDIT"; then
    echo "  ok   30-minute substitute is literal, fail-closed, and records the owner waiver"
else
    echo "  FAIL 30-minute substitute can be scaled, is non-gating, or loses the owner waiver"
    fail=$((fail + 1))
fi
if XENEON_RELEASE_GATE=0 bash "$PERFORMANCE_PREPARE" >/dev/null 2>&1; then
    echo "  FAIL performance candidate preparation ran outside the strict release gate"
    fail=$((fail + 1))
else
    echo "  ok   performance candidate preparation rejects non-release invocation before mutation"
fi

echo "==> Portable payload release boundary"
portable_copy_line="$(grep -nF 'cp -v "${BUILD_DIR}/${bin_tarball}" "$DIST_DIR/"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
portable_extract_line="$(grep -nF 'tar -xzf "${DIST_DIR}/${bin_tarball}" -C "$smoke_root"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
portable_smoke_line="$(grep -nF 'bash "$RELEASE_SOURCE_DIR/packaging/ci/smoke.sh"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
signing_line="$(grep -nF 'step "Signing (gpg will prompt you for the passphrase - this is intentional)"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$portable_copy_line" ] && [ -n "$portable_extract_line" ] \
        && [ -n "$portable_smoke_line" ] && [ -n "$signing_line" ] \
        && [ "$portable_copy_line" -lt "$portable_extract_line" ] \
        && [ "$portable_extract_line" -lt "$portable_smoke_line" ] \
        && [ "$portable_smoke_line" -lt "$signing_line" ] \
        && grep -Fq 'portable_root="$smoke_root/${bin_tarball%.tar.gz}"' "$RELEASE_SCRIPT" \
        && grep -Fq 'hub_version="$("$portable_root/usr/bin/xeneon-edge-hub" --version)"' "$RELEASE_SCRIPT" \
        && grep -Fq 'manager_version="$("$portable_root/usr/bin/xeneon-edge-manager" --version)"' "$RELEASE_SCRIPT" \
        && grep -Fq '[ "$hub_version" = "Xeneon Edge Linux Hub $pkgver" ]' "$RELEASE_SCRIPT" \
        && grep -Fq '[ "$manager_version" = "Xeneon Edge Manager $pkgver" ]' "$RELEASE_SCRIPT" \
        && grep -Fq 'XDG_CONFIG_HOME="$smoke_root/config"' "$RELEASE_SCRIPT" \
        && grep -Fq 'XDG_CACHE_HOME="$smoke_root/cache"' "$RELEASE_SCRIPT" \
        && grep -Fq 'XDG_RUNTIME_DIR="$smoke_root/runtime"' "$RELEASE_SCRIPT"; then
    echo "  ok   exact dist payload is versioned and smoke-tested in isolated XDG state before signing"
else
    echo "  FAIL portable payload is not fully checked before signing"
    fail=$((fail + 1))
fi

echo "==> Final artifact identity + collision boundary"
final_revalidation_line="$(grep -nE '^[[:space:]]*verify_final_artifacts$' "$RELEASE_SCRIPT" \
    | head -1 | cut -d: -f1)"
checksum_line="$(grep -nF 'step "Generating SHA256SUMS"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
if grep -Fq 'duplicate --extra basename' "$RELEASE_SCRIPT" \
        && grep -Fq 'is reserved for a release-generated artifact' "$RELEASE_SCRIPT" \
        && grep -Fq 'cp -v --no-clobber -- "$extra" "$extra_target"' "$RELEASE_SCRIPT" \
        && grep -Fq 'cmp -s -- "$extra" "$extra_target"' "$RELEASE_SCRIPT" \
        && grep -Fq 'record_final_artifact "$extra_target"' "$RELEASE_SCRIPT" \
        && grep -Fq 'record_final_artifact "$sidecar_target"' "$RELEASE_SCRIPT" \
        && grep -Fq 'assert_dist_exact "${FINAL_ARTIFACT_NAMES[@]}"' "$RELEASE_SCRIPT" \
        && [ -n "$final_revalidation_line" ] && [ -n "$checksum_line" ] \
        && [ "$final_revalidation_line" -lt "$checksum_line" ]; then
    echo "  ok   extras cannot replace generated artifacts and all final bytes are revalidated before SHA256SUMS"
else
    echo "  FAIL extra collision/no-clobber/final-byte boundary is incomplete"
    fail=$((fail + 1))
fi

if grep -Fq 'readonly EXPECTED_APPIMAGE="xeneon-edge-hub-${PREFLIGHT_PKGVER}-x86_64.AppImage"' "$RELEASE_SCRIPT" \
        && grep -Fq '[ "$APPIMAGE_COUNT" -le 1 ]' "$RELEASE_SCRIPT" \
        && grep -Fq '[ "$extra_name" = "$EXPECTED_APPIMAGE" ]' "$RELEASE_SCRIPT" \
        && grep -Fq 'verify_extra_attestation "$extra" "$extra_signer"' "$RELEASE_SCRIPT" \
        && grep -Fq 'timeout 300 bash "$RELEASE_SOURCE_DIR/scripts/validate_release_extra.sh"' "$RELEASE_SCRIPT" \
        && grep -Fq -- '--appimage-update-info "$EXPECTED_APPIMAGE_UPDATE_INFO"' "$RELEASE_SCRIPT" \
        && grep -Fq 'safe_extract_appimage.sh' "$PROJECT_DIR/scripts/validate_release_extra.sh" \
        && grep -Fq 'Hub payload version mismatch' "$PROJECT_DIR/scripts/validate_release_extra.sh" \
        && grep -Fq 'Manager payload version mismatch' "$PROJECT_DIR/scripts/validate_release_extra.sh"; then
    echo "  ok   AppImage count, name, provenance, update metadata, payload, and versions are mandatory"
else
    echo "  FAIL AppImage extras can escape an exact identity/runtime check"
    fail=$((fail + 1))
fi

echo "==> Publish preflight + repository pin"
publish_auth_line="$(grep -nF 'gh auth status --hostname github.com' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
strict_gate_line="$(grep -nF 'bash "$STRICT_RELEASE_GATE" 3<<<"$RELEASE_OWNER_TEST_LICENSE_KEY"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
certification_line="$(grep -nF 'bash "$RELEASE_CERTIFICATION_VERIFIER"' \
    "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
canonical_origin_line="$(grep -nF \
    'xeneon_origin_matches_github_repo "$REPO_DIR" "$RELEASE_REPO"' \
    "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
publish_branch_line="$(grep -nF 'if [ "$PUBLISH" -eq 1 ]; then' \
    "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$publish_auth_line" ] && [ -n "$strict_gate_line" ] \
        && [ "$publish_auth_line" -lt "$strict_gate_line" ] \
        && [ -n "$certification_line" ] \
        && [ "$certification_line" -lt "$strict_gate_line" ] \
        && [ -n "$canonical_origin_line" ] && [ -n "$publish_branch_line" ] \
        && [ "$canonical_origin_line" -lt "$publish_branch_line" ] \
        && grep -Fq 'release_notes_blob="$(git -C "$REPO_DIR" rev-parse --verify "${tag_commit}:RELEASE_NOTES.md")"' "$RELEASE_SCRIPT" \
        && grep -Fq 'existing_release_tags="$(gh release list --repo "$RELEASE_REPO"' "$RELEASE_SCRIPT" \
        && grep -Fq '"$REPO_DIR" "$VERSION" "$head_commit" "$tag_object"' "$RELEASE_SCRIPT" \
        && grep -Fq 'release_command=(gh release create "$VERSION" --repo "$RELEASE_REPO" --verify-tag --draft)' "$RELEASE_SCRIPT" \
        && grep -Fq 'gh release edit "$VERSION" --repo "$RELEASE_REPO"' "$RELEASE_SCRIPT" \
        && grep -Fq -- '--draft=false --prerelease --latest=false' "$RELEASE_SCRIPT"; then
    echo "  ok   canonical origin is unconditional and publish checks precede the strict gate"
else
    echo "  FAIL release can defer origin/publish failure or target an inferred repository"
    fail=$((fail + 1))
fi

release_origin_repo="$(mktemp -d "${TMPDIR:-/tmp}/xe-release-origin.XXXXXX")"
release_origin_gnupg="$(mktemp -d "${TMPDIR:-/tmp}/xe-release-origin-gpg.XXXXXX")"
release_origin_log="$(mktemp "${TMPDIR:-/tmp}/xe-release-origin-log.XXXXXX")"
chmod 0700 "$release_origin_gnupg"
mkdir -p "$release_origin_repo/scripts/lib"
cp -- \
    "$RELEASE_SCRIPT" \
    "$SOURCE_TRACKER" \
    "$release_origin_repo/scripts/"
cp -- \
    "$PROJECT_DIR/scripts/lib/release_sequence.sh" \
    "$PROJECT_DIR/scripts/lib/release_origin.sh" \
    "$PROJECT_DIR/scripts/lib/github_immutable_releases.sh" \
    "$OWNER_LICENSE_READER" \
    "$RELEASE_RUST_TOOLCHAIN_HELPER" \
    "$release_origin_repo/scripts/lib/"
GNUPGHOME="$release_origin_gnupg" \
    gpg --batch --quiet --passphrase '' \
        --quick-generate-key \
        "Release Origin Contract <release-origin@example.invalid>" \
        ed25519 sign 1d
release_origin_key="$(
    GNUPGHOME="$release_origin_gnupg" \
        gpg --with-colons --list-keys \
        | awk -F: '$1 == "fpr" { print $10; exit }'
)"
python3 - "$release_origin_repo/scripts/release.sh" \
    "$release_origin_key" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
if text.count(old) != 1:
    raise SystemExit("could not pin fixture release key")
path.write_text(text.replace(old, sys.argv[2]), encoding="utf-8")
PY
printf 'fixture release notes\n' >"$release_origin_repo/RELEASE_NOTES.md"
git -C "$release_origin_repo" init -q
git -C "$release_origin_repo" config user.name "Release Origin Contract"
git -C "$release_origin_repo" config user.email \
    "release-origin@example.invalid"
git -C "$release_origin_repo" remote add origin \
    https://example.invalid/not-the-release-repository.git
git -C "$release_origin_repo" add .
git -C "$release_origin_repo" -c commit.gpgSign=false commit -qm fixture
GNUPGHOME="$release_origin_gnupg" \
    git -C "$release_origin_repo" \
        -c user.signingkey="$release_origin_key" \
        tag -s v9.8.7-rc.1 -m v9.8.7-rc.1
release_origin_owner_file="${release_origin_log}.owner-key"
printf 'contract-owner-key\n' >"$release_origin_owner_file"
chmod 0600 "$release_origin_owner_file"
if env GNUPGHOME="$release_origin_gnupg" \
        XENEON_TEST_LICENSE_KEY_FILE="$release_origin_owner_file" \
        bash "$release_origin_repo/scripts/release.sh" \
            --version v9.8.7-rc.1 \
        >"$release_origin_log" 2>&1; then
    echo "  FAIL non-publish release accepted a noncanonical origin"
    fail=$((fail + 1))
elif grep -Fq \
        "origin fetch and push URLs do not identify the pinned GitHub release repository" \
        "$release_origin_log" \
        && ! grep -Fq "Preflight: mandatory strict release test gate" \
            "$release_origin_log"; then
    echo "  ok   non-publish release behaviorally rejects a noncanonical origin before the strict gate"
else
    echo "  FAIL non-publish release deferred or misreported origin validation"
    sed -n '1,24p' "$release_origin_log"
    fail=$((fail + 1))
fi
rm -rf -- "$release_origin_repo" "$release_origin_gnupg"
rm -f -- "$release_origin_log" "$release_origin_owner_file"

extra_loop_count="$(grep -Ec '^[[:space:]]*for extra in ' "$RELEASE_SCRIPT" || true)"
safe_extra_loop_count="$(grep -Fc 'for extra in "${EXTRA_ARTIFACTS[@]}"; do' "$RELEASE_SCRIPT" || true)"
if [ "$extra_loop_count" -gt 0 ] && [ "$extra_loop_count" -eq "$safe_extra_loop_count" ] \
        && ! sed '/^[[:space:]]*#/d' "$RELEASE_SCRIPT" \
        | grep -Eq '(^|[;[:space:]])eval([[:space:]]|$)'; then
    echo "  ok   extra artifacts remain array-safe and release.sh contains no eval"
else
    echo "  FAIL extra artifacts can be word-split or release.sh contains eval"
    fail=$((fail + 1))
fi

# Prove the bootstrap changes both imported process constants and the default
# tuple captured by assert_binaries_current(), including paths with shell syntax.
hardware_contract_dir="$(mktemp -d "${TMPDIR:-/tmp}/xe-hardware-runner.XXXXXX")"
cat >"$hardware_contract_dir/e2e_harness.py" <<'PY'
HUB = "developer-hub"
MANAGER = "developer-manager"
def assert_binaries_current(binaries=(HUB, MANAGER)):
    return binaries
PY
cat >"$hardware_contract_dir/probe.py" <<'PY'
from e2e_harness import HUB, MANAGER, assert_binaries_current
import os
expected = (os.environ["XENEON_HUB"], os.environ["XENEON_MANAGER"])
assert (HUB, MANAGER) == expected
assert assert_binaries_current() == expected
PY
contract_hub="$hardware_contract_dir/hub ; literal"
contract_manager="$hardware_contract_dir/manager \$(literal)"
if XENEON_HUB="$contract_hub" XENEON_MANAGER="$contract_manager" \
        python3 "$HARDWARE_PYTHON_RUNNER" "$hardware_contract_dir/probe.py"; then
    echo "  ok   hardware bootstrap preserves candidate paths as literal data"
else
    echo "  FAIL hardware bootstrap lost or shell-reparsed a candidate binary path"
    fail=$((fail + 1))
fi
rm -rf "$hardware_contract_dir"
owner_suite="$(printf '%s\n' "$release_execution" | sed -n '/run_release_suite "Owner Pro key against shipped issuer"/,+2p')"
if printf '%s\n' "$owner_suite" | grep -Fq 'scripts/run_owner_key_release_test.sh'; then
    echo "  ok   owner-issued Pro key release suite invokes the exact-count runner"
else
    echo "  FAIL owner-issued Pro key suite does not invoke the exact-count runner"
    fail=$((fail + 1))
fi
if [ "$(printf '%s\n' "$release_execution" | grep -Fc 'export XENEON_TEST_LICENSE_KEY=')" -eq 0 ] \
        && [ "$(printf '%s\n' "$release_execution" | grep -Fc 'export XENEON_OWNER_KEY_FD=3')" -eq 2 ] \
        && [ "$(printf '%s\n' "$release_execution" | grep -Fc '3<<<"$OWNER_TEST_LICENSE_KEY"')" -eq 2 ] \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'unset XENEON_TEST_LICENSE_KEY' \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'run_rust_core_with_owner_key' \
        && printf '%s\n' "$run_all_execution" | grep -Fq 'exec 3<&-' \
        && grep -Fq 'exec 3<&-' "$OWNER_RUNNER"; then
    echo "  ok   owner-issued Pro key reaches only Rust through short-lived closed descriptors"
else
    echo "  FAIL owner-issued Pro key can leak into unrelated release children"
    fail=$((fail + 1))
fi
if [ -f "$RELEASE_RUST_TOOLCHAIN_HELPER" ] \
        && grep -Fq 'XENEON_RELEASE_RUST_TOOLCHAIN="1.86.0"' \
            "$RELEASE_RUST_TOOLCHAIN_HELPER" \
        && grep -Fq 'rustc 1.86.0 (05f9846f8 2025-03-31)' \
            "$RELEASE_RUST_TOOLCHAIN_HELPER" \
        && grep -Fq 'cargo 1.86.0 (adf9b6ad1 2025-02-28)' \
            "$RELEASE_RUST_TOOLCHAIN_HELPER" \
        && grep -Fq 'export RUSTUP_TOOLCHAIN=1.86.0' "$RELEASE_SCRIPT" \
        && grep -Fq 'xeneon_release_rust_toolchain_verify' "$RELEASE_SCRIPT" \
        && grep -Fq 'export RUSTUP_TOOLCHAIN=1.86.0' "$STRICT_RUNNER" \
        && grep -Fq 'xeneon_release_rust_toolchain_verify' "$STRICT_RUNNER" \
        && grep -Fq 'export RUSTUP_TOOLCHAIN=1.86.0' \
            "$PROJECT_DIR/scripts/run_all_tests.sh" \
        && grep -Fq 'xeneon_release_rust_toolchain_verify' \
            "$PROJECT_DIR/scripts/run_all_tests.sh" \
        && grep -Fq 'export RUSTUP_TOOLCHAIN=1.86.0' "$OWNER_RUNNER" \
        && grep -Fq 'xeneon_release_rust_toolchain_verify' "$OWNER_RUNNER"; then
    echo "  ok   release and direct strict entry points pin and verify Rust 1.86.0"
else
    echo "  FAIL a release or direct strict entry point can use an unverified Rust toolchain"
    fail=$((fail + 1))
fi
if (
    # shellcheck source=lib/release_rust_toolchain.sh
    . "$RELEASE_RUST_TOOLCHAIN_HELPER"
    xeneon_release_rust_toolchain_select
    xeneon_release_rust_toolchain_verify
); then
    echo "  ok   the exact release Rust 1.86.0 toolchain is installed and selectable"
else
    echo "  FAIL the exact release Rust 1.86.0 toolchain is not selectable"
    fail=$((fail + 1))
fi
toolchain_mismatch_bin="$(
    mktemp -d "${TMPDIR:-/tmp}/xe-rust-toolchain.XXXXXX"
)"
cat >"$toolchain_mismatch_bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.97.0 (mismatch)"
EOF
chmod +x "$toolchain_mismatch_bin/cargo"
if PATH="$toolchain_mismatch_bin:$PATH" bash -c '
        . "$1"
        xeneon_release_rust_toolchain_select
        xeneon_release_rust_toolchain_verify
    ' bash "$RELEASE_RUST_TOOLCHAIN_HELPER" >/dev/null 2>&1; then
    echo "  FAIL release Rust preflight accepted a mismatched Cargo product"
    fail=$((fail + 1))
else
    echo "  ok   release Rust preflight rejects a mismatched Cargo product"
fi
rm -rf -- "$toolchain_mismatch_bin"
if [ -f "$OWNER_RUNNER" ] \
        && grep -Fq 'license::tests::owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key' "$OWNER_RUNNER" \
        && grep -Fq '"$OWNER_TEST" -- --exact --nocapture' "$OWNER_RUNNER" \
        && grep -Fq "grep -Fxc 'running 1 test'" "$OWNER_RUNNER"; then
    echo "  ok   owner-key runner requires one exact visible Cargo test"
else
    echo "  FAIL owner-key runner can accept a skipped, filtered, or zero-test Cargo run"
    fail=$((fail + 1))
fi
for ingress_script in \
        "$RELEASE_SCRIPT" \
        "$STRICT_RUNNER" \
        "$PROJECT_DIR/scripts/run_all_tests.sh" \
        "$OWNER_RUNNER"; do
    raw_guard_line="$(grep -nF '[[ -v XENEON_TEST_LICENSE_KEY ]]' \
        "$ingress_script" | head -1 | cut -d: -f1)"
    first_path_child_line="$(grep -nE \
        '(PROJECT_DIR|REPO_DIR)=.*[$][(].*(cd|dirname)' \
        "$ingress_script" | head -1 | cut -d: -f1)"
    if [ -n "$raw_guard_line" ] && [ -n "$first_path_child_line" ] \
            && [ "$raw_guard_line" -lt "$first_path_child_line" ]; then
        echo "  ok   $(basename "$ingress_script") rejects raw key input before path-resolution children"
    else
        echo "  FAIL $(basename "$ingress_script") can spawn a child before rejecting raw key input"
        fail=$((fail + 1))
    fi
done
if XENEON_TEST_LICENSE_KEY= bash "$OWNER_RUNNER" >/dev/null 2>&1; then
    echo "  FAIL owner-key runner accepted the legacy value environment"
    fail=$((fail + 1))
else
    echo "  ok   owner-key runner rejects legacy value input before Cargo"
fi

owner_file_fixture="$(mktemp -d "${TMPDIR:-/tmp}/xe-owner-file.XXXXXX")"
owner_file="$owner_file_fixture/owner.key"
printf 'contract-owner-key\n' >"$owner_file"
chmod 0600 "$owner_file"
for reader_guard in \
        'os.O_NOFOLLOW' \
        'os.O_NONBLOCK' \
        'stat.S_ISREG(metadata.st_mode)' \
        'metadata.st_uid != os.geteuid()' \
        'permissions & 0o077' \
        'MAX_LICENSE_BYTES = 4096'; do
    if grep -Fq "$reader_guard" "$OWNER_LICENSE_READER"; then
        echo "  ok   owner-licence reader retains guard: $reader_guard"
    else
        echo "  FAIL owner-licence reader lost guard: $reader_guard"
        fail=$((fail + 1))
    fi
done
if [ "$(env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$OWNER_LICENSE_READER" "$owner_file")" = "contract-owner-key" ]; then
    echo "  ok   protected owner-licence reader accepts one owner-only regular file"
else
    echo "  FAIL protected owner-licence reader rejected a valid fixture"
    fail=$((fail + 1))
fi
if env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_READER" \
        "relative-owner.key" >/dev/null 2>&1; then
    echo "  FAIL owner-licence reader accepted a relative path"
    fail=$((fail + 1))
else
    echo "  ok   owner-licence reader rejects relative paths"
fi
ln -s "$owner_file" "$owner_file_fixture/link.key"
if env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_READER" \
        "$owner_file_fixture/link.key" >/dev/null 2>&1; then
    echo "  FAIL owner-licence reader followed a symbolic link"
    fail=$((fail + 1))
else
    echo "  ok   owner-licence reader rejects symbolic links"
fi
if env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_READER" \
        "$owner_file_fixture" >/dev/null 2>&1; then
    echo "  FAIL owner-licence reader accepted a directory"
    fail=$((fail + 1))
else
    echo "  ok   owner-licence reader rejects non-regular files"
fi
chmod 0640 "$owner_file"
if env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_READER" \
        "$owner_file" >/dev/null 2>&1; then
    echo "  FAIL owner-licence reader accepted group-readable key material"
    fail=$((fail + 1))
else
    echo "  ok   owner-licence reader rejects group or other access"
fi
chmod 0600 "$owner_file"
python3 - "$owner_file_fixture/oversized.key" <<'PY'
import os
import sys

descriptor = os.open(
    sys.argv[1],
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
    0o600,
)
try:
    os.write(descriptor, b"x" * 4097)
finally:
    os.close(descriptor)
PY
if env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_READER" \
        "$owner_file_fixture/oversized.key" >/dev/null 2>&1; then
    echo "  FAIL owner-licence reader accepted an oversized key file"
    fail=$((fail + 1))
else
    echo "  ok   owner-licence reader enforces its exact byte limit"
fi

# Use a fake Cargo plus instrumented tee/grep to prove the release wrapper's
# execution contract without possessing the real owner secret: Cargo alone sees
# the entitlement, exactly one named PASS is required, and zero tests fail.
owner_contract_bin="$(mktemp -d "${TMPDIR:-/tmp}/xe-owner-contract.XXXXXX")"
real_tee="$(command -v tee)"
real_grep="$(command -v grep)"
cat >"$owner_contract_bin/cargo" <<'EOF'
#!/usr/bin/env bash
[ "${RUSTUP_TOOLCHAIN:-}" = "1.86.0" ] || {
    echo "fake cargo did not inherit the pinned release toolchain" >&2
    exit 89
}
if [ "${1:-}" = "--version" ]; then
    echo "cargo 1.86.0 (adf9b6ad1 2025-02-28)"
    exit 0
fi
[ "${XENEON_TEST_LICENSE_KEY:-}" = "contract-owner-key" ] || {
    echo "fake cargo did not receive the owner key" >&2
    exit 90
}
case "${XENEON_FAKE_OWNER_RESULT:-pass}" in
    pass)
        echo "running 1 test"
        echo "test license::tests::owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key ... ok"
        echo "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 40 filtered out"
        ;;
    zero)
        echo "running 0 tests"
        echo "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 41 filtered out"
        ;;
    *) exit 91 ;;
esac
EOF
cat >"$owner_contract_bin/tee" <<'EOF'
#!/usr/bin/env bash
[ -z "${XENEON_TEST_LICENSE_KEY:-}" ] || {
    echo "owner key leaked into tee" >&2
    exit 92
}
exec "$XENEON_REAL_TEE" "$@"
EOF
cat >"$owner_contract_bin/grep" <<'EOF'
#!/usr/bin/env bash
[ -z "${XENEON_TEST_LICENSE_KEY:-}" ] || {
    echo "owner key leaked into grep" >&2
    exit 93
}
exec "$XENEON_REAL_GREP" "$@"
EOF
chmod +x "$owner_contract_bin/cargo" "$owner_contract_bin/tee" "$owner_contract_bin/grep"
if PATH="$owner_contract_bin:$PATH" \
        XENEON_REAL_TEE="$real_tee" XENEON_REAL_GREP="$real_grep" \
        XENEON_TEST_LICENSE_KEY_FILE="$owner_file" \
        bash "$OWNER_RUNNER" >/dev/null 2>&1; then
    echo "  ok   owner-key runner accepts only the protected file at its public ingress"
else
    echo "  FAIL owner-key runner rejected a valid protected licence file"
    fail=$((fail + 1))
fi
if PATH="$owner_contract_bin:$PATH" \
        XENEON_REAL_TEE="$real_tee" XENEON_REAL_GREP="$real_grep" \
        XENEON_TEST_LICENSE_KEY=unsafe-value \
        XENEON_TEST_LICENSE_KEY_FILE="$owner_file" \
        bash "$OWNER_RUNNER" >/dev/null 2>&1; then
    echo "  FAIL owner-key runner accepted simultaneous raw and file input"
    fail=$((fail + 1))
else
    echo "  ok   owner-key runner rejects raw value input even when a file is supplied"
fi
if PATH="$owner_contract_bin:$PATH" \
        XENEON_REAL_TEE="$real_tee" XENEON_REAL_GREP="$real_grep" \
        XENEON_TEST_LICENSE_KEY_FILE="$owner_file" XENEON_OWNER_KEY_FD=3 \
        bash "$OWNER_RUNNER" 3<<<'contract-owner-key' >/dev/null 2>&1; then
    echo "  FAIL owner-key runner accepted simultaneous file and descriptor input"
    fail=$((fail + 1))
else
    echo "  ok   owner-key runner rejects simultaneous file and descriptor input"
fi
if PATH="$owner_contract_bin:$PATH" \
        XENEON_REAL_TEE="$real_tee" XENEON_REAL_GREP="$real_grep" \
        XENEON_OWNER_KEY_FD=3 bash "$OWNER_RUNNER" \
        3<<<'contract-owner-key' >/dev/null 2>&1; then
    echo "  ok   owner-key runner behaviorally requires one PASS and confines the key to Cargo"
else
    echo "  FAIL owner-key runner rejected an exact passing test or leaked the key"
    fail=$((fail + 1))
fi
if PATH="$owner_contract_bin:$PATH" \
        XENEON_REAL_TEE="$real_tee" XENEON_REAL_GREP="$real_grep" \
        XENEON_FAKE_OWNER_RESULT=zero XENEON_OWNER_KEY_FD=3 \
        bash "$OWNER_RUNNER" 3<<<'contract-owner-key' >/dev/null 2>&1; then
    echo "  FAIL owner-key runner accepted a zero-test Cargo success"
    fail=$((fail + 1))
else
    echo "  ok   owner-key runner behaviorally rejects a zero-test Cargo success"
fi
rm -rf "$owner_contract_bin" "$owner_file_fixture"
if grep -Fq "fn $owner_test" "$PROJECT_DIR/core/src/license.rs"; then
    echo "  ok   owner-issued Pro key release test exists in core/src/license.rs"
else
    echo "  FAIL release manifest names a missing owner-issued Pro key test"
    fail=$((fail + 1))
fi

# Keep the deprecated hardware runner out without spelling its full filename in
# the release runner itself. Reconstruct the name here so this check cannot pass
# merely because a shared grep literal was copied into that runner's comments.
legacy_name="edge_hw_""test.py"
if printf '%s\n%s\n' "$release_list" "$release_execution" | grep -Fq "$legacy_name"; then
    echo "  FAIL deprecated hardware runner is in the release manifest or executable path"
    fail=$((fail + 1))
else
    echo "  ok   deprecated hardware runner is absent"
fi

for required in tests/hardware/test_input_safety.py tests/hardware/test_e2e_contract.py; do
    if printf '%s\n' "$run_all_execution" | grep -Fq "$required"; then
        echo "  ok   $required is wired into run_all_tests.sh"
    else
        echo "  FAIL $required is absent from run_all_tests.sh"
        fail=$((fail + 1))
    fi
done
if printf '%s\n' "$run_all_execution" | grep -Fq 'tests/performance' \
        && printf '%s\n' "$run_all_execution" | grep -Fq -- "-p 'test_*.py'" \
        && [ -f "$PROJECT_DIR/tests/performance/test_resource_probe.py" ] \
        && [ -f "$PROJECT_DIR/tests/performance/test_performance_contract.py" ]; then
    echo "  ok   performance sampler unit/contract tests are wired into run_all_tests.sh"
else
    echo "  FAIL performance sampler tests are absent or orphaned"
    fail=$((fail + 1))
fi

for required in scripts/run_cpp_tests.sh scripts/run_manager_tests.sh tests/gui/run_gui_tests.sh; do
    if printf '%s\n' "$run_all_execution" | grep -Fq "$required"; then
        echo "  ok   $required is wired into run_all_tests.sh"
    else
        echo "  FAIL mandatory integration tier is absent: $required"
        fail=$((fail + 1))
    fi
done

for scenario in "$PROJECT_DIR"/tests/runtime/run_*.sh; do
    base="$(basename "$scenario")"
    if ! printf '%s\n' "$run_all_execution" | grep -Fq "$base"; then
        echo "  FAIL runtime scenario is orphaned: $base"
        fail=$((fail + 1))
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAILURE ($fail release-gate contract check(s))"
    exit 1
fi
echo "RESULT: SUCCESS"
