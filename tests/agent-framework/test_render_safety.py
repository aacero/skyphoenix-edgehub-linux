"""Renderer filesystem-safety regressions (CXR-010/011/012/014/015, KF-H09/H10/H11,
KF-M17/M18/M19, IX-001/IX-002).

All tests run in a scratch copy of the repository; nothing touches the real tree.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import check_drift, copy_repo, render, scratch_dir  # noqa: E402


class RenderSafetyBase(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch_dir()
        self.repo = copy_repo(self.tmp / "repo")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class TestSymlinkSafety(RenderSafetyBase):
    def test_symlinked_output_refused_and_victim_untouched(self):
        """CXR-010/KF-H10: a symlinked generated target must refuse the render."""
        victim = self.tmp / "victim.toml"
        victim.write_text("PRETEST-VICTIM\n")
        target = self.repo / ".codex" / "config.toml"
        target.unlink()
        target.symlink_to(victim)
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        # refused either by the symlink check (in-repo target) or the containment
        # check (resolve() follows the link outside the repo) — both are safe
        msg = (r.stderr + r.stdout).lower()
        self.assertTrue("symlink" in msg or "escapes the repository root" in msg, msg)
        self.assertEqual(victim.read_text(), "PRETEST-VICTIM\n")

    def test_symlinked_parent_dir_refused(self):
        """IX-002 vector: a managed directory that is itself a symlink to an external
        location must refuse the render (no external writes or deletions)."""
        external = self.tmp / "external-agents"
        external.mkdir()
        (external / "keepme.md").write_text("external file\n")
        agents = self.repo / ".claude" / "agents"
        shutil.rmtree(agents)
        agents.symlink_to(external)
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        msg = (r.stderr + r.stdout).lower()
        self.assertTrue("symlink" in msg or "escapes the repository root" in msg, msg)
        self.assertEqual((external / "keepme.md").read_text(), "external file\n")
        self.assertEqual(sorted(p.name for p in external.iterdir()), ["keepme.md"])

    def test_traversal_role_id_refused(self):
        """IX-001: unsafe role ids must be rejected before any path is constructed."""
        evil = self.repo / "agent-framework" / "canonical" / "roles" / "zz-evil.yaml"
        evil.write_text('id: "../../escape"\ntitle: x\n')
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unsafe", (r.stderr + r.stdout).lower())
        self.assertFalse((self.tmp / "escape.md").exists())


class TestPreservation(RenderSafetyBase):
    def test_project_local_file_with_generated_words_survives(self):
        """CXR-012/KF-H11: content heuristics must never drive deletion."""
        local = self.repo / ".claude" / "agents" / "project-local.md"
        local.write_text("# Project-owned agent\n\nThis file mentions GENERATED and "
                         "render.py in ordinary documentation text.\n")
        r = render(self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(local.exists())
        self.assertIn("GENERATED and", local.read_text())

    def test_collision_refused_then_adopted_with_backup(self):
        """CXR-014/KF-H09: pre-existing non-generated files are never silently
        overwritten; --adopt backs them up first."""
        # simulate an adopting repo: no prior manifest, hand-written codex config
        (self.repo / "agent-framework" / "generated-manifest.json").unlink()
        cfg = self.repo / ".codex" / "config.toml"
        cfg.write_text('# my hand-written codex config\nmodel = "my-model"\n')
        r = render(self.repo)
        self.assertEqual(r.returncode, 2)
        self.assertIn(".codex/config.toml", r.stderr)
        self.assertIn("my hand-written codex config", cfg.read_text())
        r2 = render(self.repo, "--adopt")
        self.assertEqual(r2.returncode, 0, r2.stderr)
        backup = self.repo / ".codex" / "config.toml.bak-pre-framework"
        self.assertTrue(backup.exists())
        self.assertIn("my hand-written codex config", backup.read_text())
        self.assertIn("GENERATED", cfg.read_text())

    def test_manifest_membership_alone_does_not_prove_ownership(self):
        """Collision-gate bypass regression: a manifest that merely LISTS a path is
        not proof of framework ownership — the file on disk must still match the
        recorded hash. A manifest copied into an adopting repo (or any stale entry)
        must not let the next render silently overwrite hand-written content. So
        hand-written bytes at a manifest-listed path are refused (exit 2) and backed
        up under --adopt, exactly like the manifest-absent case above."""
        manifest = self.repo / "agent-framework" / "generated-manifest.json"
        self.assertIn(".codex/config.toml", json.loads(manifest.read_text())["files"])
        cfg = self.repo / ".codex" / "config.toml"
        cfg.write_text('# my hand-written codex config\nmodel = "my-model"\n')
        r = render(self.repo)  # manifest is PRESENT and lists the path
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn(".codex/config.toml", r.stderr)
        self.assertIn("my hand-written codex config", cfg.read_text())
        r2 = render(self.repo, "--adopt")
        self.assertEqual(r2.returncode, 0, r2.stderr)
        backup = self.repo / ".codex" / "config.toml.bak-pre-framework"
        self.assertTrue(backup.exists())
        self.assertIn("my hand-written codex config", backup.read_text())
        self.assertIn("GENERATED", cfg.read_text())

    def test_opencode_project_keys_survive_render_and_drift(self):
        """CXR-014/KF-H09 + the CI trap: the documented local-LLM provider block must
        survive re-render, and check-drift must stay green with it present."""
        oc = self.repo / "opencode.json"
        data = json.loads(oc.read_text())
        data["provider"] = {"local-review-sentinel": {"npm": "@ai-sdk/openai-compatible",
                                                      "options": {"baseURL": "http://localhost:11434/v1"}}}
        data["model"] = "local-review-sentinel/qwen3"
        oc.write_text(json.dumps(data, indent=2) + "\n")
        r = render(self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        after = json.loads(oc.read_text())
        self.assertIn("local-review-sentinel", after.get("provider", {}))
        self.assertEqual(after.get("model"), "local-review-sentinel/qwen3")
        self.assertEqual(after["permission"]["bash"]["git push --force*"], "deny")
        d = check_drift(self.repo)
        self.assertEqual(d.returncode, 0, d.stdout + d.stderr)


class TestStaleCleanup(RenderSafetyBase):
    def _select_domain_skill(self, name: str = "sap-s4hana"):
        (self.repo / "project.yaml").write_text(
            f"agent_framework:\n  skills:\n    - {name}\n")

    def test_deselected_skill_fully_removed_including_references(self):
        """KF-M18/CXR-015: stale cleanup is manifest-diff based and covers every
        generated file, including markerless references/SOURCES.md."""
        self._select_domain_skill()
        self.assertEqual(render(self.repo).returncode, 0)
        src = self.repo / ".agents" / "skills" / "sap-s4hana" / "references" / "SOURCES.md"
        self.assertTrue(src.exists())
        (self.repo / "project.yaml").unlink()
        self.assertEqual(render(self.repo).returncode, 0)
        for root in (".agents/skills/sap-s4hana", ".claude/skills/sap-s4hana"):
            self.assertFalse((self.repo / root).exists(), root)

    def test_modified_stale_file_not_deleted(self):
        """Stale deletion requires an exact provenance hash match — a hand-modified
        formerly-generated file is preserved with a warning."""
        self._select_domain_skill()
        self.assertEqual(render(self.repo).returncode, 0)
        f = self.repo / ".agents" / "skills" / "sap-s4hana" / "SKILL.md"
        f.write_text(f.read_text() + "\nlocal adaptation\n")
        (self.repo / "project.yaml").unlink()
        r = render(self.repo)
        self.assertEqual(r.returncode, 0)
        self.assertTrue(f.exists())
        self.assertIn("not deleting", r.stderr)


class TestRecoverability(RenderSafetyBase):
    def test_failed_commit_is_detectable_and_rerender_recovers(self):
        """CXR-011/KF-M19: a mid-commit failure leaves the manifest untouched (drift
        detectable) and a plain re-render restores a fully consistent state."""
        manifest_before = (self.repo / "agent-framework" / "generated-manifest.json").read_text()
        # sabotage one later target: a directory cannot be atomically replaced
        target = self.repo / ".kimi-code" / "agents" / "orchestrator.md"
        target.unlink()
        target.mkdir()
        (target / "x").write_text("occupied")
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        manifest_after = (self.repo / "agent-framework" / "generated-manifest.json").read_text()
        self.assertEqual(manifest_before, manifest_after, "manifest must be written last")
        # recovery: remove the obstruction, re-render, everything green
        shutil.rmtree(target)
        self.assertEqual(render(self.repo).returncode, 0)
        d = check_drift(self.repo)
        self.assertEqual(d.returncode, 0, d.stdout)

    def test_no_orphan_temp_files_after_success(self):
        self.assertEqual(render(self.repo).returncode, 0)
        leftovers = [str(p) for p in self.repo.rglob("*.tmp-af-render*")]
        self.assertEqual(leftovers, [])


def _sha(data: bytes) -> str:
    import hashlib
    return hashlib.sha256(data).hexdigest()


class TestTempPathSafety(RenderSafetyBase):
    def test_planted_symlink_at_temp_path_never_followed(self):
        """Verification finding 1 (CXR-010/KF-H10 residual): a pre-existing symlink
        at the renderer's temp path must never be opened or followed. Pre-fix the
        temp path was the fixed '<target>.tmp-af-render' and Path.write_text()
        followed a symlink planted there, clobbering the victim."""
        victim = self.tmp / "victim.txt"
        victim.write_text("PRETEST-VICTIM\n")
        planted = self.repo / ".codex" / "config.toml.tmp-af-render"
        planted.symlink_to(victim)
        r = render(self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(victim.read_text(), "PRETEST-VICTIM\n")
        target = self.repo / ".codex" / "config.toml"
        self.assertFalse(target.is_symlink())
        self.assertIn("GENERATED", target.read_text())


class TestPriorManifestContainment(RenderSafetyBase):
    """Verification finding 2: every previous-manifest key must pass the same
    containment validation as a new output path before read, stat, or unlink."""

    def _manifest(self) -> Path:
        return self.repo / "agent-framework" / "generated-manifest.json"

    def _add_prior_entry(self, key: str, content: bytes):
        m = json.loads(self._manifest().read_text())
        m["files"][key] = {"mode": "full", "sha256": _sha(content)}
        self._manifest().write_text(json.dumps(m, indent=2) + "\n")

    def test_absolute_manifest_key_refused(self):
        victim = self.tmp / "abs-victim.txt"
        victim.write_bytes(b"KEEP-ABS\n")
        self._add_prior_entry(str(victim), b"KEEP-ABS\n")
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unsafe", (r.stderr + r.stdout).lower())
        self.assertEqual(victim.read_bytes(), b"KEEP-ABS\n")

    def test_dotdot_manifest_key_refused(self):
        victim = self.tmp / "dd-victim.txt"
        victim.write_bytes(b"KEEP-DD\n")
        self._add_prior_entry("../dd-victim.txt", b"KEEP-DD\n")
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unsafe", (r.stderr + r.stdout).lower())
        self.assertEqual(victim.read_bytes(), b"KEEP-DD\n")

    def test_symlink_escape_via_manifest_key_refused(self):
        external = self.tmp / "external-legacy"
        external.mkdir()
        (external / "stale.md").write_bytes(b"EXTERNAL-STALE\n")
        (self.repo / ".codex" / "legacy").symlink_to(external)
        self._add_prior_entry(".codex/legacy/stale.md", b"EXTERNAL-STALE\n")
        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        msg = (r.stderr + r.stdout).lower()
        self.assertTrue("symlink" in msg or "escapes the repository root" in msg, msg)
        self.assertEqual((external / "stale.md").read_bytes(), b"EXTERNAL-STALE\n")


class TestExactOwnershipMarker(RenderSafetyBase):
    def test_ordinary_generated_words_do_not_transfer_ownership(self):
        """Verification finding 3 (CXR-014/KF-H09 residual): a project-owned file at
        an intended output path whose text merely contains the ordinary words
        'GENERATED' and 'render.py' must be a refused collision, never silently
        overwritten. Only the exact framework marker or a prior-manifest record
        proves ownership."""
        (self.repo / "agent-framework" / "generated-manifest.json").unlink()
        cfg = self.repo / ".codex" / "config.toml"
        cfg.write_text("# my hand-written config. This documentation mentions GENERATED "
                       "artifacts and the render.py workflow in ordinary words.\n"
                       'model = "my-model"\n')
        r = render(self.repo)
        self.assertEqual(r.returncode, 2, r.stderr + r.stdout)
        self.assertIn(".codex/config.toml", r.stderr)
        self.assertIn("my hand-written config", cfg.read_text())


class TestDriftStrayClassification(RenderSafetyBase):
    def test_unmanifested_generated_looking_rule_fails_drift(self):
        """Verification finding 8 (CXR-015/KF-M17): an unmanifested file carrying the
        exact framework marker in a managed directory is stale generated output and
        must FAIL check-drift, not merely warn."""
        stray = self.repo / ".aiassistant" / "rules" / "99-stale-old-rule.md"
        stray.write_text("<!-- GENERATED by scripts/agent-framework/render.py — old rule "
                         "from a previous framework version -->\n\nStale rule body.\n")
        d = check_drift(self.repo)
        self.assertEqual(d.returncode, 1, d.stdout + d.stderr)
        self.assertIn("unmanifested generated-looking file", d.stdout)
        self.assertIn("99-stale-old-rule.md", d.stdout)

    def test_markerless_project_file_warns_only(self):
        """Project-owned (markerless) additions in managed directories stay a
        warning: they are explicitly classified as not framework-managed."""
        stray = self.repo / ".claude" / "agents" / "project-local-note.md"
        stray.write_text("# Project-owned agent note\n\nNo framework marker here.\n")
        d = check_drift(self.repo)
        self.assertEqual(d.returncode, 0, d.stdout + d.stderr)
        self.assertIn("WARN", d.stdout)
        self.assertIn("project-local-note.md", d.stdout)


class TestTransactionRollback(RenderSafetyBase):
    def test_failure_after_staged_files_rolls_back_to_all_old(self):
        """Verification finding 9 (CXR-011/KF-M19): a failed multi-file render must
        leave the tree in the all-old state — files replaced before the failure are
        restored, the manifest is untouched, and no staging files remain."""
        import yaml
        cat_path = self.repo / "agent-framework" / "catalogs" / "role-catalog.yaml"
        cat = yaml.safe_load(cat_path.read_text())
        for entry in cat["roles"]:
            if entry["id"] == "orchestrator":
                entry["summary"] = str(entry.get("summary", "")) + " (rollback-regression)"
        cat_path.write_text(yaml.safe_dump(cat, sort_keys=False, allow_unicode=True))

        early = self.repo / ".claude" / "agents" / "orchestrator.md"
        early_before = early.read_bytes()
        manifest = self.repo / "agent-framework" / "generated-manifest.json"
        manifest_before = manifest.read_text()

        # sabotage a LATER target in commit order: a non-empty directory cannot be
        # atomically replaced, so the commit fails after earlier files were replaced
        late = self.repo / ".opencode" / "agents" / "orchestrator.md"
        late.unlink()
        late.mkdir()
        (late / "x").write_text("occupied")

        r = render(self.repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rolled back", r.stderr)
        self.assertEqual(early.read_bytes(), early_before,
                         "earlier replaced file was not rolled back to its pre-render state")
        self.assertEqual(manifest.read_text(), manifest_before, "manifest must be untouched")
        self.assertEqual([str(p) for p in self.repo.rglob("*.tmp-af-render*")], [])

        # recovery: remove the obstruction, re-render, all-new state, drift clean
        shutil.rmtree(late)
        r2 = render(self.repo)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertIn("(rollback-regression)", early.read_text())
        d = check_drift(self.repo)
        self.assertEqual(d.returncode, 0, d.stdout + d.stderr)


if __name__ == "__main__":
    unittest.main()
