---
name: no-saturation-load-tests
description: "Simon's hard rule: never run anything that deliberately maxes out his CPU/GPU/RAM — boundary tests fine, saturation never"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d3d1c5bb-7a0f-4098-b6e7-1733889f2568
  modified: 2026-08-02T09:19:36.677Z
---

Never run anything whose purpose is to saturate Simon's machine — no CPU spinners,
no GPU floods, no memory hogs, no "let's see what happens under full load".
Boundary and limit tests are fine; *hammering everything* is never OK, on any
machine of his, for any reason.

**Why:** on 2026-08-02 I spawned 64 busy-loop shells (`while :; do :; done`) on
his 32 cores to try to reproduce a CI-only Qt binding loop by simulating a loaded
runner. My cleanup was `LOADPIDS=$(jobs -p); … kill $LOADPIDS`, and `jobs -p`
returns nothing in a non-interactive shell — so the kill was a no-op and all 64
kept spinning for ~10 minutes until he noticed and told me to stop. He has been
here before: careless limitless tests already crashed his system once (see
[[oom-containment-rule]] — the 2026-07-19 `global_oom` that killed his IntelliJ).
This is the second time my tooling has degraded his working machine, and he
regards it as a hard line, not a trade-off to weigh.

**How to apply:** never generate synthetic load as a debugging technique. To
reproduce an environment-dependent failure, change the *environment*, not the
machine's load: pin the real dependency version (e.g. `aqt install-qt` into the
scratchpad and rebuild against it — that is what actually reproduced the Qt 6.7.3
binding loop after five load-based attempts failed), use the software renderer,
or reduce the runner's own resources with `taskset`/`ulimit` on that one process.
If some bounded load ever is genuinely unavoidable, cap it (`timeout`, an explicit
PID list captured at spawn time, `trap`-based cleanup) and verify afterwards with
`ps`/`pgrep` that nothing survived — never trust `jobs -p` in a non-interactive
shell.
