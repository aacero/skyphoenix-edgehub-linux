"""Parse-gate regressions for generated artifacts (KF-B01, CXR-001/KF-H03, KF-H02).

Every generated agent file, TOML, and JSON artifact must be loadable by a
standards-compliant parser — including when canonical role text contains quotes,
backslashes, Unicode, and multiline content.
"""
from __future__ import annotations

import re
import shutil
import sys
import tomllib
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import REPO_ROOT, copy_repo, render, scratch_dir, validate  # noqa: E402

sys.path.insert(0, str(REPO_ROOT / "scripts" / "agent-framework"))
import yaml  # noqa: E402  (framework dependency)

NASTY_ROLE = '''id: nasty-fixture-role
title: Nasty "Fixture" Role
purpose: >
  Contains "double quotes", 'single quotes', backslashes \\like\\ this, a colon: here,
  Unicode — äöü ↦ 🚀 — and
  multiple lines to stress every serializer.
decision_role: reviewer
invoke_when:
  - "A test needs: quotes \\"inside\\" bullets"
do_not_invoke_when:
  - Never in production
inputs:
  - nothing
outputs:
  - nothing
permitted_tools: [read]
prohibited_actions:
  - Editing files (read-only)
write_ownership: none
read_only: true
collaboration_boundaries:
  - none
acceptance_criteria:
  - parses everywhere
stopping_condition: Immediately.
handover_format: none
task_weight: trivial
model_class: economy
fallback_model_class: economy
skills_default: []
notes: fixture
'''


def parse_all_artifacts(repo: Path) -> list[str]:
    problems = []
    for f in sorted((repo / ".claude" / "agents").glob("*.md")) \
            + sorted((repo / ".opencode" / "agents").glob("*.md")):
        m = re.match(r"\A---\s*\n(.*?)\n---\s*\n", f.read_text(encoding="utf-8"), re.S)
        if not m:
            problems.append(f"{f}: no frontmatter")
            continue
        try:
            fm = yaml.safe_load(m.group(1))
            assert isinstance(fm, dict) and fm.get("description")
        except Exception as e:  # noqa: BLE001
            problems.append(f"{f}: {e}")
    for f in sorted((repo / ".codex").rglob("*.toml")):
        try:
            tomllib.loads(f.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as e:
            problems.append(f"{f}: {e}")
    return problems


class TestGeneratedArtifacts(unittest.TestCase):
    def test_committed_artifacts_parse(self):
        problems = parse_all_artifacts(REPO_ROOT)
        self.assertEqual(problems, [])

    def test_nasty_role_renders_valid_everywhere(self):
        """Regression for CXR-001/KF-B01: quotes/backslashes/Unicode/multiline in a
        role must not break any provider serialization."""
        tmp = scratch_dir()
        try:
            repo = copy_repo(tmp / "repo")
            (repo / "agent-framework" / "canonical" / "roles" / "nasty-fixture-role.yaml").write_text(NASTY_ROLE)
            # register in the role catalog so catalog-sync stays green
            cat = repo / "agent-framework" / "catalogs" / "role-catalog.yaml"
            cat.write_text(cat.read_text() + '\n  - id: nasty-fixture-role\n    summary: "Fixture: has quotes, a colon and — unicode."\n    decision_role: reviewer\n    read_only: true\n    model_class: economy\n')
            r = render(repo)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
            self.assertEqual(parse_all_artifacts(repo), [])
            # role brief round-trips through the Codex TOML string
            t = tomllib.loads((repo / ".codex" / "agents" / "nasty-fixture-role.toml").read_text())
            self.assertIn('"double quotes"', t["developer_instructions"])
            self.assertIn("🚀", t["developer_instructions"])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_kimi_profile_uses_documented_schema(self):
        """Regression for KF-H02: only decision/scope/pattern/reason keys and
        ToolName(arg-pattern) patterns; required deny rules present."""
        text = (REPO_ROOT / ".kimi-code" / "README.md").read_text(encoding="utf-8")
        m = re.search(r"```toml\n(.*?)```", text, re.S)
        self.assertIsNotNone(m, "profile TOML block missing")
        prof = tomllib.loads(m.group(1))
        rules = prof["permission"]["rules"]
        self.assertTrue(rules)
        for r in rules:
            self.assertLessEqual(set(r), {"decision", "scope", "pattern", "reason"}, r)
            self.assertRegex(r["pattern"], r"^[A-Za-z]+(\(.*\))?$")
            self.assertNotIn("tool", r)
        deny = [r["pattern"] for r in rules if r["decision"] == "deny"]
        for req in ("Bash(git push --force*)", "Bash(git push -f*)", "Read(**/.env*)"):
            self.assertIn(req, deny)

    def test_validate_fails_on_broken_frontmatter(self):
        """The parse gate must catch a regression to raw-f-string frontmatter."""
        tmp = scratch_dir()
        try:
            repo = copy_repo(tmp / "repo")
            bad = repo / ".claude" / "agents" / "code-reviewer.md"
            bad.write_text("---\nname: x\ndescription: broken: because: unquoted colons: everywhere\n---\nbody\n")
            v = validate(repo)
            self.assertEqual(v.returncode, 1)
            self.assertIn("frontmatter", v.stdout)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_validate_fails_on_invalid_codex_toml(self):
        tmp = scratch_dir()
        try:
            repo = copy_repo(tmp / "repo")
            bad = repo / ".codex" / "agents" / "code-reviewer.toml"
            bad.write_text('name = "broken\ndescription = "unterminated\n')
            v = validate(repo)
            self.assertEqual(v.returncode, 1)
            self.assertIn("invalid TOML", v.stdout)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
