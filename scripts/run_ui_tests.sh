#!/usr/bin/env bash
# Run the QML widget GUI test suite against source QML with the repository's
# resource-aware QuickTest runner. The runner embeds the shipped icons,
# wallpapers, and fonts, so a qrc miss is a real defect rather than 10,000 lines
# of allowlisted harness noise.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Release evidence must identify a committed source state. Refuse an accidental
# dirty-tree run unless an engineer explicitly opts into a non-audit diagnostic.
if [ "${XENEON_ALLOW_DIRTY_TESTS:-0}" != "1" ] \
        && [ -n "$(git status --porcelain=v1 --untracked-files=normal)" ]; then
    echo "ERROR: QML tests require a clean committed tree." >&2
    echo "       Set XENEON_ALLOW_DIRTY_TESTS=1 only for a non-audit diagnostic." >&2
    exit 2
fi

TEST_BUILD_DIR="${XENEON_TEST_BUILD_DIR:-$PROJECT_DIR/build}"
QMLTESTRUNNER="$TEST_BUILD_DIR/xeneon-qmltestrunner"
CMAKE_BIN="$(command -v cmake 2>/dev/null || true)"
[ -n "$CMAKE_BIN" ] || { echo "ERROR: cmake is required for the resource-aware QML runner"; exit 1; }

# Always ask CMake to update the small runner target. This is incremental when
# current and prevents a stale executable from validating changed resource files.
"$CMAKE_BIN" -B "$TEST_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DXENEON_BUILD_TESTS=ON
"$CMAKE_BIN" --build "$TEST_BUILD_DIR" --target xeneon-qmltestrunner -j"$(nproc)"
[ -x "$QMLTESTRUNNER" ] || {
    echo "ERROR: resource-aware QML runner was not produced: $QMLTESTRUNNER"
    exit 1
}

IMPORTS=(-import ui/qml -import ui/qml/widgets -import manager/qml -import tests/ui)
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

# Both shipped binaries pin the Controls style (app/src/main.cpp:271 and
# manager/src/main.cpp:116 call QQuickStyle::setStyle("Fusion")). Without this
# the suite runs under the user's desktop style (Breeze here), so every control
# under test is a DIFFERENT control than ships - different indicator geometry,
# different colours, different implicit sizes. A pixel assertion tuned to Fusion
# then fails for a reason that has nothing to do with the product.
export QT_QUICK_CONTROLS_STYLE=Fusion

# Every runner is bounded in time and memory. A QML test that leaks must fail
# ITSELF, never the machine - on 2026-07-19 an unbounded qmltestrunner reached
# 18.8 GB and the resulting system-wide OOM killed the developer's IDE.
# The repaired suite is comfortably below 2 GiB.  Keep the ceiling low enough
# that a reintroduced scene-graph explosion is killed before it can pressure
# the developer's desktop.
# shellcheck source=lib/run_bounded.sh
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
RUN_MEM_MAX_MB=${RUN_MEM_MAX_MB:-2048}
. "$PROJECT_DIR/scripts/lib/run_bounded.sh"
# shellcheck source=lib/qml_test_result.sh
. "$PROJECT_DIR/scripts/lib/qml_test_result.sh"

fail=0
filecount=0
# Per-file stdout is kept so check_qml_diagnostics.sh can scan it. QML runtime
# errors surface as QWARN lines on STDOUT (measured - NOT stderr), and until
# this landed nothing anywhere treated them as failures: the inert
# BackgroundPicker threw a TypeError on every click while three suites reported
# 5/5, 16/16 and 16/16.
full_sha="$(git rev-parse HEAD)"
qml_run_id="qml-ui-$(date -u +%Y%m%dT%H%M%SZ)-$$"
QLOGDIR="${QLOGDIR:-$PROJECT_DIR/artifacts/$full_sha/$qml_run_id}"
mkdir -p "$QLOGDIR"

for t in tests/ui/tst_*.qml; do
    echo "==> $t"
    filecount=$((filecount+1))
    base=$(basename "$t" .qml)
    # `set -e` must not skip the bookkeeping below, so capture rc explicitly.
    rc=0
    # -maxwarnings 0 = unlimited. QtTest caps messages at 2000 and then prints
    # "Maximum amount of warnings exceeded", DROPPING everything after it -
    # including the QWARN lines check_qml_diagnostics.sh counts. A gate blinded
    # by the noise it exists to measure will silently undercount, which is the
    # exact failure family this suite keeps hitting.
    run_bounded "$QMLTESTRUNNER" -input "$t" "${IMPORTS[@]}" -maxwarnings 0 \
        > >(tee "$QLOGDIR/$base.log") 2>&1 || rc=$?
    case "$rc" in
        0)  ;;
        97) echo "!! $t MEMKILLed (>${RUN_MEM_MAX_MB} MiB RSS) - treat as a leak"; fail=1 ;;
        98) echo "!! $t TIMEKILLed (>${RUN_TIMEOUT}s) - treat as a hang"; fail=1 ;;
        *)  fail=1 ;;
    esac
    # A QML runtime diagnostic fails the file even when every assertion passed.
    "$PROJECT_DIR/scripts/check_qml_diagnostics.sh" "$QLOGDIR/$base.log" \
        --tier compiled || fail=1
    # Exit zero is not proof of execution: an accidentally overridden runner
    # such as /bin/true produces no QtTest output at all.  Require a real Totals
    # record with at least one pass and no omitted/blacklisted checks per file.
    xeneon_qml_require_live_totals "$QLOGDIR/$base.log" "$t" || fail=1
done

# Anti-vacuity floor: a glob that matched nothing must not report success.
if [ "$filecount" -eq 0 ]; then
    echo "!! no test files matched tests/ui/tst_*.qml - refusing to report success"
    exit 1
fi

echo "  logs: $QLOGDIR  ($filecount files)"
[ "$fail" -eq 0 ] && echo "ALL UI TESTS PASSED" || { echo "SOME UI TESTS FAILED"; exit 1; }
