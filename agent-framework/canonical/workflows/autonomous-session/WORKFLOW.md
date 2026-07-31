---
id: autonomous-session
title: Autonomous Long-Run Session
description: Supervisor-driven multi-hour agent run with checkpoints, restarts, budget and deadline enforcement, and an evidence-backed morning report.
roles: [orchestrator, implementation-engineer, qa-test-engineer, code-reviewer]
entry_criteria: Approved backlog exists; run config written and human-reviewed; isolated worktree available; budget and duration explicitly chosen by the user.
exit_criteria: Morning report written; run-state.json validates; worktree left in a clean, committed state; no unapproved scope implemented.
---

# Autonomous Long-Run Session

Long autonomy is NOT solved with a larger prompt. It is solved by an external
**supervisor process** (`scripts/agent-framework/run-autonomous-session.py`) that owns
time, budget, state, and restarts, and by small per-phase prompts to fresh provider
sessions that inherit context through compact handovers.

## Configuration (all user-selected, schema-enforced)

`agent-framework/schemas/autonomous-run.schema.json` requires: objective, provider
(claude|codex|kimi|opencode), model, duration_hours (absolute start/deadline derived),
min_useful_work_minutes, scope_boundary, definition_of_done, approved_backlog,
budget, network_policy, command_policy, max_restarts, heartbeat_seconds,
checkpoint_interval_minutes, worktree (isolated Git worktree; created via
`scripts/create-worktree.sh`), kill_switch_file, dry_run.

Budget semantics (honest): `max_cost_usd`/`max_total_tokens` are SOFT thresholds —
they are checked before every provider call and can be exceeded by at most one
in-flight call. The HARD caps are `max_provider_calls` (persisted in run state) and
the per-call timeout, which is bounded by the remaining time to the deadline.

## State machine

```
INITIALIZE -> DISCOVER -> PLAN
   -> IMPLEMENT -> VERIFY -> REVIEW -> UPDATE_STATE -> SELECT_NEXT_TASK
        -> CONTINUE_OR_HANDOVER  (loops back to IMPLEMENT while work + time remain)
-> FINAL_REPORT
```

Persistent artifacts per run (in `agent-framework/runs/<run-id>/`, gitignored):
`run-state.json` (schema-validated, atomically rewritten at every transition),
`exec-plan.md`, `handover-<n>.md`, `morning-report.md`, `logs/` (every prompt and raw
provider output), heartbeat timestamps inside run-state.

## Session rotation and resume

- Each provider call goes through `scripts/agent-framework/provider-<p>.sh`, which
  normalizes output to `{session_ref, text, cost_usd, tokens, exit_kind}`.
- Within one session, consecutive phase calls continue the provider conversation via
  the provider's native session-resume (`claude --resume`, `codex exec resume` with a
  `-c sandbox_mode=...` override, `kimi --session`, `opencode --session`).
- On `context-exhausted`, `crashed`, or `timeout`: the supervisor writes a compact
  handover (handover contract format), increments `restarts_used`, and opens a FRESH
  provider session whose first prompt embeds the handover content verbatim
  (recovery model `handover-injection`, recorded per session in run-state). Restarted
  sessions treat handover claims as `REPORTED, NOT INDEPENDENTLY VERIFIED`.
- The supervisor re-invokes a provider whenever a session ends before the deadline
  and meaningful approved work remains (`min_useful_work_minutes` guard).
- Restarts stop at `max_restarts` → stop_reason `max-restarts`.

## Stopping rules

Kill-switch file, deadline, and SIGTERM/SIGINT are enforced IN-FLIGHT: provider calls
run in their own process group, the supervisor polls the guards while the call runs,
and on trigger the whole group receives SIGTERM then SIGKILL after a grace period.
Budget (cost/tokens/calls) is checked before every provider call. A phase whose
output carries no `PHASE_RESULT` marker fails closed (one retry, then blocked /
`provider-output-invalid`). Stop reasons recorded in run-state: `deadline | budget |
backlog-exhausted | kill-switch | max-restarts | blocked-all-tasks | signal |
min-work-window | provider-output-invalid | crashed`.

Recovery: `--resume <run-id>` reloads the schema-validated checkpoint (corrupt state
is quarantined, never guessed at), resets `in_progress` tasks to `pending`, and
continues. A `supervisor.lock` file with the owner PID prevents two supervisors from
sharing one run directory; duplicate run IDs are refused at creation.

## Never burn time

When the approved backlog reaches Definition of Done before the deadline, the
supervisor appends the **quality ladder** (deterministic verification → missing tests
→ security review → accessibility review → documentation validation → packaging
validation → usability review → backlog triage → release-readiness assessment) —
each at most once. It NEVER invents features. When the ladder is exhausted, the run
stops with `backlog-exhausted` regardless of remaining time.

## Blockers and fallback

Sessions signal `BLOCKER: needs-decision|needs-access|needs-approval|budget-exhausted: <why>`; the
supervisor marks the task blocked, records the class, and selects the next pending
task (fallback selection). If every task is blocked → `blocked-all-tasks` and the
morning report lists each blocker for the human.

## Evidence

Sessions print `EVIDENCE: <command> => <result>` lines; the supervisor stores them
per task. A task without evidence is recorded `done-claimed`, never `done-verified` —
the morning report shows the difference (evidence policy).

## Morning report

`morning-report.md`: objective, window, stop reason, sessions/restarts, budget spent,
per-task status with evidence lines, and the human follow-up list.

## Safety

- Isolated worktree only; never the user's primary checkout. The supervisor VERIFIES
  this for real runs: `worktree.path` is required, must be a linked worktree listed by
  `git worktree list`, on the declared branch, and clean — otherwise the run is
  REFUSED. An attended pilot run is required before the first unattended run of any
  provider (see the capability matrix unknowns).
- Network and command policy are declared in config and passed to shims; enforcement
  uses provider-native sandboxes/permissions (capability matrix documents gaps).
- No force-push, no merges, no releases, no provider login from inside a run.
- Dry-run mode (`--dry-run`) exercises the entire loop with canned shim responses —
  required before the first real run of any new configuration. Do not start
  multi-hour real runs without explicit human approval of the run config.
