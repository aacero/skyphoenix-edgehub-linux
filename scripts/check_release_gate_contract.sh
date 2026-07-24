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
PERFORMANCE_RUNNER="$PROJECT_DIR/tests/performance/run_hub_profiles.py"
PERFORMANCE_PREPARE="$PROJECT_DIR/tests/performance/prepare_release_candidate.sh"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/release.sh"
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
check "exact Qt Virtual Keyboard dependency warning is separately dispositioned" \
    "$QML_DIAGNOSTIC_CHECKER" "$diagnostic_log" --tier compiled
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
release_list="$(bash "$PROJECT_DIR/scripts/run_release_tests.sh" --list)" || {
    echo "  FAIL run_release_tests.sh --list failed"
    fail=$((fail + 1))
    release_list=""
}
release_execution="$(sed -n '/^names=()/,$p' "$PROJECT_DIR/scripts/run_release_tests.sh" | sed '/^[[:space:]]*#/d')"
release_preflight="$(sed -n '1,/^names=()/p' "$PROJECT_DIR/scripts/run_release_tests.sh" | sed '/^[[:space:]]*#/d')"
run_all_execution="$(sed '/^[[:space:]]*#/d' "$PROJECT_DIR/scripts/run_all_tests.sh")"
for required in \
    tests/hardware/edge_e2e.py \
    tests/hardware/e2e_buildup.py \
    tests/hardware/widget_render_matrix.py \
    tests/performance/prepare_release_candidate.sh \
    tests/performance/run_hub_profiles.py \
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

owner_test="owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key"
if printf '%s\n' "$release_list" | grep -Fq "$owner_test"; then
    echo "  ok   owner-issued Pro key attestation is in the release manifest"
else
    echo "  FAIL owner-issued Pro key attestation is absent from the release manifest"
    fail=$((fail + 1))
fi
if printf '%s\n' "$release_preflight" | grep -Fq 'OWNER_TEST_LICENSE_KEY="${XENEON_TEST_LICENSE_KEY:-}"' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'unset XENEON_TEST_LICENSE_KEY' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'case "$OWNER_TEST_LICENSE_KEY" in' \
        && printf '%s\n' "$release_preflight" | grep -Fq 'preflight_bad "set XENEON_TEST_LICENSE_KEY to a real owner-issued Pro key"'; then
    echo "  ok   release preflight captures, unexports, and requires a non-empty owner-issued Pro key"
else
    echo "  FAIL release preflight does not require XENEON_TEST_LICENSE_KEY"
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
        | grep -Fq 'run_release_suite "Hub literal 48h idle stability/performance soak" 174600' \
        && printf '%s\n' "$release_execution" \
        | grep -Fq -- '--mode idle-48h --hub "$PERFORMANCE_HUB"'; then
    echo "  ok   strict release executes both five-minute gates and the literal 48-hour soak"
else
    echo "  FAIL strict release omits or shortens a performance/soak gate"
    fail=$((fail + 1))
fi
if ! grep -Fq -- '--duration' "$PERFORMANCE_RUNNER" \
        && ! grep -Fq 'XENEON_PERF_DURATION' "$PERFORMANCE_RUNNER" \
        && grep -Fq 'twenty_four_hour_checkpoint' "$PROJECT_DIR/tests/performance/resource_probe.py"; then
    echo "  ok   long performance evidence has no duration override and gates its 24h checkpoint"
else
    echo "  FAIL long performance evidence can be scaled or can conceal a failed 24h checkpoint"
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
final_revalidation_line="$(grep -nF 'verify_final_artifacts' "$RELEASE_SCRIPT" | tail -1 | cut -d: -f1)"
checksum_line="$(grep -nF 'step "Generating SHA256SUMS"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
if grep -Fq 'duplicate --extra basename' "$RELEASE_SCRIPT" \
        && grep -Fq 'is reserved for a release-generated artifact' "$RELEASE_SCRIPT" \
        && grep -Fq 'cp -v --no-clobber -- "$extra" "$extra_target"' "$RELEASE_SCRIPT" \
        && grep -Fq 'cmp -s -- "$extra" "$extra_target"' "$RELEASE_SCRIPT" \
        && grep -Fq 'record_final_artifact "$extra_target"' "$RELEASE_SCRIPT" \
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
        && grep -Fq -- '--appimage-updateinformation' "$RELEASE_SCRIPT" \
        && grep -Fq 'smoke-appimage.sh' "$RELEASE_SCRIPT" \
        && grep -Fq 'AppImage Hub version mismatch' "$RELEASE_SCRIPT" \
        && grep -Fq 'AppImage Manager version mismatch' "$RELEASE_SCRIPT"; then
    echo "  ok   AppImage count, canonical name, update metadata, versions, and runtime smoke are mandatory"
else
    echo "  FAIL AppImage extras can escape an exact identity/runtime check"
    fail=$((fail + 1))
fi

echo "==> Publish preflight + repository pin"
publish_auth_line="$(grep -nF 'gh auth status --hostname github.com' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
strict_gate_line="$(grep -nF 'bash "$STRICT_RELEASE_GATE" 3<<<"$RELEASE_OWNER_TEST_LICENSE_KEY"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$publish_auth_line" ] && [ -n "$strict_gate_line" ] \
        && [ "$publish_auth_line" -lt "$strict_gate_line" ] \
        && grep -Fq 'cat-file -e "${tag_commit}:RELEASE_NOTES.md"' "$RELEASE_SCRIPT" \
        && grep -Fq 'existing_release_tags="$(gh release list --repo "$RELEASE_REPO"' "$RELEASE_SCRIPT" \
        && grep -Fq 'release_command=(gh release create "$VERSION" --repo "$RELEASE_REPO")' "$RELEASE_SCRIPT"; then
    echo "  ok   publish notes/auth/collision checks precede the long gate and GitHub target is pinned"
else
    echo "  FAIL publish can fail late, collide, or target an inferred repository"
    fail=$((fail + 1))
fi
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
if [ -f "$OWNER_RUNNER" ] \
        && grep -Fq 'license::tests::owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key' "$OWNER_RUNNER" \
        && grep -Fq '"$OWNER_TEST" -- --exact --nocapture' "$OWNER_RUNNER" \
        && grep -Fq "grep -Fxc 'running 1 test'" "$OWNER_RUNNER"; then
    echo "  ok   owner-key runner requires one exact visible Cargo test"
else
    echo "  FAIL owner-key runner can accept a skipped, filtered, or zero-test Cargo run"
    fail=$((fail + 1))
fi
if XENEON_TEST_LICENSE_KEY= bash "$OWNER_RUNNER" >/dev/null 2>&1; then
    echo "  FAIL owner-key runner accepted an empty key"
    fail=$((fail + 1))
else
    echo "  ok   owner-key runner behaviorally rejects an empty key before Cargo"
fi
if XENEON_TEST_LICENSE_KEY='   ' bash "$OWNER_RUNNER" >/dev/null 2>&1; then
    echo "  FAIL owner-key runner accepted a whitespace-only key"
    fail=$((fail + 1))
else
    echo "  ok   owner-key runner behaviorally rejects a whitespace-only key before Cargo"
fi

# Use a fake Cargo plus instrumented tee/grep to prove the release wrapper's
# execution contract without possessing the real owner secret: Cargo alone sees
# the entitlement, exactly one named PASS is required, and zero tests fail.
owner_contract_bin="$(mktemp -d "${TMPDIR:-/tmp}/xe-owner-contract.XXXXXX")"
real_tee="$(command -v tee)"
real_grep="$(command -v grep)"
cat >"$owner_contract_bin/cargo" <<'EOF'
#!/usr/bin/env bash
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
rm -rf "$owner_contract_bin"
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
