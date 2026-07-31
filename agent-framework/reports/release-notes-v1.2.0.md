# Agent Framework v1.2.0 — release notes

**Status: prepared, NOT tagged.** The tag must be created and GPG-signed by the framework
maintainer. Nothing in this branch self-authorizes a release.

**Supersedes v1.1.4 for all purposes. No repository should adopt v1.1.4.**

---

## Why this release exists

v1.1.4 turns every *initialized* adopter's CI red. The fix (`3358bec`) has been sitting on
`main` unreleased since 2026-07-20, and because `update-framework.py` resolves signed tags,
the only thing an adopter could actually fetch was the broken release. Adoption across the
estate has been blocked on this since.

Full detail in `CHANGELOG.md` → `[1.2.0]`.

## What an adopter gets

| Area | Change |
|---|---|
| Adoption | The v1.1.4 CI-red defect is fixed, plus a second latent instance of it that would have hit every *new* repo created from the template |
| Versioning | The framework version is derived from `agent-framework/VERSION` instead of hand-copied; it was 4 releases stale in every provider file |
| Roles → skills | `skills_default` is finally rendered; 19 roles declared it and nothing consumed it |
| Roles → research | The 17 roles without web tools get an explicit delegation route instead of being asked to cite sources they cannot reach |
| Auto-update | The weekly cron that failed 100% of the time in every adopter is removed; manual procedure documented |
| Docs | The migration guide no longer claims the update job runs the gate — it does not |

## Upgrading

Manual, from a throwaway clone — never your working copy:

```bash
git clone git@github.com:skyphoenix-it/<repo>.git /tmp/upgrade-<repo>
cd /tmp/upgrade-<repo>
git checkout -b chore/agent-framework-update

python3 scripts/agent-framework/update-framework.py --ref agent-framework-v1.2.0 --dry-run
python3 scripts/agent-framework/update-framework.py --ref agent-framework-v1.2.0

./scripts/ci.sh          # YOU run the gate. Nothing else runs it. Check the exit code.
git push -u origin chore/agent-framework-update
```

Set `AF_REQUIRE_SIGNED_TAG=1` to require signature verification. That needs `gpg` present;
without it `git verify-tag` fails with `error: cannot run gpg: No such file or directory`.
Install `gpg` rather than disabling the check.

### Expect the updater to refuse (exit 2) on some repos

`PAYLOAD` owns `scripts/ci.sh`, `scripts/validate-repository.sh` and
`scripts/create-worktree.sh` — but **not** `scripts/build.sh` or `scripts/test.sh`, which
stay project-owned. Repositories with a customised `ci.sh` will collide and the updater
will refuse rather than overwrite. That refusal is the safety contract working. Re-run with
`--adopt` (which backs each file up to `.bak-pre-framework` first) only after reading the
diff, and do not let those backups get swept into the PR by `git add -A` — commit explicit
paths.

Known local customisation in this estate: `skyphoenix-finmatics-tosca-integration` and
`skyphoenix-company-website` both extend `scripts/ci.sh`.

## Verification evidence

Run on the preparing workstation, 2026-07-30. Recorded exactly as observed.

Run on the preparing workstation with a conforming toolchain (Python 3.12.13 + PyYAML,
GNU coreutils `timeout` on `PATH`).

| Gate | Result |
|---|---|
| `./scripts/ci.sh` | **exit 0** |
| `validate.py` | **0 errors, 0 warnings** |
| `render.py --check` | **OK** — all generated files match canonical sources |
| `check-drift.py` | **OK** — matches canonical sources and manifest |
| `unittest discover` | **167 tests, 0 failures** |
| `run-evals.py --check` | **34 evals, 0 failures**; `results.md` matches a fresh run |
| Working tree after the gate | **0 dirty paths** — the `CI` dirty-file guard passes |
| Independent parse of every generated artifact (real `yaml.safe_load` / TOML parser / `json.loads`) | **OK** — 20 Codex TOML, Claude + OpenCode frontmatter, `opencode.json` |
| Tag signature verification | **OK** — `agent-framework-v1.1.2/3/4` all verify against the shipped trust anchor |
| Tag **signing** | **NOT RUN** — the maintainer's secret key is not on this host |

`results.md` matching a fresh run is the load-bearing part: it confirms both that the
hand-edited version header is right and that the newly wired `--check` gate agrees with the
committed contract.

### Toolchain the gate actually requires

Two host requirements are stricter than the docs claim, and both silently degrade rather
than announcing themselves:

- **Python 3.11+, not the documented 3.9+.** `validate.py:15` and
  `tests/agent-framework/test_generated_artifacts.py:12` hard-import `tomllib`. On 3.9 the
  gate cannot run at all. Left uncorrected in this release deliberately — it is either a
  docs fix or a `tomli` fallback, and that choice should not be made inside a release branch.
- **GNU `timeout` must be on `PATH`.** `provider-common.sh:99` falls back to running
  unbounded when it is missing, so provider calls lose their timeout silently and
  `test_provider_shims.TestShimLevelTimeout` fails. The shim looks for `timeout`, not
  `gtimeout`, so on macOS `brew install coreutils` is not sufficient — put
  `$(brew --prefix)/opt/coreutils/libexec/gnubin` on `PATH`.

Confirming the gate green in hosted CI as well remains worthwhile, since that is the
environment adopters' own runs resemble.

## Cutting the tag (maintainer, on a host with the signing key)

```bash
git checkout release/agent-framework-v1.2.0
git pull --ff-only
./scripts/ci.sh                       # must exit 0 here, on a 3.11+ host with PyYAML
git tag -s agent-framework-v1.2.0 -m "Agent framework v1.2.0"
git verify-tag agent-framework-v1.2.0
git push origin agent-framework-v1.2.0
```

Signing key `93CDC77EACF98990`; the public half ships at
`agent-framework/trust/framework-maintainer.asc`.

## Still open after this release

- `framework-update.yml` automation stays off until a cross-repo read credential exists
  (owner decision 2026-07-30 was to defer). The workflow is wired for it already.
- `agent-framework/BACKLOG.md` → "Needs an owner decision": unanchored ignore patterns,
  design system as mandate vs library, and the concept rename table.
- OpenCode live pilot, JetBrains runtime, local models and Windows remain **NOT RUN**.
