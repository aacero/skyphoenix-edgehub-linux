#!/usr/bin/env bash
# run_all_tests.sh - run every developer test suite and aggregate the result.
#
# Set XENEON_RELEASE_GATE=1 for strict release semantics: C++ is configured and
# executed rather than conditionally reused, and PASS is the only acceptable
# outcome. Any missing prerequisite, SKIP, ignored test, KNOWN-RED result, or
# compositor failure makes the run fail. scripts/run_release_tests.sh is the
# complete pre-release entry point, adding hardware E2E, tool crates + coverage.
#
# Suites:
#   1. Gate/input contracts : injection-free shell + Python unit tests
#   2. Rust core            : cd core && cargo test --locked
#   3. QML GUI              : scripts/run_ui_tests.sh (offscreen qmltestrunner)
#   4. C++ (ctest)          : existing build in developer mode; clean dedicated
#                             build in strict release mode
#   5. QML requirements     : every enumerated item must be assertion-backed
#   6. Runtime E2E battery  : tests/runtime/run_*.sh - ten scenarios driving the
#                            REAL hub binary (focus goal bonus, w/h→size
#                            migration, org policy, update-check-off, secret
#                            refs, corrupt salvage, reset flags, live-push
#                            single-writer, page-name dedup, safe mode). Each needs a hub
#                            binary and SKIPs (77) if none is built/installed.
#
# Exits non-zero if any suite fails. Prints a clear per-suite summary.
set -euo pipefail

# A raw bearer key is never a supported process-environment input. Direct strict
# invocations may name a protected file; the canonical release runner supplies
# the already-read key through descriptor 3.
if [[ -v XENEON_TEST_LICENSE_KEY ]]; then
    unset XENEON_TEST_LICENSE_KEY
    echo "ERROR: XENEON_TEST_LICENSE_KEY is unsupported; use XENEON_TEST_LICENSE_KEY_FILE." >&2
    exit 2
fi
incoming_owner_test_file_supplied=0
incoming_owner_test_file=""
if [[ -v XENEON_TEST_LICENSE_KEY_FILE ]]; then
    incoming_owner_test_file_supplied=1
    incoming_owner_test_file="$XENEON_TEST_LICENSE_KEY_FILE"
fi
unset XENEON_TEST_LICENSE_KEY_FILE
incoming_owner_test_key="" # gitleaks:allow, explicit empty local; never key material
incoming_owner_test_from_fd=0
if [[ -v XENEON_OWNER_KEY_FD ]]; then
    [ "$XENEON_OWNER_KEY_FD" = "3" ] || {
        unset XENEON_OWNER_KEY_FD
        echo "ERROR: XENEON_OWNER_KEY_FD must name descriptor 3." >&2
        exit 2
    }
    [ "$incoming_owner_test_file_supplied" -eq 0 ] || {
        unset XENEON_OWNER_KEY_FD
        echo "ERROR: owner licence file and internal descriptor input cannot be combined." >&2
        exit 2
    }
    incoming_owner_test_from_fd=1
    IFS= read -r incoming_owner_test_key <&3 || incoming_owner_test_key=""
    exec 3<&-
fi
unset XENEON_OWNER_KEY_FD
if [ "${XENEON_RELEASE_GATE:-0}" = "1" ]; then
    # Direct strict invocations get the same exact toolchain as release.sh.
    export RUSTUP_TOOLCHAIN=1.86.0
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
owner_license_file_reader="$PROJECT_DIR/scripts/lib/owner_license_file.py"

# shellcheck source=lib/release_gate.sh
. "$PROJECT_DIR/scripts/lib/release_gate.sh"
if ! xeneon_release_gate_init; then
    exit 2
fi
release_gate=0
if xeneon_release_gate_enabled; then
    release_gate=1
    echo "==> STRICT RELEASE GATE: every suite must execute and pass."
    release_rust_toolchain_helper="$PROJECT_DIR/scripts/lib/release_rust_toolchain.sh"
    [ -f "$release_rust_toolchain_helper" ] || {
        echo "ERROR: release Rust toolchain helper is unavailable: $release_rust_toolchain_helper" >&2
        exit 2
    }
    # shellcheck source=lib/release_rust_toolchain.sh
    . "$release_rust_toolchain_helper"
    xeneon_release_rust_toolchain_select
    xeneon_release_rust_toolchain_verify || exit 2
fi

# All consumers share one build-tree selection. Developer runs retain the
# historical build/ default. Strict runs are pinned to a clean, dedicated tree;
# run_cpp_tests.sh owns the fail-closed cleanup immediately before configure.
developer_build_dir="$PROJECT_DIR/build"
strict_build_dir="$PROJECT_DIR/cmake-build-release-tests"
if [ "$release_gate" -eq 1 ]; then
    test_build_dir="${XENEON_TEST_BUILD_DIR:-$strict_build_dir}"
    if [ "$test_build_dir" != "$strict_build_dir" ]; then
        echo "ERROR: strict tests must use the dedicated build directory: $strict_build_dir" >&2
        exit 2
    fi
    export XENEON_TEST_BUILD_DIR="$test_build_dir"
    export XENEON_HUB="$test_build_dir/xeneon-edge-hub"
    export XENEON_MANAGER="$test_build_dir/xeneon-edge-manager"
else
    test_build_dir="${XENEON_TEST_BUILD_DIR:-$developer_build_dir}"
fi

# The release runner passes the owner-issued Pro key only so the core Cargo test
# can exercise the shipped issuer. Do not leak that entitlement into unrelated
# QML, Manager, compositor, runtime, or hardware children.
release_owner_test_key=""
if [ "$release_gate" -eq 1 ]; then
    if [ "$incoming_owner_test_from_fd" -eq 0 ]; then
        [ "$incoming_owner_test_file_supplied" -eq 1 ] || {
            echo "ERROR: strict tests require XENEON_TEST_LICENSE_KEY_FILE." >&2
            exit 2
        }
        [ -f "$owner_license_file_reader" ] || {
            echo "ERROR: owner licence file reader is unavailable: $owner_license_file_reader" >&2
            exit 2
        }
        if ! incoming_owner_test_key="$(
                env PYTHONDONTWRITEBYTECODE=1 python3 \
                    "$owner_license_file_reader" "$incoming_owner_test_file"
            )"; then
            echo "ERROR: owner-issued Pro licence file was rejected." >&2
            exit 2
        fi
    fi
    release_owner_test_key="$incoming_owner_test_key"
    case "$release_owner_test_key" in
        *[![:space:]]*) ;;
        *)
            echo "ERROR: strict Rust core tests require the owner-issued Pro key." >&2
            exit 2
            ;;
    esac
elif [ "$incoming_owner_test_file_supplied" -eq 1 ] \
        || [ "$incoming_owner_test_from_fd" -eq 1 ]; then
    echo "ERROR: owner licence input is accepted only in strict release mode." >&2
    exit 2
fi
unset incoming_owner_test_key incoming_owner_test_file

# Names and outcomes kept in parallel arrays (bash 3.2 compatible).
names=()
results=()

run_suite() {
    local name="$1"; shift
    local -a suite_command
    echo ""
    echo "==================================================================="
    echo "==> ${name}"
    echo "==================================================================="
    names+=("$name")
    if [ "$release_gate" -eq 1 ]; then
        # Frameworks including QtTest, unittest and Cargo can exit zero with
        # skipped/ignored tests. Release mode treats that as an incomplete run.
        suite_command=("$@")
        if xeneon_run_rejecting_skips "${suite_command[@]}"; then
            results+=("PASS")
            echo "--- ${name}: PASS"
        else
            results+=("FAIL")
            echo "--- ${name}: FAIL"
        fi
    elif "$@"; then
        results+=("PASS")
        echo "--- ${name}: PASS"
    else
        results+=("FAIL")
        echo "--- ${name}: FAIL"
    fi
}

# Ordinary developer and CI runs use the reviewed repository stage declaration.
# release.sh overrides both values from its already validated --version so the
# strict suite cannot accidentally certify metadata for a different candidate.
release_metadata_args=()
if [ -n "${XENEON_RELEASE_METADATA_STAGE:-}" ]; then
    release_metadata_args+=(--stage "$XENEON_RELEASE_METADATA_STAGE")
fi
if [ -n "${XENEON_RELEASE_VERSION:-}" ]; then
    release_metadata_args+=(--target-version "$XENEON_RELEASE_VERSION")
fi

# 1. Cheap, injection-free contracts. These must stay before GUI/build work so
# a broken safety boundary or hollow release gate fails in seconds.
run_suite "Release-gate contract" bash "$PROJECT_DIR/scripts/check_release_gate_contract.sh"
run_suite "Release provenance + signed SBOM contract" \
    bash "$PROJECT_DIR/scripts/check_release_provenance_contract.sh"
run_suite "CI/toolchain/release metadata contract" \
    env PYTHONDONTWRITEBYTECODE=1 \
        python3 "$PROJECT_DIR/scripts/check_ci_release_metadata_contract.py" \
        "${release_metadata_args[@]}"
run_suite "Release metadata lifecycle unit tests" \
    env PYTHONDONTWRITEBYTECODE=1 \
        python3 "$PROJECT_DIR/tests/runtime/test_ci_release_metadata_contract.py"
run_suite "Signed audit-artifact finalizer contract" \
    bash "$PROJECT_DIR/scripts/check_audit_artifact_finalizer.sh"
run_suite "Signed stable-publication certification contract" \
    bash "$PROJECT_DIR/scripts/check_release_certification_contract.sh"
run_suite "Unsigned release evidence builder contracts" \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/runtime/test_release_evidence_builders.py"
run_suite "Signed release-run semantic evidence contract" \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/runtime/test_release_run_contract.py"
run_suite "Desktop notification + MPRIS evidence contract" \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/runtime/test_desktop_bridge_evidence.py"
run_suite "Certified native package byte-binding contract" \
    bash "$PROJECT_DIR/scripts/check_native_package_binding_contract.sh"
run_suite "Published AppImage zsync and stable-promotion contract" \
    bash "$PROJECT_DIR/scripts/check_published_zsync_contract.sh"
run_suite "Safe local update lifecycle contract" \
    bash "$PROJECT_DIR/scripts/check_update_local_contract.sh"
run_suite "Manual physical-touch sealing contract" \
    bash "$PROJECT_DIR/scripts/check_manual_touch_audit_contract.sh"
run_suite "Input safety (injection-free unit tests)" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_DIR/tests/hardware/test_input_safety.py"
run_suite "Hardware E2E manifest contract (injection-free)" \
    env PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_DIR/tests/hardware/test_e2e_contract.py"
run_suite "Performance sampler unit + release-contract tests (injection-free)" \
    env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
        -s "$PROJECT_DIR/tests/performance" -p 'test_*.py' -v

# Export the entitlement inside the command-side pipeline subshell only. The
# strict output scanner and its tee process therefore never inherit it.
run_rust_core_with_owner_key() {
    local cargo_rc
    export XENEON_TEST_LICENSE_KEY="$release_owner_test_key"
    if bash -c 'cd "'"$PROJECT_DIR"'/core" && cargo test --locked'; then
        cargo_rc=0
    else
        cargo_rc=$?
    fi
    unset XENEON_TEST_LICENSE_KEY
    return "$cargo_rc"
}

# 2. Rust core tests.
if [ "$release_gate" -eq 1 ]; then
    run_suite "Rust (cargo test)" run_rust_core_with_owner_key
    release_owner_test_key=""
else
    run_suite "Rust (cargo test)" bash -c 'cd "'"$PROJECT_DIR"'/core" && cargo test --locked'
fi

# 3. C++ ctest. Both modes configure and build before testing. Reusing an
# existing ctest tree without rebuilding can run a Hub from an unrelated commit
# in the runtime tier while presenting results under the current source SHA.
# Release mode additionally uses a clean dedicated tree and makes ctest verbose
# so an internal QSKIP is visible to the strict output scanner.
if [ "$release_gate" -eq 1 ]; then
    # Release mode never trusts CMAKE/CTEST command overrides: `CTEST=true`
    # would otherwise turn the entire C++ tier into a zero-work success.
    real_cmake="$(command -v cmake 2>/dev/null || true)"
    real_ctest="$(command -v ctest 2>/dev/null || true)"
    [ -z "$real_cmake" ] && [ -x "$HOME/.local/bin/cmake" ] && real_cmake="$HOME/.local/bin/cmake"
    [ -z "$real_ctest" ] && [ -x "$HOME/.local/bin/ctest" ] && real_ctest="$HOME/.local/bin/ctest"
    run_suite "C++ (strict configure + build + ctest)" \
        env CMAKE="$real_cmake" XENEON_REAL_CTEST="$real_ctest" \
            CTEST="$PROJECT_DIR/scripts/lib/ctest_release_gate.sh" \
            XENEON_RELEASE_GATE=1 \
            XENEON_TEST_BUILD_DIR="$test_build_dir" \
            bash "$PROJECT_DIR/scripts/run_cpp_tests.sh" "$test_build_dir"
else
    run_suite "C++ (configure + build + ctest)" \
        bash "$PROJECT_DIR/scripts/run_cpp_tests.sh" "$test_build_dir"
fi

# 4. QML GUI tests. C++ configuration runs first so strict mode reuses the
# resource-aware QuickTest runner from the same clean candidate build tree.
run_suite "QML GUI (compiled resources)" \
    env QT_QPA_PLATFORM=offscreen bash "$PROJECT_DIR/scripts/run_ui_tests.sh"

# 5. QML enumerated-requirements assertion gate.
run_suite "QML enumerated requirements (all assertion-backed)" \
    python3 "$PROJECT_DIR/scripts/qml_coverage.py"

# Static guard against the scene-graph walk bug that caused a system-wide OOM on
# 2026-07-19 (three independent copies; 18.8 GB and 20 GB RSS). Cheap and fast -
# keep it ahead of the heavy suites so a reintroduction fails in seconds.
run_suite "Tree-walk memory guard (check_tree_walks.py)" python3 "$PROJECT_DIR/scripts/check_tree_walks.py"

# 5b. Egress lint - raw XMLHttpRequest may only live in the NetHub gate.
run_suite "Egress lint (no raw XHR)" bash "$PROJECT_DIR/scripts/check_no_raw_xhr.sh"
run_suite "Live-test lint (no inert test_*_data)" bash "$PROJECT_DIR/scripts/check_live_tests.sh"
run_suite "Open-defect lint (bugs belong in BACKLOG)" bash "$PROJECT_DIR/scripts/check_no_open_bug_notes.sh"
# The Manager is never tested inside a nested compositor - it is tested against
# a REAL hub in tests/hardware/. See the script header for why this is absolute.
run_suite "No Manager tests under a compositor" bash "$PROJECT_DIR/scripts/check_no_manager_compositor_tests.sh"
run_suite "Doc links (files + anchors)" bash "$PROJECT_DIR/scripts/check_doc_links.sh"
run_suite "UI links (no dead openUrlExternally)" bash "$PROJECT_DIR/scripts/check_ui_links.sh"
# Bundled fonts. Theme.qml resolves every face through a FontLoader so each
# machine renders the same glyphs; that spans three files nothing compared.
# tst_theme.qml proves the loaders are Ready inside the TEST RUNNER, which has
# its own fonts.qrc line - so the suite would stay green while the shipped Hub
# and Manager fell back to fontconfig.
run_suite "Bundled fonts (Theme.qml <-> fonts.qrc <-> targets)" python3 "$PROJECT_DIR/scripts/check_bundled_fonts.py"

# 5c. Icon lint - every widget type needs a bundled, registered picker icon.
#     The compiled-resource QML suite exercises resolution; this static check
#     additionally proves exact catalog-to-resource parity.
run_suite "Icon lint (widget types)" bash "$PROJECT_DIR/scripts/check_widget_icons.sh"
run_suite "Widget resource parity (Catalog, Hub, Manager)" \
    python3 "$PROJECT_DIR/scripts/check_widget_resources.py"

# 5d. AppImage update contract - the cross-file invariants of the zsync delta-update
#     path (artifact name ↔ binary appVersion ↔ zsync -u URL ↔ UpdateChecker's repo).
#     No single suite spans those four files, and every one of them was independently
#     broken while the rest of the tests stayed green.
run_suite "AppImage update contract" bash "$PROJECT_DIR/scripts/check_appimage_update_contract.sh"
run_suite "Rust third-party notice inventory" \
    python3 "$PROJECT_DIR/scripts/generate_rust_third_party_notices.py" \
        --check "$PROJECT_DIR/packaging/THIRD_PARTY_NOTICES-RUST.txt"
run_suite "Debian machine-readable copyright" \
    python3 "$PROJECT_DIR/scripts/generate_debian_copyright.py" \
        --check "$PROJECT_DIR/packaging/debian/copyright"
run_suite "CPack release identity + tooling contract" \
    bash "$PROJECT_DIR/scripts/check_cpack_contract.sh"

# 6. Runtime E2E battery - drives the real hub binary through one scenario
#    script per guarantee (see tests/runtime/README.md). Exit 77 = SKIP (no
#    binary built or installed); anything else is PASS/FAIL as usual.
runtime_scenarios=(
    "focus goal bonus:run_focus_goal_bonus.sh"
    "01 w/h→size migration:run_01_wh_size_migration.sh"
    "02 org policy:run_02_org_policy.sh"
    "03 update check off:run_03_update_check_off.sh"
    "04 secret refs:run_04_secret_refs.sh"
    "05 corrupt salvage:run_05_corrupt_salvage.sh"
    "06 reset flags:run_06_reset_flags.sh"
    "07 live push single-writer:run_07_live_push_single_writer.sh"
    "08 page dedup roundtrip:run_08_page_dedup_roundtrip.sh"
    "09 HTTP fault recovery:run_09_http_faults.sh"
    "10 safe-mode widget boundary:run_10_safe_mode.sh"
)
for entry in "${runtime_scenarios[@]}"; do
    rt_name="${entry%%:*}"; rt_script="${entry#*:}"
    echo ""
    echo "==================================================================="
    echo "==> Runtime E2E ($rt_script)"
    echo "==================================================================="
    names+=("Runtime E2E ($rt_name)")
    # A failed/partial strict C++ build must not make this tier silently fall
    # back to the mutable developer build or an installed hub. Record the
    # candidate failure directly and continue collecting the remaining verdicts.
    if [ "$release_gate" -eq 1 ] && [ ! -x "$XENEON_HUB" ]; then
        echo "FAIL: strict candidate hub is missing or not executable: $XENEON_HUB"
        results+=("FAIL")
        continue
    fi
    # `if` guards against `set -e` aborting on a non-zero (fail/skip) exit.
    if [ "$release_gate" -eq 1 ]; then
        if xeneon_run_rejecting_skips \
            bash "$PROJECT_DIR/tests/runtime/$rt_script"; then rt_rc=0; else rt_rc=$?; fi
    else
        if bash "$PROJECT_DIR/tests/runtime/$rt_script"; then rt_rc=0; else rt_rc=$?; fi
    fi
    if [ "$rt_rc" -eq 0 ]; then
        results+=("PASS"); echo "--- Runtime E2E ($rt_name): PASS"
    elif [ "$rt_rc" -eq 77 ]; then
        results+=("SKIP"); echo "--- Runtime E2E ($rt_name): SKIPPED (no hub binary)"
    else
        results+=("FAIL"); echo "--- Runtime E2E ($rt_name): FAIL"
    fi
done

# 6b. Manager suites - the REAL Manager binary driven with REAL input against
#     the REAL hub over the control socket. These replaced the deleted
#     tests/gui Manager tests, which ran against a stubbed backend inside a
#     nested compositor and whose pixel assertions were provably false.
#
#     Desktop input is opt-in twice over (XENEON_HW_INPUT + _DESKTOP), because
#     the cursor moves on the owner's screen. Without both, this SKIPs loudly.
echo ""
echo "==================================================================="
echo "==> Manager (real binaries, real hub)"
echo "==================================================================="
names+=("Manager (real Manager + real hub)")
if { [ "$release_gate" -eq 1 ] && xeneon_run_rejecting_skips \
        bash "$PROJECT_DIR/scripts/run_manager_tests.sh"; } || \
   { [ "$release_gate" -eq 0 ] && bash "$PROJECT_DIR/scripts/run_manager_tests.sh"; }; then
    results+=("PASS")
else
    mgr_rc=$?
    if [ "$mgr_rc" -eq 77 ]; then
        results+=("SKIP")
        echo "--- Manager suites: SKIPPED (desktop input not opted in)"
    else
        results+=("FAIL")
    fi
fi

# 7. QML compositor suite (tests/gui) - real KWin, real input, real pixels, and
#    the ONLY aspect-ratio assertions in the repo. It was orphaned for months
#    AND could not fail (it exited 0 unconditionally; fixed 2026-07-20).
#
#    This is blocking in both developer and release runs. The historical red
#    baseline was cleared on 2026-07-20; retaining a KNOWN-RED escape hatch after
#    that point would let the only real-compositor tier regress silently.
if [ "${XENEON_SKIP_GUI_SUITE:-0}" = "1" ]; then
    echo ""; echo "==> QML compositor suite: SKIPPED (XENEON_SKIP_GUI_SUITE=1)"
    if [ "$release_gate" -eq 1 ]; then
        names+=("QML compositor (tests/gui) [STRICT]")
    else
        names+=("QML compositor (tests/gui) [BLOCKING]")
    fi
    results+=("SKIP")
elif ! command -v kwin_wayland >/dev/null 2>&1; then
    echo ""; echo "==> QML compositor suite: SKIPPED (no kwin_wayland)"
    if [ "$release_gate" -eq 1 ]; then
        names+=("QML compositor (tests/gui) [STRICT]")
    else
        names+=("QML compositor (tests/gui) [NONBLOCKING]")
    fi
    results+=("SKIP")
else
    echo ""
    echo "==================================================================="
    if [ "$release_gate" -eq 1 ]; then
        echo "==> QML compositor suite (tests/gui)  [STRICT / BLOCKING]"
    else
        echo "==> QML compositor suite (tests/gui)  [BLOCKING]"
    fi
    echo "==================================================================="
    if [ "$release_gate" -eq 1 ]; then
        names+=("QML compositor (tests/gui) [STRICT]")
    else
        names+=("QML compositor (tests/gui) [BLOCKING]")
    fi
    # -j8 deliberately: run_gui_tests.sh defaults to J=1, which its own header
    # says takes "hours"; -j8 brings the tier under half an hour. Each file gets
    # its OWN nested KWin, and run_bounded caps every slot at RUN_MEM_MAX_MB, so
    # the ceiling is bounded rather than trusting the kernel OOM killer.
    if { [ "$release_gate" -eq 1 ] && xeneon_run_rejecting_skips \
            bash "$PROJECT_DIR/tests/gui/run_gui_tests.sh" -j"${XENEON_GUI_JOBS:-8}"; } || \
       { [ "$release_gate" -eq 0 ] && \
            bash "$PROJECT_DIR/tests/gui/run_gui_tests.sh" -j"${XENEON_GUI_JOBS:-8}"; }; then
        results+=("PASS")
        run_suite "Reviewed visual baselines (30 widgets + 19 presets + orientation)" \
            python3 "$PROJECT_DIR/scripts/visual_baselines.py" compare
    else
        results+=("FAIL")
        echo "--- QML compositor suite: FAIL"
        names+=("Reviewed visual baselines (30 widgets + 19 presets + orientation)")
        results+=("NOT RUN")
        echo "--- Visual baselines: NOT RUN (compositor evidence failed)"
    fi
fi

# --- Summary ---
echo ""
echo "==================================================================="
echo "  TEST SUMMARY"
echo "==================================================================="
fail=0
for i in "${!names[@]}"; do
    printf "  %-40s %s\n" "${names[$i]}" "${results[$i]}"
    if ! xeneon_gate_accepts_result "${results[$i]}"; then
        fail=1
    fi
done
echo "==================================================================="

if [ "$fail" -ne 0 ]; then
    if [ "$release_gate" -eq 1 ]; then
        echo "RESULT: FAILURE (strict release gate requires PASS for every suite)"
    else
        echo "RESULT: FAILURE"
    fi
    exit 1
fi
echo "RESULT: SUCCESS"
