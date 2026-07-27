#!/usr/bin/env bash
# run_manager_tests.sh - the REAL Manager, driven with REAL input, against the
# REAL hub. No nested compositor, no stubbed backend.
#
# WHY THIS SCRIPT EXISTS
#
# The Manager used to be "tested" inside a nested kwin_wayland with its C++
# backend stubbed out (screensJson()="[]", metricsJson()="{}"). That was not the
# shipped Manager, and its pixel assertions were false besides: Qt's
# TestCase.grabImage(item) crops at (0,0) and ignores item position, so
# "did the preview repaint?" was sampling the nav sidebar. Those tests were
# deleted 2026-07-20 and scripts/check_no_manager_compositor_tests.sh keeps them
# out.
#
# Meanwhile the REAL tests - the ones that launch both binaries and talk over the
# control socket - already existed and were ORPHANED: no runner, no workflow,
# never executed. That is the same disease. This script is the fix.
#
# GATES. Both are required and neither is implied by the other:
#   XENEON_HW_INPUT=1          - synthetic input at all
#   XENEON_HW_INPUT_DESKTOP=1  - input on the DESKTOP (the Manager lives there,
#                                not on the Edge). The cursor moves on your
#                                screen; any real input from you aborts the run.
# Without them every suite here SKIPs loudly rather than silently passing.
#
# Requires the Edge connected and binaries matching the working tree - the
# suites assert that themselves and refuse to run stale (reconfigure, don't just
# rebuild: git describe is evaluated at configure time).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SUITES=(
    "tab navigation + hub liveness:manager_gui_test.py"
    "Manager->hub adds + capacity boundary:manager_hub_boundary.py"
    "hub mirrors the Manager's screen (O1):manager_page_mirror_test.py"
    "hub->Manager reflection:manager_reflection_test.py"
    "drag-to-reorder:manager_drag_reorder_test.py"
)

if [ "${XENEON_HW_INPUT:-0}" != "1" ] || [ "${XENEON_HW_INPUT_DESKTOP:-0}" != "1" ]; then
    echo "==> Manager suites SKIPPED - desktop input is opt-in."
    echo "    Run: XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 $0"
    echo "    (${#SUITES[@]} suites were not executed - this is a SKIP, not a pass.)"
    exit 77
fi

names=(); results=(); fail=0
for entry in "${SUITES[@]}"; do
    label="${entry%%:*}"; script="${entry#*:}"
    echo ""
    echo "==================================================================="
    echo "==> $label  ($script)"
    echo "==================================================================="
    # Never leave a previous suite's binaries holding the Edge or the socket.
    # Linux truncates comm to 15 characters, so the Manager is reported as
    # xeneon-edge-man. Match that exact kernel name instead of using `pkill -f`.
    # A command-line pattern can match and terminate the parent audit shell.
    pkill -TERM -x xeneon-edge-hub 2>/dev/null
    pkill -TERM -x xeneon-edge-man 2>/dev/null
    sleep 2

    names+=("$label")
    if timeout "${XENEON_MGR_TIMEOUT:-900}" python3 \
            "$PROJECT_DIR/scripts/run_hardware_python.py" \
            "$PROJECT_DIR/tests/hardware/$script"; then
        results+=("PASS")
    else
        rc=$?
        if [ "$rc" -eq 77 ]; then results+=("SKIP")
        else results+=("FAIL"); fail=1; fi
    fi
done

echo ""
echo "==================================================================="
echo "  MANAGER (real binaries, real hub) SUMMARY"
echo "==================================================================="
for i in "${!names[@]}"; do printf "  %-44s %s\n" "${names[$i]}" "${results[$i]}"; done
echo "==================================================================="

# ANTI-VACUITY: zero suites executed must never read as success. Every gate in
# this repo that reported OK for "I did no work" is why the suite rotted.
if [ "${#names[@]}" -eq 0 ]; then
    echo "!! no Manager suites ran - refusing to report success"; exit 1
fi
[ "$fail" -ne 0 ] && { echo "RESULT: FAILURE"; exit 1; }
echo "RESULT: SUCCESS (${#names[@]} suites)"
