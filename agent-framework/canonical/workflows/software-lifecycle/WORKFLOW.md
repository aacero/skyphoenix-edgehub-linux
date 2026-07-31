---
id: software-lifecycle
title: Software Lifecycle Workflow
description: >
  Full product lifecycle from discovery through user validation. The orchestrator
  drives the workflow, delegates each stage to the minimal set of roles the current
  task actually requires, and enforces the agent task contract, evidence policy,
  and scope-control policy at every gate.
roles:
  - orchestrator
  - product-manager
  - market-opportunity-researcher
  - deep-researcher
  - software-architect
  - integration-architect
  - data-database-engineer
  - ui-ux-designer
  - implementation-engineer
  - code-reviewer
  - qa-test-engineer
  - security-privacy-reviewer
  - accessibility-reviewer
  - performance-reliability-engineer
  - technical-writer
  - devops-release-engineer
  - end-user-simulator
  - rubber-duck
  - skeptical-reviewer
entry_criteria:
  - A product idea, approved backlog item, or change request exists.
  - "Scope anchors are readable: PROJECT.md, docs/product/product-vision.md, BACKLOG.md."
  - The orchestrator has read the delegation, evidence, scope-control, and autonomy policies.
exit_criteria:
  - Release-level Definition of Done met with evidence (definition-of-done-contract.md), or
  - the work is handed over per the handover contract with an explicit blocker class.
---

# Software Lifecycle Workflow

The orchestrator selects **only the roles the current task requires**. Most tasks
touch a few stages, not all fifteen. Any stage may be **skipped with a recorded
reason** (e.g., "Stage 4 UX: skipped — no user-facing surface changed") in the
task log or handover. Skipping silently is a workflow violation; skipping with a
recorded reason is normal operation.

Stage order is the default flow; the orchestrator may run independent stages in
parallel (e.g., 8 Security, 9 Accessibility, 10 Performance) when their inputs
are ready and writers do not overlap.

---

## Stage 1 — Product discovery

- **Purpose:** Establish that a real user problem exists and is worth solving.
- **Role(s):** product-manager (lead); market-opportunity-researcher, deep-researcher (support, read-only).
- **Inputs:** Product idea or request; `docs/product/product-vision.md`; market-research workflow output if available.
- **Outputs:** Problem statement, target users, success measures; candidate entry in `BACKLOG.md` if new.
- **Gate:** Problem statement traces to the product vision or carries explicit product-owner approval; otherwise it stays a `Candidate`.
- **Delegation notes:** Research support is delegated via the deep-research or market-research workflow with `owned_files: []` (read-only, report output only).

## Stage 2 — Requirements

- **Purpose:** Turn the problem into testable requirements and acceptance criteria.
- **Role(s):** product-manager (lead); rubber-duck (optional clarity check, read-only).
- **Inputs:** Stage 1 problem statement; scope anchors (`PROJECT.md`, PoV scope).
- **Outputs:** Requirements with objectively checkable acceptance criteria; updated backlog item(s) in `Now`/`Next` after product-owner approval.
- **Gate:** Every requirement has at least one acceptance criterion an agent can verify without judgment calls; scope boundary is stated (in/out).
- **Delegation notes:** Requirements drafting is a single-role task; do not fan out. Acceptance criteria written here become the `acceptance_criteria` fields of later task contracts.

## Stage 3 — Architecture

- **Purpose:** Decide structure, boundaries, data flow, and failure handling before code exists.
- **Role(s):** software-architect (lead); integration-architect and data-database-engineer for external interfaces and persistence; skeptical-reviewer (adversarial pass on the proposal, read-only).
- **Inputs:** Requirements; `docs/architecture/overview.md`; existing ADRs; threat model.
- **Outputs:** Architecture decision(s) recorded as ADR(s) in `docs/adr/`; updated overview if structure changes.
- **Gate:** ADR approved before implementation starts. No silent dependency additions or public-contract changes (scope-control policy).
- **Delegation notes:** Architecture uses a premium model class (delegation policy, model tiering). The skeptical-reviewer receives the ADR draft as input and returns findings, never edits.

## Stage 4 — UX

- **Purpose:** Define user-facing flows, states, and interaction behavior.
- **Role(s):** ui-ux-designer (lead); accessibility-reviewer (early consult, read-only).
- **Inputs:** Requirements; design-system tokens; personas from `agent-framework/canonical/personas/`.
- **Outputs:** Flow descriptions, screen/state specifications, empty/error/loading states, acceptance notes for implementation.
- **Gate:** Every user-visible requirement has a specified flow including failure states; accessibility consult recorded.
- **Skip condition example:** No user-facing surface changed — record and continue.

## Stage 5 — Implementation

- **Purpose:** Build the smallest complete vertical slice satisfying the requirements.
- **Role(s):** implementation-engineer (writer); data-database-engineer for schema/migrations; integration-architect for external integrations; code-reviewer at the gate (read-only).
- **Inputs:** Requirements, ADRs, UX specs; an agent task contract per delegated slice.
- **Outputs:** Code changes within `owned_files`; migrations with rollback notes; change referencing its backlog item (traceability).
- **Gate:** Code review passed; architecture conformance checked against ADRs (deviations are Blocking); no changes outside owned files; task-level DoD lines met with evidence.
- **Delegation notes:** Parallel implementation writers MUST have non-overlapping `owned_files` or separate worktrees (`scripts/create-worktree.sh`). The orchestrator re-runs or cites validation commands before integrating — a subagent's success claim is not evidence.

## Stage 6 — Unit testing

- **Purpose:** Prove changed behavior at the unit level, including failure paths.
- **Role(s):** qa-test-engineer or implementation-engineer (writer, test files only).
- **Inputs:** Implemented slice; acceptance criteria.
- **Outputs:** Focused tests covering changed behavior and at least one failure path per behavior.
- **Gate:** Tests run with actual output recorded. While `scripts/test.sh` is a stub, this gate can only be `NOT RUN` — never reported as passing (evidence policy).
- **Delegation notes:** Test authoring may run in parallel with review if test files are a disjoint ownership set.

## Stage 7 — Integration testing

- **Purpose:** Prove components and external interfaces work together.
- **Role(s):** qa-test-engineer (lead); integration-architect for contract/interface tests.
- **Inputs:** Integrated branch; interface contracts; test strategy document.
- **Outputs:** Integration test results with commands and output; defects filed with reproduction steps.
- **Gate:** Broader validation gate run (`./scripts/ci.sh` or project equivalent) with recorded output; open defects triaged (fix now vs. `Risks and debt`).

## Stage 8 — Security

- **Purpose:** Assess the change against the threat model and security policy.
- **Role(s):** security-privacy-reviewer (read-only; premium model class).
- **Inputs:** Diff, threat model (`docs/security/threat-model.md`), security policy, security-review skill.
- **Outputs:** Findings with severity; threat-model update required in the same change if a trust boundary changed.
- **Gate:** No unresolved Blocking security findings; secrets scan clean; authorization enforced server-side for any new endpoint.
- **Delegation notes:** Reviewer never edits; fixes go back to Stage 5 as new task contracts.

## Stage 9 — Accessibility

- **Purpose:** Verify UI changes are usable with keyboard, screen reader, and zoom.
- **Role(s):** accessibility-reviewer (read-only).
- **Inputs:** UI changes, UX specs, accessibility-user persona.
- **Outputs:** Findings with severity and affected requirement.
- **Gate:** No Blocking accessibility findings on changed UI; slice-level DoD accessibility line satisfied or `N/A` with reason.
- **Skip condition example:** No UI changed — record and continue.

## Stage 10 — Performance

- **Purpose:** Verify the change meets performance and reliability expectations.
- **Role(s):** performance-reliability-engineer.
- **Inputs:** Integrated change; stated performance expectations from requirements; observability output.
- **Outputs:** Measured results (commands + numbers), regressions filed, capacity/limit notes.
- **Gate:** Measurements recorded per evidence policy; regressions either fixed or explicitly accepted by the product-owner in `Risks and debt`.
- **Skip condition example:** Documentation-only change — record and continue.

## Stage 11 — Documentation

- **Purpose:** Update user, operator, and developer documentation affected by the change.
- **Role(s):** technical-writer (writer, docs files only).
- **Inputs:** Merged behavior, ADRs, requirement text.
- **Outputs:** Updated docs; known-limitations section current.
- **Gate:** Every behavioral change is reflected in the docs it affects, or `N/A` with reason recorded.

## Stage 12 — Packaging

- **Purpose:** Produce installable, versioned artifacts.
- **Role(s):** devops-release-engineer.
- **Inputs:** Green integration gate; version and changelog inputs.
- **Outputs:** Build artifacts, changelog entry, install/upgrade notes.
- **Gate:** Build command and output recorded; install and upgrade validated (release-level DoD); rollback path stated.

## Stage 13 — Release

- **Purpose:** Ship the release with explicit human approval.
- **Role(s):** devops-release-engineer (executes); product-owner (approves).
- **Inputs:** Release checklist (`docs/releases/release-checklist.md`); packaging outputs.
- **Outputs:** Released version, release notes, recorded human approval.
- **Gate:** **Human approval recorded — releases are never agent-approved** (security policy, DoD contract). No auto-merge, no unapproved deploy.

## Stage 14 — Operations

- **Purpose:** Confirm the release is observable and operable; watch for regressions.
- **Role(s):** devops-release-engineer; performance-reliability-engineer.
- **Inputs:** Deployed release; observability tooling; rollback procedure.
- **Outputs:** Post-release health check with evidence; incidents/regressions filed to backlog.
- **Gate:** Observability adequate to operate the change (release-level DoD); rollback verified available; any incident has a filed follow-up.

## Stage 15 — User validation

- **Purpose:** Validate shipped behavior against real usage patterns via personas.
- **Role(s):** end-user-simulator (via the persona-validation workflow, read-only); product-manager (triage).
- **Inputs:** Released or release-candidate build; persona catalog; requirements.
- **Outputs:** Ranked persona findings mapped to requirements; candidate backlog items.
- **Gate:** Findings triaged by the product-manager; anything requiring scope change goes to `BACKLOG.md` `Candidates` and waits for product-owner approval (scope-control policy).

---

## Rules

1. **Task contract everywhere.** Every delegated task in every stage uses the agent
   task contract (`agent-framework/canonical/contracts/agent-task-contract.md`):
   objective, context, owned files, prohibited files, expected output, acceptance
   criteria, validation commands, stopping condition. A delegation missing owned
   files or a stopping condition is invalid and must be rejected by the receiving agent.
2. **Parallel writers never overlap.** Concurrent writer roles own non-overlapping
   file sets or work in separate Git worktrees (`scripts/create-worktree.sh`), and
   integrate frequently. Read-only roles (reviewers, researchers, personas,
   rubber-duck) receive `owned_files: []` and never edit.
3. **Completion requires evidence, never another role's narrative.** Per the
   evidence policy (`agent-framework/canonical/policies/evidence-policy.md`), a
   gate passes only on the exact command and its actual output, or a cited evidence
   ledger marked `REPORTED, NOT INDEPENDENTLY VERIFIED` that is re-run at merge,
   release, and Definition-of-Done gates. `NOT RUN` is never `PASS`; stub scripts
   count as `NOT RUN`.
4. **Minimal role selection.** The orchestrator engages only the roles the current
   task requires. Skipped stages get a recorded reason; unrecorded skips fail review.
5. **Scope control at every stage.** Work outside owned files, unapproved
   dependencies, or behavior not traceable to an approved requirement stops the
   thread and lands in `BACKLOG.md` `Candidates` (scope-control policy).
6. **Unfinished work is handed over, not rounded up.** If a stage cannot meet its
   gate within the stopping condition, the role returns a handover per the handover
   contract instead of a partial success claim.
