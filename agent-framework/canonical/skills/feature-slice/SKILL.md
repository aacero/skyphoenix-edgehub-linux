---
name: feature-slice
description: Define criteria and ownership, implement the smallest end-to-end slice, add tests, run checks, update docs, and report evidence. Use when implementing an approved feature, enhancement, or bounded change — before writing code, to shape the work as a small complete vertical slice.
---

# Feature Slice

## Purpose

Deliver approved functionality as the smallest slice that works end-to-end — through every layer it touches — with tests, docs, and evidence, instead of a broad half-finished horizontal layer. A slice is done or it is not; there is no "90% done".

## When to use

- Starting any approved feature, enhancement, or bounded change from `BACKLOG.md` `Now`/`Next` or a task contract.
- Splitting a large approved feature into shippable increments.

## When not to use

- Diagnosing a defect — use `debug-systematically` first.
- Unapproved ideas or `Candidates` items — per `agent-framework/canonical/policies/scope-control-policy.md`, these need product-owner approval before any implementation.
- Architecture-changing work without an ADR — run `architecture-review` first.

## Procedure

1. **Confirm the mandate.** Trace the task to an approved requirement or backlog item. If it is not traceable, stop and route it through scope control instead of building it.
2. **Write acceptance criteria first.** 2–6 observable, testable statements of what will be true when done. If you cannot state them, the task is materially ambiguous — stop and ask, per the autonomy rules.
3. **Declare ownership.** List the files/components this slice may touch. Anything outside that set mid-task is a scope signal: record it as a `Candidate` or `Risk`, do not edit it.
4. **Cut the smallest vertical slice.** Choose the thinnest path that exercises every layer the feature needs (e.g., one endpoint → service → persistence → response; one happy path plus its most likely failure path). Defer variants, batch modes, and polish to later slices — list them explicitly as deferred.
5. **Design the seam before the code.** Identify the public contract the slice adds or changes. No silent contract or dependency changes; if one is needed, that is an ADR/approval stop.
6. **Implement.** Keep the diff aligned with the ownership set. Handle input validation and the slice's primary failure path — error handling is part of the slice, not a follow-up.
7. **Test at the right level.** Add focused tests for the new behavior including at least one failure-path test (per `agent-framework/canonical/policies/evidence-policy.md` and `docs/testing/test-strategy.md`, behavioral changes require tests and relevant failure paths). Run the focused tests while iterating; run the broader affected suite before declaring done.
8. **Update docs and observability.** Adjust user/developer docs the slice invalidates; ensure new failure modes are logged or measurable.
9. **Run the gate checks.** Execute the project's build/test/lint commands and record actual output. Stub scripts count as `NOT RUN`, not passes.
10. **Report with evidence.** Changed files, commands run, actual results, deferred items, risks, and the next bounded slice.

## Verification checklist

- [ ] Task traced to approved requirement/backlog item
- [ ] Acceptance criteria written before implementation and each one now demonstrably met
- [ ] Diff confined to the declared ownership set (or deviation approved)
- [ ] Slice works end-to-end, verified by running it — not by reading the code
- [ ] Tests cover the new behavior and at least one failure path; suite results recorded
- [ ] No silent dependency or public-contract changes
- [ ] Docs/observability updated where behavior changed
- [ ] Deferred scope and unrelated findings filed in `BACKLOG.md`, not smuggled into the diff

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`. The completion report includes an evidence ledger (claim, command, actual result, location). Map each acceptance criterion to the evidence proving it. `NOT RUN` items are listed with reasons.

## Output format

```
## Slice Report: <feature slice name>
Traceability: <requirement/backlog item>
Acceptance criteria → evidence:
  1. <criterion> — <command/observation> → <result>
Changed files: <list>
Evidence ledger: | # | Claim | Command | Result | Where |
Deferred (next slices): <list>
Risks / limitations: <list>
Next bounded task: <one sentence>
```
