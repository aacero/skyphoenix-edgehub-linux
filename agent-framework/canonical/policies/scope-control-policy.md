# Scope Control Policy

Canonical source: `agent-framework/canonical/policies/scope-control-policy.md`.

The framework must prevent projects from becoming something else.

## Anchors

- **Product vision:** `docs/product/product-vision.md` (including "Strategic non-goals") is the approved vision reference. Work that does not trace to it needs product-owner approval.
- **Scope boundary:** `PROJECT.md` "In scope" / "Out of scope" plus the active PoV scope (`docs/product/pov-scope.md`).
- **Definition of Done:** `agent-framework/canonical/contracts/definition-of-done-contract.md`.
- **Decisions:** approved ADRs in `docs/adr/`. Architecture changes REQUIRE a new or amended ADR before implementation. No silent dependency additions or public-contract changes.

## Backlog classification

Every idea, finding, or task lands in exactly one `BACKLOG.md` bucket:

- `Now` / `Next` — approved work; agents may pick these autonomously.
- `Later` — approved direction, not yet scheduled.
- `Candidates` — unapproved ideas, persona findings, optional improvements. Agents MUST NOT implement candidates without explicit product-owner approval, however good the idea.
- `Risks and debt` — known issues to triage.

Unrelated discoveries made mid-task go to `Candidates` (or `Risks and debt`), never into the current change set.

## Scope-change detection

A change is a scope expansion if any of:

- it implements behavior not traceable to an approved requirement or backlog item;
- it adds a dependency, service, external integration, or public API not covered by an ADR;
- it modifies files outside the assigned ownership set;
- it changes acceptance criteria.

On detection: stop that thread, record the proposal as a `Candidate` with rationale, and continue with approved work.

## Traceability

- Each implemented change references its requirement or backlog item (commit message or PR description).
- Reviews check architecture conformance against `docs/architecture/overview.md` and ADRs; deviations are Blocking findings.
- Generated provider files must match canonical sources (`python3 scripts/agent-framework/check-drift.py`); drift is treated like failing CI.
- Session handovers use the handover contract so scope survives context resets and framework updates.
