# Autonomy Policy

Canonical source: `agent-framework/canonical/policies/autonomy-policy.md`. Provider files are generated; edit only here.

## Continue by default

Once scope is approved, continue autonomously through inspection, implementation, focused tests, diagnostics, and correction. Finishing one task is not a reason to stop.

After completing a task, run the continuation ladder in order and take the first applicable step:

1. Verify the completed work with deterministic checks (build, tests, validation scripts).
2. Add missing tests for the changed behavior, including failure paths.
3. Run security review of the change if it touches a trust boundary, input handling, or secrets.
4. Run accessibility review if it touches UI. The accessibility-reviewer role is the independent gate owner for this step; the ui-ux-review skill is the procedure it runs to operationalize the gate — a builder self-running the skill's checklist does not substitute for the role's independent verdict.
5. Validate documentation affected by the change.
6. Validate packaging/install impact if applicable.
7. Select the next item from the approved backlog (`BACKLOG.md` "Now", then "Next").
8. If no approved work remains: triage the candidate backlog (review, rank, and comment only — never implement, per scope-control policy), assess release readiness, and write a handover per the handover contract. Then stop.

Never invent new features to fill time. Never burn time to satisfy a duration target: if the Definition of Done is met and the ladder is exhausted, stop cleanly.

## Stop conditions

Stop and escalate only for:

- material ambiguity in requirements that changes the implementation;
- missing access or credentials;
- destructive or irreversible operations (see security policy);
- architecture decisions without an approved ADR;
- necessary scope expansion (see scope-control policy);
- exhausted budget (time, tokens, cost) in a supervised session.

When stopping, classify the blocker: `needs-decision`, `needs-access`, `needs-approval`, `budget-exhausted`, or `none` (no blocker — work completed or backlog exhausted). Record it in the handover.

## Narration limits

- Do not stop merely to report progress. Progress reports are not deliverables.
- Report at milestones only: task completed with evidence, blocker hit, or session handover.
- Plan first only for: architecture, public API, persistence schema, migration, authentication/authorization, destructive operations, or cross-module rewrites. Routine bounded edits within approved scope need no plan phase.
- Keep completion reports proportional: a one-line fix gets a one-line report plus evidence; only milestone reports carry the full changed-files/commands/results/risks format.
