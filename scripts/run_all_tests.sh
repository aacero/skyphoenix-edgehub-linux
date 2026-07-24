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
#   2. Rust core            : cd core && cargo test
#   3. QML GUI              : scripts/run_ui_tests.sh (offscreen qmltestrunner)
#   4. C++ (ctest)          : existing build in developer mode; clean dedicated
#                             build in strict release mode
#   5. QML behavior matrix  : python3 scripts/qml_coverage.py
#   6. Runtime E2E battery  : tests/runtime/run_*.sh - nine scenarios driving the
#                            REAL hub binary (focus goal bonus, w/h→size
#                            migration, org policy, update-check-off, secret
#                            refs, corrupt salvage, reset flags, live-push
#                            single-writer, page-name dedup). Each needs a hub
#                            binary and SKIPs (77) if none is built/installed.
#
# Exits non-zero if any suite fails. Prints a clear per-suite summary.
set -euo pipefail

# Remove the owner entitlement before even the path-resolution subprocess. The
# strict release path may supply it through descriptor 3 instead of environment.
incoming_owner_test_key="${XENEON_TEST_LICENSE_KEY:-}"
if [ "${XENEON_OWNER_KEY_FD:-}" = "3" ]; then
    IFS= read -r incoming_owner_test_key <&3 || incoming_owner_test_key=""
    exec 3<&-
fi
unset XENEON_TEST_LICENSE_KEY
unset XENEON_OWNER_KEY_FD

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/release_gate.sh
. "$PROJECT_DIR/scripts/lib/release_gate.sh"
if ! xeneon_release_gate_init; then
    exit 2
fi
release_gate=0
if xeneon_release_gate_enabled; then
    release_gate=1
    echo "==> STRICT RELEASE GATE: every suite must execute and pass."
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
    release_owner_test_key="$incoming_owner_test_key"
    case "$release_owner_test_key" in
        *[![:space:]]*) ;;
        *)
            echo "ERROR: strict Rust core tests require the owner-issued Pro key." >&2
            exit 2
            ;;
    esac
fi
unset incoming_owner_test_key

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

# 1. Cheap, injection-free contracts. These must stay before GUI/build work so
# a broken safety boundary or hollow release gate fails in seconds.
run_suite "Release-gate contract" bash "$PROJECT_DIR/scripts/check_release_gate_contract.sh"
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
    if bash -c 'cd "'"$PROJECT_DIR"'/core" && cargo test'; then
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
    run_suite "Rust (cargo test)" bash -c 'cd "'"$PROJECT_DIR"'/core" && cargo test'
fi

# 3. C++ ctest. A developer run keeps the historical fast path (reuse an
# existing test build or report SKIP). A release run ALWAYS configures, builds,
# and executes with QA hooks, and ctest is made verbose so an internal QSKIP is
# visible to the strict output scanner.
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
elif [ -d "$test_build_dir" ] && [ -f "$test_build_dir/CTestTestfile.cmake" ]; then
    # The two smoke tests QSKIP unless the tree was configured with
    # -DXENEON_QA_HOOKS=ON, because XENEON_GRAB is compiled out otherwise. A
    # default build therefore reports 21/21 green having launched NEITHER real
    # binary. Silent skips are how a suite rots, so say it out loud.
    if ! grep -q '^XENEON_QA_HOOKS:BOOL=ON' "$test_build_dir/CMakeCache.txt" 2>/dev/null; then
        echo ""
        echo "!! WARNING: $test_build_dir configured WITHOUT -DXENEON_QA_HOOKS=ON."
        echo "!! tst_smoke_hub and tst_smoke_manager will QSKIP - ctest will report"
        echo "!! green having never launched the real hub or manager binary."
        echo "!! Reconfigure: cmake -B '$test_build_dir' -DXENEON_BUILD_TESTS=ON -DXENEON_QA_HOOKS=ON"
        echo ""
        names+=("C++ smoke hooks (XENEON_QA_HOOKS)")
        if [ "${XENEON_ALLOW_SMOKE_SKIP:-0}" = "1" ]; then
            results+=("SKIP")
        else
            results+=("FAIL")
        fi
    else
        names+=("C++ smoke hooks (XENEON_QA_HOOKS)")
        results+=("PASS")
    fi
    run_suite "C++ (ctest)" ctest --test-dir "$test_build_dir" --output-on-failure
else
    echo ""
    echo "==> C++ (ctest): SKIPPED (no test tree at $test_build_dir; run scripts/run_cpp_tests.sh)"
    names+=("C++ (ctest)")
    results+=("SKIP")
fi

# 4. QML GUI tests. C++ configuration runs first so strict mode reuses the
# resource-aware QuickTest runner from the same clean candidate build tree.
run_suite "QML GUI (compiled resources)" \
    env QT_QPA_PLATFORM=offscreen bash "$PROJECT_DIR/scripts/run_ui_tests.sh"

# 5. QML behavior-matrix coverage gate.
run_suite "QML behavior matrix (qml_coverage.py)" python3 "$PROJECT_DIR/scripts/qml_coverage.py"

# Static guard against the scene-graph walk bug that caused a system-wide OOM on
# 2026-07-19 (three independent copies; 18.8 GB and 20 GB RSS). Cheap and fast -
# keep it ahead of the heavy suites so a reintroduction fails in seconds.
run_suite "Tree-walk memory guard (check_tree_walks.py)" python3 "$PROJECT_DIR/scripts/check_tree_walks.py"

# 5b. Egress lint - raw XMLHttpRequest may only live in the NetHub gate.
run_suite "Egress lint (no raw XHR)" bash "$PROJECT_DIR/scripts/check_no_raw_xhr.sh"
run_suite "Live-test lint (no inert test_*_data)" bash "$PROJECT_DIR/scripts/check_live_tests.sh"
# The Manager is never tested inside a nested compositor - it is tested against
# a REAL hub in tests/hardware/. See the script header for why this is absolute.
run_suite "No Manager tests under a compositor" bash "$PROJECT_DIR/scripts/check_no_manager_compositor_tests.sh"
run_suite "Doc links (files + anchors)" bash "$PROJECT_DIR/scripts/check_doc_links.sh"
run_suite "UI links (no dead openUrlExternally)" bash "$PROJECT_DIR/scripts/check_ui_links.sh"

# 5c. Icon lint - every widget type needs a bundled, registered picker icon (the
#     QML suite can't see missing assets: it runs source-tree, with no qrc).
run_suite "Icon lint (widget types)" bash "$PROJECT_DIR/scripts/check_widget_icons.sh"
run_suite "Widget resource parity (Catalog, Hub, Manager)" \
    python3 "$PROJECT_DIR/scripts/check_widget_resources.py"

# 5d. AppImage update contract - the cross-file invariants of the zsync delta-update
#     path (artifact name ↔ binary appVersion ↔ zsync -u URL ↔ UpdateChecker's repo).
#     No single suite spans those four files, and every one of them was independently
#     broken while the rest of the tests stayed green.
run_suite "AppImage update contract" bash "$PROJECT_DIR/scripts/check_appimage_update_contract.sh"
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
    else
        results+=("FAIL")
        echo "--- QML compositor suite: FAIL"
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
