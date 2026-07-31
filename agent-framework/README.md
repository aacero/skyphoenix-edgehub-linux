# SKYPhoenix Cross-Provider Agent Framework

Version: see `VERSION`. Provider-neutral agent framework for Claude Code, OpenAI
Codex, Kimi Code, OpenCode (incl. local LLMs), and JetBrains AI Assistant/Junie.

## Architecture

```
canonical/            SOURCE OF TRUTH — edit here only
  core-instructions.md  -> AGENTS.md / CLAUDE.md managed blocks
  policies/             autonomy, delegation, evidence, research, scope-control, security
  contracts/            task, handover, definition-of-done
  roles/                19 role definitions (YAML)
  skills/               open-spec Agent Skills (core + domain)
  workflows/            software-lifecycle, deep-research, market-research,
                        persona-validation, autonomous-session
  personas/             12 user-validation personas
providers/            adapter definitions per provider (mapping documentation)
catalogs/             role/skill/workflow/persona catalogs + provider capability matrix
design-system/        extracted SKYPhoenix brand tokens + guidelines (source-ledger backed)
schemas/              JSON Schemas (autonomous-run, run-state)
evals/                deterministic checks (artifact/mutation/dry-run); live-model
                      rubrics for behaviors needing runtime observation are
                      separate (evals/rubrics.md), marked NOT RUN unless executed
reports/              audit, research, security review, migration guide, release reports
runs/                 autonomous-session run state (gitignored)
```

Generated provider files (`.claude/`, `.agents/skills/`, `.codex/`, `.kimi-code/`,
`.opencode/`, `.aiassistant/rules/`, `opencode.json`, and the managed blocks in
`AGENTS.md`/`CLAUDE.md`) are **build artifacts**. Never edit them directly.

## Commands

```bash
python3 scripts/agent-framework/render.py          # regenerate provider files
python3 scripts/agent-framework/render.py --check  # fail if generated files drifted
python3 scripts/agent-framework/validate.py        # validate canonical content
python3 scripts/agent-framework/check-drift.py     # render-check + manifest integrity
python3 scripts/agent-framework/run-autonomous-session.py --config run.json --dry-run
python3 scripts/agent-framework/evals/run-evals.py # deterministic checks (see evals/rubrics.md for live-model rubrics, NOT RUN by this command)
```

`validate-repository.sh` (and therefore CI) runs validate + check-drift.
Script dependency: Python 3.9+ and PyYAML. `scripts/agent-framework/*.sh` are Bash
programs — Bash is required; they are invocable from fish/zsh as executables but
are not fish-syntax-compatible and must not be sourced into a non-Bash shell.

## Workflow for changes

1. Edit files under `canonical/` (or catalogs/design-system).
2. `python3 scripts/agent-framework/render.py`
3. `python3 scripts/agent-framework/validate.py && python3 scripts/agent-framework/check-drift.py`
4. Commit canonical + generated files together.

## Adopting or updating this framework in another repository

One idempotent command handles both the first migration and every later upgrade:

```bash
python3 scripts/agent-framework/update-framework.py            # --dry-run to preview
```

It syncs the framework payload, bootstraps the project-side requirements, renders, and
runs the full gate — refusing (exit 2) rather than overwriting anything it cannot prove
the framework owns. It also installs `.github/workflows/framework-update.yml`, which
opens a gated update pull request on **manual dispatch**.

**Updates are manual while this template repository is private.** The workflow carries no
`schedule:` trigger: a scheduled run cannot read a private template (the job holds no
cross-repo credential by design, and `GITHUB_TOKEN` cannot read another repository), so
the weekly cron failed in every adopter, every time, until it was removed on 2026-07-30.
The manual procedure, and how to restore automation with an `AF_TEMPLATE_READ_TOKEN`
secret, are in `reports/migration-guide.md` → "Updating manually" — which is also the
bootstrap reference for repositories that do not have the script yet.

Running it against THIS repository is refused — the template is the framework source
(marked by `.framework-source`); edit canonical sources and render instead.

That marker is tracked, so a repository **created from** the template inherits it and the
updater then refuses there too, reporting that a product repository is the framework
source. `scripts/initialize-project.sh` deletes and untracks it (since v1.2.4). A repo
made before v1.2.4 that has never been able to update should check for the file first:

```bash
git rm -f agent-framework/.framework-source   # only in an ADOPTING repository
```

### Repository-specific gates

`scripts/validate-repository.sh` is framework-owned and an update takes it over, so put
repository-specific checks in `scripts/validate-project.sh` instead. The scanner runs it
when present and folds its exit status into the result; the framework never ships,
overwrites, or removes that file (ADR 0002). Checks left in `validate-repository.sh`
survive an adoption only as a gitignored `.bak-pre-framework` copy.

Domain skills are installed per project via `project.yaml` → `agent_framework.skills`
(core skills always installed; never install the whole domain catalogue).

## Key documents

- `reports/current-state-audit.md` — pre-redesign audit
- `reports/provider-research.md` + `catalogs/provider-capability-matrix.yaml` — dated provider facts
- `canonical/workflows/autonomous-session/WORKFLOW.md` — long-run supervisor design
- `reports/migration-guide.md` — adopting/upgrading the framework in existing repos
