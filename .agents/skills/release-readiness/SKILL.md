---
name: release-readiness
description: Verify criteria, tests, security, compatibility, migrations, install, upgrade, rollback, observability, docs, notices, and limitations; return Go/Conditional Go/No-Go. Use when deciding whether a release, milestone, or deliverable is ready to ship, tag, or hand to a customer.
---


<!-- GENERATED from agent-framework/canonical/skills/release-readiness/SKILL.md — edit the canonical source, then run: python3 scripts/agent-framework/render.py -->
# Release Readiness

## Purpose

Render a defensible Go / Conditional Go / No-Go verdict from verified evidence — not from narrative status reports. The reviewer's job is to distrust claims politely: per the evidence policy, completion claims without commands and results are unverified.

## When to use

- Before tagging a release, shipping a milestone, delivering to a customer or PoV, or closing a Definition-of-Done gate.
- When asked "can we ship this?" in any form.

## When not to use

- Mid-development quality checks — use `feature-slice` gates or `architecture-review`.
- Deep security analysis — require a completed `security-review` as an input; do not substitute for it.

## Procedure

Assess each area below. For every area record: verified (evidence cited) / failed (evidence cited) / `NOT RUN` (reason). Second-hand claims are cited as `REPORTED, NOT INDEPENDENTLY VERIFIED` and the gate-critical ones re-run, per `agent-framework/canonical/policies/evidence-policy.md`.

1. **Acceptance criteria.** Every criterion for the release scope maps to evidence. Unmet or unevidenced criteria are enumerated.
2. **Tests.** Full relevant suites executed on the release candidate (exact commit), commands and results recorded. Flaky reruns disclosed. Stub test scripts count as `NOT RUN`.
3. **Security.** Security review completed for changes touching trust boundaries; findings resolved or explicitly accepted by the owner. No secrets in the artifact or history.
4. **Compatibility.** Impact on existing clients, data, configs, and integrations assessed; breaking changes documented and versioned per policy.
5. **Migrations.** Forward migration tested on realistic data; reverse/rollback migration tested or its impossibility stated in the notes.
6. **Install and upgrade.** Fresh install and upgrade-from-previous both exercised, not assumed. Record the environments used.
7. **Rollback.** A rehearsed or at least written rollback procedure exists for the deployment; data implications stated.
8. **Observability.** New failure modes are logged/measurable; operators can tell the release is healthy after deploy.
9. **Docs and notices.** User docs, changelog/release notes, and required legal/compliance notices updated for this version.
10. **Known limitations.** Honest list assembled; each one classified as acceptable-for-release or blocking.

## Verdict rules

- **Go** — all areas verified; residual items are Optional-grade and documented.
- **Conditional Go** — no gate-critical failures, but specific, named conditions remain (e.g., "docs PR merged before announce", "rollback rehearsal before production rollout"). Every condition has an owner and a deadline; unowned conditions make it a No-Go.
- **No-Go** — any gate-critical failure or any gate-critical area stuck at `NOT RUN` without an approved waiver. Unknown is not Go: missing evidence is treated as failure, never as pass.

## Verification checklist

- [ ] Release candidate commit/artifact identified precisely
- [ ] All ten areas assessed with evidence or explicit `NOT RUN` + reason
- [ ] No claim accepted from narrative alone; second-hand evidence labeled
- [ ] Rollback path stated (or its absence stated as a risk)
- [ ] Known limitations list reviewed by the product owner
- [ ] Every Conditional Go condition has owner + deadline

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`: the report carries an evidence ledger with exact commands and actual outputs (or precise pointers). Gate-critical validations are re-run at this gate even if previously reported by another role.

## Output format

```
## Release Readiness: <version / milestone>
Candidate: <commit / artifact id>

| Area | Status (verified/failed/NOT RUN) | Evidence |
|------|----------------------------------|----------|
| Acceptance criteria | ... | ... |
| Tests | ... | ... |
| Security | ... | ... |
| Compatibility | ... | ... |
| Migrations | ... | ... |
| Install/upgrade | ... | ... |
| Rollback | ... | ... |
| Observability | ... | ... |
| Docs/notices | ... | ... |
| Known limitations | ... | ... |

### Verdict: Go | Conditional Go | No-Go
Conditions (if Conditional Go): <condition — owner — deadline>
Blocking items (if No-Go): <list>
Known limitations shipped: <list>
```
