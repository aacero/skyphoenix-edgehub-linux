---
name: oom-containment-rule
description: "Simon's hard rule after the 2026-07-19 GUI-suite OOM killed IntelliJ — never enforce test memory limits via kernel OOM killer"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 010f297c-48f4-45ae-9c33-f0e6105d0be8
  modified: 2026-07-19T08:31:13.805Z
---

Never let anything I run produce an OOM notification or risk an IntelliJ/system
crash. Bound test memory in a way the kernel OOM killer is NEVER involved in.

**Why:** on 2026-07-19 a runaway scene-graph walk in `tests/gui/` drove
qmltestrunner to 18.8 GB RSS and triggered a `global_oom`, which killed Simon's
IntelliJ. While investigating I used `systemd-run -p MemoryMax=`, which is
enforced by the kernel OOM killer — it raised a desktop "system is low on memory"
notification indistinguishable from a real system-wide OOM. Simon found that
alarming and unacceptable even though it was cgroup-local and contained.

**How to apply:** bound runners with `ulimit -v` (hard address-space ceiling —
allocation fails and the process self-aborts) plus a userspace RSS watchdog that
polls `/proc/<pid>/status` and `kill -9`s on breach. Never `MemoryMax`/cgroup
caps for this. Sizing evidence on this repo: a healthy `qmltestrunner` GUI run is
~2.9 GB virtual / ~0.3 GB RSS; the runaway was 78 GB virtual / 18.8 GB RSS — so
`ulimit -v 12G` + a 2 GB RSS watchdog separates them cleanly. Implemented in
`scripts/lib/run_bounded.sh` (shared; sourced by `run_gui_tests.sh`,
`run_ui_tests.sh`, `validate_gui_file.sh`). When distinguishing OOM events, check
`oom-kill:constraint=` in the journal: `CONSTRAINT_MEMCG` is cgroup-local,
`global_oom` is the dangerous one. See [[v1-alpha-verification-state]].

**The underlying bug, twice:** a QML scene-graph walk that recurses over BOTH
`children` and `data` with no visited-set re-walks each node's subtree once per
path — exponential in depth (1,701 real nodes → >2,000,000 visits). Found in
`tests/gui/GuiUtil.js` AND in `tests/ui/tst_manager.qml` (the tracked suite;
7 MB → 20 GB in 25 s, and the repo's "tst_manager takes 250–300 s" note was that
leak — it now runs in 1.1 s at 105 MB). If you write or review a QML tree walk in
this repo, the seen-set is mandatory. Guard: `tests/gui/tst_gui_util_walk.qml`.
