# Migration & Update Guide — Agent Framework

Audience: repositories created from this template (or ad-hoc repos with hand-written
`AGENTS.md`/`CLAUDE.md`/`.claude/`) that are adopting or upgrading the cross-provider
agent framework.

**Adoption and every later upgrade use the same single command.** It is idempotent —
running it twice changes nothing the second time.

```bash
python3 scripts/agent-framework/update-framework.py
```

Everything below explains what that command does, how to bootstrap a repository that
does not have it yet, how to automate it, and what to do when it refuses.

---

## 1. Quick start

### A repository that already has the framework (upgrade)

```bash
python3 scripts/agent-framework/update-framework.py          # from the template's main
python3 scripts/agent-framework/update-framework.py --ref v1.2.0   # pin a release
git diff && git commit -am "chore: update agent framework"
```

### A repository adopting the framework for the first time (bootstrap)

```bash
git clone --depth 1 https://github.com/skyphoenix-it/skyphoenix-enterprise-template.git /tmp/af-template
python3 /tmp/af-template/scripts/agent-framework/update-framework.py \
    --from /tmp/af-template --target "$PWD"
```

Preview first — the plan is printed and nothing is written:

```bash
python3 scripts/agent-framework/update-framework.py --dry-run
```

Typical first-adoption sequence for a repo with hand-written provider files:

```bash
python3 scripts/agent-framework/update-framework.py                        # lists collisions, exits 2
python3 scripts/agent-framework/update-framework.py --adopt --retire-legacy  # takes them over, with backups
```

### Options

| Flag | Effect |
|---|---|
| `--dry-run` | print the plan, change nothing |
| `--from DIR` | sync from a local template checkout (offline; no clone) |
| `--ref REF` / `--url URL` | template git ref / repository (env: `AF_TEMPLATE_REF`, `AF_TEMPLATE_URL`) |
| `--target DIR` | repository to update (default: current directory) |
| `--adopt` | take over files the framework cannot prove it owns, after backing each up to `<name>.bak-pre-framework` |
| `--retire-legacy` | delete superseded pre-v1.1.0 files whose bytes still match the template baseline (modified ones are always kept) |
| `--no-verify` | skip the verification gate (render still runs) |

Exit codes: **0** success · **1** error or failed verification · **2** collisions need an explicit `--adopt` decision.

---

## 2. What the updater does

1. **Acquires the template** (`--from`, or a shallow clone of `--ref`).
2. **Re-executes the template's own copy of the updater** when it differs from the
   installed one, so an outdated updater can never drive an upgrade.
3. **Syncs the framework payload** — `agent-framework/{canonical,catalogs,schemas,providers,design-system,templates}`,
   `evals/rubrics.md`, `VERSION`, framework reference docs, `scripts/agent-framework/`,
   `scripts/{validate-repository,ci,create-worktree}.sh`, and `tests/agent-framework/`.
4. **Bootstraps the project side** (additive only, skipped when already satisfied):
   managed markers in `AGENTS.md`/`CLAUDE.md`, `.gitignore` entries, a `## Candidates`
   section in `BACKLOG.md`, the `agent_framework.skills` block in `project.yaml`,
   `docs/research/`, the Claude permission baseline, and the CI workflows.
5. **Renders provider artifacts** (`render.py`), refusing on adopter-file collisions.
6. **Reports superseded legacy files** (deleting them only with `--retire-legacy`).
7. **Runs the full gate**: render, `render --check`, validate, check-drift, unit tests,
   evals. Actual exit codes are reported — nothing is summarized away.

### Safety contract

Nothing is ever silently clobbered. The updater applies the same provenance discipline
`render.py` uses:

- **`agent-framework/generated-manifest.json` is NEVER copied from the template.** It
  records *your* repository's generated state. Copying it would transfer framework
  ownership of files your repository hand-wrote and let the next render overwrite them
  with no backup. (Earlier revisions of this guide told you to copy all of
  `agent-framework/` — that instruction destroyed 17 hand-written files in a
  reproduction and has been removed. If you migrated by hand using the old text, check
  `git log` for unintended overwrites.)
- A payload file is written only when the target is **missing**, already
  **byte-identical**, or **provably framework-owned** — its bytes match either the hash
  recorded when the updater last installed it (`agent-framework/.framework-payload.json`)
  or a known template baseline. Anything else is a local modification: the run refuses
  (exit 2) and lists every conflict.
- `--adopt` copies each conflicting file to `<name>.bak-pre-framework` **before**
  taking it over. Nothing is destroyed; the pre-framework version stays on disk and in
  git history.
- Files the template stopped shipping are removed **only** when their bytes still match
  the recorded hash; a locally modified one is kept with a warning.
- Project-side bootstrapping never rewrites existing content, and permission rules are
  only ever **added** — never removed or weakened.

---

## 3. Updating manually

**Updates are manual while the template repository is private.** Read this section
before looking for automation — the scheduled job was removed on purpose.

### Why there is no schedule

The updater installs `.github/workflows/framework-update.yml` into your repository
(source: `agent-framework/templates/framework-update.yml`). Until 2026-07-30 that
workflow carried a weekly `cron` trigger. It fired for the first time on 2026-07-20 and
**failed in every adopting repository**, every time, at the "resolve the template tag"
step:

```
fatal: could not read Username for 'https://github.com': No such device or address
```

The template repository is **private**. That step runs after `actions/checkout` with
`persist-credentials: false` and holds no cross-repo credential (ADR 0001 decision 4
requires the job to hold no write-scoped token while it handles fetched template code),
so `git ls-remote` ran anonymously and git fell through to an interactive credential
prompt. `GITHUB_TOKEN` cannot fix this — it is scoped to the calling repository and
cannot read another private repo.

Rather than ship automation that cannot succeed, the `schedule:` trigger is gone
(owner decision, 2026-07-30). `workflow_dispatch` remains, and it now fails fast with
instructions instead of hanging.

### The manual procedure

Run this from a throwaway clone, never your working copy:

```bash
git clone git@github.com:skyphoenix-it/<your-repo>.git /tmp/upgrade-<your-repo>
cd /tmp/upgrade-<your-repo>
git checkout -b chore/agent-framework-update

# Preview first — writes nothing:
python3 scripts/agent-framework/update-framework.py --ref <signed-tag> --dry-run

# Then for real:
python3 scripts/agent-framework/update-framework.py --ref <signed-tag>

# Prove it: the gate must be run by YOU, here. Nothing else runs it.
./scripts/ci.sh

git push -u origin chore/agent-framework-update   # open a PR; never push to main
```

Use a **signed release tag** for `--ref`, not a branch. Verifying the signature needs
`gpg` installed and the maintainer's public key (it ships at
`agent-framework/trust/framework-maintainer.asc`); set `AF_REQUIRE_SIGNED_TAG=1` to make
verification mandatory. Without `gpg` on the machine, `git verify-tag` fails with
`error: cannot run gpg: No such file or directory`, so install it before relying on the
signature rather than disabling the check.

### The gate does NOT run in the update job

Worth stating plainly, because an earlier version of this guide claimed the opposite:
the workflow invokes the updater with `--no-verify` and **never executes the fetched
template code** (ADR 0001 decision 4 — the job fetches code from another repository, so
it must not run it before a human has looked at it). A PR produced by that workflow
therefore carries **no** gate evidence. You must run `./scripts/ci.sh` on the branch
yourself before merging.

Also note pull requests created with the built-in `GITHUB_TOKEN` deliberately do not
start other workflows, so your own Quality workflow will not run on such a PR either. To
change that, add a repository secret `AF_UPDATE_TOKEN` holding a fine-grained PAT with
`contents: write` + `pull-requests: write`; it is used automatically when present.

### Restoring automation later

The workflow already reads an optional secret `AF_TEMPLATE_READ_TOKEN` (a read-only
cross-repo contents credential) and uses it for both the resolve and fetch steps when
present, passed as an HTTP header so it cannot leak through an echoed URL. Once that
secret exists in a repository, re-adding a `schedule:` block to that repository's copy is
safe. There is no branch tracking to fall back on: the updater resolves the highest
semver **tag** and treats a missing tag as an error (ADR 0001 decision 1).

---

## 4. When the updater refuses (exit 2)

The refusal lists every conflicting path. For each one:

- **Obsolete scaffolding you are retiring** → re-run with `--adopt` (a
  `.bak-pre-framework` copy is made first).
- **Content you need to keep** → move it somewhere the framework does not own *before*
  re-running: project-local files, canonical sources (`agent-framework/canonical/`), or
  a preserved key. `opencode.json` is a partial exception — only `$schema` and
  `permission` are generated; every other top-level key (`provider`, `model`, `mcp`,
  `plugin`, `instructions`, …) is project-owned and survives every render, so a
  local-LLM provider block never collides.

### `scripts/validate-repository.sh` — move project gates, do not keep them here

This is the most damaging collision to accept without reading, because taking it over is
*silent*: `--adopt` writes the old file to `<name>.bak-pre-framework`, and `.gitignore`
excludes that suffix, so repository-specific checks disappear without ever showing up as
deleted content in the adoption diff. One estate repository had 13 gates in it, including
a scan for tracked Apple signing credentials, wired straight into its CI job.

Move them to `scripts/validate-project.sh` before re-running. The framework-owned scanner
runs that file when present and folds its exit status into the result, and never ships,
overwrites or removes it (ADR 0002). The relocation changes no behaviour: same checks,
same gate, same CI job.

Files that commonly collide on first adoption: `.codex/config.toml`,
`.kimi-code/README.md`, `.kimi-code/AGENTS.md`, `.claude/rules/agent-framework.md`,
`.aiassistant/rules/*.md`, `.claude/agents/*`, `.codex/agents/*`, `.kimi-code/agents/*`,
`.opencode/agents/*`, and rendered skill copies under `.claude/skills/`, `.agents/skills/`.

### Superseded pre-v1.1.0 files

`.claude/agents/{architect,implementer,release-manager,reviewer,security-reviewer,test-architect}.md`
and `.claude/rules/{00-core,10-security,20-testing,30-parallel-work}.md` are replaced by
generated equivalents. The updater reports them; `--retire-legacy` deletes only the ones
still byte-identical to the template baseline. Anything you customized is kept for you to
review — move its substance into `agent-framework/canonical/` or a clearly project-local
file.

---

## 5. What changes conceptually

- `agent-framework/canonical/` is the single source of truth. Everything under
  `.claude/`, `.agents/skills/`, `.codex/`, `.kimi-code/`, `.opencode/`,
  `.aiassistant/rules/`, `opencode.json`, and the managed blocks in `AGENTS.md`/`CLAUDE.md`
  is generated. Hand edits to generated files are drift and fail CI.
- Project-specific instructions live **outside** the managed blocks and survive every
  update (regression-tested: eval E17).
- Domain skills are opt-in per repository:

  ```yaml
  agent_framework:
    skills: [servicenow, rest-openapi]   # only what this project needs
  ```

  Re-run the updater (or `render.py`) after changing the list.

---

## 6. One-time provider setup (not committable)

- **Codex:** mark the project trusted so `.codex/config.toml` loads. Supported CLI
  series is **0.144.x** — the shim refuses other versions before invoking them
  (`AF_ACCEPT_UNSUPPORTED_CLI=1` overrides for an attended pilot).
- **Kimi:** copy the `[[permission.rules]]` block from `.kimi-code/README.md` into
  `~/.kimi-code/config.toml` (Kimi permissions are user-level only). Run `kimi doctor`
  and confirm the rules load — a rule with the wrong schema is silently inert, not
  rejected. Headless Kimi remains **experimental**.
- **JetBrains:** rules auto-load from `.aiassistant/rules/`; skills from `.agents/skills/`.
- **OpenCode / Claude:** no manual step; permissions ship in `opencode.json` and
  `.claude/settings.json`.

---

## 7. Verifying and rolling back

```bash
./scripts/ci.sh    # validate-repository + validate + drift + unit tests + evals
```

Generated files are deterministic, so rollback is exact:

```bash
git revert <framework update commit>
python3 scripts/agent-framework/render.py
python3 scripts/agent-framework/render.py --check   # proves the restored state
```

The updater itself writes no state outside your repository; re-running it after a revert
restores the newer version just as deterministically.

### A failed or refused update rolls itself back

Since v1.1.0 the update is transactional. The updater snapshots every path before it
touches it, and any refusal or error restores the tree in reverse order before exiting.
You do not need to revert a *failed* update — only a successful one you changed your
mind about.

Rehearsed on a real pre-framework repository (a clone of the ServiceNow pilot at
`b6e534c`), which is what this behaviour was built for:

| Command | Result |
|---|---|
| `update-framework.py --from <template> --target <repo> --retire-legacy --dry-run` | exit **2**, names all 14 colliding files, `git status --porcelain` **empty** |
| same without `--dry-run` (real run, no `--adopt`) | exit **2**, **0** changed paths, all 6 legacy files intact |
| `... --adopt --retire-legacy` | exit **0**, gates green |

Before v1.1.0 that middle row left 24 changed paths, 10 deleted files and no backups.

If a rollback cannot complete — a filesystem or permission failure mid-restore — the
updater prints `ROLLBACK FAILED for <path>` for each path it could not restore and exits
non-zero. That message means the tree is in a mixed state: recover with
`git checkout -- .` (or `git status` plus the per-path list) and re-run. This is the same
degraded-path contract `render.py` uses.

`--dry-run` runs the real update against a disposable copy of your repository rather than
simulating it, so its exit code is the exit code the real run would return. A dry run that
exits 0 means the real run will not refuse; a dry run that exits 2 lists exactly the files
you need to review or `--adopt`.

---

## 8. Requirements and known impacts

- **Python 3.9+**, **PyYAML**, **git**, and **Bash** on `PATH`. `scripts/agent-framework/*.sh`
  are Bash programs: invoke them as executables (`./scripts/agent-framework/provider-claude.sh`),
  never `source` them into fish/zsh. The updater itself is pure Python — no rsync, and no
  network access when `--from` is used.
- Tooling that greps the old `.claude/rules/00-core.md` etc. must point at
  `.claude/rules/agent-framework.md` or the canonical policies.
- `AGENTS.md` is restructured; forks with heavy hand edits do the marker step once (the
  updater appends markers automatically, keeping your text).
- The placeholder check in `validate-repository.sh` enforces only after
  `initialize-project.sh` has stamped `.project-initialized`.
- Windows execution and Windows CI are **NOT RUN** for this framework version.
