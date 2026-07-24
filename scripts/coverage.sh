#!/usr/bin/env bash
# coverage.sh - measure and gate test coverage across all layers.
#
#   Rust : cargo llvm-cov (LLVM source-based line coverage), gate >= 95%
#   C++  : gcovr over the selected CMake test build,             gate >= 95%
#          writing coverage/cpp-lcov.info
#   merge: Rust + C++ lcov    -> coverage/merged-lcov.info
#   QML  : scripts/qml_coverage.py (behavior matrix, reported; own gate)
#
# Developer mode skips a layer gracefully (with a clear message) when its
# tooling or build artifacts are absent. XENEON_RELEASE_GATE=1 requires fresh
# Rust and C++ reports and turns every such omission into a failure.
# Final line: "Rust: X% | C++: Y% | merged: Z% | QML behaviors: N%".
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

COVERAGE_DIR="$PROJECT_DIR/coverage"
mkdir -p "$COVERAGE_DIR"

GATE=95

# C++ has its own independently enforced floor. The gate was originally made
# honest at a 91% baseline; meaningful ConfigBridge, ControlServer and Manager
# backend tests raised the clean measurement to 96.1% on 2026-07-20, so the
# developer ratchet can now match the release requirement. Never lower it to
# turn a red run green.
CPP_GATE=95

RUST_PCT="n/a"
CPP_PCT="n/a"
MERGED_PCT="n/a"
QML_PCT="n/a"
fail=0
RUST_READY=0
CPP_READY=0
STRICT_RELEASE=0
case "${XENEON_RELEASE_GATE:-0}" in
    0) ;;
    1) STRICT_RELEASE=1; CPP_GATE="$GATE" ;;
    *) echo "FAIL: XENEON_RELEASE_GATE must be 0 or 1"; exit 2 ;;
esac

DEVELOPER_BUILD_DIR="$PROJECT_DIR/build"
STRICT_BUILD_DIR="$PROJECT_DIR/cmake-build-release-tests"
if [ "$STRICT_RELEASE" -eq 1 ]; then
    CPP_BUILD_DIR="${XENEON_TEST_BUILD_DIR:-$STRICT_BUILD_DIR}"
    if [ "$CPP_BUILD_DIR" != "$STRICT_BUILD_DIR" ]; then
        echo "FAIL: strict coverage must use the dedicated build directory: $STRICT_BUILD_DIR"
        exit 2
    fi
else
    CPP_BUILD_DIR="${XENEON_TEST_BUILD_DIR:-$DEVELOPER_BUILD_DIR}"
fi

# gcovr may live in ~/.local/bin rather than on PATH.
GCOVR=""
if command -v gcovr >/dev/null 2>&1; then
    GCOVR="gcovr"
elif [ -x "$HOME/.local/bin/gcovr" ]; then
    GCOVR="$HOME/.local/bin/gcovr"
fi

pct_ge_gate() {
    # pct_ge_gate <pct> [gate]  -> 0 if pct >= gate (default $GATE) else 1
    python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$1" "${2:-$GATE}"
}

# ---------------------------------------------------------------- Rust --------
echo "==> Rust coverage (cargo llvm-cov)"
if command -v cargo-llvm-cov >/dev/null 2>&1; then
    rust_rc=0
    (
        cd "$PROJECT_DIR/core"
        cargo llvm-cov --lib --lcov --output-path "$COVERAGE_DIR/rust-lcov.info" &&
        cargo llvm-cov --lib --json --summary-only --output-path "$COVERAGE_DIR/rust-summary.json"
    ) || rust_rc=$?
    if [ "$rust_rc" -eq 0 ] && [ -f "$COVERAGE_DIR/rust-lcov.info" ] && \
       [ -f "$COVERAGE_DIR/rust-summary.json" ]; then
        RUST_READY=1
        RUST_PCT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%.2f" % d["data"][0]["totals"]["lines"]["percent"])' "$COVERAGE_DIR/rust-summary.json")"
        echo "    Rust line coverage: ${RUST_PCT}%"
        if ! pct_ge_gate "$RUST_PCT"; then
            echo "    FAIL: Rust ${RUST_PCT}% < ${GATE}%"
            fail=1
        fi
    else
        echo "    FAIL: Rust coverage command failed or did not produce fresh reports"
        fail=1
    fi
else
    echo "    SKIP: cargo-llvm-cov not installed (cargo install cargo-llvm-cov)"
    [ "$STRICT_RELEASE" -eq 1 ] && fail=1
fi

# ---------------------------------------------------------------- C++ ---------
echo "==> C++ coverage (gcovr)"
HAVE_GCNO=0
FRESH_GCDA=0
CPP_INSTRUMENTED=0
if [ -f "$CPP_BUILD_DIR/CMakeCache.txt" ] \
        && grep -Fxq 'XENEON_COVERAGE:BOOL=ON' "$CPP_BUILD_DIR/CMakeCache.txt"; then
    CPP_INSTRUMENTED=1
fi

# A CMake reconfigure with coverage disabled can leave old .gcno/.gcda files
# behind. Never measure those stale counters as if they described the current
# build. In developer mode, prepare the missing instrumented build once. Strict
# mode is already prepared by run_release_tests.sh and must fail closed instead
# of mutating its dedicated candidate tree here.
if [ "$CPP_INSTRUMENTED" -eq 0 ] && [ "$STRICT_RELEASE" -eq 0 ]; then
    echo "==> Preparing C++ coverage build (current CMake cache is not instrumented)"
    if XENEON_COVERAGE=ON XENEON_TEST_BUILD_DIR="$CPP_BUILD_DIR" \
            bash "$PROJECT_DIR/scripts/run_cpp_tests.sh" "$CPP_BUILD_DIR"; then
        CPP_INSTRUMENTED=1
    else
        echo "    FAIL: C++ coverage build or tests failed"
        fail=1
    fi
fi

if [ "$CPP_INSTRUMENTED" -eq 1 ] && [ -d "$CPP_BUILD_DIR" ] \
        && find "$CPP_BUILD_DIR" -name '*.gcno' -print -quit 2>/dev/null | grep -q .; then
    HAVE_GCNO=1
fi
if [ -f "$CPP_BUILD_DIR/.xeneon-release-coverage-reset" ] && \
   find "$CPP_BUILD_DIR" -name '*.gcda' \
       -newer "$CPP_BUILD_DIR/.xeneon-release-coverage-reset" -print -quit 2>/dev/null | grep -q .; then
    FRESH_GCDA=1
fi
if [ -z "$GCOVR" ]; then
    echo "    SKIP: gcovr not found (pip install --user gcovr; also checked ~/.local/bin)"
elif [ "$HAVE_GCNO" -eq 0 ]; then
    echo "    SKIP: no current coverage-instrumented build at $CPP_BUILD_DIR"
    [ "$STRICT_RELEASE" -eq 1 ] && fail=1
else
    cpp_export_rc=0
    "$GCOVR" --root "$PROJECT_DIR" \
        --filter 'app/src/' --filter 'manager/src/' \
        --exclude '.*main\.cpp' \
        --lcov "$COVERAGE_DIR/cpp-lcov.info" \
        "$CPP_BUILD_DIR" || cpp_export_rc=$?
    if [ "$cpp_export_rc" -ne 0 ]; then
        echo "    FAIL: gcovr lcov export reported an error"
        fail=1
    fi
    # The search path MUST come before --json-summary. gcovr 8's
    # `--json-summary [OUTPUT]` takes an OPTIONAL FILENAME, so
    # `--json-summary "$CPP_BUILD_DIR"` is parsed as "write the summary to
    # the file build/" -> "Could not create output file 'build': Is a directory"
    # -> swallowed by 2>/dev/null -> CPP_PCT="n/a" -> the gate below skipped
    # ITSELF, silently. This gate had never once run. Same born-inert class as
    # the QtTest `_data` trap: a check that cannot fail is worse than no check.
    CPP_PCT="$("$GCOVR" --root "$PROJECT_DIR" \
        --filter 'app/src/' --filter 'manager/src/' \
        --exclude '.*main\.cpp' \
        "$CPP_BUILD_DIR" --json-summary 2>/dev/null \
        | python3 -c 'import json,sys; print("%.2f" % json.load(sys.stdin)["line_percent"])' 2>/dev/null || echo "n/a")"
    echo "    C++ line coverage: ${CPP_PCT}%"
    # An "n/a" here is now a FAILURE, not a shrug. It used to mean "the gate
    # quietly skipped itself", which is exactly how this stayed broken.
    if [ "$CPP_PCT" = "n/a" ]; then
        echo "    FAIL: C++ coverage could not be measured (gcovr produced no summary)"
        fail=1
    else
        if [ "$cpp_export_rc" -eq 0 ] && [ -f "$COVERAGE_DIR/cpp-lcov.info" ]; then
            CPP_READY=1
        fi
        if ! pct_ge_gate "$CPP_PCT" "$CPP_GATE"; then
            echo "    FAIL: C++ ${CPP_PCT}% < ${CPP_GATE}%"
            fail=1
        fi
    fi
fi

if [ "$STRICT_RELEASE" -eq 1 ]; then
    if [ "$RUST_READY" -ne 1 ]; then
        echo "    FAIL: strict release coverage requires a fresh Rust report"
        fail=1
    fi
    if [ "$CPP_READY" -ne 1 ]; then
        echo "    FAIL: strict release coverage requires a fresh C++ report"
        fail=1
    fi
    if [ "$FRESH_GCDA" -ne 1 ]; then
        echo "    FAIL: strict release coverage requires counters created after the release reset"
        fail=1
    fi
fi

# --------------------------------------------------------------- merge --------
echo "==> Merging lcov reports"
MERGE_INPUTS=()
[ "$RUST_READY" -eq 1 ] && MERGE_INPUTS+=("$COVERAGE_DIR/rust-lcov.info")
[ "$CPP_READY" -eq 1 ] && MERGE_INPUTS+=("$COVERAGE_DIR/cpp-lcov.info")
if [ "${#MERGE_INPUTS[@]}" -eq 0 ]; then
    echo "    SKIP: no lcov inputs to merge"
else
    if command -v lcov >/dev/null 2>&1; then
        args=()
        for f in "${MERGE_INPUTS[@]}"; do args+=(--add-tracefile "$f"); done
        lcov "${args[@]}" --output-file "$COVERAGE_DIR/merged-lcov.info" >/dev/null 2>&1 \
            && echo "    merged -> coverage/merged-lcov.info" \
            || { cat "${MERGE_INPUTS[@]}" > "$COVERAGE_DIR/merged-lcov.info"; echo "    merged (concat fallback) -> coverage/merged-lcov.info"; }
    else
        # lcov absent: concatenating tracefiles is a valid combined lcov report.
        cat "${MERGE_INPUTS[@]}" > "$COVERAGE_DIR/merged-lcov.info"
        echo "    merged (concat, lcov not installed) -> coverage/merged-lcov.info"
    fi
    # Compute merged line % from the tracefile (DA lines: hit if count > 0).
    MERGED_PCT="$(python3 - "$COVERAGE_DIR/merged-lcov.info" <<'PY'
import sys
total = hit = 0
for line in open(sys.argv[1]):
    if line.startswith("DA:"):
        parts = line[3:].strip().split(",")
        if len(parts) >= 2:
            total += 1
            if int(parts[1]) > 0:
                hit += 1
print("%.2f" % (100.0 * hit / total if total else 100.0))
PY
)"
    echo "    merged line coverage: ${MERGED_PCT}%"
    if ! pct_ge_gate "$MERGED_PCT"; then
        echo "    FAIL: merged ${MERGED_PCT}% < ${GATE}%"
        fail=1
    fi
fi

# ---------------------------------------------------------------- QML ---------
echo "==> QML behavior matrix (qml_coverage.py)"
QML_OUT="$(python3 "$PROJECT_DIR/scripts/qml_coverage.py")"
QML_STATUS=$?
echo "$QML_OUT"
QML_PCT="$(printf '%s\n' "$QML_OUT" | sed -nE 's/.*ratio[^0-9]*([0-9]+(\.[0-9]+)?)%.*/\1/p' | head -1)"
[ -z "$QML_PCT" ] && QML_PCT="n/a"
if [ "$QML_STATUS" -ne 0 ]; then
    fail=1
fi

# --------------------------------------------------------------- report -------
echo ""
echo "==================================================================="
echo "Rust: ${RUST_PCT}% | C++: ${CPP_PCT}% | merged: ${MERGED_PCT}% | QML behaviors: ${QML_PCT}%"
echo "==================================================================="

exit "$fail"
