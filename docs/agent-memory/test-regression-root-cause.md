---
name: test-regression-root-cause
description: Why XeneonEdge kept regressing — tests that never run or cannot fail — and where the resume point is
metadata:
  type: project
---

Simon's recurring complaint ("we regress on features fixed dozens of versions
ago") was root-caused on 2026-07-20. It is NOT a coverage problem: ~9,464
assertions across 176 test-bearing files already existed. They regress because a
large fraction never execute and another fraction cannot fail.

Four causes, all fixed in Phase 0 (r230-r236):
- CI triggered on master only while v1.0-alpha was 86 commits ahead
- tests/gui/ was orphaned AND exited 0 unconditionally (ended in an `echo`)
- QML runtime errors were failures nowhere (QT_FATAL_WARNINGS: 0 occurrences)
- widget QML never loaded in ANY tier — qrc aliases flat, unresolvable under
  qmltestrunner — so widgets were tested only in isolation at a hand-supplied
  sizeClass, and the shell was tested with no widgets in it

**Full state, open items and gotchas live in the repo:**
`docs/agent-memory/SESSION-HANDOFF-2026-07-20.md` and `TEST-STRATEGY-v2.md`.
Read those first on resume — they are authoritative and kept current.

Verification discipline this established: qmltestrunner reports QML errors as
QWARN on STDOUT, not stderr — a first version of the gate scanned stderr, found
zero, and was itself the vacuous check it existed to catch. Always prove a
detector can emit a 1 before believing its 0. See [[test-integrity]].
