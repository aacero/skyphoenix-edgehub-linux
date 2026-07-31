---
id: persona-validation
title: Persona Validation Workflow
description: >
  Synthesis workflow that exercises the product through simulated end-user
  personas, deduplicates and ranks their findings, maps them to requirements,
  and files candidate backlog items. Personas are strictly read-only simulators;
  scope expansion requires product-owner approval.
roles:
  - orchestrator
  - end-user-simulator
  - product-manager
entry_criteria:
  - A runnable product surface, prototype, or specification exists to validate.
  - The persona catalog (agent-framework/catalogs/persona-catalog.yaml) is available.
  - Requirements or acceptance criteria exist to map findings against.
exit_criteria:
  - "A deduplicated, ranked findings report exists, mapped to requirements where possible, at the location named in the task contract's report path (default: docs/reports/persona-<id>-<date>.md)."
  - Actionable findings are filed in BACKLOG.md as Candidates; nothing was implemented.
  - Any scope-expanding follow-up carries explicit product-owner approval or remains a Candidate.
---

# Persona Validation Workflow

The orchestrator selects only the personas the current validation target
requires (Stage 1) — running all twelve on every change is an anti-pattern.
Stages may be skipped with a recorded reason (e.g., Stage 5 mapping skipped
because no requirements document exists yet — recorded, and filed as a risk).

**Personas never edit product code, configuration, or tests.** Each persona run
is a read-only end-user-simulator task with `owned_files: []` (or a findings
file only), per the delegation and security policies.

---

## Stage 1 — Persona selection

- **Purpose:** Pick the smallest persona set that covers the change's risk surface.
- **Role(s):** orchestrator; product-manager advises.
- **Inputs:** Change description or release scope; persona catalog; affected requirements.
- **Outputs:** Selected persona list with a one-line reason per inclusion and per notable exclusion.
- **Gate:** Every selected persona maps to a risk of the change (e.g., accessibility-user for UI changes, procurement-buyer for pricing/licensing surfaces). Selection reasons recorded.

## Stage 2 — Persona simulation

- **Purpose:** Produce findings from each persona's perspective.
- **Role(s):** end-user-simulator, instantiated once per selected persona with that persona's YAML as its behavioral contract.
- **Inputs:** Persona definition (`agent-framework/canonical/personas/<id>.yaml`); the product surface/spec; the persona's probes list.
- **Outputs:** Findings in the persona finding format: persona, severity (blocker/major/minor), frequency-likelihood, description, expectation-vs-reality, affected requirement if known. Finding types limited to: questions, usability-findings, misunderstandings, missing-information, edge-cases, acceptance-concerns.
- **Gate:** Each persona stayed in character (traits and probes from its YAML), produced findings in the required format, and wrote nothing outside its findings output. Personas run in parallel — they are independent readers.
- **Delegation notes:** Each run uses the agent task contract with `read_only` behavior, `prohibited_files` covering all product code and configuration, and a stopping condition (e.g., probes exhausted or finding cap reached). Default finding cap: 15 findings per persona run, unless the task contract states a different cap.

## Stage 3 — Deduplication

- **Purpose:** Merge findings describing the same underlying issue.
- **Role(s):** orchestrator (economy/standard model class — mechanical work per delegation policy).
- **Inputs:** All persona findings.
- **Outputs:** Deduplicated finding list; each merged finding retains the list of personas that hit it (this feeds frequency).
- **Gate:** No two findings describe the same expectation-vs-reality mismatch; persona attribution preserved on every merged item.

## Stage 4 — Ranking

- **Purpose:** Order findings by impact.
- **Role(s):** orchestrator; product-manager reviews the top of the list.
- **Inputs:** Deduplicated findings.
- **Outputs:** Findings ranked by **severity × frequency**: severity (blocker=3, major=2, minor=1) × frequency-likelihood (how many personas hit it and how likely a real user encounters it: high=3, medium=2, low=1).
- **Gate:** Every blocker-severity finding appears above every minor one unless an explicit, recorded justification exists.

## Stage 5 — Requirement mapping

- **Purpose:** Connect findings to what the product promised.
- **Role(s):** product-manager.
- **Inputs:** Ranked findings; requirements and acceptance criteria.
- **Outputs:** Per finding: the requirement/acceptance criterion it violates, or `UNMAPPED` — an unmapped finding signals a requirements gap, not a defect.
- **Gate:** Every finding is either mapped or explicitly `UNMAPPED`; unmapped blockers are flagged for Stage 6 as potential requirement gaps.

## Stage 6 — Candidate backlog items

- **Purpose:** Turn findings into decision-ready backlog entries.
- **Role(s):** product-manager (writer for BACKLOG.md only).
- **Inputs:** Mapped, ranked findings.
- **Outputs:** Entries in `BACKLOG.md` under **Candidates** (or **Risks and debt** for defects in shipped behavior), each with severity, frequency, affected requirement, and originating personas.
- **Gate:** Every blocker and major finding has a backlog entry or a recorded won't-fix reason. Nothing is implemented in this workflow.

## Stage 7 — Product-owner approval gate

- **Purpose:** Keep persona findings from silently expanding scope.
- **Role(s):** product-owner (human decision); product-manager presents.
- **Inputs:** Candidate entries from Stage 6.
- **Outputs:** Per candidate: approved (moved to `Now`/`Next`/`Later`) or left in `Candidates`.
- **Gate:** **Product-owner approval is REQUIRED before any scope expansion** (scope-control policy). Agents MUST NOT implement candidates that lack this approval, however severe the finding — a blocker finding justifies escalation, never self-approval.

---

## Rules

1. **Personas never edit product code**, configuration, tests, or documentation.
   They are read-only simulators; their entire output is findings.
2. Every persona run is delegated via the agent task contract with read-only
   ownership and an explicit stopping condition.
3. Findings use the persona finding format (persona, severity, frequency-likelihood,
   description, expectation-vs-reality, affected requirement) — free-form
   narratives are rejected at the Stage 2 gate.
4. Findings become work only through Stage 6 candidates plus Stage 7 approval;
   there is no direct persona-to-implementation path.
5. Per the evidence policy, "persona validation done" claims cite the findings
   report and the backlog entries created, not a narrative summary.
