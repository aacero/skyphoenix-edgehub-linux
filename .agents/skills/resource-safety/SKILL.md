---
name: resource-safety
description: Review process lifecycle, memory growth, output capture, and handle management for unbounded resource consumption, and confirm long-running or third-party-driven work runs under an explicit memory/CPU bound. Use when a change spawns subprocesses, runs long-lived or third-party-driven work (test runners, build tools, watchers, workers), reads or buffers files/streams of unbounded size, or before any release gate requiring a reliability verdict on resource behavior.
---


<!-- GENERATED from agent-framework/canonical/skills/resource-safety/SKILL.md — edit the canonical source, then run: python3 scripts/agent-framework/render.py -->
# Resource Safety

## Purpose

Prevent the defect class where a single unbounded process, buffer, or handle exhausts host memory or file descriptors and takes down more than itself. Assume any spawned process, retained buffer, or open handle grows without bound until proven otherwise, and report findings as actionable Blocking / Important / Optional items with concrete evidence.

### Motivating incident

On 2026-07-19 a Qt test runner grew to 18.85 GB RSS and triggered a host-wide OOM kill that took down the IDE and other unrelated processes. A contained failure (a process killed inside its own cgroup, `CONSTRAINT_MEMCG` in the kernel OOM record) is survivable and expected; an unbounded process that triggers `global_oom` is not — it degrades or kills unrelated work on the same host. The kernel OOM killer names the victim and its RSS at the time of death:

```
journalctl -k -b -1 | grep -i oom-kill
```

Use this (or `dmesg | grep -i oom-kill` on the live boot) to confirm the constraint (`CONSTRAINT_MEMCG` vs `CONSTRAINT_NONE`/global) and the victim's RSS when investigating a suspected resource-exhaustion incident.

## When to use

- A change spawns subprocesses (test runners, build tools, linters, watchers, workers, CI steps) directly or via a library.
- A change reads, buffers, logs, or captures output from a process or stream whose size is not bounded by design (test output, file uploads, query results, event streams).
- Long-running or third-party-driven work (test suites, external tools, plugins, generated code) is introduced or changed without an existing resource bound.
- `architecture-review` or `release-readiness` flags a reliability/resource review as required, or a performance-reliability-engineer or code-reviewer task calls for it.

## When not to use

- General code quality unrelated to process spawning, memory growth, output capture, or handle lifecycle — use ordinary review.
- Pure algorithmic performance (latency, throughput) with no resource-growth or process-lifecycle concern — use `debug-systematically` or standard performance measurement instead.

## Procedure

Trace each area in the code and, where possible, with a live measurement — do not accept "it cleans up" from a description. Per `agent-framework/canonical/policies/evidence-policy.md`, every claim carries the command and actual output.

1. **Map the spawn and I/O surface.** List every place the change spawns a process, thread, or async task, and every place it reads a file, stream, or subprocess output. Note which are one-shot, which are long-running, and which are third-party-driven (test frameworks, plugins, generated/foreign code the change does not fully control).
2. **Process lifecycle.** For every spawned process or task: who owns it (a variable/handle the caller controls), is there an explicit timeout, and is there a cleanup path that runs on both the success path and the error/exception/cancellation path? Check specifically for:
   - Orphaned children: a parent that exits (normally or via exception) while children keep running.
   - Recursive or unbounded spawning: a process that spawns more of itself or of workers without a depth/count cap (e.g., a test runner re-launching itself per test file with no ceiling).
   - Missing `finally`/`try`-`finally`/context-manager cleanup around process creation — cleanup written only for the happy path is not cleanup.
3. **Memory.** Look for buffers, queues, caches, and lists that accumulate without a bound (no max size, no eviction, no backpressure). Look for whole-file or whole-result loads (`read()`, `.fetchall()`, slurp-to-string/list) where streaming, chunking, or pagination is the correct approach given the data's real-world size. Look for retained references — closures, global registries, event-listener lists, caches keyed by request/session — that prevent garbage collection of objects that should be short-lived.
4. **Output capture.** Check subprocess output handling specifically: is stdout/stderr captured into an in-memory buffer with no size cap, or streamed/discarded/bounded? Is log output written to files that grow without rotation or truncation? A verbose third-party tool (compiler, test runner, browser driver) producing gigabytes of diagnostic output into an unbounded capture is a common trigger for exactly this defect class.
5. **Handles.** For every file descriptor, socket, database connection, and temp file/directory opened: is it closed/removed on every exit path, including exceptions, timeouts, and early returns? Prefer context managers/RAII/`defer`-style guarantees over manual close calls scattered across branches. Temp files/dirs in particular are easy to leak silently because a leak does not fail the immediate operation.
6. **Limits.** For long-running or third-party-driven work, confirm it runs under an explicit memory and/or CPU bound — a cgroup, systemd scope (`MemoryMax=`, `CPUQuota=`), container limit, ulimit, or equivalent language-level bound — so that a runaway is contained to that unit of work rather than exhausting the host. Absence of any bound on a process class that has already misbehaved once, or that runs third-party/generated code, is a Blocking finding, not an Optional one.
7. **Measure, don't assert.** Where feasible, take a before/after (or bounded-run) measurement rather than relying on code inspection alone: peak RSS of the process tree, open file-descriptor count, and open handle/connection count. Compare against the declared or newly-added bound to confirm it actually constrains the workload rather than being cosmetic.

## Verification checklist

- [ ] Every spawned process/task has a named owner, an explicit timeout, and cleanup on both success and error/exception paths
- [ ] No orphaned children: parent exit paths (including exceptions) are traced to child termination
- [ ] No recursive or unbounded spawning: a concrete cap on process/worker count or recursion depth is identified in code
- [ ] Buffers, queues, caches, and accumulating lists have an explicit bound or eviction policy; whole-file/whole-result loads are justified by the data's actual bounded size or replaced with streaming/pagination
- [ ] No reference retention (closures, global registries, listener lists, unbounded caches) blocking garbage collection of short-lived objects
- [ ] Subprocess stdout/stderr capture and log output are bounded or streamed, not accumulated without limit; log files rotate or truncate
- [ ] File descriptors, sockets, DB connections, and temp files/dirs are closed/removed on every exit path, including error paths
- [ ] Long-running or third-party-driven work runs under an explicit memory/CPU bound (cgroup, systemd scope, container limit, ulimit, or language-level equivalent), not just application-level intent
- [ ] At least one measurement (RSS, fd count, or handle count) taken before/after or against the declared bound, not asserted from reading code alone
- [ ] Each finding has location, failure mechanism (host-wide vs contained), and a concrete fix

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`. Each finding cites file:line or config location. Each "no issue found" area states what was actually inspected and how (files read, commands run, with results) — for example the exact command and output used to confirm a bound exists and is enforced (`systemctl show <unit> -p MemoryMax`, `cat /sys/fs/cgroup/.../memory.max`, `ulimit -a` in the relevant shell, or the process-tree RSS captured with `ps -o rss,pid,cmd --ppid <pid>` / `pmap`/`smem` before and after a bounded run). When investigating an actual incident, cite the kernel OOM record (`journalctl -k -b -1 | grep -i oom-kill` or the equivalent for the affected boot), quoting the constraint (`CONSTRAINT_MEMCG` vs global) and victim RSS. Areas not examined are `NOT ASSESSED` with a reason — silence never implies safety. Do not report a measurement you did not actually take.

## Output format

```
## Resource Safety Review: <change/component>
Surface mapped: <spawn points, streams/buffers, handles>
Inspected: <files, commands run, measurements taken>
Not assessed: <areas + reasons, or "none">

### Blocking   (unbounded resource growth or missing containment on a runaway path — must fix before merge/release)
- <finding> — location — failure mechanism (host-wide / contained) — required fix

### Important  (weakens containment or plausible under realistic load — fix soon, owner assigned)
- ...

### Optional   (hardening opportunity)
- ...

### Verdict
<pass | pass after Blocking fixes | fail> — resource bound in place: <yes/no/n-a> — measurement taken: <yes/no + command>
```
