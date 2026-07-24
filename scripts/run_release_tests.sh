#!/usr/bin/env bash
# The one strict pre-release test entry point.
#
# This intentionally requires a live KDE Wayland session, a connected Xeneon
# Edge, writable /dev/uinput, both explicit input opt-ins, a real owner-issued
# Pro key, coverage tooling and the network-namespace attestation prerequisites.
# Missing prerequisites are a release failure, never an implicit omission. Every
# long-running child is bounded by its own runner and/or an outer wall-clock timeout.
set -uo pipefail

# Keep the real entitlement out of every unrelated compiler, GUI, compositor,
# hardware, and coverage child. It is handed to the two Rust core invocations
# through descriptor 3; the receiving runner exports it only to Cargo itself.
OWNER_TEST_LICENSE_KEY="${XENEON_TEST_LICENSE_KEY:-}"
if [ "${XENEON_OWNER_KEY_FD:-}" = "3" ]; then
    IFS= read -r OWNER_TEST_LICENSE_KEY <&3 || OWNER_TEST_LICENSE_KEY=""
    exec 3<&-
fi
unset XENEON_TEST_LICENSE_KEY
unset XENEON_OWNER_KEY_FD

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

export XENEON_RELEASE_GATE=1
export XENEON_COVERAGE=ON
# One pinned CMake tree is shared by C++ tests, real-binary suites, and gcovr.
# run_cpp_tests.sh recreates it from scratch, so no mutable developer build/
# cache or binary can influence the candidate verdict.
export XENEON_TEST_BUILD_DIR="$PROJECT_DIR/cmake-build-release-tests"
# Pin completeness-sensitive knobs. Developer overrides that shorten a soak or
# select a widget subset must never weaken a release verdict.
export XENEON_HUB="$XENEON_TEST_BUILD_DIR/xeneon-edge-hub"
export XENEON_MANAGER="$XENEON_TEST_BUILD_DIR/xeneon-edge-manager"
PERFORMANCE_BUILD_DIR="$PROJECT_DIR/cmake-build-release-performance"
PERFORMANCE_HUB="$PERFORMANCE_BUILD_DIR/xeneon-edge-hub"
export XENEON_HW_IDLE_SECONDS=3
export E2E_SOAK_SECONDS=1200
export XENEON_EGRESS_SECS=10
# The AppImage contract supports mutated-tree negative controls in developer
# tests. A release must always audit the signed candidate, never a caller-chosen
# alternate tree.
export XENEON_CONTRACT_REPO="$PROJECT_DIR"

# shellcheck source=lib/release_gate.sh
. "$PROJECT_DIR/scripts/lib/release_gate.sh"

list_suites() {
    cat <<'EOF'
core/Cargo.toml (rustfmt + clippy; tests via scripts/run_all_tests.sh)
owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key (explicit --nocapture)
tools/license-tool/Cargo.toml (rustfmt + clippy + tests)
tools/license-webhook/Cargo.toml (rustfmt + clippy + tests)
scripts/run_all_tests.sh (strict: unit, QML, C++, runtime, Manager, compositor)
tests/hardware/test_input_safety.py (via scripts/run_all_tests.sh)
tests/hardware/test_e2e_contract.py (via scripts/run_all_tests.sh)
tests/hardware/edge_e2e.py
tests/hardware/e2e_buildup.py
tests/hardware/widget_render_matrix.py
scripts/coverage.sh
tests/performance/prepare_release_candidate.sh
tests/performance/run_hub_profiles.py --mode short (literal 5m idle + 5m active + first render)
tests/performance/run_hub_profiles.py --mode idle-48h (literal 48h; includes a gated 24h checkpoint)
EOF
}

case "${1:-}" in
    --list)
        list_suites
        exit 0
        ;;
    -h|--help)
        echo "Usage: XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 XENEON_TEST_LICENSE_KEY=<key> $0 [--list]"
        echo "Runs the complete strict pre-release suite; no omissions are accepted."
        exit 0
        ;;
    "") ;;
    *) echo "ERROR: unknown argument '$1' (use --help)" >&2; exit 2 ;;
esac

preflight_fail=0
preflight_ok() { printf '  ok   %s\n' "$1"; }
preflight_bad() { printf '  FAIL %s\n' "$1" >&2; preflight_fail=$((preflight_fail + 1)); }

require_command() {
    if command -v "$1" >/dev/null 2>&1; then
        preflight_ok "$1"
    else
        preflight_bad "$1 is required"
    fi
}

require_command_or_executable() {
    if command -v "$1" >/dev/null 2>&1 || [ -x "$2" ]; then
        preflight_ok "$1"
    else
        preflight_bad "$1 is required"
    fi
}

echo "==================================================================="
echo "  STRICT RELEASE TEST PREFLIGHT"
echo "==================================================================="

case "$OWNER_TEST_LICENSE_KEY" in
    *[![:space:]]*)
        preflight_ok "XENEON_TEST_LICENSE_KEY is non-empty (owner-key attestation enabled)"
        ;;
    *)
        preflight_bad "set XENEON_TEST_LICENSE_KEY to a real owner-issued Pro key"
        ;;
esac
if [ "${XENEON_HW_INPUT:-0}" = "1" ]; then
    preflight_ok "XENEON_HW_INPUT=1 (live Edge input explicitly authorised)"
else
    preflight_bad "set XENEON_HW_INPUT=1 to authorise Edge-confined synthetic input"
fi
if [ "${XENEON_HW_INPUT_DESKTOP:-0}" = "1" ]; then
    preflight_ok "XENEON_HW_INPUT_DESKTOP=1 (Manager input explicitly authorised)"
else
    preflight_bad "set XENEON_HW_INPUT_DESKTOP=1 to authorise Manager-window input"
fi
if [ "${XENEON_GEOM_TRUST:-0}" = "1" ]; then
    preflight_bad "XENEON_GEOM_TRUST=1 disables live geometry verification"
else
    preflight_ok "live geometry verification is mandatory"
fi
if [ "${XENEON_SKIP_GUI_SUITE:-0}" = "1" ]; then
    preflight_bad "XENEON_SKIP_GUI_SUITE=1 is incompatible with a release run"
else
    preflight_ok "compositor suite is mandatory"
fi
case "${QT_QPA_PLATFORM:-}" in
    offscreen|minimal)
        preflight_bad "QT_QPA_PLATFORM=${QT_QPA_PLATFORM} cannot drive the real hardware tiers"
        ;;
    *) preflight_ok "hardware Qt platform is not forced headless" ;;
esac

for command_name in \
    bash cargo cargo-llvm-cov git ip kscreen-doctor \
    kwin_wayland python3 spectacle strace tee timeout unshare busctl; do
    require_command "$command_name"
done
require_command_or_executable cmake "$HOME/.local/bin/cmake"
require_command_or_executable ctest "$HOME/.local/bin/ctest"
require_command_or_executable gcovr "$HOME/.local/bin/gcovr"

# A caller-supplied QMLTESTRUNNER=/bin/true previously made every offscreen QML
# file exit zero without running a single check. Ignore that override. The suite
# now builds and requires the repository's resource-aware QuickTest runner from
# the clean candidate build tree and still requires live per-file Totals.
unset QMLTESTRUNNER
unset XENEON_STRICT_QMLTESTRUNNER
preflight_ok "resource-aware QuickTest runner will be built from the candidate tree"

if [ -c /dev/uinput ] && [ -r /dev/uinput ] && [ -w /dev/uinput ]; then
    preflight_ok "/dev/uinput is a readable/writable character device"
else
    preflight_bad "/dev/uinput must exist and be readable/writable by this user"
fi

runtime_dir="${XDG_RUNTIME_DIR:-}"
wayland_display="${WAYLAND_DISPLAY:-wayland-0}"
if [ -z "$runtime_dir" ] || [ ! -d "$runtime_dir" ]; then
    preflight_bad "XDG_RUNTIME_DIR must name the live session runtime directory"
else
    case "$wayland_display" in
        /*) wayland_socket="$wayland_display" ;;
        *) wayland_socket="$runtime_dir/$wayland_display" ;;
    esac
    if [ -S "$wayland_socket" ]; then
        preflight_ok "live Wayland socket ($wayland_socket)"
    else
        preflight_bad "live Wayland socket not found at $wayland_socket"
    fi
fi

if env PYTHONDONTWRITEBYTECODE=1 python3 -c 'from PIL import Image' >/dev/null 2>&1; then
    preflight_ok "Python Pillow"
else
    preflight_bad "Python Pillow is required for render evidence"
fi

# Both probes are read-only. The first verifies that the Edge geometry can be
# derived from the live KScreen layout; the second ensures the Manager has a
# non-Edge desktop screen on which it can be render-verified and confined.
if timeout 20 env PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="$PROJECT_DIR/tests/hardware" python3 -c \
    'import uinput_touch as u; g=u.detect_edge_ex(); assert g[3] > 0 and g[4] > 0; print(g[0])' \
    >/dev/null 2>&1; then
    preflight_ok "connected Edge geometry is detectable"
else
    preflight_bad "could not detect and verify the connected Edge geometry"
fi
if timeout 20 env PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="$PROJECT_DIR/tests/hardware" python3 -c \
    'import uinput_touch as u, desktop_target as d; g=u.detect_edge_ex(); assert d.desktop_screens(g[0])' \
    >/dev/null 2>&1; then
    preflight_ok "a non-Edge Manager target screen is available"
else
    preflight_bad "no verified non-Edge screen is available for the Manager"
fi

if timeout 15 busctl --user status org.kde.KWin >/dev/null 2>&1; then
    preflight_ok "KWin session D-Bus service"
else
    preflight_bad "org.kde.KWin is unavailable on the user D-Bus"
fi

# Scenario 03's strongest privacy assertion needs both tools and permission to
# create an unprivileged network+mount namespace. Falling back to its proxy is
# useful in developer mode but not sufficient for a release verdict.
if command -v unshare >/dev/null 2>&1 && \
   timeout 15 unshare --net --mount --map-root-user true >/dev/null 2>&1; then
    preflight_ok "unprivileged network namespace (real no-egress attestation)"
else
    preflight_bad "network namespace unavailable; the real no-egress attestation cannot run"
fi

if [ "$preflight_fail" -ne 0 ]; then
    echo "==================================================================="
    echo "RESULT: FAILURE ($preflight_fail release prerequisite(s) missing)"
    exit 1
fi

names=()
results=()
run_release_suite() {
    local name="$1" max_seconds="$2"; shift 2
    echo ""
    echo "==================================================================="
    echo "==> $name (timeout ${max_seconds}s)"
    echo "==================================================================="
    names+=("$name")
    if xeneon_run_rejecting_skips \
        timeout --signal=INT --kill-after=60 "$max_seconds" "$@"; then
        results+=("PASS")
        echo "--- $name: PASS"
    else
        results+=("FAIL")
        echo "--- $name: FAIL"
    fi
}

# Rust static analysis is intentionally outside run_all_tests.sh: developer
# runs stay quick, while a release verifies every first-party Rust crate.
run_release_suite "Rust core format" 600 \
    cargo fmt --manifest-path "$PROJECT_DIR/core/Cargo.toml" --all -- --check
run_release_suite "Rust core clippy" 1800 \
    cargo clippy --manifest-path "$PROJECT_DIR/core/Cargo.toml" --all-targets --locked -- -D warnings
export XENEON_OWNER_KEY_FD=3
run_release_suite "Owner Pro key against shipped issuer" 600 \
    bash "$PROJECT_DIR/scripts/run_owner_key_release_test.sh" 3<<<"$OWNER_TEST_LICENSE_KEY"
unset XENEON_OWNER_KEY_FD

for tool in license-tool license-webhook; do
    manifest="$PROJECT_DIR/tools/$tool/Cargo.toml"
    run_release_suite "$tool format" 600 \
        cargo fmt --manifest-path "$manifest" --all -- --check
    run_release_suite "$tool clippy" 1800 \
        cargo clippy --manifest-path "$manifest" --all-targets --locked -- -D warnings
    run_release_suite "$tool tests" 1800 \
        cargo test --manifest-path "$manifest" --locked
done

# XENEON_COVERAGE=ON makes the strict C++ build in run_all produce the gcno
# artifacts consumed by the final coverage gate. Pass the owner key through a
# private inherited descriptor: exporting it here would expose it to timeout,
# tee, and the entire multi-hour integration process tree.
export XENEON_OWNER_KEY_FD=3
run_release_suite "Strict complete developer/integration suite" \
    18000 \
    bash "$PROJECT_DIR/scripts/run_all_tests.sh" 3<<<"$OWNER_TEST_LICENSE_KEY"
unset XENEON_OWNER_KEY_FD
OWNER_TEST_LICENSE_KEY=""

# Current non-legacy real-device suites. These are deliberately explicit: a
# release manifest is reviewable, and the contract check prevents orphaning.
run_release_suite "Real Edge comprehensive E2E + soak" \
    3600 \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/scripts/run_hardware_python.py" \
        "$PROJECT_DIR/tests/hardware/edge_e2e.py"
run_release_suite "Real Edge incremental build-up" \
    1800 \
    env PYTHONDONTWRITEBYTECODE=1 XENEON_BUILDUP_SETTLE=0.25 \
        python3 "$PROJECT_DIR/scripts/run_hardware_python.py" \
        "$PROJECT_DIR/tests/hardware/e2e_buildup.py"
run_release_suite "Real Edge widget render matrix" \
    1800 \
    env PYTHONDONTWRITEBYTECODE=1 XENEON_WIDGETS= \
        python3 "$PROJECT_DIR/scripts/run_hardware_python.py" \
        "$PROJECT_DIR/tests/hardware/widget_render_matrix.py"

run_release_suite "Coverage gates" 7200 \
    bash "$PROJECT_DIR/scripts/coverage.sh"

# Coverage instrumentation changes code generation and is not valid CPU/RSS
# evidence. Rebuild the same source revision in a second fixed, clean Release
# tree with coverage and QA hooks disabled, then measure only that pinned
# candidate. The long mode has no duration override: it waits a literal 48
# hours and independently gates the first 24-hour checkpoint.
run_release_suite "Fresh non-instrumented performance candidate" 7200 \
    bash "$PROJECT_DIR/tests/performance/prepare_release_candidate.sh"

if ! performance_evidence_root="$(mktemp -d "${TMPDIR:-/tmp}/xeneon-release-performance.XXXXXX")"; then
    echo "RESULT: FAILURE - could not create the performance evidence directory" >&2
    exit 1
fi
echo "Performance evidence root: $performance_evidence_root"
run_release_suite "Hub startup + literal 5m idle/10-widget performance" 1200 \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/performance/run_hub_profiles.py" \
        --mode short --hub "$PERFORMANCE_HUB" \
        --output-dir "$performance_evidence_root/short"
run_release_suite "Hub literal 48h idle stability/performance soak" 174600 \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/performance/run_hub_profiles.py" \
        --mode idle-48h --hub "$PERFORMANCE_HUB" \
        --output-dir "$performance_evidence_root/idle-48h"

echo ""
echo "==================================================================="
echo "  STRICT RELEASE TEST SUMMARY"
echo "==================================================================="
release_fail=0
for i in "${!names[@]}"; do
    printf "  %-52s %s\n" "${names[$i]}" "${results[$i]}"
    if ! xeneon_gate_accepts_result "${results[$i]}"; then
        release_fail=1
    fi
done
echo "==================================================================="
if [ "$release_fail" -ne 0 ]; then
    echo "RESULT: FAILURE - release is blocked"
    exit 1
fi
echo "RESULT: SUCCESS - every release suite executed and passed"
