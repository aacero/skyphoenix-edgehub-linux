#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check_ui_links.sh - a link the UI offers must actually go somewhere.
#
# The Manager's About pane shipped a "GitHub" button wired to
# `Qt.openUrlExternally("#")`. Clicking it did nothing at all: no browser, no
# error, no log line. That is worse than having no button - the user concludes
# the app is broken rather than the link, and there is no failure for anyone to
# notice. It survived every test and review because nothing could fail on it.
#
# So: every `Qt.openUrlExternally(...)` with a literal argument must name a real
# scheme. Non-literal arguments (a property, an expression) are skipped - this
# lint only judges what it can actually see.
#
# NOTE ON THE SCAN: this deliberately does NOT grep for `openUrlExternally("`.
# The first version did, and was born inert - the call it was written to catch
# is wrapped:
#
#     onClicked: Qt.openUrlExternally(
#         "https://github.com/...")
#
# so the `(` and the `"` are on different lines and the pattern never matched.
# The negative control caught it (the lint stayed green with the dead link put
# back), which is the entire argument for running one. Parse the CALL, not the
# LINE.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - "$@" <<'PYEOF'
import re, sys, pathlib

# openUrlExternally ( <whitespace/newlines> "literal" )
LITERAL = re.compile(r'openUrlExternally\s*\(\s*"([^"]*)"\s*\)', re.S)
# any call at all, so we can report how many we skipped as non-literal
ANY_CALL = re.compile(r'openUrlExternally\s*\(', re.S)
OK_SCHEMES = ("http://", "https://", "mailto:", "file://")

ROOTS = ("ui/qml", "manager/qml")

fail = 0          # a link the UI offers goes nowhere - the gate's day job
vacuous = 0       # the gate could not see its own subjects - it did no work
literals = skipped = scanned = 0
for root in ROOTS:
    # A root that stops existing must be fatal, not empty. `rglob` on a missing
    # directory yields nothing and raises nothing, so a rename here would take
    # the gate silently to zero subjects - see the anti-vacuity floor below.
    if not pathlib.Path(root).is_dir():
        print(f"  scan root is missing: {root}/")
        vacuous = 1
        continue
    for path in sorted(pathlib.Path(root).rglob("*.qml")):
        scanned += 1
        src = path.read_text(encoding="utf-8")
        calls = len(ANY_CALL.findall(src))
        found = LITERAL.findall(src)
        literals += len(found)
        skipped += calls - len(found)
        for url in found:
            if not url.startswith(OK_SCHEMES):
                # Report the line the literal sits on, not the call's start.
                line = src[:src.index('"%s"' % url)].count("\n") + 1
                print(f'  {path}:{line} - openUrlExternally("{url}") goes nowhere')
                fail = 1

if fail:
    print()
    print("FAIL: the UI offers a link that does nothing when clicked.")
    sys.exit(1)

# Anti-vacuity floor. A gate must assert its own subjects exist, or it reports
# SUCCESS for the state where it did no work - the shape logged six times in
# BACKLOG.md "Test-integrity debt". This one WAS that shape: renaming the scan
# roots printed "OK: 0 literal UI link(s)" and exited 0.
#
# Reported separately from a dead link: "the gate went blind" and "the UI ships
# a broken button" need different fixes, so they must not share a message.
if vacuous or scanned == 0:
    print()
    if vacuous:
        print(f"FAIL: a scan root is unreadable, so this gate is blind to part "
              f"of the UI ({scanned} .qml file(s) reached).")
        print("      Fix the root above, or update ROOTS if the tree moved "
              "deliberately.")
    else:
        print("FAIL: this gate scanned ZERO .qml files - it did no work, so "
              "its OK would")
        print("      have meant nothing.")
    sys.exit(1)
if literals == 0:
    print(f"FAIL: {scanned} .qml file(s) scanned but ZERO literal "
          "openUrlExternally() calls were parsed.")
    print("      The UI ships literal links (the Manager's About pane), so "
          "zero means the")
    print("      parser stopped matching, not that the links went away. If "
          "they genuinely")
    print("      did, delete this floor deliberately - do not let the gate "
          "go quiet.")
    sys.exit(1)
print(f"OK: {literals} literal UI link(s) across {scanned} .qml file(s) name "
      f"a real scheme ({skipped} non-literal call(s) not judged).")
PYEOF
