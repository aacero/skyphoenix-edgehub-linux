---
name: architecture-review
description: Review scope, boundaries, state, failure modes, reuse, security, testability, compatibility, migration, rollback, and ADR needs. Use when a change proposal, design document, ADR draft, or diff alters system structure, public contracts, persistence, dependencies, or cross-module boundaries and needs an architecture verdict before implementation or merge.
---


<!-- GENERATED from agent-framework/canonical/skills/architecture-review/SKILL.md — edit the canonical source, then run: python3 scripts/agent-framework/render.py -->
# Architecture Review

## Purpose

Produce an evidence-based architecture verdict on a proposed or implemented change: does it fit the approved architecture, where does it create risk, and what must change before it proceeds. The output is a finding list (Blocking / Important / Optional), not a rewrite of the design.

## When to use

- A new component, service, dependency, external integration, or public API is proposed.
- A diff crosses module boundaries, changes persistence schemas, or alters a public contract.
- An ADR is drafted, amended, or should exist but does not.
- Before merging any change flagged as "broad" or "cross-module" by the task contract.

## When not to use

- Pure implementation detail inside one owned component with no contract change — use normal code review.
- Security-specific concerns as the primary question — use `security-review` (this skill only flags that one is needed).
- Deciding release readiness — use `release-readiness`.

## Procedure

1. **Anchor.** Read `PROJECT.md` (scope boundary), `docs/architecture/overview.md` if present, and the ADRs in `docs/adr/`. Per `agent-framework/canonical/policies/scope-control-policy.md`, architecture changes require a new or amended ADR before implementation.
2. **Restate the change.** One paragraph: what changes, which components, which contracts. If you cannot restate it from the material provided, that is itself a Blocking finding (design not reviewable).
3. **Scope check.** Does the change trace to an approved requirement or backlog item? Does it add dependencies, services, or public APIs not covered by an ADR? Any untraced expansion is Blocking.
4. **Boundaries and ownership.** Are module boundaries respected? Does any component reach into another's internals, share a database it should not, or duplicate an existing capability instead of reusing it?
5. **State and data.** Where does state live, who owns each datum, what are the consistency expectations, and how do schema changes migrate forward AND roll back?
6. **Failure modes.** For each new interaction: what happens on timeout, partial failure, retry, duplicate delivery, and restart? Unhandled failure paths on critical flows are Blocking; on non-critical flows, Important.
7. **Security and privacy touchpoints.** Identify new trust boundaries, external inputs, secrets, and personal data flows. Do not perform the full review here — flag that `security-review` is required and mark it Blocking if the change adds a trust boundary without one.
8. **Testability and observability.** Can the change be tested at its boundary without the whole system? Are failures observable (logs/metrics) enough to debug in production?
9. **Compatibility and migration.** Impact on existing clients, stored data, and configuration; upgrade path; rollback path. "Rollback not possible" must be stated explicitly, never implied.
10. **ADR check.** If the change alters architecture and no ADR covers it, require one (Blocking). If an ADR exists, check the implementation actually conforms to it.

## Verification checklist

- [ ] Scope traced to approved requirement/backlog item, or deviation flagged
- [ ] No silent dependency or public-contract additions
- [ ] Ownership of every touched datum and component identified
- [ ] Failure modes enumerated for each new interaction
- [ ] Migration forward and rollback path stated
- [ ] Security review need assessed and flagged
- [ ] ADR requirement satisfied or raised as Blocking
- [ ] Every finding cites a concrete file, section, or diff hunk

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`. Every finding must point at concrete evidence: a file path, ADR section, diff hunk, or command output. Never claim you inspected something you did not open; if an area could not be assessed (missing docs, no access), report it as `NOT ASSESSED` with the reason — that is never equivalent to "no findings".

## Output format

```
## Architecture Review: <change name>
Reviewed: <files/docs actually read>
Not assessed: <areas + reasons, or "none">

### Blocking
- <finding> — evidence: <path/section> — required action: <what>

### Important
- <finding> — evidence — recommended action

### Optional
- <finding> — evidence — suggestion

### Verdict
<proceed | proceed after Blocking items resolved | needs ADR / redesign>
```

Blocking = violates scope, breaks a contract, unrecoverable failure mode, or missing required ADR. Important = real risk with a workaround or deferable cost. Optional = improvement, not required for approval.
