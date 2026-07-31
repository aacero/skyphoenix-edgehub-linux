# Agent Framework v1.1.0 — Release Notes

Date: 2026-07-18 · Branch: `feat/agent-framework-v1.1.0-cross-provider` · Status: awaiting approval (not merged, not tagged)

## Headline

First cross-provider release. One canonical source (`agent-framework/canonical/`)
now generates adapters for **Claude Code, OpenAI Codex, Kimi Code, OpenCode
(incl. local LLMs), and JetBrains AI Assistant/Junie** — with drift detection, an
autonomous-session supervisor, behavioral evals, and an evidence-backed corporate
design system.

## Post-review remediation

Before this release was approved for merge, two independent adversarial reviews
were run against a candidate of this branch: `agent-framework/reports/codex-engineering-review.md`
(OpenAI Codex) and `agent-framework/reports/kimi-portability-review.md` (Kimi
Code, including a cross-review pass over the Codex findings). Both returned
NOT_APPROVED. Every finding from both reviews was triaged, deduplicated, and
disposed in `agent-framework/reports/review-disposition.md` (accepted findings
were assigned to remediation work packages WP1–WP12; deferred items are recorded
there with reasons and routed to `BACKLOG.md` Candidates where applicable). The
remediation described in that disposition has been implemented; the resulting
final state — including which findings were fixed, reduced, or knowingly deferred
— is recorded in `agent-framework/reports/framework-v1.1.0-final-report.md`. Any
claim in this document that appears to conflict with that final report should be
resolved in the final report's favor; this file describes the release as shipped
after remediation, not the pre-review candidate.

## Added

- **Canonical layer:** 6 policies (autonomy w/ continuation ladder, delegation,
  evidence, research, scope-control, security), 3 contracts (task, handover,
  Definition of Done), `core-instructions.md` (source of the AGENTS.md managed block).
- **19 roles** (orchestrator → end-user-simulator) with per-role tools, ownership,
  stopping conditions, model tiering (premium/standard/economy + fallback). Read-only
  roles' `bash-readonly` boundary is **mechanically enforced only where the
  capability matrix (`agent-framework/catalogs/provider-capability-matrix.yaml`)
  records enforcement for that provider**; elsewhere it is a documented,
  instructions-level convention the provider does not mechanically police. Do not
  assume uniform enforcement across providers without checking the matrix entry
  for the specific provider and tool.
- **20 skills** (open Agent Skills spec): 6 core (incl. new `ui-ux-review`),
  5 substantive technical domain skills (SQL, REST/OpenAPI, Playwright, Selenium,
  Appium) and 9 honest domain stubs (SAP S/4HANA, ServiceNow, Jira, Zephyr Scale,
  Tosca, qTest, UiPath, Worksoft, Finmatics) with official-source policies and dated
  references — no fabricated product knowledge. Domain skills install per project
  via `project.yaml`; never the whole catalogue.
- **5 workflows:** software lifecycle (15 evidence-gated stages), deep research,
  market research (evidence-anchored opportunity score), persona validation
  (12 read-only personas + synthesis with product-owner approval gate),
  autonomous session.
- **Autonomous-session supervisor** (`run-autonomous-session.py` + 4 provider shims):
  schema-validated run config, INITIALIZE→…→FINAL_REPORT state machine, session
  rotation with compact handovers and provider-native resume, hard budget/deadline/
  kill-switch/restart limits, quality ladder instead of feature invention, morning
  report, dry-run mode.
- **Render pipeline:** `render.py` (+`--check`), `validate.py`, `check-drift.py`;
  byte-deterministic generation, managed blocks in AGENTS.md/CLAUDE.md, generated
  manifest, CI enforcement via `validate-repository.sh`.
- **Design system** extracted read-only from CompanyWebsite with `path:line` evidence
  for every token; light theme extracted; dark/high-contrast shipped as clearly
  marked `proposed-derived` (site has no dark theme); brand inconsistencies flagged
  (logo palette ≠ UI palette; AA contrast failures documented as binding rules).
- **Evals:** 20 behavioral evals, all deterministic and passing; live-model rubrics
  documented for behaviors that need runtime observation.
- **Provider research** (all sources accessed 2026-07-18) + capability matrix with
  supported / supported-through-adapter / experimental / unsupported / unknown.

## Changed

- `AGENTS.md`/`CLAUDE.md` restructured around managed blocks; project-specific
  content lives outside and survives updates.
- `BACKLOG.md` gains the `Candidates` bucket (unapproved ideas — never implemented
  without approval).
- `project.yaml` gains `agent_framework.skills`.
- `validate-repository.sh` runs framework validation + drift check; placeholder check
  now applies only after project initialization (fixes template-CI false failure).
- `.gitignore`: `agent-framework/runs/`, `.kimi-code/local.toml`.

## Removed

- Hand-written `.claude/agents/*` (6) and `.claude/rules/{00-core,10-security,
  20-testing,30-parallel-work}.md` — superseded by generated adapters.
- Triplicated manual skill copies — now rendered from canonical.

## Known limitations

- Kimi Code: no custom-subagent format → roles ship as prompt briefs; permission
  profile is user-level (not committable). JetBrains: no hooks/subagents/committable
  permissions — policies are advisory there.
- Codex `/goal` is feature-flag-gated; supervisor uses `codex exec resume` instead.
- Dark and high-contrast tokens are proposals pending brand-owner approval.
- Live-model eval rubrics defined but not executed (cost/provider-dependent).
- 9 commercial-product domain skills are stubs by design until verified content is
  approved.
