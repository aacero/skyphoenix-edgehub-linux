#!/usr/bin/env python3
"""Install or update the agent framework in a repository created from this template.

ONE command for both the first migration and every later upgrade — it is idempotent:
running it twice in a row changes nothing the second time.

  python3 scripts/agent-framework/update-framework.py --ref v1.2.0 # pin a template tag
  python3 scripts/agent-framework/update-framework.py              # reuse the recorded source_commit
  python3 scripts/agent-framework/update-framework.py --from ../template   # local template checkout
  python3 scripts/agent-framework/update-framework.py --dry-run    # predict the real run, change nothing

There is no implicit branch default: this tool fetches code and then executes it, so the
ref must be a tag or a commit SHA (ADR 0001 decision 1). A branch requires an explicit
--allow-mutable-ref. Set AF_REQUIRE_SIGNED_TAG=1 — as the update workflow does — to
additionally require `git verify-tag` to pass before anything is copied.

Bootstrap (repository that does not have this script yet):

  git clone --depth 1 <template-url> /tmp/af-template
  python3 /tmp/af-template/scripts/agent-framework/update-framework.py \
      --from /tmp/af-template --target /path/to/repo

What it does, in order:

  1. Acquires the template source (local `--from`, or a pinned fetch of `--ref`).
  2. Re-executes the TEMPLATE's copy of this script when it differs from the running
     one, so an outdated installed updater can never drive an upgrade.
  3. Syncs the framework payload (canonical sources, catalogs, schemas, providers,
     design system, framework scripts, tests, CI wrapper).
  4. Bootstraps project-side requirements that must exist for the gates to pass —
     managed markers, .gitignore entries, BACKLOG Candidates bucket, project.yaml
     agent_framework block, docs/research/, Claude permission baseline, CI workflows.
  5. Renders provider artifacts (render.py) — refusing on adopter-file collisions.
  6. Reports superseded legacy files (removing them only with --retire-legacy).
  7. Runs the full verification gate (validate, drift, unit tests, evals).

Safety contract (the same provenance discipline render.py uses — nothing is ever
silently clobbered):

  * `agent-framework/generated-manifest.json` is NEVER copied from the template: it
    records the ADOPTING repository's own generated state. Copying it would transfer
    framework ownership of files this repository hand-wrote and let the next render
    overwrite them without backup.
  * A payload file is written only when the target is missing, already byte-identical,
    or PROVABLY framework-owned: its current bytes match either the hash this updater
    recorded when it last installed that file (`agent-framework/.framework-payload.json`)
    or a known template baseline hash. Anything else is a local modification: the run
    refuses (exit 2) and lists every conflict. `--adopt` accepts them, copying each to
    `<name>.bak-pre-framework` first.
  * Payload files that disappeared from the template are removed only when their bytes
    still match the recorded hash; a locally modified one is kept with a warning.
  * Project-side bootstrapping is additive only: existing content is never rewritten,
    permission rules are only ever ADDED (never removed or weakened), and every step
    is skipped when it is already satisfied.
  * The update is transactional (ADR 0001 decision 5): a refusal or failure during the
    mutation phase rolls every completed write and delete back to its pre-run state,
    printing `ROLLBACK FAILED` per path if restoration itself cannot complete. `--dry-run`
    runs the real apply-and-render flow — including render.py's own collision check —
    against a disposable copy of the target, so the plan it prints is the outcome a real
    run would produce, not a separate prediction that could drift from it.

Exit codes: 0 success · 1 verification failed / error · 2 collisions need --adopt.
Dependencies: Python 3.9+, PyYAML (for render/validate), git, and Bash for the
provider shims. No rsync, no network access when `--from` is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_TEMPLATE_URL = "https://github.com/skyphoenix-it/skyphoenix-enterprise-template.git"
# No DEFAULT_TEMPLATE_REF. ADR 0001 decision 1: a mutable branch as the implicit default
# meant every adopting repo fetched-and-executed whatever happened to be on `main`.
# The ref now comes from --ref, AF_TEMPLATE_REF, or the source_commit recorded by the
# previous update, and a branch is refused unless --allow-mutable-ref is passed.

# ADR 0001 decision 3: git's `ext::` transport executes an arbitrary command, and a
# leading `-` is parsed as an option. Neither is reachable through an allowlisted scheme.
ALLOWED_URL_SCHEMES = ("https://", "ssh://", "file://")

PAYLOAD_MANIFEST = "agent-framework/.framework-payload.json"
SOURCE_MARKER = "agent-framework/.framework-source"
GENERATED_MANIFEST = "agent-framework/generated-manifest.json"

# Framework payload: template-owned content with no project-specific parts. Directories
# are copied recursively. `generated-manifest.json`, `runs/`, and the review reports are
# deliberately absent — see the safety contract above.
PAYLOAD = [
    "agent-framework/canonical",
    "agent-framework/catalogs",
    "agent-framework/schemas",
    "agent-framework/providers",
    "agent-framework/design-system",
    "agent-framework/evals/rubrics.md",
    "agent-framework/templates",
    # Public trust anchor for template tag signatures. framework-update.yml imports it
    # before `git verify-tag`, because a hosted runner starts with an empty keyring and
    # verification would otherwise fail closed on every update forever (ADR 0001
    # decisions 2/4). Public key material only — never the private half.
    "agent-framework/trust",
    "agent-framework/VERSION",
    "agent-framework/README.md",
    # Framework reference documentation. `provider-research.md` is also read by eval
    # E11 (dated-source discipline); the review/verification reports are template
    # process artifacts and are deliberately NOT shipped to adopting repositories.
    "agent-framework/reports/migration-guide.md",
    "agent-framework/reports/provider-research.md",
    "agent-framework/reports/release-notes-v1.1.0.md",
    # v1.2.0 supersedes v1.1.4 for every purpose; adopters need its upgrade procedure and
    # its refusal/collision guidance locally, not only in the private template.
    "agent-framework/reports/release-notes-v1.2.0.md",
    "scripts/agent-framework",
    "scripts/validate-repository.sh",
    "scripts/ci.sh",
    # Cited by the delegation policy and both lifecycle workflows (parallel writers
    # must use isolated worktrees) — validate.py fails if canonical cites it and it
    # is missing, so it is part of the payload, not optional tooling.
    "scripts/create-worktree.sh",
    "tests/agent-framework",
]
PAYLOAD_EXCLUDE_DIRS = {"__pycache__", "runs", ".git", ".pytest_cache"}
PAYLOAD_EXCLUDE_SUFFIXES = (".pyc", ".pyo")

# Scaffold files: shipped by the template but commonly customized downstream. Same
# provenance rule as payload files, tracked separately so a customized CI workflow is
# reported instead of overwritten.
SCAFFOLD_FILES = {
    ".github/workflows/quality.yml": ".github/workflows/quality.yml",
    ".github/workflows/framework-update.yml": "agent-framework/templates/framework-update.yml",
}

# Known template baselines: bytes a file had in an earlier template version. Matching
# one proves the file is untouched template output and may be upgraded in place.
KNOWN_BASELINE_HASHES = {
    ".github/workflows/quality.yml": {
        "5baf5911bb60bc7049b076dd1860a80f38b45fb6bea9249146d451e3aa4e1ed5",  # v1.0 template
    },
    "scripts/ci.sh": {
        "67038fa3b27803a07046b5e1dae21927cf40b686e453661009e6c9e29f42838e",  # v1.0 template
    },
    "scripts/validate-repository.sh": {
        "a5fb448e902550f63ac6030ef629af1dc75da870d6860c321f4d301d312b8dd7",  # v1.0 template
    },
}

# Superseded by generated equivalents in v1.1.0. Removed ONLY with --retire-legacy and
# only when the bytes still match the template baseline (a customized file is kept).
LEGACY_FILES = {
    ".claude/agents/architect.md": {"c57135add50ae96882d13c0d78963b8f183c3e687a7d5825a91f5641cf1ff351"},
    ".claude/agents/implementer.md": {"108300d7136a36b890fad0bbf2cd59d8424b492c9bbaaab208eaeb98b96e7627"},
    ".claude/agents/release-manager.md": {"d9f8cf3bf115491df60c5a567e5f67cc4925cb11eb18a46c00551595daa99bc7"},
    ".claude/agents/reviewer.md": {"c49356398ee5dd5c98279c6a6a28aa2886a63139eb03db69271ffc645a3d2bac"},
    ".claude/agents/security-reviewer.md": {"6458f2c3252a057e79c5daf321e7b029b47e20bb4049a0cc3bf8d0823693fdf6"},
    ".claude/agents/test-architect.md": {"54f8583ce34f9168c9219b3be50ef3fd223023469559778540d0fa9db34770cb"},
    ".claude/rules/00-core.md": {"00ddf81233a0a9576dadc5f84aa2ae014a264a6768d7543f87a56f16cafed7e6"},
    ".claude/rules/10-security.md": {"c22e81f924e6d72c7dd23ebd9ef7f2f81135db44152057b2d094ee23ee924f1b"},
    ".claude/rules/20-testing.md": {"27b7f4e009bcf8b9b4c1392d16ced390edcab4347efc99f8b714b5e382e6c0f1"},
    ".claude/rules/30-parallel-work.md": {"80a270988a8a714460637a4de2d6003e147f2f9cb5ffd69ae63379a53a2996cf"},
}

MARKER_BEGIN = ("<!-- AGENT-FRAMEWORK:BEGIN — GENERATED from agent-framework/canonical/. "
                "Do not edit inside this block; edit canonical sources and run: "
                "python3 scripts/agent-framework/render.py -->")
MARKER_END = "<!-- AGENT-FRAMEWORK:END -->"
MARKER_SENTINEL = "AGENT-FRAMEWORK:BEGIN"

# Required by validate.py (check_managed_files) plus the Kimi adapter's local config
# and the one-time `--adopt` backups: those are kept locally as safety copies but must
# never be committed — otherwise the update workflow's `git add -A` sweeps every
# `*.bak-pre-framework` into the adoption PR (observed on the first real adopter).
GITIGNORE_LINES = ["agent-framework/runs/", ".claude/settings.local.json",
                   ".kimi-code/local.toml", ".env", "*.bak-pre-framework"]
CANDIDATES_HEADING = "## Candidates"
CANDIDATES_BLOCK = f"""
{CANDIDATES_HEADING}

Unapproved ideas, findings, and out-of-scope proposals land here. Nothing in this
section is implemented without explicit product-owner approval (scope-control policy).
"""
PROJECT_YAML_BLOCK = """
agent_framework:
  # Domain skills installed into this repository (opt-in; see
  # agent-framework/catalogs/skill-catalog.yaml for the available ids).
  skills: []
"""


class Refused(Exception):
    """Collisions that need an explicit --adopt decision."""


class Failed(Exception):
    """Fatal error or failed verification."""


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str | None:
    try:
        return sha(path.read_bytes())
    except OSError:
        return None


# ---------------------------------------------------------------- reporting

class Report:
    def __init__(self, dry_run: bool):
        self.dry_run = dry_run
        self.installed: list[str] = []
        self.updated: list[str] = []
        self.removed: list[str] = []
        self.adopted: list[str] = []
        self.scaffolded: list[str] = []
        self.conflicts: list[str] = []
        self.warnings: list[str] = []
        self.legacy: list[str] = []

    def note(self, msg: str):
        self.warnings.append(msg)


def log(msg: str = ""):
    print(msg, flush=True)


# ---------------------------------------------------------------- payload

def payload_files(source: Path) -> dict[str, Path]:
    """Map repo-relative path -> absolute source path for every payload file."""
    found: dict[str, Path] = {}
    for entry in PAYLOAD:
        src = source / entry
        if src.is_file():
            found[entry] = src
        elif src.is_dir():
            for f in sorted(src.rglob("*")):
                if not f.is_file():
                    continue
                if set(f.relative_to(src).parts) & PAYLOAD_EXCLUDE_DIRS:
                    continue
                if f.name.endswith(PAYLOAD_EXCLUDE_SUFFIXES):
                    continue
                found[f.relative_to(source).as_posix()] = f
    return found


def load_payload_manifest(target: Path) -> dict:
    p = target / PAYLOAD_MANIFEST
    if not p.exists():
        return {"files": {}, "scaffold": {}}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"files": {}, "scaffold": {}}
    data.setdefault("files", {})
    data.setdefault("scaffold", {})
    return data


def owned(rel: str, current: str | None, new_hash: str, prior: dict) -> bool:
    """Is the target file provably framework-owned (safe to overwrite)?"""
    if current is None or current == new_hash:
        return True
    if prior.get("files", {}).get(rel) == current:
        return True
    if prior.get("scaffold", {}).get(rel) == current:
        return True
    return current in KNOWN_BASELINE_HASHES.get(rel, set())


_TARGET_ROOT: Path | None = None


def set_target_root(target: Path) -> None:
    """Pin the containment boundary for every subsequent write (ADR 0001 decision 3)."""
    global _TARGET_ROOT
    _TARGET_ROOT = target.resolve()


class Journal:
    """Snapshots every path this run is about to create, modify, or delete, so that a
    refusal or failure during the mutation phase can restore the exact pre-run state
    (ADR 0001 decision 5). Mirrors render.py's `Renderer._rollback`: the tree is either
    all-old or all-new, never a partial mix of the two."""

    def __init__(self) -> None:
        self._seen: set[Path] = set()
        self._entries: list[tuple[Path, tuple[bytes, int] | None]] = []

    def record(self, path: Path) -> None:
        """Snapshot `path` BEFORE it is mutated. Idempotent per path: the first call
        wins, so a write made earlier in the same run is never mistaken for the
        pre-run baseline."""
        if path in self._seen:
            return
        self._seen.add(path)
        try:
            self._entries.append((path, (path.read_bytes(), path.stat().st_mode)))
        except OSError:
            self._entries.append((path, None))   # did not exist before this run

    def __len__(self) -> int:
        return len(self._entries)

    def rollback(self) -> None:
        """Restore every recorded path to its pre-run snapshot, in reverse order. A
        path that did not exist before this run is deleted; one that did is restored
        via a staged write-then-replace, matching render.py's atomic-restore pattern."""
        if not self._entries:
            return
        for path, snapshot in reversed(self._entries):
            try:
                if snapshot is None:
                    if path.exists() or path.is_symlink():
                        path.unlink()
                else:
                    data, mode = snapshot
                    path.parent.mkdir(parents=True, exist_ok=True)
                    tmp = path.parent / f".{path.name}.af-update-rollback-tmp"
                    with open(tmp, "wb") as f:
                        f.write(data)
                    try:
                        os.chmod(tmp, mode)
                    except OSError:
                        pass
                    os.replace(tmp, path)
            except OSError as e:
                print(f"update-framework.py: ROLLBACK FAILED for {path}: {e} — the "
                      "repository may be left partially updated; inspect it with "
                      "`git status`/`git diff` and restore manually.", file=sys.stderr)
        print("update-framework.py: run failed — all completed changes were rolled "
              "back (tree restored to its pre-run state).", file=sys.stderr)


_JOURNAL: "Journal | None" = None


def set_journal(journal: "Journal | None") -> None:
    """Active only for a real (non-preview) run — a --dry-run's mutations land on a
    disposable copy that is discarded regardless of outcome, so nothing needs undoing."""
    global _JOURNAL
    _JOURNAL = journal


def _journal_record(path: Path) -> None:
    if _JOURNAL is not None:
        _JOURNAL.record(path)


def remove_file(path: Path) -> None:
    """Delete `path`, journaling its pre-delete state first (ADR 0001 decision 5)."""
    _journal_record(path)
    path.unlink()


def contained(path: Path) -> Path:
    """Assert `path` stays inside the target repository after symlink resolution.

    Checked against the deepest EXISTING ancestor, not the leaf: the leaf usually does
    not exist yet, and `mkdir(parents=True)` follows a symlinked parent directory out of
    the repository before any leaf-only check could fire. Both escapes were demonstrated
    against scratch repos during the v1.1.0 release gate (findings F4/F5)."""
    if _TARGET_ROOT is None:
        raise Failed("internal error: target root not pinned before a write")
    if path.is_symlink():
        raise Failed(f"{path} is a symlink — refusing to write through it")
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    resolved = probe.resolve()
    if resolved != _TARGET_ROOT and _TARGET_ROOT not in resolved.parents:
        raise Failed(f"refusing to write outside the target repository: {path} "
                     f"resolves under {resolved}, not {_TARGET_ROOT}")
    return path


def write_text_file(target_path: Path, text: str):
    """Text convenience wrapper. Every scaffolding helper MUST route through this rather
    than Path.write_text, which bypasses the containment and symlink guards."""
    write_file(target_path, text.encode("utf-8"))


def write_file(target_path: Path, data: bytes):
    """Write `data` to `target_path`, contained and journaled.

    A --dry-run is no longer a special case here: it writes to a disposable copy of the
    target (see main()), so the write is real — only its destination differs. The
    pre-write snapshot is recorded before anything is touched (ADR 0001 decision 5),
    so a later refusal or failure can restore this exact byte content."""
    contained(target_path)
    _journal_record(target_path)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = target_path.parent / f".{target_path.name}.af-update-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    if target_path.exists():
        shutil.copymode(target_path, tmp)
    os.replace(tmp, target_path)


def sync_payload(source: Path, target: Path, prior: dict, adopt: bool, rep: Report) -> dict:
    """Install/update every payload file; remove payload files the template dropped."""
    files = payload_files(source)
    if not files:
        raise Failed(f"no framework payload found in {source} — is it a template checkout?")
    new_manifest: dict[str, str] = {}
    conflicts: list[tuple[str, Path, bytes]] = []

    for rel, src in sorted(files.items()):
        data = src.read_bytes()
        new_hash = sha(data)
        new_manifest[rel] = new_hash
        dst = target / rel
        current = file_sha(dst)
        if current == new_hash:
            continue
        if not owned(rel, current, new_hash, prior):
            conflicts.append((rel, dst, data))
            continue
        write_file(dst, data)
        if src.stat().st_mode & 0o111:
            dst.chmod(dst.stat().st_mode | 0o111)
        (rep.installed if current is None else rep.updated).append(rel)

    if conflicts and not adopt:
        rep.conflicts = [rel for rel, _, _ in conflicts]
        raise Refused("locally modified framework files")
    for rel, dst, data in conflicts:
        backup = dst.with_name(dst.name + ".bak-pre-framework")
        write_file(backup, dst.read_bytes())
        write_file(dst, data)
        rep.adopted.append(rel)

    # Stale payload files: recorded by a previous run, gone from the template.
    for rel, old_hash in sorted(prior.get("files", {}).items()):
        if rel in new_manifest:
            continue
        dst = target / rel
        current = file_sha(dst)
        if current is None:
            continue
        if current != old_hash:
            rep.note(f"kept locally modified {rel} (no longer shipped by the template)")
            continue
        remove_file(dst)
        rep.removed.append(rel)
    return new_manifest


def sync_scaffold(source: Path, target: Path, prior: dict, adopt: bool, rep: Report) -> dict:
    """Install customizable template files (CI workflows) under the same ownership rule."""
    installed: dict[str, str] = {}
    conflicts: list[tuple[str, Path, bytes, str]] = []
    for rel, src_rel in SCAFFOLD_FILES.items():
        src = source / src_rel
        if not src.is_file():
            continue
        data = src.read_bytes()
        new_hash = sha(data)
        dst = target / rel
        current = file_sha(dst)
        if current == new_hash:
            installed[rel] = new_hash
            continue
        if not owned(rel, current, new_hash, prior):
            conflicts.append((rel, dst, data, src_rel))
            # Do NOT record the customized file's hash (ADR 0003). The scaffold map is the
            # framework's own write-record and owned() treats a match in it as PROOF of
            # ownership, so writing the target's bytes here silently converts "I saw this
            # file" into "I own this file" — and the next update takes the branch below,
            # overwriting the customization in place with no backup, no report entry, and
            # no --adopt required. Carry forward the last hash the framework actually
            # wrote, or record nothing if it never wrote one.
            carried = prior.get("scaffold", {}).get(rel)
            if carried is not None:
                installed[rel] = carried
            continue
        # An existing scaffold file whose bytes differ from the template is backed up and
        # reported even when it is provably owned. Scaffold files are the ones adopters are
        # EXPECTED to customize, and manifests poisoned before ADR 0003 still claim
        # ownership of customized bytes — this is what stops such a claim from being
        # actioned silently. A first install (current is None) has nothing to preserve.
        if current is not None:
            write_file(dst.with_name(dst.name + ".bak-pre-framework"), dst.read_bytes())
            rep.note(f"replaced framework-owned {rel} with the template version; the "
                     f"previous bytes are in {rel}.bak-pre-framework")
        write_file(dst, data)
        installed[rel] = new_hash
        (rep.installed if current is None else rep.updated).append(rel)

    for rel, dst, data, src_rel in conflicts:
        if adopt:
            write_file(dst.with_name(dst.name + ".bak-pre-framework"), dst.read_bytes())
            write_file(dst, data)
            rep.adopted.append(rel)
            installed[rel] = sha(data)
        else:
            rep.note(f"kept customized {rel} — review it against the template version "
                     f"({src_rel}); re-run with --adopt to take it over (a .bak-pre-framework "
                     "copy is made first)")
    return installed


# ---------------------------------------------------------------- scaffolding

def ensure_markers(target: Path, name: str, rep: Report):
    """Append managed markers when absent. Existing project text is never rewritten."""
    p = target / name
    if p.exists():
        text = p.read_text(encoding="utf-8")
        if MARKER_SENTINEL in text and MARKER_END in text:
            return
        addition = f"\n{MARKER_BEGIN}\n{MARKER_END}\n"
        write_text_file(p, text.rstrip("\n") + "\n" + addition)
        rep.scaffolded.append(f"{name} (managed markers appended)")
        return
    body = "@AGENTS.md\n" if name == "CLAUDE.md" else ""
    write_text_file(p, f"# {name.replace('.md', '')}\n\n{MARKER_BEGIN}\n{MARKER_END}\n\n{body}")
    rep.scaffolded.append(f"{name} (created with managed markers)")


def ensure_gitignore(target: Path, rep: Report):
    p = target / ".gitignore"
    text = p.read_text(encoding="utf-8") if p.exists() else ""
    missing = [line for line in GITIGNORE_LINES
               if line not in {x.strip() for x in text.splitlines()}]
    if not missing:
        return
    prefix = text if text.endswith("\n") or not text else text + "\n"
    write_text_file(p, prefix + "\n# agent framework\n" + "\n".join(missing) + "\n")
    rep.scaffolded.append(f".gitignore (+{', '.join(missing)})")


def ensure_candidates(target: Path, rep: Report):
    p = target / "BACKLOG.md"
    text = p.read_text(encoding="utf-8") if p.exists() else "# Backlog\n"
    if CANDIDATES_HEADING in text:
        return
    write_text_file(p, text.rstrip("\n") + "\n" + CANDIDATES_BLOCK)
    rep.scaffolded.append("BACKLOG.md (Candidates section added)")


def ensure_project_yaml(target: Path, rep: Report):
    p = target / "project.yaml"
    if not p.exists():
        # A repository that never came from this template has no project.yaml, and merely
        # warning was not enough: the eval suite reads it unconditionally and died with
        # FileNotFoundError, so `ci.sh` could never go green on a freshly adopted
        # independent repo. Create a starter instead — derived from the directory name,
        # carrying none of the template initialization placeholders (validate-repository.sh
        # flags those), and obviously in need of completion.
        #
        # Do NOT write that placeholder prefix literally anywhere in this file. The scanner
        # in validate-repository.sh greps the whole tree for it and only excludes
        # initialize-project.sh and itself, so a literal mention here — even inside a
        # comment explaining the rule — turns every adopting repository's CI red. That is
        # exactly what shipped in v1.1.4; see PLACEHOLDER_PREFIX in
        # tests/agent-framework/test_update_framework.py for the regression test.
        slug = target.resolve().name
        name = slug.replace("-", " ").replace("_", " ").title()
        write_text_file(p, (
            "# Created on framework adoption. Replace the values below with the real\n"
            "# ones — they are a starting point, not a description of this project.\n"
            "project:\n"
            f'  name: "{name}"\n'
            f'  slug: "{slug}"\n'
            '  description: "TODO — one line describing what this project is."\n'
            '  owner: "TODO"\n'
            "  status: discovery\n"
            "technology:\n"
            '  language: "to be decided"\n'
            '  runtime: "to be decided"\n'
            '  build_command: "./scripts/build.sh"\n'
            '  test_command: "./scripts/test.sh"\n'
            + PROJECT_YAML_BLOCK.lstrip("\n")))
        rep.scaffolded.append("project.yaml (created — replace the TODO values)")
        return
    text = p.read_text(encoding="utf-8")
    if any(line.startswith("agent_framework:") for line in text.splitlines()):
        return
    write_text_file(p, text.rstrip("\n") + "\n" + PROJECT_YAML_BLOCK)
    rep.scaffolded.append("project.yaml (agent_framework.skills block added)")


# Project files the gates REQUIRE but the payload deliberately does not own. A repository
# created from this template already has them; one that adopts the framework later never
# did, so `validate-repository.sh`'s required set and `validate.py`'s canonical-path check
# both failed on the first run (26 errors when adopting skyphoenix-company-website).
#
# These are PROJECT-owned, not template-owned: they must be created when absent and NEVER
# overwritten, which is why they are scaffolding rather than payload. Content is a
# deliberately thin, honest starter — it states that it needs completing rather than
# inventing facts about a project the framework knows nothing about.
_SCAFFOLD_NOTE = ("> Scaffold created on framework adoption. Replace this with the real "
                  "content — the gates check that this file exists, not that it is true.\n")

PROJECT_SCAFFOLD: dict[str, str] = {
    "PROJECT.md": (
        "# Project\n\n" + _SCAFFOLD_NOTE +
        "\n## Purpose\n\n## Status\n\n## Stack\n\n## Owner\n"),
    "SECURITY.md": (
        "# Security\n\n" + _SCAFFOLD_NOTE +
        "\n## Reporting\n\nReport suspected vulnerabilities privately to the repository "
        "owner. Do not open a public issue for credential- or data-related reports.\n"
        "\n## Scope\n\nAssets, trust boundaries and open findings: "
        "`docs/security/threat-model.md`.\n"),
    "docs/product/product-vision.md": (
        "# Product Vision\n\n" + _SCAFFOLD_NOTE +
        "\n## Purpose\n\n## Users\n\n## Strategic non-goals\n"),
    "docs/product/pov-scope.md": (
        "# Scope\n\n" + _SCAFFOLD_NOTE +
        "\n## In scope\n\n## Out of scope\n\nOut-of-scope work needs product-owner "
        "approval, and an ADR when structural.\n"),
    "docs/architecture/overview.md": (
        "# Architecture Overview\n\n" + _SCAFFOLD_NOTE +
        "\n## Shape\n\n## Persistence\n\n## Known structural debt\n\n"
        "Structural changes require an ADR in `docs/adr/`.\n"),
    "docs/security/threat-model.md": (
        "# Threat Model\n\n" + _SCAFFOLD_NOTE +
        "\n## Assets\n\n## Actors\n\n## Trust boundaries\n\n## Open findings\n\n"
        "## Not yet assessed\n\nAreas not examined are `NOT ASSESSED` with a reason — "
        "silence never implies safety.\n"),
    "docs/testing/test-strategy.md": (
        "# Test Strategy\n\n" + _SCAFFOLD_NOTE +
        "\n## Current state\n\nRecord honestly what automated coverage exists. If "
        "`scripts/build.sh` and `scripts/test.sh` are still the framework stubs they "
        "prove nothing, and no completion claim may cite them (evidence policy).\n"
        "\n## Failure paths that matter most\n"),
    "docs/releases/release-checklist.md": (
        "# Release Checklist\n\n" + _SCAFFOLD_NOTE +
        "\nTicked entries carry evidence. An unticked entry is a real gap, never a "
        "formality. `NOT RUN` is stated, never silently passed.\n\n"
        "- [ ] Criteria complete\n- [ ] Tests passed\n- [ ] Security reviewed\n"
        "- [ ] Migrations tested\n- [ ] Install/upgrade/rollback validated\n"
        "- [ ] Observability/docs/notices complete\n- [ ] Limitations documented\n"
        "- [ ] Decision recorded\n"),
    "docs/operations/runbook.md": (
        "# Operational Runbook\n\n" + _SCAFFOLD_NOTE +
        "\n## Health\n\n## Startup/shutdown\n\n## Backup/restore\n\n## Failures\n\n"
        "## Diagnostics\n\n## Escalation\n\n## Rollback\n"),
}

# Executable stubs. Same rule: created only when absent, never overwritten — an adopter
# that already has a real build or test command keeps it.
SCAFFOLD_SCRIPTS: dict[str, str] = {
    "scripts/build.sh": ("#!/usr/bin/env bash\nset -euo pipefail\n"
                         "echo 'No build command configured. Replace after stack approval.'\n"),
    "scripts/test.sh": ("#!/usr/bin/env bash\nset -euo pipefail\n"
                        "echo 'No test command configured. Replace after stack approval.'\n"),
}


def ensure_project_scaffold(source: Path, target: Path, rep: Report):
    """Create the project-owned files the gates require, only when they are absent.

    Never overwrites: an adopting repository's own PROJECT.md, threat model or test
    strategy is authoritative and is left byte-for-byte alone."""
    created = []
    for rel, body in PROJECT_SCAFFOLD.items():
        p = target / rel
        if p.exists():
            continue
        write_text_file(p, body)
        created.append(rel)
    for rel, body in SCAFFOLD_SCRIPTS.items():
        p = target / rel
        if p.exists():
            continue
        write_text_file(p, body)
        p.chmod(p.stat().st_mode | 0o111)
        created.append(rel)
    # The ADR template is genuinely template-owned content, so copy it rather than
    # re-authoring it here — but still only when the adopter has no docs/adr/ yet.
    adr = target / "docs" / "adr" / "0000-template.md"
    src_adr = source / "docs" / "adr" / "0000-template.md"
    if not adr.exists() and src_adr.is_file():
        write_file(adr, src_adr.read_bytes())
        created.append("docs/adr/0000-template.md")
    if created:
        rep.scaffolded.append(
            f"project scaffold created ({len(created)}): {', '.join(sorted(created))}")


def ensure_research_dir(target: Path, rep: Report):
    p = target / "docs" / "research" / ".gitkeep"
    if p.exists():
        return
    write_text_file(p, "")
    rep.scaffolded.append("docs/research/ (referenced by the research workflows)")


def merge_claude_permissions(source: Path, target: Path, rep: Report):
    """Additively merge the template's deny/ask permission baseline.

    Only ever ADDS restrictions: existing rules, `allow`, and every other settings key
    are preserved byte-for-byte in meaning. A repository that hardened its own rules
    keeps them (validate.py independently pins the security-critical subset)."""
    src = source / ".claude" / "settings.json"
    dst = target / ".claude" / "settings.json"
    if not src.is_file():
        return
    if not dst.exists():
        write_file(dst, src.read_bytes())
        rep.scaffolded.append(".claude/settings.json (installed from template)")
        return
    try:
        cur = json.loads(dst.read_text(encoding="utf-8"))
        tpl = json.loads(src.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        rep.note(f".claude/settings.json is not valid JSON ({e}) — fix it manually; "
                 "permission merge skipped")
        return
    if not isinstance(cur, dict):
        rep.note(".claude/settings.json is not a JSON object — permission merge skipped")
        return
    perms = cur.setdefault("permissions", {})
    added: list[str] = []
    for bucket in ("deny", "ask"):
        want = (tpl.get("permissions") or {}).get(bucket) or []
        have = perms.setdefault(bucket, [])
        if not isinstance(have, list):
            rep.note(f".claude/settings.json permissions.{bucket} is not a list — skipped")
            continue
        for rule in want:
            if rule not in have and rule not in (perms.get("deny") or []):
                have.append(rule)
                added.append(f"{bucket}: {rule}")
    if not added:
        return
    write_file(dst, (json.dumps(cur, indent=2) + "\n").encode("utf-8"))
    rep.scaffolded.append(".claude/settings.json (+" + "; ".join(added) + ")")


# ---------------------------------------------------------------- legacy

def handle_legacy(target: Path, retire: bool, rep: Report):
    for rel, hashes in sorted(LEGACY_FILES.items()):
        p = target / rel
        current = file_sha(p)
        if current is None:
            continue
        if current in hashes:
            if retire:
                remove_file(p)
                rep.removed.append(f"{rel} (superseded legacy file)")
            else:
                rep.legacy.append(f"{rel} — unmodified template baseline; remove with --retire-legacy")
        else:
            rep.legacy.append(f"{rel} — locally modified; review and remove manually "
                              "(its role is now covered by generated files)")


# ---------------------------------------------------------------- external commands

def run_cmd(cmd: list[str], cwd: Path, capture: bool = False) -> subprocess.CompletedProcess:
    # PYTHONDONTWRITEBYTECODE: a subprocess (render.py etc.) importing a sibling module
    # (e.g. render.py -> _lib.py) would otherwise leave __pycache__/*.pyc under the
    # target that neither the payload sync nor the journal (ADR 0001 decision 5) tracks
    # — untracked litter after a clean run, and a rollback gap after a failed one.
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    return subprocess.run(cmd, cwd=str(cwd), text=True, env=env,
                          stdin=subprocess.DEVNULL,
                          capture_output=capture)


def validate_url(url: str) -> str:
    """ADR 0001 decision 3. `ext::sh -c ...` executes an arbitrary command and a leading
    '-' is parsed by git as an option; an allowlisted scheme reaches neither."""
    if url.startswith("-"):
        raise Failed(f"refusing template URL starting with '-' (git would parse it as an "
                     f"option): {url}")
    if "::" in url:
        raise Failed(f"refusing template URL using a git transport helper ('::'), which "
                     f"can execute arbitrary commands: {url}")
    if not url.startswith(ALLOWED_URL_SCHEMES):
        raise Failed(f"refusing template URL {url}: scheme not allowed "
                     f"(permitted: {', '.join(ALLOWED_URL_SCHEMES)})")
    return url


def resolve_ref(url: str, ref: str, allow_mutable: bool, cwd: Path) -> tuple[str, str]:
    """Resolve `ref` to an immutable commit SHA. Returns (sha, kind).

    ADR 0001 decision 1: a branch is a moving target, and this tool fetches code it then
    executes. Branches are refused unless the caller opts in explicitly."""
    if len(ref) == 40 and all(c in "0123456789abcdef" for c in ref.lower()):
        return ref.lower(), "commit"
    p = run_cmd(["git", "ls-remote", "--tags", "--heads", "--", url, ref],
                cwd=cwd, capture=True)
    if p.returncode != 0:
        raise Failed(f"git ls-remote of {url} failed:\n{(p.stderr or '').strip()}")
    tag_sha = branch_sha = None
    for line in (p.stdout or "").splitlines():
        found, _, name = line.partition("\t")
        name = name.strip()
        if name.endswith("^{}"):          # dereferenced annotated tag
            name = name[:-3]
        if name == f"refs/tags/{ref}":
            tag_sha = found.strip()
        elif name == f"refs/heads/{ref}":
            branch_sha = found.strip()
    if tag_sha:
        return tag_sha, "tag"
    if branch_sha:
        if not allow_mutable:
            raise Failed(
                f"'{ref}' is a branch, i.e. a mutable ref — refusing to fetch and execute "
                f"code from a moving target (ADR 0001 decision 1). Pass a tag or a commit "
                f"SHA, or re-run with --allow-mutable-ref to accept {branch_sha[:12]} "
                f"explicitly.")
        return branch_sha, "branch"
    raise Failed(f"ref '{ref}' not found in {url} as either a tag or a branch")


def validate_template_checkout(src: Path, label: str) -> None:
    """A source must carry both canonical sources and the scripts the gate runs.

    render.py in particular: python exits 2 when it cannot open a file, and exit 2 from
    render otherwise means "adopter files collide", so a template missing render.py used
    to surface as a collision refusal naming no real conflict."""
    missing = [rel for rel in ("agent-framework/canonical",
                               "scripts/agent-framework/render.py")
               if not (src / rel).exists()]
    if missing:
        raise Failed(f"{label} does not look like a template checkout "
                     f"(missing: {', '.join(missing)})")


def acquire_source(args, workdir: Path, prior: dict) -> tuple[Path, str, str | None]:
    if args.from_path:
        src = Path(args.from_path).expanduser().resolve()
        if not (src / "agent-framework" / "canonical").is_dir():
            raise Failed(f"--from {src} does not look like a template checkout "
                         "(no agent-framework/canonical/)")
        # A re-exec hands the template's updater --from <fetched source>, which would
        # otherwise drop the provenance of the fetch that just happened. The parent
        # passes the resolved commit through the environment so it still gets recorded.
        return src, f"local:{src}", os.environ.get("AF_SOURCE_COMMIT") or None

    url = validate_url(args.url or os.environ.get("AF_TEMPLATE_URL")
                       or prior.get("source_url") or DEFAULT_TEMPLATE_URL)
    # Falling back to the recorded source_commit makes a bare re-run reproducible.
    ref = args.ref or os.environ.get("AF_TEMPLATE_REF") or prior.get("source_commit")
    if not ref:
        raise Failed(
            "no template ref given and none recorded from a previous update. Pass "
            "--ref <tag|commit-sha> — ADR 0001 decision 1 removed the implicit 'main' "
            "default, because it made every update fetch and execute whatever happened "
            "to be on that branch.")

    require_signed = os.environ.get("AF_REQUIRE_SIGNED_TAG") == "1"
    sha_, kind = resolve_ref(url, ref, args.allow_mutable_ref, workdir)
    if require_signed and kind != "tag":
        raise Failed(f"AF_REQUIRE_SIGNED_TAG=1 but '{ref}' resolved to a {kind}, not a "
                     f"tag — unattended runs must verify a signature (ADR 0001 "
                     f"decision 2).")
    if kind == "branch":
        log(f"WARNING: '{ref}' is a mutable branch — pinned to {sha_[:12]} for this run")

    dest = workdir / "template"
    dest.mkdir(parents=True, exist_ok=True)
    log(f"fetching template {url} @ {ref} ({sha_[:12]}) ...")
    for cmd in (["git", "init", "-q"], ["git", "remote", "add", "origin", "--", url]):
        p = run_cmd(cmd, cwd=dest, capture=True)
        if p.returncode != 0:
            raise Failed(f"{' '.join(cmd)} failed:\n{(p.stderr or '').strip()}")

    fetch = ["git", "fetch", "--depth", "1", "origin"]
    fetch += [f"refs/tags/{ref}:refs/tags/{ref}"] if kind == "tag" else [sha_]
    p = run_cmd(fetch, cwd=dest, capture=True)
    if p.returncode != 0:
        raise Failed(f"git fetch of {ref} from {url} failed:\n{(p.stderr or '').strip()}")

    if require_signed:
        v = run_cmd(["git", "verify-tag", "--", ref], cwd=dest, capture=True)
        if v.returncode != 0:
            raise Failed(f"signature verification failed for tag '{ref}' with "
                         f"AF_REQUIRE_SIGNED_TAG=1:\n{(v.stderr or '').strip()}")
        log(f"  signature verified for tag {ref}")

    co = run_cmd(["git", "checkout", "-q", "--detach", sha_], cwd=dest, capture=True)
    if co.returncode != 0:
        raise Failed(f"checkout of {sha_} failed:\n{(co.stderr or '').strip()}")
    # An ANNOTATED tag (which is what a signed tag is) resolves to a tag OBJECT, not a
    # commit — and `git ls-remote <url> <pattern>` omits the `^{}` dereferenced line that
    # would give the commit, so `sha_` above is the tag object. HEAD after checkout is
    # the commit, so comparing the two raw values rejects every signed tag. Dereference
    # locally before comparing; `^{commit}` is a no-op for a lightweight tag or a SHA.
    deref = run_cmd(["git", "rev-parse", f"{sha_}^{{commit}}"], cwd=dest, capture=True)
    expected = (deref.stdout or "").strip()
    if deref.returncode != 0 or not expected:
        raise Failed(f"could not resolve {ref} ({sha_[:12]}) to a commit:\n"
                     f"{(deref.stderr or '').strip()}")
    head = run_cmd(["git", "rev-parse", "HEAD"], cwd=dest, capture=True)
    got = (head.stdout or "").strip()
    if got != expected:
        raise Failed(f"fetched tree is at {got}, expected {expected} "
                     f"(from {ref} @ {sha_[:12]}) — refusing to continue")

    # Validate the fetched tree the same way --from is validated. Without this, a
    # malformed template surfaces as a bogus collision refusal: python exits 2 when it
    # cannot open render.py, and exit 2 from render is otherwise read as "adopter files
    # collide" — reporting a conflict that does not exist.
    validate_template_checkout(dest, f"{url}@{ref}")

    # Record the COMMIT, not the tag object: it is what a later bare re-run re-fetches.
    return dest.resolve(), f"{url}@{ref} ({expected[:12]})", expected


def maybe_reexec(source: Path, target: Path, argv: list[str],
                 source_commit: str | None = None):
    """Run the TEMPLATE's updater when it differs from this one, so an outdated
    installed copy can never drive an upgrade."""
    if os.environ.get("AF_UPDATE_REEXEC") == "1":
        return
    theirs = source / "scripts" / "agent-framework" / "update-framework.py"
    mine = Path(__file__).resolve()
    if not theirs.is_file() or file_sha(theirs) == file_sha(mine) or theirs.resolve() == mine:
        return
    log("template ships a newer updater — re-executing it")
    keep, skip_next = [], False
    for a in argv:
        if skip_next:
            skip_next = False
            continue
        if a in ("--from", "--ref", "--url", "--target"):
            skip_next = True
            continue
        if a.startswith(("--from=", "--ref=", "--url=", "--target=")):
            continue
        keep.append(a)
    env = dict(os.environ, AF_UPDATE_REEXEC="1")
    if source_commit:
        env["AF_SOURCE_COMMIT"] = source_commit
    os.execve(sys.executable, [sys.executable, str(theirs),
                               "--from", str(source), "--target", str(target), *keep], env)


def verify(target: Path, rep: Report) -> None:
    """Full gate. Every command's real exit code is reported — never summarized away."""
    steps = [
        ("render (write)", [sys.executable, "scripts/agent-framework/render.py"]),
        ("render --check", [sys.executable, "scripts/agent-framework/render.py", "--check"]),
        ("validate", [sys.executable, "scripts/agent-framework/validate.py"]),
        ("check-drift", [sys.executable, "scripts/agent-framework/check-drift.py"]),
        ("unit tests", [sys.executable, "-m", "unittest", "discover",
                        "-s", "tests/agent-framework", "-t", "."]),
        ("evals", [sys.executable, "scripts/agent-framework/evals/run-evals.py",
                   "--report", "agent-framework/evals/results.md"]),
    ]
    failures = []
    for name, cmd in steps:
        if name.startswith("unit tests") and not (target / "tests" / "agent-framework").is_dir():
            continue
        log(f"  → {name}")
        p = run_cmd(cmd, target, capture=True)
        if p.returncode != 0:
            tail = ((p.stdout or "") + (p.stderr or "")).strip().splitlines()[-25:]
            failures.append(f"{name} exited {p.returncode}:\n    " + "\n    ".join(tail))
        if name == "render (write)" and p.returncode == 2:
            raise Refused("render refused: pre-existing provider files collide")
    if failures:
        raise Failed("verification failed:\n\n" + "\n\n".join(failures))


# ---------------------------------------------------------------- main

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="from_path", metavar="DIR",
                    help="local template checkout to sync from (skips cloning; offline)")
    ap.add_argument("--ref", metavar="REF",
                    help="template git tag or commit SHA to fetch (env AF_TEMPLATE_REF). "
                         "No default: falls back to the source_commit recorded by the "
                         "previous update. Branches require --allow-mutable-ref.")
    ap.add_argument("--url", metavar="URL",
                    help=f"template repository URL (default: {DEFAULT_TEMPLATE_URL}; "
                         "env AF_TEMPLATE_URL)")
    ap.add_argument("--target", metavar="DIR", default=os.getcwd(),
                    help="repository to update (default: current directory)")
    ap.add_argument("--allow-mutable-ref", action="store_true",
                    help="accept a branch as --ref (ADR 0001 decision 1: branches are "
                         "refused by default because this tool executes fetched code)")
    ap.add_argument("--adopt", action="store_true",
                    help="take over locally modified framework/CI files after backing "
                         "each up to <name>.bak-pre-framework")
    ap.add_argument("--retire-legacy", action="store_true",
                    help="delete superseded pre-v1.1.0 files whose bytes still match the "
                         "template baseline (modified ones are always kept)")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the verification gate (render still runs)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan and change nothing")
    return ap


def summarize(rep: Report, target: Path, source_desc: str, version: str) -> None:
    log("")
    log("=" * 72)
    log(f"agent framework {version} — {'PLAN (dry run)' if rep.dry_run else 'update complete'}")
    log(f"source: {source_desc}")
    log(f"target: {target}")
    log("=" * 72)
    for label, items in (("installed", rep.installed), ("updated", rep.updated),
                         ("adopted (backed up)", rep.adopted), ("removed", rep.removed),
                         ("project setup", rep.scaffolded)):
        if not items:
            continue
        log(f"\n{label}: {len(items)}")
        for x in items[:12]:
            log(f"  {x}")
        if len(items) > 12:
            log(f"  … and {len(items) - 12} more")
    if rep.legacy:
        log("\nsuperseded legacy files:")
        for x in rep.legacy:
            log(f"  {x}")
    if rep.warnings:
        log("\nnotes:")
        for x in rep.warnings:
            log(f"  {x}")
    if not any((rep.installed, rep.updated, rep.adopted, rep.removed, rep.scaffolded)):
        log("\nalready up to date — nothing changed.")


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    args = build_parser().parse_args(argv)
    real_target = Path(args.target).expanduser().resolve()
    rep = Report(args.dry_run)
    # ADR 0001 decision 5: a --dry-run's writes land on a disposable copy (see below),
    # so nothing needs undoing there. Only a real run journals its mutations.
    journal = Journal()
    set_journal(None if args.dry_run else journal)

    try:
        if not real_target.is_dir():
            raise Failed(f"--target {real_target} does not exist")
        if (real_target / SOURCE_MARKER).exists():
            raise Failed(
                f"{real_target} IS the framework source template — it is edited here and "
                "rendered with render.py, never synced onto itself. Run this in an "
                "adopting repository (or pass --target).")

        prior = load_payload_manifest(real_target)
        workdir = Path(tempfile.mkdtemp(prefix="af-update-"))
        try:
            source, source_desc, source_commit = acquire_source(args, workdir, prior)
            maybe_reexec(source, real_target, argv, source_commit)

            version = (source / "agent-framework" / "VERSION").read_text(encoding="utf-8").strip()
            log(f"agent framework {version} → {real_target}")

            # ADR 0001 decision 5: --dry-run shares the real apply-and-render flow rather
            # than reimplementing render.py's collision rule (which would drift from it).
            # It runs the ENTIRE mutation flow, including render, against a disposable
            # copy of the target, so a refusal render.py would raise is actually raised
            # here and reported — not merely predicted.
            if args.dry_run:
                log("(dry run — the plan below comes from running the real update against "
                    "a disposable copy; this repository is not modified)")
                preview = workdir / "preview"
                shutil.copytree(real_target, preview, symlinks=True,
                                ignore=shutil.ignore_patterns(".git"))
                work_target = preview
            else:
                if not (real_target / ".git").exists():
                    rep.note(f"{real_target} is not a git repository — you lose `git diff`"
                             "/revert as a safety net (file backups are still written)")
                work_target = real_target

            set_target_root(work_target)   # ADR 0001 decision 3: pin containment before any write

            installed_from = prior.get("template", "(first install)")
            if prior.get("framework_version"):
                log(f"currently installed: {prior['framework_version']} from {installed_from}")

            log("syncing framework payload ...")
            new_files = sync_payload(source, work_target, prior, args.adopt, rep)
            new_scaffold = sync_scaffold(source, work_target, prior, args.adopt, rep)

            log("checking project setup ...")
            for name in ("AGENTS.md", "CLAUDE.md"):
                ensure_markers(work_target, name, rep)
            ensure_gitignore(work_target, rep)
            ensure_candidates(work_target, rep)
            ensure_project_yaml(work_target, rep)
            ensure_project_scaffold(source, work_target, rep)
            ensure_research_dir(work_target, rep)
            merge_claude_permissions(source, work_target, rep)
            handle_legacy(work_target, args.retire_legacy, rep)

            # Deterministic hook for the rollback regression test: forces a failure after
            # every pre-render mutation above has landed, so the test can assert the
            # journal restores all of them (writes AND deletions) rather than a subset.
            if os.environ.get("AF_UPDATE_TEST_FORCE_FAILURE") == "1":
                raise Failed("injected failure (AF_UPDATE_TEST_FORCE_FAILURE=1) — test-only, "
                             "used to exercise the rollback path")

            write_file(work_target / PAYLOAD_MANIFEST,
                       (json.dumps({"framework_version": version,
                                    "template": source_desc if not args.from_path else "local checkout",
                                    "source_url": args.url or os.environ.get("AF_TEMPLATE_URL")
                                    or prior.get("source_url") or DEFAULT_TEMPLATE_URL,
                                    "source_commit": source_commit or prior.get("source_commit"),
                                    "files": dict(sorted(new_files.items())),
                                    "scaffold": dict(sorted(new_scaffold.items()))},
                                   indent=2) + "\n").encode("utf-8"))

            log("rendering provider artifacts ...")
            p = run_cmd([sys.executable, "scripts/agent-framework/render.py"]
                        + (["--adopt"] if args.adopt else []), work_target, capture=True)
            if p.returncode == 2:
                log((p.stdout or "") + (p.stderr or ""))
                rep.conflicts = ["(see the render.py list above)"]
                raise Refused("render refused: pre-existing provider files collide")
            if p.returncode != 0:
                raise Failed("render.py failed:\n" + ((p.stdout or "") + (p.stderr or "")).strip())
            log("  " + (p.stdout or "").strip().splitlines()[-1])

            # A dry run predicts the plan through render (where the real refusal lives)
            # and stops there: the unit tests/evals phase is too slow to pay for twice,
            # and the render outcome is the part decision 5 requires to be trustworthy.
            if not args.no_verify and not args.dry_run:
                log("verifying ...")
                verify(work_target, rep)

            summarize(rep, real_target, source_desc, version)
            log("")
            if args.dry_run:
                log("re-run without --dry-run to apply.")
            elif args.no_verify:
                log("NOT VERIFIED (--no-verify). Run ./scripts/ci.sh before committing.")
            else:
                log("all gates green: render, validate, drift, unit tests, evals.")
            if not args.dry_run:
                log("Review `git diff`, then commit. Provider-side one-time setup (Codex "
                    "trust, Kimi permission profile) is documented in "
                    "agent-framework/reports/migration-guide.md.")
            return 0
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    except Refused as e:
        if not args.dry_run:
            journal.rollback()
        log("")
        log(f"REFUSED — {e}")
        if rep.conflicts:
            log("\nThese files exist and are neither framework-owned nor byte-identical:")
            for c in rep.conflicts:
                log(f"  {c}")
        log("\nReview each one. Content you need must be moved somewhere the framework does "
            "not own (project-local files, or preserved keys such as opencode.json's "
            "non-permission keys). Then re-run with --adopt: every file is copied to "
            "<name>.bak-pre-framework before being taken over.")
        return 2
    except Failed as e:
        if not args.dry_run:
            journal.rollback()
        log("")
        log(f"ERROR — {e}")
        return 1
    except Exception:
        if not args.dry_run:
            journal.rollback()
        raise


if __name__ == "__main__":
    sys.exit(main())
