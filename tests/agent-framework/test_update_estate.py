"""Regressions for the estate updater (scripts/update-estate.sh).

TEMPLATE-ONLY. The script is deliberately absent from update-framework.py's PAYLOAD, so
these tests are skipped in adopting repositories the same way the other template-only
suites are.

Every test here exists because the bug it pins reached a live twelve-repository rollout on
2026-08-01. The script had no tests at all, so its only exercise was production: it was
written, used once against the real estate, and three faults were found by reading the
output afterwards. The injection points it now carries (AF_ESTATE_REMOTE_BASE,
AF_ESTATE_REPOS, AF_ESTATE_ALLOW_TMP) exist so that stops being the case.

These tests never reach the network and never run update-framework.py to completion: the
fixture repositories contain no framework, so the updater invocation fails immediately.
That is deliberate — every behaviour pinned here happens BEFORE the update runs, which is
exactly why it survived a real rollout unnoticed.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import REPO_ROOT, scratch_dir  # noqa: E402

SCRIPT = REPO_ROOT / "scripts" / "update-estate.sh"
SOURCE_MARKER = REPO_ROOT / "agent-framework" / ".framework-source"
REPO = "demo-product"
TARGET_REF = "agent-framework-v9.9.9"     # deliberately not a real tag
TARGET_VERSION = "9.9.9"
SOURCE_VERSION = "1.0.0"                  # what the fixture repo currently declares


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout.strip()


@unittest.skipUnless(SOURCE_MARKER.exists(),
                     "template-only: scripts/update-estate.sh is not part of the payload")
class TestUpdateEstate(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch_dir()
        self.remotes = self.tmp / "remotes"
        self.work = self.tmp / "work"
        self.remotes.mkdir(parents=True)
        self.work.mkdir(parents=True)

        # A bare remote whose default branch carries an agent-framework/VERSION, so a
        # test can prove the branch name does NOT come from the target's own version.
        src = self.tmp / "seed"
        (src / "agent-framework").mkdir(parents=True)
        (src / "agent-framework" / "VERSION").write_text(SOURCE_VERSION + "\n")
        (src / "README.md").write_text("seed\n")
        git("init", "-q", "-b", "main", ".", cwd=src)
        git("add", "-A", cwd=src)
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed", cwd=src)
        bare = self.remotes / f"{REPO}.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(src), str(bare)], check=True,
                       capture_output=True)
        self.remote_head = git("rev-parse", "main", cwd=bare)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args: str) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update({
            "AF_ESTATE_REMOTE_BASE": str(self.remotes),
            "AF_ESTATE_REPOS": REPO,
            "AF_ESTATE_ALLOW_TMP": "1",     # scratch_dir() lives under /tmp
            "AF_ESTATE_NO_SSH_REWRITE": "1",  # local paths, no github.com rewrite
        })
        return subprocess.run(
            ["bash", str(SCRIPT), "--ref", TARGET_REF, "--workdir", str(self.work), *args],
            cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=300)

    def clone_present(self) -> Path:
        """Pre-create the work clone so a test can put it in a specific state."""
        d = self.work / REPO
        subprocess.run(["git", "clone", "-q", str(self.remotes / f"{REPO}.git"), str(d)],
                       check=True, capture_output=True)
        return d

    def branches(self, d: Path) -> list[str]:
        return git("for-each-ref", "--format=%(refname:short)", "refs/heads",
                   cwd=d).splitlines()

    # ── bug 1: branched from the clone's current HEAD ────────────────────────────
    def test_branches_from_origin_default_not_the_clones_current_head(self):
        """A reused work clone sits on the previous round's merged branch.

        Branching from there builds the update on stale commits and produces a diff full
        of already-merged work. The rollout that exposed this only escaped it because the
        clones happened to be freshly synced.
        """
        d = self.clone_present()
        git("checkout", "-q", "-b", "stale/previous-round", cwd=d)
        (d / "stale.txt").write_text("work that is NOT on the default branch\n")
        git("add", "-A", cwd=d)
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "stale", cwd=d)
        stale_head = git("rev-parse", "HEAD", cwd=d)

        self.run_script("--apply")

        created = [b for b in self.branches(d) if b.startswith("chore/upgrade-agent-framework")]
        self.assertTrue(created, f"no upgrade branch was created; branches={self.branches(d)}")
        tip = git("rev-parse", created[0], cwd=d)
        self.assertEqual(
            tip, self.remote_head,
            "the upgrade branch must start from origin's default branch, not from "
            "whatever the work clone had checked out")
        self.assertNotEqual(tip, stale_head)
        self.assertFalse((d / "stale.txt").exists(),
                         "stale work from the previous round leaked into the update branch")

    # ── bug 2: named after the version being replaced ────────────────────────────
    def test_branch_is_named_after_the_target_version_not_the_source(self):
        """A 1.2.4 -> 1.2.5 rollout produced twelve branches called ...-1.2.4."""
        d = self.clone_present()
        self.run_script("--apply")
        created = [b for b in self.branches(d) if b.startswith("chore/upgrade-agent-framework")]
        self.assertTrue(created, "no upgrade branch was created")
        self.assertIn(TARGET_VERSION, created[0],
                      f"branch {created[0]!r} must name the version being INSTALLED")
        self.assertNotIn(SOURCE_VERSION, created[0],
                         f"branch {created[0]!r} names the version being REPLACED")

    # ── bug 3: version read from the caller's directory ──────────────────────────
    def test_branch_name_does_not_come_from_the_callers_own_version_file(self):
        """`cat agent-framework/VERSION` resolved against the CALLER's cwd — the
        template's own copy — not the target's. It agreed by luck during the rollout."""
        d = self.clone_present()
        self.run_script("--apply")
        created = [b for b in self.branches(d) if b.startswith("chore/upgrade-agent-framework")]
        template_version = (REPO_ROOT / "agent-framework" / "VERSION").read_text().strip()
        self.assertTrue(created)
        if template_version != TARGET_VERSION:
            self.assertNotIn(
                template_version, created[0],
                "the branch name must derive from --ref, not from the template's own "
                "VERSION file that happens to sit in the caller's working directory")

    # ── the guard that keeps a dirty clone out of the update ─────────────────────
    def test_dirty_work_clone_is_skipped_rather_than_folded_in(self):
        d = self.clone_present()
        (d / "uncommitted.txt").write_text("a human was mid-edit here\n")

        r = self.run_script("--apply")

        self.assertNotEqual(r.returncode, 0, "a dirty clone must make the run report failure")
        self.assertIn("uncommitted", (r.stdout + r.stderr).lower())
        created = [b for b in self.branches(d) if b.startswith("chore/upgrade-agent-framework")]
        self.assertEqual(created, [],
                         "no branch may be created in a clone with uncommitted changes")
        self.assertTrue((d / "uncommitted.txt").exists(), "the human's edit must survive")

    # ── the /tmp refusal (linkhub's suite deletes a /tmp checkout) ───────────────
    def test_tmp_workdir_is_refused_without_the_explicit_override(self):
        env = os.environ.copy()
        env.update({"AF_ESTATE_REMOTE_BASE": str(self.remotes), "AF_ESTATE_REPOS": REPO,
                    "AF_ESTATE_NO_SSH_REWRITE": "1"})
        env.pop("AF_ESTATE_ALLOW_TMP", None)
        r = subprocess.run(
            ["bash", str(SCRIPT), "--ref", TARGET_REF, "--workdir", "/tmp/af-estate-should-refuse"],
            cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 2)
        self.assertIn("REFUSING", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
