#!/usr/bin/env bash
# check_qml_diagnostics.sh - fail on QML runtime diagnostics in a test log.
#
# WHY THIS EXISTS
# The hub's Settings->Background picker shipped completely inert: a QML
# self-binding trap meant every interaction threw
#     TypeError: Cannot call method 'setAppearance' of undefined
# on every click. Three test files covering that picker passed 5/5, 16/16 and
# 16/16 -- identically with and without the bug -- because nothing anywhere in
# the test infrastructure treated a QML runtime error as a failure.
#
# STREAM NOTE (measured, not assumed): qmltestrunner reports these as `QWARN`
# lines on STDOUT, not stderr. An earlier version of this gate grepped stderr,
# found zero, and was itself vacuous. Feed it the STDOUT log.
#
# Usage: check_qml_diagnostics.sh <logfile> [--tier offscreen|compiled|composed]
set -uo pipefail

LOG="${1:?usage: check_qml_diagnostics.sh <logfile> [--tier offscreen|composed]}"
TIER="offscreen"
[ "${2:-}" = "--tier" ] && TIER="${3:-offscreen}"
[ -r "$LOG" ] || { echo "!! cannot read $LOG"; exit 2; }

# Always fatal: these are product defects in any tier.
FATAL='TypeError|ReferenceError|is not a function|is not defined|Unable to assign|Binding loop detected|conflicting anchors'

# Resource-resolution failures. In the OFFSCREEN tier the .qrc is compiled into
# the app binaries and is genuinely absent from qmltestrunner, so these are
# harness artifacts (2391 of them in a 15-file sample) and are reported but not
# enforced. In a COMPOSED tier -- tests/gui under a real compositor, or the real
# binaries -- the resources ARE present, so a miss is a real broken asset.
RESOURCE='Cannot open: qrc:|No such file or directory'

fatal_hits=$(grep -E 'QWARN' "$LOG" | grep -cE "$FATAL")
res_hits=$(grep -E 'QWARN|No such file' "$LOG" | grep -cE "$RESOURCE")
warn_hits=$(grep -cE '^QWARN[[:space:]]*:' "$LOG")

echo "  QML diagnostics [$TIER]: warnings=$warn_hits fatal=$fatal_hits resource=$res_hits"

rc=0
if [ "$fatal_hits" -gt 0 ]; then
  echo "  !! FAIL: $fatal_hits QML runtime diagnostic(s) - these are product bugs:"
  grep -E 'QWARN' "$LOG" | grep -E "$FATAL" | sed 's/^/     /' | sort -u | head -40
  rc=1
fi

if { [ "$TIER" = "compiled" ] || [ "$TIER" = "composed" ]; } \
        && [ "$warn_hits" -gt 0 ]; then
  echo "  !! FAIL: $warn_hits unexpected QML warning(s) with compiled resources:"
  grep -E '^QWARN[[:space:]]*:' "$LOG" | sed 's/^/     /' | sort -u | head -80
  rc=1
elif [ "$TIER" = "composed" ] && [ "$res_hits" -gt 0 ]; then
  echo "  !! FAIL: $res_hits unresolved resource(s) in a tier where resources exist:"
  grep -E 'QWARN|No such file' "$LOG" | grep -E "$RESOURCE" | sed 's/^/     /' | sort -u | head -40
  rc=1
elif [ "$res_hits" -gt 0 ]; then
  echo "     (offscreen: $res_hits resource misses not enforced - qrc is not"
  echo "      registered in qmltestrunner. See TEST-STRATEGY-v2.md Phase 1.)"
fi

exit $rc
