# Agent Handover Contract

Used when: a session ends, a task is returned unfinished, a blocker stops work, or an autonomous run rotates sessions. Handovers must be compact — the next agent reads this instead of the full transcript.

```markdown
## Handover

- Task: <objective + link to task contract / backlog item>
- Status: done | partial | blocked
- Blocker class: needs-decision | needs-access | needs-approval | budget-exhausted | none
- Branch/worktree: <name>

### Completed (with evidence)
| Claim | Command | Result |
|-------|---------|--------|

### Not done / remaining
- <ordered, smallest resumable steps first>

### Decisions made
- <decision> — <rationale> — <ADR ref if architectural>

### New candidates / risks filed
- <BACKLOG.md entries added>

### Next action
<the single next command or step a resuming agent should take>
```

## Rules

- The evidence table follows the evidence policy; `NOT RUN` entries stay visible.
- "Next action" is mandatory and concrete (a command, a file, a decision to request) — never "continue working".
- Handovers never inflate status: partial is partial. A resuming agent treats prior claims as `REPORTED, NOT INDEPENDENTLY VERIFIED` until it re-runs the validation commands.
- Autonomous-session handovers are written to the run directory as `handover-<n>.md` and referenced from the run-state JSON.
