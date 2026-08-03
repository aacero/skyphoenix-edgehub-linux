#!/usr/bin/env bash
# check_no_open_bug_notes.sh - a known defect belongs in BACKLOG.md, never in a
# test comment.
#
# WHY THIS EXISTS
# On 2026-08-03 the widget tests carried 36 "BUG (audit ...)" annotations, five of
# them ending "This assertion is expected to FAIL". None were in BACKLOG.md, and
# every single one had been FIXED - the assertions all pinned the corrected
# behaviour and the whole suite was green. So the comments described defects that
# no longer existed, in a suite whose entire value is that you can trust what it
# says. Anyone reading those files was told the product was broken in 36 ways it
# was not, and anyone filing from them would have imported 36 phantom items.
#
# A comment cannot go stale silently if it is not allowed to exist: an open
# defect goes to BACKLOG.md where it is tracked and closed, and the test states
# what it pins. Past-tense provenance ("FIXED, and this test pins it ... The
# defect was: ...") is explicitly fine - it is history, not a claim about today.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# The banned shapes: a marker asserting there is a defect HERE, NOW.
PATTERN='BUG \(audit|(^|[^A-Za-z])(FIXME|XXX|HACK)([^A-Za-z]|$)|expected to FAIL|expected to fail'

scanned=0
hits=""
for f in tests/ui/tst_*.qml tests/gui/tst_*.qml tests/ui/*.js tests/gui/*.js; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  # Only comment lines - a test may legitimately assert on a string like "fixme".
  found=$(grep -nE '^\s*(//|\*)' "$f" | grep -EI "$PATTERN" || true)
  [ -n "$found" ] && hits="$hits
$f:
$found"
done

# Anti-vacuity floor, same rule as the other guards here: a gate that scanned
# nothing must fail rather than report OK. This one has been inert-by-typo before
# in its sibling scripts.
if [ "$scanned" -eq 0 ]; then
  echo "!! FAIL: no test files were scanned - this gate would pass for the wrong reason"
  exit 1
fi

if [ -n "$hits" ]; then
  echo "!! FAIL: open-defect markers found in test comments."
  echo "   A known defect belongs in BACKLOG.md, not in a comment that nobody"
  echo "   re-reads when it is fixed. Past-tense provenance is fine:"
  echo "     // FIXED, and this test pins it (audit high). The defect was: ..."
  echo "$hits"
  exit 1
fi

echo "OK: $scanned test file(s) scanned; no open-defect markers in comments"
