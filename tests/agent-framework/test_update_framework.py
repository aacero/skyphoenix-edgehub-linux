"""Regressions for the one-command framework installer/updater
(scripts/agent-framework/update-framework.py).

The updater is the supported migration and upgrade path for every repository created
from this template, so its safety properties are pinned here: it must never copy the
adopting repository's generated manifest, never overwrite a file it cannot prove the
framework owns, never remove a locally modified file, and must be idempotent.

Every test runs the updater with `--no-verify` against a scratch downstream repo.
That is REQUIRED, not an optimization: the payload includes this very test suite, so
a verifying run inside a scratch repo would execute these tests recursively. The
end-to-end test therefore runs render/validate/check-drift explicitly instead.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import REPO_ROOT, SCRIPTS, run, scratch_dir  # noqa: E402

UPDATER = SCRIPTS / "update-framework.py"

# Assembled at runtime rather than written as one literal, and that is the whole point.
# scripts/validate-repository.sh greps the entire tree for this prefix and excludes only
# initialize-project.sh and itself, so any payload file containing it literally — even in
# a comment or an assertion message *about* placeholders — makes validate-repository.sh
# fail in every repository that adopts the framework. v1.1.4 shipped exactly that: a
# comment in update-framework.py and an assertion message in this file, both merely
# mentioning the token, turned adopter CI red. test_no_payload_file_contains_placeholder
# below is the guard.
PLACEHOLDER_PREFIX = "__PROJECT" + "_"
# Suffix update-framework.py writes beside every file `--adopt` takes over. Transient,
# gitignored, never committed; check-drift.py skips it too. The placeholder scan must
# skip it as well, or adopting a file that legitimately contains the token produces a
# backup that fails the gate the adoption itself is running.
BACKUP_SUFFIX = ".bak-pre-framework"
# Present only in the framework source repo; deliberately not part of the payload.
# update-framework.py:630 keys its self-update refusal off this file.
SOURCE_MARKER = REPO_ROOT / "agent-framework" / ".framework-source"

# Project-side content a template-derived repository owns (no framework payload here).
FIXTURE_COPY = [
    "README.md", "PROJECT.md", "SECURITY.md", "CHANGELOG.md", "CONTRIBUTING.md",
    "LICENSE.md", "THIRD_PARTY_NOTICES.md", "docs", ".editorconfig",
    "scripts/build.sh", "scripts/test.sh", ".github/ISSUE_TEMPLATE",
    ".github/pull_request_template.md",
]

OLD_SETTINGS = {
    "autoMemoryEnabled": True,
    "permissions": {
        "deny": [
            "Read(./.env)", "Read(./secrets/**)", "Read(./credentials/**)",
            "Bash(git push --force *)",
            "Bash(curl * | sh)",  # repo-specific hardening: must survive the merge
        ],
        "ask": ["Bash(git reset --hard *)"],
    },
}


def make_downstream(dst: Path) -> Path:
    """A repository created from an older template: project content, no framework."""
    dst.mkdir(parents=True, exist_ok=True)
    for rel in FIXTURE_COPY:
        src = REPO_ROOT / rel
        if not src.exists():
            continue
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, out, dirs_exist_ok=True)
        else:
            shutil.copy2(src, out)
    (dst / "AGENTS.md").write_text(
        "# Agent Instructions\n\nProject-owned guidance written by this repository.\n"
        "SENTINEL-PROJECT-TEXT-AGENTS\n", encoding="utf-8")
    (dst / "CLAUDE.md").write_text(
        "# Claude\n\nProject-owned Claude notes.\nSENTINEL-PROJECT-TEXT-CLAUDE\n",
        encoding="utf-8")
    (dst / "BACKLOG.md").write_text("# Backlog\n\n## Now\n\n- Ship the thing\n", encoding="utf-8")
    (dst / "project.yaml").write_text(
        'project:\n  name: "Fixture"\n  slug: "fixture"\n  description: "d"\n'
        '  owner: "o"\n  status: discovery\n', encoding="utf-8")
    (dst / ".gitignore").write_text(".env\nnode_modules/\n", encoding="utf-8")
    (dst / ".claude").mkdir(exist_ok=True)
    (dst / ".claude" / "settings.json").write_text(
        json.dumps(OLD_SETTINGS, indent=2) + "\n", encoding="utf-8")
    for script in ("build.sh", "test.sh"):
        p = dst / "scripts" / script
        if p.exists():
            p.chmod(0o755)
    subprocess.run(["git", "init", "-q"], cwd=dst, check=True)
    subprocess.run(["git", "add", "-A"], cwd=dst, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", "downstream fixture"], cwd=dst, check=True,
                   capture_output=True)
    return dst


class UpdaterTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch_dir()
        self.repo = make_downstream(self.tmp / "downstream")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def update(self, *args: str, timeout: int = 300,
               env: dict | None = None) -> subprocess.CompletedProcess:
        """Run the updater against the scratch repo. --no-verify is mandatory here."""
        return run([sys.executable, str(UPDATER), "--from", str(REPO_ROOT),
                    "--target", str(self.repo), "--no-verify", *args],
                   cwd=self.repo, env=env, timeout=timeout)

    def payload_manifest(self) -> dict:
        return json.loads((self.repo / "agent-framework" / ".framework-payload.json")
                          .read_text(encoding="utf-8"))


class TestSafetyContract(UpdaterTestBase):
    def test_clean_repo_migrates_in_one_command(self):
        """A repository with no hand-written provider files needs no --adopt at all."""
        p = self.update()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue((self.repo / ".claude" / "agents" / "orchestrator.md").exists())

    def test_generated_manifest_is_never_copied(self):
        """THE data-loss defect this tool exists to prevent: copying the template's
        generated-manifest.json transfers framework ownership of files the adopting
        repo hand-wrote, letting the next render overwrite them with no backup.

        Proven through its consequence: a hand-written file at a generated path must
        make render REFUSE. With a copied manifest it would be silently overwritten.

        Since ADR 0001 decision 5, a refused run also leaves no manifest behind at all
        (the write is rolled back with everything else) — checked here, then confirmed
        directly against a manifest a *successful* run actually persists."""
        victim = self.repo / ".claude" / "rules" / "agent-framework.md"
        victim.parent.mkdir(parents=True, exist_ok=True)
        victim.write_text("# our own pointer file\nHAND-WRITTEN-SENTINEL\n", encoding="utf-8")
        p = self.update()
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn("HAND-WRITTEN-SENTINEL", victim.read_text(encoding="utf-8"))
        self.assertFalse((self.repo / "agent-framework" / ".framework-payload.json").exists(),
                         "a refused run left a payload manifest behind (ADR 0001 decision 5)")
        p2 = self.update("--adopt")
        self.assertEqual(p2.returncode, 0, p2.stdout + p2.stderr)
        self.assertNotIn("agent-framework/generated-manifest.json", self.payload_manifest()["files"])

    @unittest.skipUnless(SOURCE_MARKER.exists(),
                         "template-only invariant: this repository is not the framework "
                         "source, so --target here is not a self-update")
    def test_framework_source_repo_refused_as_target(self):
        """Template-only. The guard above is load-bearing, not tidiness.

        The payload ships this suite into every adopting repo, and the updater's own
        verify() runs `unittest discover` there. Unguarded, this asserts a refusal that
        can only happen in the source repo (update-framework.py:630 keys off the
        SOURCE_MARKER, which correctly does not ship), so it failed in every downstream
        repo and made a correct migration exit 1."""
        p = run([sys.executable, str(UPDATER), "--from", str(REPO_ROOT),
                 "--target", str(REPO_ROOT), "--no-verify", "--dry-run"], cwd=REPO_ROOT)
        self.assertEqual(p.returncode, 1)
        self.assertIn("IS the framework source", p.stdout + p.stderr)

    def test_dry_run_changes_nothing(self):
        before = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                                capture_output=True, text=True).stdout
        p = self.update("--dry-run")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        after = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                               capture_output=True, text=True).stdout
        self.assertEqual(before, after, "--dry-run modified the working tree")
        self.assertFalse((self.repo / "agent-framework" / "canonical").exists())

    def test_locally_modified_payload_file_refused_then_adopted_with_backup(self):
        self.update("--adopt")  # establish provenance
        victim = self.repo / "agent-framework" / "canonical" / "policies" / "security-policy.md"
        victim.write_text("LOCAL EDIT — must not be silently overwritten\n", encoding="utf-8")
        p = self.update()
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn("security-policy.md", p.stdout)
        self.assertIn("LOCAL EDIT", victim.read_text(encoding="utf-8"))
        p2 = self.update("--adopt")
        self.assertEqual(p2.returncode, 0, p2.stdout + p2.stderr)
        backup = victim.with_name(victim.name + ".bak-pre-framework")
        self.assertTrue(backup.exists(), "adopt overwrote a local edit without a backup")
        self.assertIn("LOCAL EDIT", backup.read_text(encoding="utf-8"))
        self.assertNotIn("LOCAL EDIT", victim.read_text(encoding="utf-8"))

    def test_stale_payload_file_removed_only_when_unmodified(self):
        self.update("--adopt")
        manifest_path = self.repo / "agent-framework" / ".framework-payload.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        # Two files the template no longer ships: one pristine, one locally modified.
        pristine = self.repo / "agent-framework" / "canonical" / "gone-pristine.md"
        modified = self.repo / "agent-framework" / "canonical" / "gone-modified.md"
        pristine.write_text("retired\n", encoding="utf-8")
        modified.write_text("retired\n", encoding="utf-8")
        import hashlib
        h = hashlib.sha256(b"retired\n").hexdigest()
        manifest["files"]["agent-framework/canonical/gone-pristine.md"] = h
        manifest["files"]["agent-framework/canonical/gone-modified.md"] = h
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        modified.write_text("retired\nplus a local change\n", encoding="utf-8")
        p = self.update("--adopt")
        self.assertFalse(pristine.exists(), "unmodified stale payload file was not removed")
        self.assertTrue(modified.exists(), "locally modified stale file was deleted")
        self.assertIn("kept locally modified", p.stdout)


class TestProjectBootstrapping(UpdaterTestBase):
    def test_scaffolding_is_applied_and_project_text_preserved(self):
        self.update("--adopt")
        agents = (self.repo / "AGENTS.md").read_text(encoding="utf-8")
        claude = (self.repo / "CLAUDE.md").read_text(encoding="utf-8")
        self.assertIn("SENTINEL-PROJECT-TEXT-AGENTS", agents)
        self.assertIn("SENTINEL-PROJECT-TEXT-CLAUDE", claude)
        self.assertIn("AGENT-FRAMEWORK:BEGIN", agents)
        self.assertIn("AGENT-FRAMEWORK:END", claude)
        gitignore = (self.repo / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("agent-framework/runs/", gitignore)
        self.assertIn("*.bak-pre-framework", gitignore)  # --adopt backups never committed
        self.assertIn("node_modules/", gitignore)  # existing entries preserved
        self.assertIn("## Candidates", (self.repo / "BACKLOG.md").read_text(encoding="utf-8"))
        self.assertIn("agent_framework:", (self.repo / "project.yaml").read_text(encoding="utf-8"))
        self.assertTrue((self.repo / "docs" / "research" / ".gitkeep").exists())
        self.assertTrue((self.repo / ".github" / "workflows" / "framework-update.yml").exists())

    def test_scaffolding_is_idempotent(self):
        self.update("--adopt")
        first = {p: (self.repo / p).read_text(encoding="utf-8")
                 for p in ("AGENTS.md", "CLAUDE.md", ".gitignore", "BACKLOG.md", "project.yaml")}
        p = self.update("--adopt")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for rel, before in first.items():
            after = (self.repo / rel).read_text(encoding="utf-8")
            self.assertEqual(before, after, f"{rel} changed on a second run")
        self.assertEqual((self.repo / "AGENTS.md").read_text(encoding="utf-8")
                         .count("AGENT-FRAMEWORK:BEGIN"), 1)
        self.assertIn("already up to date", p.stdout)

    def test_permission_merge_adds_required_rules_and_keeps_custom_ones(self):
        self.update("--adopt")
        data = json.loads((self.repo / ".claude" / "settings.json").read_text(encoding="utf-8"))
        deny, ask = data["permissions"]["deny"], data["permissions"]["ask"]
        self.assertIn("Bash(git push -f *)", deny)          # required, was missing
        self.assertIn("Bash(rm -rf *)", ask)                # required, was missing
        self.assertIn("Bash(curl * | sh)", deny)            # repo-specific: preserved
        self.assertIn("Bash(git push --force *)", deny)     # pre-existing: preserved
        self.assertTrue(data["autoMemoryEnabled"])          # unrelated keys preserved
        self.assertNotIn("allow", data["permissions"],
                         "the merge must never introduce an allow list")

    def test_permission_merge_never_weakens_or_duplicates(self):
        self.update("--adopt")
        first = (self.repo / ".claude" / "settings.json").read_text(encoding="utf-8")
        self.update("--adopt")
        second = (self.repo / ".claude" / "settings.json").read_text(encoding="utf-8")
        self.assertEqual(first, second, "permission merge is not idempotent")
        data = json.loads(second)
        self.assertEqual(len(data["permissions"]["deny"]),
                         len(set(data["permissions"]["deny"])), "duplicate deny rules")


class TestLegacyRetirement(UpdaterTestBase):
    LEGACY = ".claude/rules/00-core.md"

    def test_modified_legacy_file_is_never_deleted(self):
        p = self.repo / self.LEGACY
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("# our own rules, not the template baseline\n", encoding="utf-8")
        r = self.update("--adopt", "--retire-legacy")
        self.assertTrue(p.exists(), "a locally modified legacy file was deleted")
        self.assertIn("locally modified", r.stdout)

    def test_unmodified_legacy_file_reported_then_retired(self):
        baseline = subprocess.run(["git", "show", f"a09fbd2:{self.LEGACY}"],
                                  cwd=REPO_ROOT, capture_output=True)
        if baseline.returncode != 0:
            self.skipTest("v1.0 template baseline not available in this checkout")
        p = self.repo / self.LEGACY
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(baseline.stdout)
        r1 = self.update("--adopt")
        self.assertTrue(p.exists(), "legacy file removed without --retire-legacy")
        self.assertIn("remove with --retire-legacy", r1.stdout)
        self.update("--adopt", "--retire-legacy")
        self.assertFalse(p.exists(), "--retire-legacy did not remove the baseline file")


class TestCustomizedCiPreserved(UpdaterTestBase):
    CUSTOM_CI = ("name: Quality\non: [push]\njobs:\n  custom:\n    runs-on: self-hosted\n"
                 "    steps:\n      - run: echo REPO-SPECIFIC-PIPELINE\n")

    def _write_custom_ci(self) -> Path:
        wf = self.repo / ".github" / "workflows" / "quality.yml"
        wf.parent.mkdir(parents=True, exist_ok=True)
        wf.write_text(self.CUSTOM_CI, encoding="utf-8")
        return wf

    def test_customized_quality_workflow_is_kept_and_reported(self):
        """A repository that tuned its own CI must not have it silently replaced."""
        wf = self._write_custom_ci()
        p = self.update()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("REPO-SPECIFIC-PIPELINE", wf.read_text(encoding="utf-8"))
        self.assertIn("kept customized .github/workflows/quality.yml", p.stdout)
        self.assertFalse(wf.with_name(wf.name + ".bak-pre-framework").exists())

    def test_customized_quality_workflow_taken_over_only_with_adopt_and_backup(self):
        wf = self._write_custom_ci()
        p = self.update("--adopt")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn("REPO-SPECIFIC-PIPELINE", wf.read_text(encoding="utf-8"))
        backup = wf.with_name(wf.name + ".bak-pre-framework")
        self.assertTrue(backup.exists(), "adopt replaced the CI workflow without a backup")
        self.assertIn("REPO-SPECIFIC-PIPELINE", backup.read_text(encoding="utf-8"))


class TestAutoUpdateWorkflowAsset(unittest.TestCase):
    """The workflow installed into every adopting repository must be executable and
    free of script injection — it runs with contents:write and pull-requests:write."""

    ASSET = REPO_ROOT / "agent-framework" / "templates" / "framework-update.yml"

    def setUp(self):
        import yaml
        self.wf = yaml.safe_load(self.ASSET.read_text(encoding="utf-8"))

    def test_shell_blocks_are_valid_bash(self):
        import re
        import tempfile
        for step in self.wf["jobs"]["update"]["steps"]:
            if "run" not in step:
                continue
            script = re.sub(r"\$\{\{[^}]*\}\}", "PLACEHOLDER", step["run"])
            with tempfile.NamedTemporaryFile("w", suffix=".sh") as f:
                f.write(script)
                f.flush()
                p = run(["bash", "-n", f.name], cwd=REPO_ROOT)
            self.assertEqual(p.returncode, 0,
                             f"step {step.get('name', 'run')} is not valid bash: {p.stderr}")

    def test_untrusted_inputs_are_never_interpolated_into_shell(self):
        for step in self.wf["jobs"]["update"]["steps"]:
            if "run" in step:
                self.assertNotIn("github.event.inputs", step["run"],
                                 "workflow input interpolated into a run block "
                                 "(script injection); pass it through env: instead")

    def test_workflow_opens_a_pr_and_never_pushes_to_the_default_branch(self):
        steps = "\n".join(s.get("run", "") for s in self.wf["jobs"]["update"]["steps"])
        self.assertIn("gh pr create", steps)
        self.assertIn("--force-with-lease", steps)
        self.assertNotRegex(steps, r"git push[^\n|]*origin\s+(main|master)\b")

    def test_default_token_scope_is_read_only(self):
        """ADR 0001 decision 4: write access is granted at the job that needs it, not
        workflow-wide, and checkout must not leave a write token in .git/config while
        the updater is handling freshly fetched template code."""
        self.assertEqual(self.wf["permissions"], {"contents": "read"})
        checkout = next(s for s in self.wf["jobs"]["update"]["steps"]
                        if str(s.get("uses", "")).startswith("actions/checkout"))
        self.assertIs(checkout["with"]["persist-credentials"], False)

    def test_fetched_code_is_never_executed_in_the_update_job(self):
        """The updater must copy, not run, what it fetched — the gate belongs on the PR."""
        # Match the step that INVOKES the updater, not the one that greps its source
        # for the template URL.
        updater_step = next(s for s in self.wf["jobs"]["update"]["steps"]
                            if 'update-framework.py "${args[@]}"' in s.get("run", ""))
        self.assertIn("--no-verify", updater_step["run"])
        self.assertEqual(updater_step["env"]["AF_REQUIRE_SIGNED_TAG"], "1")

    def test_signature_verification_has_a_usable_trust_anchor(self):
        """AF_REQUIRE_SIGNED_TAG=1 is inoperative without the signer's public key.

        Verified empirically: `git verify-tag` on a signed tag exits 0 with the key in
        the keyring, 1 on a bare runner ("No public key"), and 1 for an unsigned tag.
        A hosted runner starts empty, so without an import step the workflow fails
        closed on every update forever. The anchor must also carry no private half."""
        steps = self.wf["jobs"]["update"]["steps"]
        names = [s.get("name", "") for s in steps]
        anchor_idx = next(i for i, n in enumerate(names) if "trust anchor" in n.lower())
        updater_idx = next(i for i, s in enumerate(steps)
                           if 'update-framework.py "${args[@]}"' in s.get("run", ""))
        self.assertLess(anchor_idx, updater_idx,
                        "the trust anchor must be imported before the updater verifies")
        anchor_step = steps[anchor_idx]["run"]
        self.assertIn("gpg --quiet --import", anchor_step)
        self.assertIn("PRIVATE KEY", anchor_step,
                      "the import step must refuse an anchor containing private material")

        anchor = REPO_ROOT / "agent-framework" / "trust" / "framework-maintainer.asc"
        self.assertTrue(anchor.exists(), f"{anchor} must ship with the framework")
        text = anchor.read_text(encoding="utf-8")
        self.assertIn("BEGIN PGP PUBLIC KEY BLOCK", text)
        self.assertNotIn("PRIVATE KEY", text, "private key material must never be committed")

    def test_no_branch_default_and_no_false_gate_claim(self):
        """ADR 0001 decision 1 removed branch tracking; and once the gate no longer runs
        in this job, any PR text claiming it did would be fabricated evidence."""
        raw = self.ASSET.read_text(encoding="utf-8")
        self.assertNotRegex(raw, r"default:\s*main\b")
        self.assertNotRegex(raw, r"(?i)gate executed.*all green")


class TestPrivateTemplateFetchIsHandled(unittest.TestCase):
    """The private-template credential gap, pinned behaviourally.

    History: `framework-update.yml` shipped a weekly `schedule:` trigger for four
    releases. It fired for the first time on 2026-07-20 and failed in EVERY adopting
    repository at the resolve step — the template repo is private, the job holds no
    cross-repo read credential by design (ADR 0001 decision 4), so `git ls-remote` ran
    anonymously and git fell through to an interactive credential prompt:
    `could not read Username for 'https://github.com': No such device or address`.

    The reason a 147-test suite and green CI missed it: no fixture ever exercised an
    unauthenticated fetch of a private remote. These tests do, using a mock `git` on
    PATH so they are hermetic and need no network (the retrospective's §5.3 rule:
    probe the contract, do not assume it).
    """

    ASSET = REPO_ROOT / "agent-framework" / "templates" / "framework-update.yml"

    def setUp(self):
        import yaml
        self.wf = yaml.safe_load(self.ASSET.read_text(encoding="utf-8"))
        self.raw = self.ASSET.read_text(encoding="utf-8")
        steps = self.wf["jobs"]["update"]["steps"]
        self.resolve = next(s for s in steps
                            if "Resolve the template tag" in s.get("name", ""))

    # --- static properties -------------------------------------------------------

    def test_no_scheduled_trigger_while_the_template_is_private(self):
        """A cron that cannot succeed is worse than no cron: it trains people to ignore
        red runs. Negative control: the exact old schedule must be gone."""
        triggers = self.wf.get(True, self.wf.get("on"))
        self.assertNotIn("schedule", triggers,
                         "a scheduled run against a private template fails 100% of the "
                         "time and cannot be fixed from inside the adopting repository")
        self.assertIn("workflow_dispatch", triggers,
                      "manual dispatch must remain available")
        self.assertNotRegex(self.raw, r'cron:\s*"0 5 \* \* 1"')

    def test_git_can_never_fall_through_to_an_interactive_prompt(self):
        """The observed failure was a *hang-then-die* on a credential prompt, not a
        clean error. Every step that reaches the TEMPLATE remote must disable it.

        Scoped to steps that actually fetch from the template: `ls-remote`, and the step
        that invokes the updater. The PR step also runs git, but against this repository
        with its own token, so it is deliberately out of scope.
        """
        checked = []
        for step in self.wf["jobs"]["update"]["steps"]:
            run_block = step.get("run", "")
            touches_template = ("ls-remote" in run_block
                                or 'update-framework.py "${args[@]}"' in run_block)
            if not touches_template:
                continue
            checked.append(step.get("name", "(run)"))
            self.assertIn("GIT_TERMINAL_PROMPT=0", run_block,
                          f"step {step.get('name')!r} reaches the template remote "
                          "but can still block on a credential prompt")
        self.assertEqual(len(checked), 2,
                         f"expected exactly the resolve and updater steps, got {checked}")

    def test_the_read_token_is_wired_everywhere_it_is_advertised(self):
        """Half-wiring the token would resolve a tag and then fail at fetch — the
        'documented mechanism != implemented mechanism' failure mode."""
        self.assertIn("AF_TEMPLATE_READ_TOKEN", self.raw)
        wired = [s.get("name", "(run)") for s in self.wf["jobs"]["update"]["steps"]
                 if "AF_TEMPLATE_READ_TOKEN" in (s.get("env") or {})]
        self.assertGreaterEqual(
            len(wired), 2,
            "both the resolve step and the updater step fetch from the template, so both "
            f"need the credential; only {wired} have it")

    def test_the_token_is_never_embedded_in_a_url(self):
        """A token in the remote URL leaks through any error message that echoes it."""
        self.assertNotRegex(self.raw, r"https://[^\s\"']*\$\{?AF_TEMPLATE_READ_TOKEN")
        self.assertIn("http.extraheader", self.raw)

    def test_the_credential_is_dropped_after_the_updater_runs(self):
        updater = next(s for s in self.wf["jobs"]["update"]["steps"]
                       if 'update-framework.py "${args[@]}"' in s.get("run", ""))
        self.assertIn("--unset-all", updater["run"],
                      "a global git credential must not outlive the step that needed it")

    # --- behavioural, with a mock git --------------------------------------------

    def _run_resolve(self, *, git_exit: int, git_stderr: str, token: str = "",
                     input_ref: str = ""):
        """Execute the real resolve script with a fake `git` first on PATH."""
        import re
        import tempfile
        script = self.resolve["run"]
        # Workflow expressions are substituted by Actions before the shell sees them.
        script = re.sub(r"\$\{\{[^}]*\}\}", "", script)
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            shim = td / "git"
            shim.write_text(
                "#!/usr/bin/env bash\n"
                "for a in \"$@\"; do\n"
                "  if [ \"$a\" = ls-remote ]; then\n"
                f"    printf '%s\\n' {git_stderr!r} >&2\n"
                f"    exit {git_exit}\n"
                "  fi\n"
                "done\n"
                "exit 0\n", encoding="utf-8")
            shim.chmod(0o755)
            out = td / "gh_output"
            out.write_text("", encoding="utf-8")
            env = dict(os.environ)
            env["PATH"] = f"{td}:{env['PATH']}"
            env["GITHUB_OUTPUT"] = str(out)
            env["INPUT_REF"] = input_ref
            env["AF_TEMPLATE_READ_TOKEN"] = token
            p = subprocess.run(["bash", "-c", script], cwd=REPO_ROOT, env=env,
                               capture_output=True, text=True, timeout=60)
            return p, out.read_text(encoding="utf-8")

    def test_anonymous_read_of_a_private_template_fails_fast_with_instructions(self):
        """THE regression. Reproduces the exact git error seen in all three adopters."""
        p, gh_out = self._run_resolve(
            git_exit=128,
            git_stderr="fatal: could not read Username for 'https://github.com': "
                       "No such device or address")
        self.assertEqual(p.returncode, 1,
                         f"expected a clean failure, got {p.returncode}\n{p.stderr}")
        self.assertIn("Could not read the template repository", p.stderr)
        self.assertIn("AF_TEMPLATE_READ_TOKEN", p.stderr,
                      "the error must name the fix")
        self.assertIn("migration-guide", p.stderr,
                      "the error must point at the manual procedure")
        self.assertNotIn("ref=", gh_out,
                         "no ref may be published when the template could not be read")

    def test_negative_control_a_readable_template_still_resolves(self):
        """Guards against 'fixed' by making the step always fail. With a git that
        succeeds, the same script must resolve a tag and write it to GITHUB_OUTPUT."""
        p, gh_out = self._run_resolve(
            git_exit=0,
            git_stderr="",
            input_ref="agent-framework-v9.9.9")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("ref=agent-framework-v9.9.9", gh_out)

    def test_a_readable_but_tagless_template_is_an_error_not_a_silent_pass(self):
        p, gh_out = self._run_resolve(git_exit=0, git_stderr="")
        self.assertEqual(p.returncode, 1,
                         "an empty tag list must refuse, never fall back to a branch")
        self.assertIn("no semver tag found", p.stderr)
        self.assertNotIn("ref=", gh_out)


def make_independent_repo(dst: Path) -> Path:
    """A repository that was NEVER created from this template.

    Deliberately built WITHOUT the FIXTURE_COPY set: no PROJECT.md, no SECURITY.md, no
    docs/ tree, no scripts/build.sh|test.sh. That omission is the whole point — the
    existing fixture copies those from the template, so every other test in this file
    silently models a template-derived repo and could never catch an adoption gap that
    only an independent repository hits."""
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "README.md").write_text("# Some Existing App\n", encoding="utf-8")
    (dst / "src").mkdir(exist_ok=True)
    (dst / "src" / "index.php").write_text("<?php echo 'hello';\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=dst, check=True)
    subprocess.run(["git", "add", "-A"], cwd=dst, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", "independent app"], cwd=dst, check=True,
                   capture_output=True)
    return dst


class TestAdoptIndependentRepository(unittest.TestCase):
    """A repository that was not created from this template must still adopt cleanly.

    Found 2026-07-20 adopting skyphoenix-company-website, a production PHP app built with
    no agentic workflow. The updater installed the payload fine and then the gates failed
    with 26 errors: validate.py requires every path cited in canonical sources to exist
    locally, and validate-repository.sh requires a fixed project file set — but neither
    PROJECT.md, SECURITY.md, docs/, nor scripts/build.sh|test.sh is in PAYLOAD, because
    they are project-owned rather than template-owned.
    """

    def setUp(self):
        self.tmp = scratch_dir()
        self.repo = make_independent_repo(self.tmp / "independent")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def update(self, *args: str, timeout: int = 300):
        return run([sys.executable, str(UPDATER), "--from", str(REPO_ROOT),
                    "--target", str(self.repo), "--no-verify", *args],
                   cwd=self.repo, timeout=timeout)

    def test_independent_repo_satisfies_the_gates_after_one_update(self):
        p = self.update()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        # exactly what scripts/validate-repository.sh requires
        for rel in ("README.md", "PROJECT.md", "AGENTS.md", "CLAUDE.md", "SECURITY.md",
                    "docs/product/product-vision.md", "docs/architecture/overview.md",
                    "docs/security/threat-model.md", "docs/testing/test-strategy.md",
                    ".claude/settings.json"):
            self.assertTrue((self.repo / rel).exists(), f"missing required file: {rel}")
        # paths cited by canonical sources that validate.py resolves
        for rel in ("docs/product/pov-scope.md", "docs/releases/release-checklist.md",
                    "docs/adr", "scripts/build.sh", "scripts/test.sh"):
            self.assertTrue((self.repo / rel).exists(), f"missing cited path: {rel}")
        r = run([sys.executable, "scripts/agent-framework/validate.py"],
                cwd=self.repo, timeout=300)
        self.assertEqual(r.returncode, 0,
                         f"validate.py failed on a freshly adopted independent repo:\n"
                         f"{r.stdout}\n{r.stderr}")

    def test_scaffold_never_overwrites_the_adopter_own_files(self):
        """A repo that already documents itself keeps its content byte-for-byte."""
        (self.repo / "docs" / "security").mkdir(parents=True, exist_ok=True)
        own = self.repo / "docs" / "security" / "threat-model.md"
        own.write_text("# Our Threat Model\nSENTINEL-ADOPTER-OWNED\n", encoding="utf-8")
        proj = self.repo / "PROJECT.md"
        proj.write_text("# Our Project\nSENTINEL-ADOPTER-OWNED\n", encoding="utf-8")
        p = self.update()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("SENTINEL-ADOPTER-OWNED", own.read_text(encoding="utf-8"))
        self.assertIn("SENTINEL-ADOPTER-OWNED", proj.read_text(encoding="utf-8"))

    def test_project_yaml_is_created_not_merely_warned_about(self):
        """Warning was not enough. The eval suite reads project.yaml unconditionally and
        died with FileNotFoundError, so `ci.sh` could never go green on a freshly adopted
        independent repo even after every other scaffold file existed."""
        self.assertEqual(self.update().returncode, 0)
        p = self.repo / "project.yaml"
        self.assertTrue(p.exists(), "project.yaml must be created, not just warned about")
        text = p.read_text(encoding="utf-8")
        self.assertNotIn(PLACEHOLDER_PREFIX, text,
                         f"must not emit {PLACEHOLDER_PREFIX} placeholders — "
                         "validate-repository.sh flags them")
        self.assertIn("agent_framework:", text, "skill selection block must be present")
        import yaml
        data = yaml.safe_load(text)
        self.assertEqual(data["project"]["slug"], self.repo.resolve().name)
        self.assertIn("TODO", data["project"]["owner"], "starter values must be obviously unfinished")

    def test_scaffolded_scripts_are_executable_and_idempotent(self):
        self.assertEqual(self.update().returncode, 0)
        for rel in ("scripts/build.sh", "scripts/test.sh"):
            self.assertTrue(os.access(self.repo / rel, os.X_OK), f"{rel} not executable")
        before = (self.repo / "PROJECT.md").read_text(encoding="utf-8")
        self.assertEqual(self.update().returncode, 0, "second update must be a no-op")
        self.assertEqual(before, (self.repo / "PROJECT.md").read_text(encoding="utf-8"))


class TestEndToEndMigration(UpdaterTestBase):
    def test_migrated_repo_passes_the_framework_gates(self):
        """Full adoption path, then the gates run explicitly (never via --verify: the
        payload contains this suite and would recurse)."""
        p = self.update("--adopt", "--retire-legacy", timeout=600)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for name, cmd in (
                ("render --check", ["scripts/agent-framework/render.py", "--check"]),
                ("validate", ["scripts/agent-framework/validate.py"]),
                ("check-drift", ["scripts/agent-framework/check-drift.py"])):
            r = run([sys.executable, *cmd], cwd=self.repo, timeout=300)
            self.assertEqual(r.returncode, 0, f"{name} failed:\n{r.stdout}\n{r.stderr}")
        # generated artifacts exist and the adopter's own manifest was produced locally
        self.assertTrue((self.repo / ".claude" / "agents" / "orchestrator.md").exists())
        self.assertTrue((self.repo / "agent-framework" / "generated-manifest.json").exists())
        self.assertEqual(self.payload_manifest()["framework_version"],
                         (REPO_ROOT / "agent-framework" / "VERSION").read_text().strip())
        self.assertFalse((self.repo / "agent-framework" / ".framework-source").exists(),
                         "the source marker must never ship into an adopting repo")

    def test_shipped_suite_does_not_fail_in_the_adopting_repo(self):
        """The gap that let a downstream-only failure ship.

        Every other test here runs the updater with --no-verify, so the suite never
        observed itself running inside a migrated repo — but the updater's real
        verify() runs `unittest discover` there. A test pinning a template-only
        invariant must SKIP downstream, not FAIL; otherwise a correct migration exits 1.

        Observed 2026-07-19 against a clone of the ServiceNow pilot at b6e534c:
        `Ran 118 tests ... FAILED (failures=1)` on an --adopt --retire-legacy migration.

        Runs the one template-only test rather than full discovery: targeted, ~0.05s,
        and it cannot recurse (that test invokes the updater with --no-verify)."""
        p = self.update("--adopt", "--retire-legacy", timeout=600)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        r = run([sys.executable, "-m", "unittest", "-v",
                 "tests.agent-framework.test_update_framework.TestSafetyContract"
                 ".test_framework_source_repo_refused_as_target"],
                cwd=self.repo, timeout=300)
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 0,
                         f"shipped suite fails inside an adopting repo:\n{out}")
        self.assertIn("skip", out.lower(),
                      f"expected the template-only test to skip downstream, got:\n{out}")


def load_updater():
    """Import update-framework.py for unit-level tests (hyphenated filename)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("af_update", UPDATER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_template_remote(dst: Path) -> Path:
    """A stand-in template remote: one branch (`main`) and one UNSIGNED tag."""
    (dst / "agent-framework" / "canonical").mkdir(parents=True, exist_ok=True)
    (dst / "agent-framework" / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    # Hermetic against the operator's git config: signing must be forced OFF here, or a
    # global commit.gpgSign/tag.gpgSign turns these into signed objects and the
    # "unsigned tag is refused" test would silently assert the wrong thing.
    env = ["-c", "user.email=t@t", "-c", "user.name=t",
           "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false",
           "-c", "tag.forceSignAnnotated=false"]
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=dst, check=True,
                   capture_output=True)
    subprocess.run(["git", "add", "-A"], cwd=dst, check=True, capture_output=True)
    subprocess.run(["git", *env, "commit", "-qm", "template"], cwd=dst, check=True,
                   capture_output=True)
    subprocess.run(["git", *env, "tag", "-a", "-m", "unsigned test tag", "v9.9.9"],
                   cwd=dst, check=True, capture_output=True)
    return dst


class TestSourceTrust(UpdaterTestBase):
    """ADR 0001 decisions 1 and 2 — what the updater is willing to fetch and execute."""

    def setUp(self):
        super().setUp()
        self.remote = make_template_remote(self.tmp / "remote")
        self.url = f"file://{self.remote}"

    def fetch(self, *args: str, env: dict | None = None):
        """Hermetic against the ambient environment.

        AF_REQUIRE_SIGNED_TAG is neutralised unless a test sets it explicitly. Without
        this, running the gate under `AF_REQUIRE_SIGNED_TAG=1` — which is exactly how
        the update workflow invokes it — made every unsigned-stub test refuse at the
        signature check instead of exercising what it was written to test. Found by a
        real end-to-end bootstrap from the published tag, and it is the same defect
        class as the template-only test that once failed in every adopting repo: a
        shipped suite must not depend on the environment that happens to invoke it."""
        merged = {"AF_REQUIRE_SIGNED_TAG": "", "AF_TEMPLATE_REF": "", "AF_TEMPLATE_URL": ""}
        merged.update(env or {})
        return run([sys.executable, str(UPDATER), "--url", self.url,
                    "--target", str(self.repo), "--no-verify", "--dry-run", *args],
                   cwd=self.repo, timeout=300, env=merged)

    def test_branch_ref_is_refused_without_the_explicit_opt_in(self):
        p = self.fetch("--ref", "main")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("mutable ref", p.stdout + p.stderr)

    def test_branch_ref_is_accepted_with_allow_mutable_ref(self):
        """Opt-in works and names the pinned SHA; it fails later on the stub payload,
        which proves resolution got past the trust gate rather than being refused."""
        p = self.fetch("--ref", "main", "--allow-mutable-ref")
        out = p.stdout + p.stderr
        self.assertNotIn("mutable ref", out)
        self.assertIn("pinned to", out)

    def test_missing_ref_with_no_recorded_commit_is_refused(self):
        p = self.fetch()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("no template ref given", p.stdout + p.stderr)

    def test_unsigned_tag_is_refused_when_signature_is_required(self):
        env = {"AF_REQUIRE_SIGNED_TAG": "1"}
        p = self.fetch("--ref", "v9.9.9", env=env)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("signature verification failed", p.stdout + p.stderr)

    def test_branch_is_refused_outright_when_signature_is_required(self):
        """Unattended runs may not fall back to --allow-mutable-ref."""
        env = {"AF_REQUIRE_SIGNED_TAG": "1"}
        p = self.fetch("--ref", "main", "--allow-mutable-ref", env=env)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("not a tag", p.stdout + p.stderr)

    def test_annotated_tag_resolves_to_its_commit_not_the_tag_object(self):
        """A signed tag IS an annotated tag, so this is the release path itself.

        `git ls-remote <url> <pattern>` returns only the tag OBJECT line and omits the
        `^{}` dereferenced line, so the resolved sha is the tag object while HEAD after
        checkout is the commit. Comparing them raw rejected every signed tag: the first
        real fetch of agent-framework-v1.1.0 failed with "fetched tree is at c16fe0d,
        expected 683f1dc". Dereference with ^{commit} before comparing.

        Acquisition succeeding is proven by the run getting past the integrity check
        into the payload phase; the stub remote is not a usable template, so it is
        expected to fail after that."""
        p = self.fetch("--ref", "v9.9.9")
        out = p.stdout + p.stderr
        self.assertNotIn("fetched tree is at", out,
                         "annotated tag rejected by the integrity check — the resolved "
                         "sha was not dereferenced to a commit")
        self.assertIn("does not look like a template checkout", out,
                      f"expected acquisition to succeed and the stub to be rejected as "
                      f"an incomplete template; got:\n{out}")

    def test_fetch_provenance_survives_the_reexec(self):
        """`maybe_reexec` hands the template's updater `--from <fetched source>`, so the
        re-executed run takes the local-checkout path and would record no source_commit
        — losing the provenance of the fetch that just happened. The parent passes the
        resolved commit through AF_SOURCE_COMMIT so it is still recorded.

        Observed against the real v1.1.0 tag: source_commit came back None."""
        sha = "deadbeefcafe1234567890abcdefdeadbeefcafe"
        p = run([sys.executable, str(UPDATER), "--from", str(REPO_ROOT),
                 "--target", str(self.repo), "--no-verify", "--adopt"],
                cwd=self.repo, env={"AF_SOURCE_COMMIT": sha}, timeout=300)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.payload_manifest().get("source_commit"), sha,
                         "fetch provenance was dropped across the re-exec")

    def test_transport_helper_and_option_like_urls_are_refused(self):
        af = load_updater()
        for bad in ("ext::sh -c 'touch /tmp/pwned'", "--upload-pack=touch /tmp/pwned",
                    "git://example.com/repo.git"):
            with self.subTest(url=bad):
                with self.assertRaises(af.Failed):
                    af.validate_url(bad)
        for good in ("https://example.com/r.git", "ssh://git@example.com/r.git",
                     "file:///tmp/r"):
            with self.subTest(url=good):
                self.assertEqual(af.validate_url(good), good)


class TestWriteContainment(UpdaterTestBase):
    """ADR 0001 decision 3 — findings F4/F5. Both escapes were demonstrated against
    scratch repos during the v1.1.0 gate; these fail without the containment helper."""

    def test_symlinked_parent_directory_cannot_escape_the_target(self):
        outside = self.tmp / "outside"
        outside.mkdir()
        (self.repo / "agent-framework").symlink_to(outside, target_is_directory=True)
        p = self.update()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("outside the target repository", p.stdout + p.stderr)
        self.assertEqual(list(outside.iterdir()), [],
                         "payload was written outside the target repository")

    def test_symlinked_scaffold_file_is_not_written_through(self):
        victim = self.tmp / "victim.txt"
        victim.write_text("ORIGINAL SECRET\n", encoding="utf-8")
        gi = self.repo / ".gitignore"
        gi.unlink()
        gi.symlink_to(victim)
        p = self.update()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("symlink", p.stdout + p.stderr)
        self.assertEqual(victim.read_text(encoding="utf-8"), "ORIGINAL SECRET\n",
                         "wrote through a symlink to a file outside the repository")

    def test_contained_accepts_paths_under_the_target(self):
        af = load_updater()
        af.set_target_root(self.repo)
        self.assertTrue(af.contained(self.repo / "agent-framework" / "new" / "f.md"))
        with self.assertRaises(af.Failed):
            af.contained(self.tmp / "elsewhere.md")


class TestTransactionalUpdate(UpdaterTestBase):
    """ADR 0001 decision 5 — D1 (`--dry-run` must predict its own refusal, not just
    stop short of it) and D2 (a refusal or failure must roll the tree back to its
    pre-run state, since payload sync/project setup/legacy retirement all run before
    render.py's own collision check can fire)."""

    VICTIM = ".claude/rules/agent-framework.md"

    def _plant_collision(self) -> Path:
        """A hand-written file at a path the framework generates: render.py refuses on
        it (no framework marker, no manifest record) — the same fixture the D2 real
        repository trial found (14 colliding provider files)."""
        victim = self.repo / self.VICTIM
        victim.parent.mkdir(parents=True, exist_ok=True)
        victim.write_text("# our own pointer file\nHAND-WRITTEN-SENTINEL\n", encoding="utf-8")
        return victim

    def test_dry_run_predicts_a_render_collision_and_names_it(self):
        """D1 regression. Before the fix, `--dry-run` against this exact fixture exited
        0 across the whole plan with zero mention of the collision, refusal, or
        `--adopt` — the real run then exited 2. This test FAILED before the fix
        (asserted and recorded in the implementation report)."""
        self._plant_collision()
        p = self.update("--dry-run")
        out = p.stdout + p.stderr
        self.assertEqual(p.returncode, 2, out)
        self.assertIn(self.VICTIM, out)
        self.assertIn("REFUSED", out)

    def test_refused_run_leaves_the_tree_unchanged(self):
        """D2 regression. Before the fix, the refusal fired AFTER sync_payload, project
        setup, and legacy retirement had already mutated the repo (24 changed paths
        observed in the real-repository trial: payload installed, legacy files deleted,
        several modified, no backups). This test FAILED before the fix."""
        self._plant_collision()
        before = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                                capture_output=True, text=True).stdout
        p = self.update("--retire-legacy")
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        after = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                               capture_output=True, text=True).stdout
        self.assertEqual(before, after, "a refused run left the working tree modified")

    def test_dry_run_still_leaves_the_real_target_byte_identical(self):
        """A --dry-run now runs the real mutation flow against a disposable COPY of the
        target; this pins that the real target itself is never touched by it."""
        before = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                                capture_output=True, text=True).stdout
        p = self.update("--dry-run")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        after = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                               capture_output=True, text=True).stdout
        self.assertEqual(before, after, "--dry-run modified the working tree")
        self.assertFalse((self.repo / "agent-framework" / "canonical").exists())

    def test_forced_mid_apply_failure_rolls_back(self):
        """A deterministic mid-apply failure, induced via AF_UPDATE_TEST_FORCE_FAILURE —
        an env var the updater checks right after payload sync, project setup, and
        legacy retirement have all landed, and right before it writes the payload
        manifest or invokes render.py. Exercises both the write-rollback path (payload
        files, project scaffolding) and the deletion-rollback path (a retired legacy
        file) in a single run. No sleeps/timing: the failure point is fixed in code."""
        legacy = self.repo / ".claude" / "rules" / "00-core.md"
        baseline = subprocess.run(["git", "show", "a09fbd2:.claude/rules/00-core.md"],
                                  cwd=REPO_ROOT, capture_output=True)
        if baseline.returncode != 0:
            self.skipTest("v1.0 template baseline for the legacy fixture not available "
                          "in this checkout")
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.write_bytes(baseline.stdout)
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit",
                        "-qm", "plant a retirable legacy baseline"], cwd=self.repo,
                       check=True, capture_output=True)

        before = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                                capture_output=True, text=True).stdout
        p = self.update("--adopt", "--retire-legacy",
                        env={"AF_UPDATE_TEST_FORCE_FAILURE": "1"})
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("injected failure", p.stdout + p.stderr)
        after = subprocess.run(["git", "status", "--porcelain"], cwd=self.repo,
                               capture_output=True, text=True).stdout
        self.assertEqual(before, after, "a forced mid-apply failure left the tree modified")
        self.assertTrue(legacy.exists(), "the retired legacy file was not restored on rollback")


class TestPayloadCarriesNoPlaceholderToken(unittest.TestCase):
    """v1.1.4 regression: a payload file must not contain the initialization placeholder
    token, not even inside a comment or a test message discussing it.

    scripts/validate-repository.sh greps the whole tree for the token and fails when
    `.project-initialized` exists — which is true of every adopted repository and false
    of this template, so the template's own CI stayed green while every adopter went red.
    That asymmetry is why this has to be asserted here rather than left to CI.
    """

    def _payload_dirs(self):
        sys.path.insert(0, str(SCRIPTS))
        import importlib.util
        spec = importlib.util.spec_from_file_location("_upd", UPDATER)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.PAYLOAD

    # Mirrors the two --exclude flags in scripts/validate-repository.sh:8-11. Those files
    # are the placeholder mechanism itself, so they are allowed to name the token; keep
    # this list in step with that grep or the test drifts from what actually gates CI.
    SCANNER_EXEMPT = {"initialize-project.sh", "validate-repository.sh"}

    def test_no_payload_file_contains_placeholder(self):
        offenders = []
        for entry in self._payload_dirs():
            root = REPO_ROOT / entry
            paths = [root] if root.is_file() else [
                p for p in root.rglob("*")
                if p.is_file() and "__pycache__" not in p.parts
            ]
            for p in paths:
                if p.name in self.SCANNER_EXEMPT:
                    continue
                try:
                    text = p.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue  # binary payload content (brand assets) cannot carry the token
                if PLACEHOLDER_PREFIX in text:
                    offenders.append(str(p.relative_to(REPO_ROOT)))
        self.assertEqual(
            offenders, [],
            "these payload files contain the initialization placeholder token and will "
            "make validate-repository.sh fail in every adopting repository: "
            + ", ".join(offenders)
            + " — refer to it as PLACEHOLDER_PREFIX or in prose, never as a literal.",
        )


class TestPlaceholderScanIsContextAware(unittest.TestCase):
    """The placeholder scan closed two holes on 2026-07-30.

    Hole 1 — coverage. TestPayloadCarriesNoPlaceholderToken above only walks PAYLOAD
    entries. But a repository created FROM this template inherits the whole template tree,
    including files that are not payload, and `initialize-project.sh` writes
    `.project-initialized` — which arms the scan. `CHANGELOG.md` carried the literal token
    in prose from 2745e09 (the v1.1.4 tag commit itself) until 2026-07-30: `3358bec` fixed
    the payload files and missed this one precisely because it is not payload. Every NEW
    repo made from the template would have failed `validate-repository.sh` on day one.

    Hole 2 — context. The scan matched raw bytes, so a file could not discuss the tokens
    at all. Files that must now opt out explicitly, per-file and greppably.
    """

    SCANNER = REPO_ROOT / "scripts" / "validate-repository.sh"
    OPT_OUT = "placeholder-scan: ignore-file"
    # Same two --exclude flags the scanner applies to itself.
    EXEMPT = {"initialize-project.sh", "validate-repository.sh"}

    # initialize-project.sh substitutes exactly these four full tokens. An occurrence of
    # the bare prefix that is NOT one of them survives initialization and then trips the
    # scan forever — which is exactly how CHANGELOG.md's bare-prefix prose broke things
    # while PROJECT.md's `..._NAME__` was always fine, because the latter gets replaced.
    SUBSTITUTED_SUFFIXES = ("NAME__", "SLUG__", "DESCRIPTION__", "OWNER__")

    def _unsubstitutable_hits(self, text: str) -> list[str]:
        hits, i = [], 0
        while True:
            i = text.find(PLACEHOLDER_PREFIX, i)
            if i < 0:
                return hits
            rest = text[i + len(PLACEHOLDER_PREFIX):]
            if not rest.startswith(self.SUBSTITUTED_SUFFIXES):
                hits.append(text[max(0, i - 25):i + 30].replace("\n", " "))
            i += len(PLACEHOLDER_PREFIX)

    def test_no_template_inherited_file_would_break_a_new_repo(self):
        """Walks the files a new repo INHERITS, not just PAYLOAD (hole 1).

        Flags only occurrences the initializer cannot substitute; the four real tokens in
        PROJECT.md / README.md / project.yaml / CLAUDE.md are the mechanism working.
        """
        skip_dirs = {".git", "__pycache__", "node_modules", ".idea", "runs"}
        offenders = []
        for p in REPO_ROOT.rglob("*"):
            if not p.is_file() or skip_dirs & set(p.parts):
                continue
            if p.name in self.EXEMPT:
                continue
            # Transient `--adopt` backups are not files a new repo inherits: they are
            # gitignored, never committed, and check-drift.py already skips the suffix.
            # Scanning them made the framework fail its own gate — adopting a repo whose
            # previous validate-repository.sh contained the token (it greps for it) wrote
            # a backup that this test then flagged, so the update rolled back. See
            # BACKUP_SUFFIX below for the regression that pins it.
            if p.name.endswith(BACKUP_SUFFIX):
                continue
            try:
                text = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if self.OPT_OUT in text:
                continue
            for ctx in self._unsubstitutable_hits(text):
                offenders.append(f"{p.relative_to(REPO_ROOT)}: …{ctx}…")
        self.assertEqual(
            offenders, [],
            "these template files mention the placeholder prefix in a form the "
            "initializer cannot substitute, so validate-repository.sh will fail in any "
            "repository created from this template once initialized:\n  "
            + "\n  ".join(offenders)
            + f"\nEither rephrase, or add the marker '{self.OPT_OUT}' to the file.")

    def test_the_detector_itself_can_fail(self):
        """Prove the check above can go red — a scan whose pass condition is 'no output'
        otherwise fails open (retrospective rule: every gate gets one deliberate
        violation)."""
        bad = "changelog: emits no " + PLACEHOLDER_PREFIX + " placeholders\n"
        self.assertTrue(self._unsubstitutable_hits(bad),
                        "a bare-prefix prose mention must be detected")
        good = "# " + PLACEHOLDER_PREFIX + "NAME__\n"
        self.assertFalse(self._unsubstitutable_hits(good),
                         "a substitutable token must NOT be flagged")

    def test_the_scanner_offers_a_per_file_opt_out_not_a_directory_exclusion(self):
        """A directory-wide exclusion would hide a real unresolved placeholder in docs/."""
        text = self.SCANNER.read_text(encoding="utf-8")
        self.assertIn(self.OPT_OUT, text, "the opt-out marker must be implemented")
        self.assertNotRegex(text, r"--exclude-dir=docs",
                            "docs/ must not be excluded wholesale from the scan")

    def test_scanner_does_not_contain_the_literal_it_hunts(self):
        """Assembled at runtime, so the scanner is not its own worst offender."""
        text = self.SCANNER.read_text(encoding="utf-8")
        self.assertNotIn(PLACEHOLDER_PREFIX + "NAME__", text)

    def _scan(self, tmp: Path, files: dict, initialized=True):
        """Run the real scanner in an adopter-shaped fixture and return its exit code.

        Deliberately captures the exit code directly. Piping this check through grep is
        how an earlier adopter-fatal failure stayed hidden.
        """
        repo = tmp / "repo"
        (repo / "scripts").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.SCANNER, repo / "scripts" / "validate-repository.sh")
        # Required-file list from the scanner; content is irrelevant to this check.
        for rel in ("README.md", "PROJECT.md", "AGENTS.md", "CLAUDE.md", "SECURITY.md",
                    "docs/product/product-vision.md", "docs/architecture/overview.md",
                    "docs/security/threat-model.md", "docs/testing/test-strategy.md",
                    ".claude/settings.json"):
            p = repo / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("placeholder-free\n", encoding="utf-8")
        if initialized:
            (repo / ".project-initialized").write_text("Fixture\n", encoding="utf-8")
        for rel, content in files.items():
            p = repo / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
        # No agent-framework/ in the fixture, so the framework gates are skipped and the
        # exit code reflects the placeholder scan alone.
        return subprocess.run(["bash", "./scripts/validate-repository.sh"], cwd=repo,
                              capture_output=True, text=True, timeout=60)

    def test_behaviour_mention_fails_optout_passes_and_real_placeholder_still_fails(self):
        token = PLACEHOLDER_PREFIX + "NAME__"
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)

            clean = self._scan(td / "a", {"docs/notes.md": "nothing to see\n"})
            self.assertEqual(clean.returncode, 0,
                             f"clean adopter must pass: {clean.stdout}{clean.stderr}")

            mention = self._scan(td / "b", {"docs/notes.md": f"initializer swaps {token}\n"})
            self.assertEqual(mention.returncode, 1,
                             "an un-opted-out mention must still fail (no silent pass)")
            self.assertIn("Unresolved placeholders", mention.stdout)

            opted = self._scan(td / "c", {
                "docs/notes.md": f"<!-- {self.OPT_OUT} -->\ninitializer swaps {token}\n"})
            self.assertEqual(opted.returncode, 0,
                             f"opt-out must pass: {opted.stdout}{opted.stderr}")

            # NEGATIVE CONTROL: the opt-out must not become a blanket amnesty.
            real = self._scan(td / "d", {"PROJECT.md": f"# {token}\n"})
            self.assertEqual(real.returncode, 1,
                             "a genuinely unresolved placeholder must still fail")
            self.assertIn("PROJECT.md", real.stdout)

    def test_adoption_backups_are_skipped_but_their_live_counterparts_are_not(self):
        """`--adopt` writes <name>.bak-pre-framework beside every file it takes over.

        Adopting a repository whose previous validate-repository.sh contained the token —
        which it does, because it greps for it — produced a backup that this very scan
        then flagged. The update failed its own gate and rolled back. Hit two repositories
        during the v1.2.1 migration; check-drift.py had always skipped the suffix, the
        placeholder scan had not.

        The negative control matters more than the positive one: skipping the suffix must
        not become a way to smuggle an unresolved placeholder past the gate.
        """
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            body = f"grep -RIl '{PLACEHOLDER_PREFIX}' .\n"

            backup = self._scan(td / "a", {f"scripts/old-scanner.sh{BACKUP_SUFFIX}": body})
            self.assertEqual(
                backup.returncode, 0,
                "an adoption backup must not fail the scan that the adoption is running: "
                f"{backup.stdout}{backup.stderr}")

            # NEGATIVE CONTROL: identical content in a live file must still fail.
            live = self._scan(td / "b", {"scripts/old-scanner.sh": body})
            self.assertEqual(live.returncode, 1,
                             "the same content in a non-backup file must still fail")
            self.assertIn("old-scanner.sh", live.stdout)

    def test_scanner_excludes_the_backup_suffix(self):
        """Pins the exclusion in the shipped scanner, not just its observable behaviour."""
        self.assertIn(f"--exclude='*{BACKUP_SUFFIX}'", self.SCANNER.read_text(encoding="utf-8"))

    def test_uninitialized_template_still_skips_the_scan(self):
        token = PLACEHOLDER_PREFIX + "NAME__"
        with tempfile.TemporaryDirectory() as td:
            r = self._scan(Path(td) / "t", {"PROJECT.md": f"# {token}\n"},
                           initialized=False)
            self.assertEqual(r.returncode, 0,
                             "an uninitialized template legitimately carries placeholders")
            self.assertIn("not yet initialized", r.stdout)


@unittest.skipUnless(SOURCE_MARKER.exists(),
                     "template-only invariant: scripts/initialize-project.sh and the "
                     "source marker are template-side files, neither of which is payload")
class TestInitializerClearsInheritedSourceMarker(unittest.TestCase):
    """A repository created FROM the template must not inherit the source marker.

    Template-only, and the guard above is load-bearing rather than tidiness — it was
    added after this class turned an adopter red. The payload ships this suite into every
    adopting repository and the updater's own verify() runs `unittest discover` there;
    `scripts/initialize-project.sh` and `agent-framework/.framework-source` are both
    template-side and absent there, so the fixture raised FileNotFoundError and rolled the
    whole adoption back. Green here, fatal in a real repository: the same asymmetry that
    made v1.1.4 expensive.

    `agent-framework/.framework-source` is tracked in the template, so every repository
    made from it — GitHub "Use this template", a fork, or a plain clone — starts life
    carrying it. update-framework.py refuses any target that has the marker, and says the
    target *IS* the framework source. In a product repository that message is wrong and
    the consequence is permanent: no framework update can ever run there again.

    The marker's own text already states the rule ("Adopting/updating repositories must
    NOT contain this file"), and the payload correctly never ships it — but the payload
    only governs repositories the updater already reached. Nothing enforced the rule on
    the copy path, which is how downstream repositories are actually created.

    Observed: skyphoenix-linkhub-manager was locked out from creation until the marker was
    deleted by hand on 2026-07-24; its agent-framework/README.md records the incident.
    """

    INITIALIZER = REPO_ROOT / "scripts" / "initialize-project.sh"
    MARKER_REL = "agent-framework/.framework-source"

    def _template_copy(self, dst: Path) -> Path:
        """A repository as it exists immediately after copying the template."""
        (dst / "scripts").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.INITIALIZER, dst / "scripts" / "initialize-project.sh")
        marker = dst / self.MARKER_REL
        marker.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE_MARKER, marker)
        (dst / "README.md").write_text(
            f"# {PLACEHOLDER_PREFIX}NAME__\n\n{PLACEHOLDER_PREFIX}DESCRIPTION__\n",
            encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=dst, check=True)
        subprocess.run(["git", "add", "-A"], cwd=dst, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-qm", "copied from template"], cwd=dst, check=True,
                       capture_output=True)
        return dst

    def _init(self, repo: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", "./scripts/initialize-project.sh", "Repro Product", "repro-product",
             "A repro product", "SKYPhoenix IT GmbH"],
            cwd=repo, capture_output=True, text=True, timeout=120)

    def test_initializer_removes_the_inherited_marker(self):
        with tempfile.TemporaryDirectory() as td:
            repo = self._template_copy(Path(td) / "repo")
            r = self._init(repo)
            self.assertEqual(r.returncode, 0, f"{r.stdout}{r.stderr}")
            self.assertFalse((repo / self.MARKER_REL).exists(),
                             "an initialized product repository must not carry the "
                             "framework source marker — it locks the repository out of "
                             "every future framework update")

    def test_initializer_also_untracks_the_marker(self):
        """Removing it from disk only is not enough: the next clone brings it back."""
        with tempfile.TemporaryDirectory() as td:
            repo = self._template_copy(Path(td) / "repo")
            self.assertEqual(self._init(repo).returncode, 0)
            tracked = subprocess.run(["git", "ls-files", self.MARKER_REL], cwd=repo,
                                     capture_output=True, text=True, check=True)
            self.assertEqual(tracked.stdout.strip(), "",
                             "the marker must be staged for deletion, not merely unlinked")

    def test_updater_is_locked_out_while_the_marker_is_present(self):
        """The control: proves the marker is what causes the refusal, so the fix matters.

        Without this, a green test above could mean the marker was simply never read.
        """
        with tempfile.TemporaryDirectory() as td:
            repo = self._template_copy(Path(td) / "repo")
            r = run([sys.executable, str(UPDATER), "--from", str(REPO_ROOT),
                     "--target", str(repo), "--no-verify", "--dry-run"],
                    cwd=repo, timeout=300)
            self.assertNotEqual(r.returncode, 0,
                                "a target carrying the marker must be refused")
            self.assertIn("IS the framework source", r.stdout + r.stderr)


class TestProjectOwnedValidationHook(unittest.TestCase):
    """Adopters must have a place for their own gates that an update cannot overwrite.

    `scripts/validate-repository.sh` is a PAYLOAD file, and it is also the obvious place
    to add repository-specific checks — so adopters put them there. Adoption then takes
    the file over, and the only surviving copy is `<name>.bak-pre-framework`, which
    `.gitignore` excludes. The checks leave the repository without appearing as deleted
    content in the adoption diff.

    Measured on skyphoenix-mobile-device-cloud before its migration: its
    validate-repository.sh carried 13 project gates, including a scan for tracked Apple
    signing credentials (*.p8/*.p12/*.pfx/*.mobileprovision) — a security control — and
    its .github/workflows/ci.yml invokes that script directly as the repository's gate.

    ADR 0002: the framework-owned scanner delegates to `scripts/validate-project.sh` when
    the adopter provides one. Absent by design in the template, so it is never a payload
    file and an update can never clobber it.
    """

    SCANNER = REPO_ROOT / "scripts" / "validate-repository.sh"
    REQUIRED = ("README.md", "PROJECT.md", "AGENTS.md", "CLAUDE.md", "SECURITY.md",
                "docs/product/product-vision.md", "docs/architecture/overview.md",
                "docs/security/threat-model.md", "docs/testing/test-strategy.md",
                ".claude/settings.json")

    def _run(self, tmp: Path, hook: str | None) -> subprocess.CompletedProcess:
        repo = tmp / "repo"
        (repo / "scripts").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.SCANNER, repo / "scripts" / "validate-repository.sh")
        for rel in self.REQUIRED:
            p = repo / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("placeholder-free\n", encoding="utf-8")
        (repo / ".project-initialized").write_text("Fixture\n", encoding="utf-8")
        if hook is not None:
            h = repo / "scripts" / "validate-project.sh"
            h.write_text(hook, encoding="utf-8")
            h.chmod(0o755)
        # No agent-framework/ here, so validate.py/check-drift.py are skipped and the
        # exit code reflects the hook alone.
        return subprocess.run(["bash", "./scripts/validate-repository.sh"], cwd=repo,
                              capture_output=True, text=True, timeout=60)

    def test_failing_project_gate_fails_the_repository_gate(self):
        with tempfile.TemporaryDirectory() as td:
            r = self._run(Path(td), "#!/usr/bin/env bash\necho 'project gate says no'\nexit 1\n")
            self.assertEqual(r.returncode, 1,
                             f"a failing project gate must fail validation: {r.stdout}{r.stderr}")
            self.assertIn("project gate says no", r.stdout + r.stderr,
                          "the project gate's own output must reach the log")

    def test_passing_project_gate_keeps_the_repository_green(self):
        with tempfile.TemporaryDirectory() as td:
            r = self._run(Path(td), "#!/usr/bin/env bash\necho 'project gate ok'\nexit 0\n")
            self.assertEqual(r.returncode, 0, f"{r.stdout}{r.stderr}")
            self.assertIn("project gate ok", r.stdout)

    def test_absent_hook_changes_nothing(self):
        """Back-compat: every existing adopter has no such file and must stay green."""
        with tempfile.TemporaryDirectory() as td:
            r = self._run(Path(td), None)
            self.assertEqual(r.returncode, 0, f"{r.stdout}{r.stderr}")

    @unittest.skipUnless(SOURCE_MARKER.exists(),
                         "template-only invariant: an adopting repository is SUPPOSED to "
                         "have this file — that is the entire point of the hook")
    def test_hook_is_not_shipped_by_the_template(self):
        """It must stay adopter-owned: shipping it would make it a payload file again.

        Template-only. Unguarded this asserts the absence of a file that every adopter
        with project gates legitimately has — it would have failed in
        skyphoenix-mobile-device-cloud, the repository the hook exists for.
        """
        self.assertFalse((REPO_ROOT / "scripts" / "validate-project.sh").exists(),
                         "the template must not ship scripts/validate-project.sh")


if __name__ == "__main__":
    unittest.main()
