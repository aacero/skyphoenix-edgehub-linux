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

# Always fatal: these are product defects in any tier. Qt can print these before
# QtTest has attached its message handler, so scan the complete log rather than
# only QWARN-prefixed lines.
FATAL='TypeError|ReferenceError|is not a function|is not defined|Unable to assign|Binding loop detected|conflicting anchors'

# Resource-resolution failures. In the OFFSCREEN tier the .qrc is compiled into
# the app binaries and is genuinely absent from qmltestrunner, so these are
# harness artifacts (2391 of them in a 15-file sample) and are reported but not
# enforced. In a COMPOSED tier -- tests/gui under a real compositor, or the real
# binaries -- the resources ARE present, so a miss is a real broken asset.
RESOURCE='Cannot open: qrc:|No such file or directory'

# Some component-construction diagnostics can also precede QtTest and therefore
# lack QWARN. Treat those as warnings too.
WARNING='^QWARN[[:space:]]*:|^(file|qrc):.*QML (Connections|Binding|Loader|Image|Settings)'

# Qt's queued QUnifiedTimer stop path can reach stopAnimationDriver after the
# installed driver has already stopped. Qt itself emits this exact line. Keep
# the disposition full-line exact and counted so no application warning is
# hidden with it.
KNOWN_QT_ANIMATION_DRIVER='^QWARN[[:space:]]*:.*QUnifiedTimer::stopAnimationDriver: driver is not running$'
KNOWN_EXTERNAL="$KNOWN_QT_ANIMATION_DRIVER"

# Qt < 6.9 SwipeView: changing the NUMBER OF PAGES makes Qt's own SwipeView.qml
# re-enter its `currentIndex: control.currentIndex` binding, because the
# ListView it wraps re-derives an index while QQuickContainer is still writing
# one back. Qt breaks the chain, warns, and the pages still land correctly.
#
# This is upstream, not ours, and that was established by construction rather
# than by argument (2026-08-02): a SwipeView holding four plain Rectangles, with
# NO product code anywhere near it, reproduces the warning on Qt 6.7.3 as soon as
# its Repeater count collapses and grows again - and the identical file is clean
# on Qt 6.11.1. Adding a page is not something this product can stop doing, and
# the loop lives inside a component we do not own, so there is nothing to fix on
# our side. Upstream did fix it, by routing Container.content{Width,Height}
# through implicitContent{Width,Height} (qtdeclarative, 2024-12-14, released in
# 6.9).
#
# The disposition is therefore pinned to the versions that actually have the
# defect, and EXPIRES BY ITSELF: on Qt >= 6.9 the pattern is not installed, so
# the same line becomes fatal again and tells us the suppression has outlived
# its cause. If the version cannot be read from the log, nothing is suppressed -
# a gate that cannot identify its subject must not excuse anything. The pattern
# is also anchored to Qt's OWN import path, so a binding loop in a SwipeView we
# declare, or in any product file, still fails.
KNOWN_QT_SWIPEVIEW_CURRENTINDEX='^QWARN[[:space:]]*:.*qrc:/qt-project\.org/imports/QtQuick/Controls/[A-Za-z]+/SwipeView\.qml:[0-9]+:[0-9]+: QML ListView: Binding loop detected for property "currentIndex":$'
QT_RUNTIME_VERSION=$(sed -nE 's/^Config: Using QtTest library ([0-9]+\.[0-9]+)\.[0-9]+.*/\1/p' "$LOG" | head -1)
swipeview_disposition="not applicable"
case "$QT_RUNTIME_VERSION" in
  6.[0-8])
    KNOWN_EXTERNAL="$KNOWN_EXTERNAL|$KNOWN_QT_SWIPEVIEW_CURRENTINDEX"
    swipeview_disposition="Qt $QT_RUNTIME_VERSION"
    ;;
esac

diag_tmp="$(mktemp "${TMPDIR:-/tmp}/xeneon-qml-diag.XXXXXX")"
trap 'rm -f "$diag_tmp"' EXIT
grep -E "$WARNING" "$LOG" > "$diag_tmp" || true

# The fatal scan reads the WHOLE log, so it must honour the same dispositions -
# otherwise a line excused above would still fail here and the disposition would
# be decorative.
fatal_hits=$(grep -E "$FATAL" "$LOG" | grep -cvE "$KNOWN_EXTERNAL")
res_hits=$(grep -cE "$RESOURCE" "$LOG")
warn_hits=$(wc -l < "$diag_tmp")
known_external_hits=$(grep -cE "$KNOWN_EXTERNAL" "$diag_tmp")
animation_driver_hits=$(grep -cE "$KNOWN_QT_ANIMATION_DRIVER" "$diag_tmp")
swipeview_hits=$(grep -cE "$KNOWN_QT_SWIPEVIEW_CURRENTINDEX" "$diag_tmp")
unexpected_hits=$(grep -Ev "$KNOWN_EXTERNAL" "$diag_tmp" | wc -l)

echo "  QML diagnostics [$TIER]: warnings=$warn_hits unexpected=$unexpected_hits known_external=$known_external_hits fatal=$fatal_hits resource=$res_hits"

rc=0
if [ "$fatal_hits" -gt 0 ]; then
  echo "  !! FAIL: $fatal_hits QML runtime diagnostic(s) - these are product bugs:"
  grep -E "$FATAL" "$LOG" | grep -vE "$KNOWN_EXTERNAL" | sed 's/^/     /' | sort -u | head -40
  rc=1
fi

if { [ "$TIER" = "compiled" ] || [ "$TIER" = "composed" ]; } \
        && [ "$unexpected_hits" -gt 0 ]; then
  echo "  !! FAIL: $unexpected_hits unexpected QML warning(s) with compiled resources:"
  grep -Ev "$KNOWN_EXTERNAL" "$diag_tmp" | sed 's/^/     /' | sort -u | head -80
  rc=1
elif [ "$TIER" = "composed" ] && [ "$res_hits" -gt 0 ]; then
  echo "  !! FAIL: $res_hits unresolved resource(s) in a tier where resources exist:"
  grep -E 'QWARN|No such file' "$LOG" | grep -E "$RESOURCE" | sed 's/^/     /' | sort -u | head -40
  rc=1
elif [ "$res_hits" -gt 0 ]; then
  echo "     (offscreen: $res_hits resource misses not enforced - qrc is not"
  echo "      registered in qmltestrunner. See TEST-STRATEGY-v2.md Phase 1.)"
fi

if [ "$known_external_hits" -gt 0 ]; then
  [ "$animation_driver_hits" -gt 0 ] \
    && echo "     known external Qt animation-driver warning: $animation_driver_hits"
  { [ "$swipeview_hits" -gt 0 ] && [ "$swipeview_disposition" != "not applicable" ]; } \
    && echo "     known external SwipeView currentIndex binding loop on $swipeview_disposition (fixed upstream in 6.9): $swipeview_hits"
fi

exit $rc
