"""Validator mutation regressions (CXR-013/KF-H12, CXR-017/KF-M25, KF-M20, KF-L01,
KF-L45): weakening a pinned permission, corrupting a catalog, or breaking a
cross-reference must fail validation. Runs in scratch copies only.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import copy_repo, scratch_dir, validate  # noqa: E402


class ValidateMutationBase(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch_dir()
        self.repo = copy_repo(self.tmp / "repo")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def assert_fails(self, needle: str):
        v = validate(self.repo)
        self.assertEqual(v.returncode, 1, v.stdout)
        self.assertIn(needle, v.stdout)


class TestPermissionPinning(ValidateMutationBase):
    def test_baseline_clean(self):
        v = validate(self.repo)
        self.assertEqual(v.returncode, 0, v.stdout)

    def test_removing_force_push_deny_fails(self):
        """CXR-013/KF-H12: weakening the Claude permission surface fails CI."""
        sp = self.repo / ".claude" / "settings.json"
        data = json.loads(sp.read_text())
        data["permissions"]["deny"] = [d for d in data["permissions"]["deny"]
                                       if "push --force" not in d]
        sp.write_text(json.dumps(data, indent=2))
        self.assert_fails("required deny rule missing")

    def test_removing_short_flag_spelling_fails(self):
        """KF-L01: both force-push spellings are pinned."""
        sp = self.repo / ".claude" / "settings.json"
        data = json.loads(sp.read_text())
        data["permissions"]["deny"] = [d for d in data["permissions"]["deny"]
                                       if "push -f" not in d]
        sp.write_text(json.dumps(data, indent=2))
        self.assert_fails("git push -f")

    def test_permissive_allow_rule_fails(self):
        sp = self.repo / ".claude" / "settings.json"
        data = json.loads(sp.read_text())
        data["permissions"]["allow"] = ["Bash(git push --force *)"]
        sp.write_text(json.dumps(data, indent=2))
        self.assert_fails("undermines a pinned protection")

    def test_weakening_opencode_bash_deny_fails(self):
        oc = self.repo / "opencode.json"
        data = json.loads(oc.read_text())
        data["permission"]["bash"]["git push --force*"] = "allow"
        oc.write_text(json.dumps(data, indent=2))
        self.assert_fails("required bash deny missing or weakened")

    def test_kimi_profile_wrong_schema_fails(self):
        """KF-H02 regression: the old undocumented `tool =` schema must fail."""
        readme = self.repo / ".kimi-code" / "README.md"
        text = readme.read_text().replace(
            'decision = "deny"\npattern = "Bash(git push --force*)"',
            'tool = "Bash"\ndecision = "deny"\npattern = "git push --force*"', 1)
        readme.write_text(text)
        v = validate(self.repo)
        self.assertEqual(v.returncode, 1)
        self.assertIn(".kimi-code/README.md", v.stdout)

    def test_missing_claude_md_reports_cleanly(self):
        """KF-L45: a missing adopter file is a diagnostic, not a traceback."""
        (self.repo / "CLAUDE.md").unlink()
        v = validate(self.repo)
        self.assertEqual(v.returncode, 1, v.stdout + v.stderr)
        self.assertNotIn("Traceback", v.stderr)


class TestCatalogIntegrity(ValidateMutationBase):
    def test_corrupt_persona_catalog_fails(self):
        """CXR-017/KF-M25."""
        (self.repo / "agent-framework" / "catalogs" / "persona-catalog.yaml").write_text("corrupt: true\n")
        self.assert_fails("persona-catalog.yaml")

    def test_corrupt_workflow_catalog_fails(self):
        (self.repo / "agent-framework" / "catalogs" / "workflow-catalog.yaml").write_text("corrupt: true\n")
        self.assert_fails("workflow-catalog.yaml")

    def test_workflow_with_unknown_role_fails(self):
        """KF-M20: the workflow->role cross-check must actually fire."""
        wf = self.repo / "agent-framework" / "canonical" / "workflows" / "deep-research" / "WORKFLOW.md"
        wf.write_text(wf.read_text().replace("- deep-researcher", "- nonexistent-role", 1))
        self.assert_fails("unknown roles")

    def test_catalog_field_divergence_fails(self):
        cat = self.repo / "agent-framework" / "catalogs" / "role-catalog.yaml"
        cat.write_text(cat.read_text().replace("read_only: true", "read_only: false", 1))
        self.assert_fails("diverges from")

    def test_upward_fallback_fails(self):
        """KF-L23: fallback must be same-or-lower tier."""
        role = self.repo / "agent-framework" / "canonical" / "roles" / "implementation-engineer.yaml"
        role.write_text(role.read_text().replace("fallback_model_class: economy",
                                                 "fallback_model_class: premium"))
        self.assert_fails("exceeds model_class")

    def test_stale_canonical_path_citation_fails(self):
        """KF-M01 regression: canonical must not cite provider paths or dead paths."""
        skill = self.repo / "agent-framework" / "canonical" / "skills" / "security-review" / "SKILL.md"
        skill.write_text(skill.read_text() + "\nSee `.claude/rules/10-security.md` for details.\n")
        self.assert_fails("provider-artifact path")


class TestCapabilityHonestyGuards(ValidateMutationBase):
    """H7 regression (KF-H08): the bash_readonly_enforcement matrix row and its
    waiver content are mechanically enforced — removal or false strengthening
    fails validation."""

    def _matrix(self) -> Path:
        return self.repo / "agent-framework" / "catalogs" / "provider-capability-matrix.yaml"

    def test_removing_bash_readonly_row_fails(self):
        m = self._matrix()
        m.write_text(m.read_text().replace("bash_readonly_enforcement:",
                                           "bash_readonly_enforcement_renamed:"))
        self.assert_fails("bash_readonly_enforcement row missing")

    def test_falsely_strengthening_kimi_waiver_fails(self):
        m = self._matrix()
        text = m.read_text()
        needle = 'kimi:      { status: unsupported, note: "Prose only;'
        self.assertIn(needle, text)
        m.write_text(text.replace(needle, 'kimi:      { status: supported, note: "Prose only;'))
        self.assert_fails("bash_readonly_enforcement.kimi claims 'supported'")

    def test_dropping_waiver_note_fails(self):
        m = self._matrix()
        text = m.read_text()
        needle = 'jetbrains: { status: unsupported, note: "Prose only (documented waiver)" }'
        self.assertIn(needle, text)
        m.write_text(text.replace(needle, 'jetbrains: { status: unsupported, note: "n/a" }'))
        self.assert_fails("must state its prose-only waiver")

    def test_model_tiering_false_claim_fails(self):
        m = self._matrix()
        text = m.read_text()
        needle = 'codex:     { status: unsupported, note: "No per-agent model mapping'
        self.assertIn(needle, text)
        m.write_text(text.replace(needle, 'codex:     { status: supported, note: "No per-agent model mapping'))
        self.assert_fails("model_tiering.codex claims 'supported'")


class TestDomainSkillDelegationGuard(ValidateMutationBase):
    """H9 regression (KF-H07): removing or rewording the research-delegation
    paragraph in a domain skill fails validation."""

    def test_removing_delegation_paragraph_fails(self):
        skill = self.repo / "agent-framework" / "canonical" / "skills" / "sap-s4hana" / "SKILL.md"
        text = skill.read_text()
        self.assertIn("deep-researcher task via the orchestrator", text)
        skill.write_text(text.replace("deep-researcher task via the orchestrator",
                                      "web search of your choice"))
        self.assert_fails("research-delegation guidance missing")


class TestSecretScanningCI(unittest.TestCase):
    """Verification finding 11 (CXR-021/KF-M30): the hosted secret-scanning job must
    be executable as configured. gitleaks-action@v2 is not (Node-24 runners); the
    job now runs a pinned, checksum-verified gitleaks binary directly. These tests
    pin the workflow shape and establish locally that the exact scanner invocation
    forms are executable. NO real secret fixture is used anywhere."""

    REPO = Path(__file__).resolve().parent.parent.parent
    WORKFLOW = REPO / ".github" / "workflows" / "quality.yml"

    def _secrets_run_steps(self) -> list[str]:
        import yaml
        wf = yaml.safe_load(self.WORKFLOW.read_text())
        job = wf["jobs"]["secrets"]
        return [s.get("run", "") for s in job["steps"]]

    def test_workflow_does_not_use_incompatible_action(self):
        import yaml
        wf = yaml.safe_load(self.WORKFLOW.read_text())
        uses = [s.get("uses", "") for job in wf["jobs"].values() for s in job["steps"]]
        self.assertFalse([u for u in uses if "gitleaks-action" in u],
                         "gitleaks-action@v2 is not executable on Node-24 hosted runners; "
                         "the job must run the pinned binary, not a JS-runtime action")

    def test_workflow_pins_scanner_and_verifies_checksum(self):
        runs = "\n".join(self._secrets_run_steps())
        self.assertIn("gitleaks_8.30.1_linux_x64.tar.gz", runs)
        self.assertIn("sha256sum -c", runs, "download must be checksum-verified")
        self.assertRegex(runs, r"[0-9a-f]{64}\s+gitleaks\.tar\.gz")

    def test_workflow_scans_history_and_tree_redacted_and_failing(self):
        runs = "\n".join(self._secrets_run_steps())
        self.assertIn("gitleaks git --redact --exit-code 1", runs)
        self.assertIn("gitleaks dir --redact --exit-code 1", runs)
        text = self.WORKFLOW.read_text()
        self.assertNotIn("--report-path", text, "no secret report may be written or uploaded")
        self.assertNotIn("upload-artifact", text, "no artifact upload in the secrets job")

    def _gitleaks(self) -> str:
        import shutil as _shutil
        exe = _shutil.which("gitleaks")
        if not exe:
            self.skipTest("gitleaks binary not installed on this machine — "
                          "invocation-executability check NOT RUN here (runs in CI)")
        return exe

    def test_scanner_invocation_forms_are_executable(self):
        """The exact subcommand/flag forms used by the CI job parse and run."""
        import subprocess, tempfile
        exe = self._gitleaks()
        with tempfile.TemporaryDirectory(prefix="af-gitleaks-") as td:
            clean = Path(td) / "clean"
            clean.mkdir()
            (clean / "README.md").write_text("no secrets here\n")
            p = subprocess.run([exe, "dir", "--redact", "--exit-code", "1", "--no-banner", str(clean)],
                               capture_output=True, text=True, timeout=120)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_finding_fails_job_without_real_secret_fixture(self):
        """Exit-code-on-finding behavior proven with a benign canary rule matching a
        harmless literal — deliberately NOT a real or realistic secret."""
        import subprocess, tempfile
        exe = self._gitleaks()
        with tempfile.TemporaryDirectory(prefix="af-gitleaks-") as td:
            cfg = Path(td) / "canary.toml"
            cfg.write_text('[[rules]]\nid = "af-ci-canary"\n'
                           'description = "benign canary for exit-code regression (not a secret)"\n'
                           "regex = '''AF-CI-CANARY-[A-Z-]+'''\n")
            scan = Path(td) / "scan"
            scan.mkdir()
            (scan / "sample.txt").write_text('note = "AF-CI-CANARY-EXIT-CODE-CHECK"\n')
            p = subprocess.run([exe, "dir", "--redact", "--exit-code", "1",
                                "--config", str(cfg), "--no-banner", str(scan)],
                               capture_output=True, text=True, timeout=120)
            self.assertEqual(p.returncode, 1, "a finding must fail the job")
            self.assertNotIn("AF-CI-CANARY-EXIT-CODE-CHECK", p.stdout + p.stderr,
                             "matched values must stay redacted in scanner output")


class TestDependencyVulnerabilityScanningCI(unittest.TestCase):
    """BACKLOG Now (approved 2026-07-19): closes the "known-vulnerability check" gap in
    agent-framework/canonical/skills/security-review/SKILL.md (line 35 / checklist line
    47), which had no CI tooling to run and was therefore always NOT RUN. The
    `dependencies` job runs a pinned, checksum-verified osv-scanner binary — the same
    shape as the gitleaks job above — gated on manifest detection so a stack that has no
    Python/Node dependencies at all stays green and needs no network beyond checkout.
    These tests pin the workflow shape and, separately, prove the exact embedded
    severity-filter script gates correctly against a synthetic (non-network) fixture
    shaped like real osv-scanner JSON output."""

    REPO = Path(__file__).resolve().parent.parent.parent
    WORKFLOW = REPO / ".github" / "workflows" / "quality.yml"

    def _workflow(self) -> dict:
        import yaml
        return yaml.safe_load(self.WORKFLOW.read_text())

    def _job(self) -> dict:
        return self._workflow()["jobs"]["dependencies"]

    def _step(self, name_prefix: str) -> dict:
        return next(s for s in self._job()["steps"]
                    if str(s.get("name", "")).startswith(name_prefix))

    def test_workflow_pins_scanner_and_verifies_checksum(self):
        install = self._step("Install pinned osv-scanner")
        self.assertIn("osv-scanner_linux_amd64", install["run"])
        self.assertIn("v2.4.0", install["run"], "release version must be pinned, not floating")
        self.assertIn("sha256sum -c", install["run"], "download must be checksum-verified")
        self.assertRegex(install["run"], r"[0-9a-f]{64}\s+osv-scanner")

    def test_scan_step_fails_closed_when_the_scanner_itself_fails(self):
        """A security gate must not read "scanner broke" as "nothing found".

        osv-scanner exits 1 on findings and other non-zero codes on real errors. A bare
        `|| true` collapses both into success, so a scanner that never ran could emit a
        results-free JSON that the filter step reports as clean."""
        scan = self._step("Scan dependency manifests")
        self.assertNotRegex(
            scan["run"], r"osv-scanner[^\n]*\|\|\s*true",
            "bare `|| true` on the scan masks scanner errors as a clean result")
        self.assertIn("rc=$?", scan["run"], "scanner exit code must be captured")
        self.assertRegex(scan["run"], r'"\$rc"\s*-ne\s*0.*\n?.*"\$rc"\s*-ne\s*1',
                         "must distinguish findings (1) from execution failure (other)")
        self.assertIn("json.load", scan["run"],
                      "unparseable scanner output must fail closed, not read as empty")

    def test_scan_and_filter_steps_are_conditional_on_manifest_detection(self):
        """A repo with no requirements.txt/package-lock.json (etc.) must stay green and
        must not need network access beyond the mandatory checkout."""
        job = self._job()
        detect = next(s for s in job["steps"] if s.get("id") == "detect")
        self.assertIsNotNone(detect)
        for prefix in ("Install pinned osv-scanner", "Scan dependency manifests",
                       "Fail on HIGH/CRITICAL"):
            step = self._step(prefix)
            self.assertEqual(step.get("if"), "steps.detect.outputs.found == 'true'",
                             f"{prefix!r} step must be gated on manifest detection")

    def test_detection_step_recognizes_common_python_and_node_manifests(self):
        detect = next(s for s in self._job()["steps"] if s.get("id") == "detect")
        for pattern in ("requirements*.txt", "Pipfile.lock", "poetry.lock", "uv.lock",
                        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
                        "pnpm-lock.yaml"):
            self.assertIn(pattern, detect["run"])

    def test_job_does_not_widen_permissions(self):
        """Least privilege: the job relies on the workflow-level `contents: read` and
        does not declare a broader permissions block of its own."""
        wf = self._workflow()
        self.assertEqual(wf["permissions"], {"contents": "read"})
        self.assertNotIn("permissions", self._job())

    def test_filter_script_fails_only_on_high_or_critical(self):
        """Runs the exact embedded severity-filter script (extracted verbatim from
        quality.yml) against a synthetic osv-scanner JSON fixture shaped like real
        output. No network call and no real CVE data are used here; the fixture below
        is invented for this test only."""
        script = self._step("Fail on HIGH/CRITICAL")["run"]

        def make_fixture(max_severity: str, database_specific_severity: str | None = None):
            vuln = {
                "id": "TEST-0001",
                "details": "Synthetic advisory used only by this regression test.",
                "aliases": ["TEST-ALIAS-0001"],
            }
            if database_specific_severity is not None:
                vuln["database_specific"] = {"severity": database_specific_severity}
            return {
                "results": [{
                    "source": {"path": "requirements.txt"},
                    "packages": [{
                        "package": {"name": "demo-pkg", "version": "1.0.0", "ecosystem": "PyPI"},
                        "groups": [{
                            "ids": ["TEST-0001"],
                            "aliases": ["TEST-ALIAS-0001"],
                            "max_severity": max_severity,
                        }],
                        "vulnerabilities": [vuln],
                    }],
                }],
            }

        cases = [
            ("critical (CVSS 9.8)", make_fixture("9.8"), 1, True),
            ("high (CVSS 7.0 boundary)", make_fixture("7.0"), 1, True),
            ("medium (CVSS 5.3, below threshold)", make_fixture("5.3"), 0, False),
            ("no CVSS but database_specific HIGH", make_fixture("", "HIGH"), 1, True),
            ("no severity data at all", make_fixture(""), 0, False),
        ]
        for label, fixture, expect_rc, expect_advisory_text in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory(prefix="af-osv-filter-") as td:
                    tdp = Path(td)
                    (tdp / "osv-scan.json").write_text(json.dumps(fixture))
                    (tdp / "run.sh").write_text(script)
                    p = subprocess.run(["bash", "run.sh"], cwd=tdp,
                                       capture_output=True, text=True, timeout=30)
                    self.assertEqual(p.returncode, expect_rc,
                                     f"{label}: stdout={p.stdout} stderr={p.stderr}")
                    if expect_advisory_text:
                        self.assertIn("Synthetic advisory used only by this regression test.",
                                      p.stdout,
                                      "step must print the actual advisory text, not a summary")
                        self.assertIn("demo-pkg@1.0.0", p.stdout)

    def _osv_scanner(self) -> str:
        exe = shutil.which("osv-scanner")
        if not exe:
            self.skipTest("osv-scanner binary not installed on this machine — "
                          "invocation-executability check NOT RUN here (runs in CI)")
        return exe

    def test_scan_invocation_form_is_executable(self):
        """The exact subcommand/flag form used by the CI job parses and runs. An empty
        requirements.txt (a manifest with zero packages) exercises the invocation
        without requiring a real, network-resolvable package name — a pinned package
        would need deps.dev resolution over the network, which this offline-friendly
        unit test does not depend on."""
        exe = self._osv_scanner()
        with tempfile.TemporaryDirectory(prefix="af-osv-scan-") as td:
            tdp = Path(td)
            (tdp / "requirements.txt").write_text("")
            p = subprocess.run([exe, "scan", "source", "--recursive", "--allow-no-lockfiles",
                                "--format", "json", "."],
                               cwd=tdp, capture_output=True, text=True, timeout=60)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
