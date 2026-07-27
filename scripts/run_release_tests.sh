#!/usr/bin/env bash
# The one strict pre-release test entry point.
#
# This intentionally requires a live KDE Wayland session, a connected Xeneon
# Edge, writable /dev/uinput, both explicit input opt-ins, a real owner-issued
# Pro key, coverage tooling and the network-namespace attestation prerequisites.
# Missing prerequisites are a release failure, never an implicit omission. Every
# long-running child is bounded by its own runner and/or an outer wall-clock timeout.
set -uo pipefail

# Reject the legacy bearer-key environment before any child can inherit it.
# Direct invocations accept only a protected file path. release.sh passes the
# already-read key through private descriptor 3, never through the environment.
if [[ -v XENEON_TEST_LICENSE_KEY ]]; then
    unset XENEON_TEST_LICENSE_KEY
    printf 'ERROR: XENEON_TEST_LICENSE_KEY is unsupported; use XENEON_TEST_LICENSE_KEY_FILE.\n' >&2
    exit 2
fi
OWNER_TEST_LICENSE_FILE_SUPPLIED=0
OWNER_TEST_LICENSE_FILE=""
if [[ -v XENEON_TEST_LICENSE_KEY_FILE ]]; then
    OWNER_TEST_LICENSE_FILE_SUPPLIED=1
    OWNER_TEST_LICENSE_FILE="$XENEON_TEST_LICENSE_KEY_FILE"
fi
unset XENEON_TEST_LICENSE_KEY_FILE
OWNER_TEST_LICENSE_KEY=""
OWNER_TEST_LICENSE_FROM_FD=0
if [[ -v XENEON_OWNER_KEY_FD ]]; then
    [ "$XENEON_OWNER_KEY_FD" = "3" ] || {
        unset XENEON_OWNER_KEY_FD
        printf 'ERROR: XENEON_OWNER_KEY_FD must name descriptor 3.\n' >&2
        exit 2
    }
    [ "$OWNER_TEST_LICENSE_FILE_SUPPLIED" -eq 0 ] || {
        unset XENEON_OWNER_KEY_FD
        printf 'ERROR: owner licence file and internal descriptor input cannot be combined.\n' >&2
        exit 2
    }
    OWNER_TEST_LICENSE_FROM_FD=1
    IFS= read -r OWNER_TEST_LICENSE_KEY <&3 || OWNER_TEST_LICENSE_KEY=""
    exec 3<&-
fi
unset XENEON_OWNER_KEY_FD
# Select the shipping MSRV before any repository or test child is started.
export RUSTUP_TOOLCHAIN=1.86.0

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

release_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

readonly RELEASE_KEY="2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
readonly RELEASE_REPO="skyphoenix-it/skyphoenix-edgehub-linux"
readonly AUDIT_FINALIZER="$PROJECT_DIR/scripts/finalize_audit_artifacts.sh"
readonly AUDIT_MANIFEST_HELPER="$PROJECT_DIR/scripts/lib/audit_artifact_manifest.py"
readonly AUDIT_RECORD_HELPER="$PROJECT_DIR/scripts/lib/audit_artifact_contract.py"
readonly RELEASE_MANIFEST_CHECKER="$PROJECT_DIR/scripts/check_release_manifest_contract.py"
readonly OWNER_LICENSE_FILE_READER="$PROJECT_DIR/scripts/lib/owner_license_file.py"
readonly RELEASE_ORIGIN_HELPER="$PROJECT_DIR/scripts/lib/release_origin.sh"
readonly RELEASE_RUST_TOOLCHAIN_HELPER="$PROJECT_DIR/scripts/lib/release_rust_toolchain.sh"

list_suites() {
    cat <<'EOF'
core/Cargo.toml (rustfmt + clippy; tests via scripts/run_all_tests.sh)
owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key (explicit --nocapture)
tools/license-tool/Cargo.toml (rustfmt + clippy + tests)
tools/license-webhook/Cargo.toml (rustfmt + clippy + tests)
gitleaks full-history secret scan
scripts/run_all_tests.sh (strict: unit, QML, C++, runtime, Manager, compositor)
tests/hardware/test_input_safety.py (via scripts/run_all_tests.sh)
tests/hardware/test_e2e_contract.py (via scripts/run_all_tests.sh)
tests/hardware/edge_e2e.py
tests/hardware/e2e_buildup.py
tests/hardware/widget_render_matrix.py
scripts/coverage.sh
tests/performance/prepare_release_candidate.sh
tests/performance/run_hub_profiles.py --mode short (literal 5m idle + 5m active + first render)
tests/performance/run_audit_14_widget_30m.py (literal 30m; owner-approved 14-widget substitute)
EOF
}

case "${1:-}" in
    --list)
        list_suites
        exit 0
        ;;
    -h|--help)
        echo "Usage: XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 XENEON_TEST_LICENSE_KEY_FILE=/absolute/path $0 [--list]"
        echo "Runs the complete strict pre-release suite; no omissions are accepted."
        exit 0
        ;;
    "") ;;
    *) echo "ERROR: unknown argument '$1' (use --help)" >&2; exit 2 ;;
esac

[ -f "$RELEASE_RUST_TOOLCHAIN_HELPER" ] \
    || release_die "release Rust toolchain helper is unavailable: $RELEASE_RUST_TOOLCHAIN_HELPER"
# shellcheck source=lib/release_rust_toolchain.sh
. "$RELEASE_RUST_TOOLCHAIN_HELPER"
xeneon_release_rust_toolchain_select
xeneon_release_rust_toolchain_verify \
    || release_die "release Rust toolchain verification failed"

if [ "$OWNER_TEST_LICENSE_FROM_FD" -eq 0 ]; then
    [ "$OWNER_TEST_LICENSE_FILE_SUPPLIED" -eq 1 ] \
        || release_die "set XENEON_TEST_LICENSE_KEY_FILE to the protected owner-issued Pro licence"
    [ -f "$OWNER_LICENSE_FILE_READER" ] \
        || release_die "owner licence file reader is unavailable: $OWNER_LICENSE_FILE_READER"
    if ! OWNER_TEST_LICENSE_KEY="$(
            env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_FILE_READER" \
                "$OWNER_TEST_LICENSE_FILE"
        )"; then
        release_die "owner-issued Pro licence file was rejected"
    fi
fi
OWNER_TEST_LICENSE_FILE=""

evidence_commit="$(git rev-parse --verify 'HEAD^{commit}')" || {
    echo "ERROR: release evidence requires a committed HEAD" >&2
    exit 2
}
case "$evidence_commit" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "ERROR: release evidence commit is not a full lowercase SHA" >&2; exit 2 ;;
esac
initial_git_state="$(git status --porcelain=v1 \
    --untracked-files=all --ignore-submodules=none)"
if [ -n "$initial_git_state" ]; then
    printf '%s\n' "$initial_git_state" >&2
    echo "ERROR: strict release evidence requires a clean tree" >&2
    exit 2
fi
env PYTHONDONTWRITEBYTECODE=1 \
    python3 "$PROJECT_DIR/scripts/check_tracked_source_inputs.py" \
        --repo "$PROJECT_DIR" \
    || release_die "strict release evidence contains an untracked or ignored build input"
env PYTHONDONTWRITEBYTECODE=1 \
    python3 "$RELEASE_MANIFEST_CHECKER" --repo "$PROJECT_DIR" \
    || release_die "strict runner and signed audit contract have drifted"
audit_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
audit_run_id="release-gate-${audit_stamp}-$$"
AUDIT_ROOT="$PROJECT_DIR/artifacts/$evidence_commit/$audit_run_id"
[ ! -e "$AUDIT_ROOT" ] || {
    echo "ERROR: audit run already exists: $AUDIT_ROOT" >&2
    exit 2
}
mkdir -m 0700 -p "$AUDIT_ROOT/logs" "$AUDIT_ROOT/work" \
    || release_die "could not create the release evidence directory"
export XENEON_AUDIT_RUN_DIR="$AUDIT_ROOT"
export QLOGDIR="$AUDIT_ROOT/qml-ui-logs"
export TMPDIR="$AUDIT_ROOT/work"
printf 'Strict release evidence: %s\n' "$AUDIT_ROOT"

export XENEON_RELEASE_GATE=1
export XENEON_COVERAGE=ON
# One pinned CMake tree is shared by C++ tests, real-binary suites, and gcovr.
# run_cpp_tests.sh recreates it from scratch, so no mutable developer build/
# cache or binary can influence the candidate verdict.
export XENEON_TEST_BUILD_DIR="$PROJECT_DIR/cmake-build-release-tests"
# Pin completeness-sensitive knobs. The historical Edge E2E endurance loop is
# explicitly omitted because the separate 30-minute 14-widget instrumented run
# is the owner-approved stability substitute. Widget subsets remain forbidden.
export XENEON_HUB="$XENEON_TEST_BUILD_DIR/xeneon-edge-hub"
export XENEON_MANAGER="$XENEON_TEST_BUILD_DIR/xeneon-edge-manager"
PERFORMANCE_BUILD_DIR="$PROJECT_DIR/cmake-build-release-performance"
PERFORMANCE_HUB="$PERFORMANCE_BUILD_DIR/xeneon-edge-hub"
export XENEON_HW_IDLE_SECONDS=3
export E2E_SOAK_SECONDS=0
export XENEON_EGRESS_SECS=10
# The AppImage contract supports mutated-tree negative controls in developer
# tests. A release must always audit the signed candidate, never a caller-chosen
# alternate tree.
export XENEON_CONTRACT_REPO="$PROJECT_DIR"

# shellcheck source=lib/release_gate.sh
. "$PROJECT_DIR/scripts/lib/release_gate.sh"

preflight_fail=0
preflight_record="$AUDIT_ROOT/PREFLIGHT.tsv"
printf 'result\tcheck\n' >"$preflight_record" \
    || release_die "could not initialize PREFLIGHT.tsv"
preflight_ok() {
    printf '  ok   %s\n' "$1"
    printf 'PASS\t%s\n' "$1" >>"$preflight_record" \
        || release_die "could not append to PREFLIGHT.tsv"
}
preflight_bad() {
    printf '  FAIL %s\n' "$1" >&2
    printf 'FAIL\t%s\n' "$1" >>"$preflight_record" \
        || release_die "could not append to PREFLIGHT.tsv"
    preflight_fail=$((preflight_fail + 1))
}

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
        preflight_ok "protected owner licence is non-empty (owner-key attestation enabled)"
        ;;
    *)
        preflight_bad "provide a real owner-issued Pro key through XENEON_TEST_LICENSE_KEY_FILE"
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
    bash cargo cargo-llvm-cov git gitleaks ip kscreen-doctor \
    kwin_wayland python3 sha256sum spectacle stat tee timeout unshare busctl \
    gpg; do
    require_command "$command_name"
done
require_command_or_executable cmake "$HOME/.local/bin/cmake"
require_command_or_executable ctest "$HOME/.local/bin/ctest"
require_command_or_executable gcovr "$HOME/.local/bin/gcovr"

missing_finalizer_tools=()
for command_name in \
    awk cat chmod cut date dirname ln mkdir mktemp realpath rm rmdir wc; do
    command -v "$command_name" >/dev/null 2>&1 \
        || missing_finalizer_tools+=("$command_name")
done
if [ "${#missing_finalizer_tools[@]}" -eq 0 ]; then
    preflight_ok "audit finalizer command prerequisites"
else
    preflight_bad \
        "audit finalizer command prerequisites are missing: ${missing_finalizer_tools[*]}"
fi

finalizer_helpers_ok=1
for helper in \
    "$AUDIT_FINALIZER" "$AUDIT_MANIFEST_HELPER" "$AUDIT_RECORD_HELPER" \
    "$RELEASE_ORIGIN_HELPER"; do
    if [ ! -f "$helper" ] || [ -L "$helper" ] || [ ! -s "$helper" ]; then
        finalizer_helpers_ok=0
    fi
done
if [ "$finalizer_helpers_ok" -eq 1 ]; then
    preflight_ok "audit finalizer and semantic helpers"
else
    preflight_bad "audit finalizer or semantic helper is missing, empty, or symlinked"
fi

origin_policy_loaded=0
if [ -f "$RELEASE_ORIGIN_HELPER" ] && [ ! -L "$RELEASE_ORIGIN_HELPER" ]; then
    # shellcheck source=lib/release_origin.sh
    . "$RELEASE_ORIGIN_HELPER"
    origin_policy_loaded=1
fi
if [ "$origin_policy_loaded" -eq 1 ] \
        && xeneon_origin_matches_github_repo "$PROJECT_DIR" "$RELEASE_REPO"; then
    preflight_ok "canonical origin fetch and push identity"
else
    preflight_bad "origin fetch and push URLs must identify the canonical GitHub repository"
fi

signing_key_record=""
if command -v gpg >/dev/null 2>&1; then
    signing_key_record="$(
        gpg --batch --list-secret-keys --with-colons "$RELEASE_KEY" 2>/dev/null \
            | awk -F: '
                $1 == "sec" && !seen {
                    validity = $2
                    expiry = $7
                    capabilities = $12
                    seen = 1
                    next
                }
                $1 == "fpr" && seen {
                    print toupper($10) ":" validity ":" expiry ":" capabilities
                    exit
                }
            '
    )"
fi
IFS=: read -r signing_fingerprint signing_validity signing_expiry signing_caps \
    <<<"$signing_key_record"
signing_key_ok=1
[ "$signing_fingerprint" = "$RELEASE_KEY" ] || signing_key_ok=0
case "$signing_validity" in
    r|e) signing_key_ok=0 ;;
esac
case "$signing_caps" in
    *s*|*S*) ;;
    *) signing_key_ok=0 ;;
esac
if [ -n "$signing_expiry" ] \
        && [ "$signing_expiry" -le "$(date +%s)" ] 2>/dev/null; then
    signing_key_ok=0
fi
if [ "$signing_key_ok" -eq 1 ]; then
    preflight_ok "pinned release signing key is present and signing-capable"
else
    preflight_bad "pinned release signing key is unavailable, expired, revoked, or not signing-capable"
fi

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

# Scenario 03's authoritative local containment assertion needs permission to
# create an unprivileged network namespace. The dedicated supply-chain CI job
# separately uses strace and a DNS/TCP sink to observe attempted connections.
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
suite_counter=0
run_release_suite() {
    local name="$1" max_seconds="$2"; shift 2
    local safe_name suite_log
    echo ""
    echo "==================================================================="
    echo "==> $name (timeout ${max_seconds}s)"
    echo "==================================================================="
    names+=("$name")
    suite_counter=$((suite_counter + 1))
    safe_name="$(printf '%s' "$name" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    suite_log="$(printf '%s/logs/%02d-%s.log' \
        "$AUDIT_ROOT" "$suite_counter" "$safe_name")"
    if xeneon_run_rejecting_skips_to "$suite_log" \
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
run_release_suite "Repository full-history secret scan" 600 \
    gitleaks git --no-banner --redact=100 --log-level warn --no-color \
        -c "$PROJECT_DIR/.gitleaks.toml" "$PROJECT_DIR"
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

if [ -d "$PROJECT_DIR/gui-evidence" ]; then
    cp -a -- "$PROJECT_DIR/gui-evidence" "$AUDIT_ROOT/gui-evidence" \
        || release_die "could not retain GUI evidence"
fi
if [ -d "$PROJECT_DIR/build/gui-logs" ]; then
    cp -a -- "$PROJECT_DIR/build/gui-logs" "$AUDIT_ROOT/gui-logs" \
        || release_die "could not retain GUI logs"
fi

# Current non-legacy real-device suites. These are deliberately explicit: a
# release manifest is reviewable, and the contract check prevents orphaning.
run_release_suite "Real Edge comprehensive functional E2E" \
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
# candidate. The release owner explicitly waived the historical 48-hour soak.
# The accepted substitute is a literal 30-minute, 14-widget instrumented
# observation with no duration or widget-subset override.
run_release_suite "Fresh non-instrumented performance candidate" 7200 \
    bash "$PROJECT_DIR/tests/performance/prepare_release_candidate.sh"

performance_evidence_root="$AUDIT_ROOT/performance"
mkdir -m 0700 "$performance_evidence_root" \
    || release_die "could not create the performance evidence directory"
echo "Performance evidence root: $performance_evidence_root"
run_release_suite "Hub startup + literal 5m idle/10-widget performance" 1200 \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/performance/run_hub_profiles.py" \
        --mode short --hub "$PERFORMANCE_HUB" \
        --output-dir "$performance_evidence_root/short"
run_release_suite "Hub literal 30m 14-widget performance observation" 2400 \
    env PYTHONDONTWRITEBYTECODE=1 python3 \
        "$PROJECT_DIR/tests/performance/run_audit_14_widget_30m.py" \
        --hub "$PERFORMANCE_HUB" \
        --output-dir "$performance_evidence_root/14-widget-30m"

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
summary_path="$AUDIT_ROOT/SUMMARY.tsv"
printf 'result\tsuite\n' >"$summary_path" \
    || release_die "could not initialize SUMMARY.tsv"
if [ "$release_fail" -ne 0 ]; then
    for i in "${!names[@]}"; do
        printf '%s\t%s\n' "${results[$i]}" "${names[$i]}" >>"$summary_path" \
            || release_die "could not append to SUMMARY.tsv"
    done
    rm -rf -- "$AUDIT_ROOT/work" \
        || release_die "could not remove transient release work files"
    echo "RESULT: FAILURE - release is blocked"
    echo "Unsealed failure evidence retained at: $AUDIT_ROOT"
    exit 1
fi
for i in "${!names[@]}"; do
    printf '%s\t%s\n' "${results[$i]}" "${names[$i]}" >>"$summary_path" \
        || release_die "could not append to SUMMARY.tsv"
done
python3 - "$AUDIT_ROOT/RUN.json" "$evidence_commit" "$audit_run_id" \
    "$preflight_record" "$summary_path" <<'PY' \
    || release_die "could not publish the complete RUN.json record"
import datetime
import hashlib
import json
import os
import pathlib
import sys
import tempfile

output, commit, run_id, preflight_path, summary_path = sys.argv[1:]


def record_details(path):
    payload = pathlib.Path(path).read_bytes()
    rows = payload.decode("utf-8").splitlines()
    if len(rows) < 2:
        raise SystemExit(f"release record has no result rows: {path}")
    return len(rows) - 1, hashlib.sha256(payload).hexdigest()


preflight_rows, preflight_sha256 = record_details(preflight_path)
summary_rows, summary_sha256 = record_details(summary_path)
document = {
    "schema": "skyphoenix-edgehub-release-gate-run/v2",
    "source_commit": commit,
    "run_id": run_id,
    "completed_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
    "result": "PASS",
    "preflight_rows": preflight_rows,
    "preflight_sha256": preflight_sha256,
    "summary_rows": summary_rows,
    "summary_sha256": summary_sha256,
}
destination = pathlib.Path(output)
descriptor, temporary = tempfile.mkstemp(
    dir=destination.parent,
    prefix=".release-run.",
)
try:
    os.fchmod(descriptor, 0o600)
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("short write while publishing RUN.json")
        remaining = remaining[written:]
    os.fsync(descriptor)
    os.close(descriptor)
    descriptor = -1
    os.replace(temporary, destination)
    temporary = ""
    directory = os.open(
        destination.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_CLOEXEC,
    )
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if descriptor >= 0:
        os.close(descriptor)
    if temporary:
        pathlib.Path(temporary).unlink(missing_ok=True)
PY
rm -rf -- "$AUDIT_ROOT/work" \
    || release_die "could not remove transient release work files"
unset TMPDIR
unset QLOGDIR
unset XENEON_AUDIT_RUN_DIR
bash "$AUDIT_FINALIZER" "$AUDIT_ROOT" \
    || {
        echo "RESULT: FAILURE - test suites passed but evidence signing/finalization failed" >&2
        exit 1
    }

if [ -n "${XENEON_RELEASE_GATE_RESULT_FILE:-}" ]; then
    result_file="$XENEON_RELEASE_GATE_RESULT_FILE"
    [ -f "$result_file" ] && [ ! -L "$result_file" ] \
        || release_die "machine result target must be an existing regular non-symlink file"
    [ "$(stat -c %a -- "$result_file")" = "600" ] \
        || release_die "machine result target must have mode 0600"
    manifest_digest_line="$(sha256sum -- "$AUDIT_ROOT/MANIFEST.sha256")" \
        || release_die "could not hash the finalized audit manifest"
    signature_digest_line="$(sha256sum -- "$AUDIT_ROOT/MANIFEST.sha256.asc")" \
        || release_die "could not hash the finalized audit signature"
    provenance_digest_line="$(sha256sum -- "$AUDIT_ROOT/PROVENANCE.json")" \
        || release_die "could not hash the finalized audit provenance"
    run_digest_line="$(sha256sum -- "$AUDIT_ROOT/RUN.json")" \
        || release_die "could not hash the finalized release run record"
    python3 - "$result_file" "$evidence_commit" "$audit_run_id" \
        "artifacts/$evidence_commit/$audit_run_id" \
        "${manifest_digest_line%% *}" "${signature_digest_line%% *}" \
        "${provenance_digest_line%% *}" "${run_digest_line%% *}" <<'PY' \
        || release_die "could not write the machine-readable release-gate result"
import json
import os
import stat
import sys

(
    output,
    commit,
    run_id,
    artifact_path,
    manifest_sha256,
    signature_sha256,
    provenance_sha256,
    run_sha256,
) = sys.argv[1:]
metadata = os.lstat(output)
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
    raise SystemExit("unsafe machine result target")
if stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("machine result target mode changed")
document = {
    "schema": "skyphoenix-edgehub-release-gate-result/v1",
    "source_commit": commit,
    "run_id": run_id,
    "artifact_path": artifact_path,
    "manifest_sha256": manifest_sha256,
    "signature_sha256": signature_sha256,
    "provenance_sha256": provenance_sha256,
    "run_sha256": run_sha256,
}
descriptor = os.open(
    output,
    os.O_WRONLY | os.O_TRUNC | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
)
try:
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("short write")
        remaining = remaining[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
    printf 'Machine result: %s\n' "$result_file"
fi
echo "RESULT: SUCCESS - every release suite executed and passed"
echo "Signed evidence: $AUDIT_ROOT"
