#!/usr/bin/env python3
"""Detect drift between canonical sources and generated provider files.

Three checks:
  1. Re-render: every generated file/managed block must byte-match a fresh render
     of the canonical sources (same as `render.py --check`).
  2. Manifest integrity: agent-framework/generated-manifest.json hashes must match
     the files on disk (catches manual edits to generated files).
  3. Stray-file scan: files inside fully-generated role/skill/rule directories that
     are not in the manifest are classified by the EXACT framework marker string.
     A marker-carrying (generated-looking) unmanifested file is stale framework
     output that could be mistaken for managed content — it FAILS the drift check
     (verification finding 8, CXR-015/KF-M17). A markerless file is classified
     project-owned and reported as a warning only.

Exit 0 = no drift. Exit 1 = drift (fix by editing canonical sources and running
`python3 scripts/agent-framework/render.py`, never by editing generated files).
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from _lib import FRAMEWORK_DIR, REPO_ROOT  # noqa: E402

spec = importlib.util.spec_from_file_location("af_render", HERE / "render.py")
af_render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(af_render)


def main() -> int:
    failed = False

    # 1) canonical -> rendered comparison
    renderer = af_render.Renderer()
    if renderer.check() != 0:
        failed = True

    # 2) manifest vs disk
    mpath = FRAMEWORK_DIR / "generated-manifest.json"
    if not mpath.exists():
        print("DRIFT: generated-manifest.json missing — run render.py")
        return 1
    manifest = json.loads(mpath.read_text(encoding="utf-8"))
    for rel, entry in manifest["files"].items():
        p = REPO_ROOT / rel
        if not p.exists():
            print(f"DRIFT: {rel} in manifest but missing on disk")
            failed = True
            continue
        if entry["mode"] == "full":
            actual = hashlib.sha256(p.read_bytes()).hexdigest()
        elif entry["mode"] == "json-keys":
            # Only the generated top-level keys are hashed; every other key in the
            # file is project-owned and preserved by render.py (e.g. opencode.json
            # provider blocks — review finding CXR-014/KF-H09).
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
                subset = {k: data.get(k) for k in entry["keys"]}
                actual = hashlib.sha256((json.dumps(subset, indent=2) + "\n").encode()).hexdigest()
            except json.JSONDecodeError:
                print(f"DRIFT: {rel} is not valid JSON")
                failed = True
                continue
        else:  # managed block
            text = p.read_text(encoding="utf-8")
            begin, end = manifest["marker_begin"], manifest["marker_end"]
            b_marker = begin.split(" — ")[0]
            try:
                start = text.index(b_marker)
                start = text.index("\n", start) + 1
                stop = text.index(end)
            except ValueError:
                print(f"DRIFT: {rel} managed markers missing")
                failed = True
                continue
            block = text[start:stop]
            actual = hashlib.sha256(block.rstrip("\n").encode() + b"\n").hexdigest()
        if actual != entry["sha256"]:
            print(f"DRIFT: {rel} was edited after generation (hash mismatch) — edit canonical instead")
            failed = True

    # 3) stray files in fully-generated directories (extended coverage: rules dirs
    #    and all skill files, not only SKILL.md — review findings CXR-015/KF-M17/KF-M18).
    #    Unmanifested files carrying an EXACT framework marker are stale generated
    #    output and FAIL the check; markerless files are project-owned and warn only
    #    (verification finding 8).
    generated = set(manifest["files"])
    for d in (".claude/agents", ".codex/agents", ".kimi-code/agents", ".opencode/agents",
              ".aiassistant/rules", ".claude/rules"):
        root = REPO_ROOT / d
        if not root.exists():
            continue
        for f in sorted(root.rglob("*")):
            rel = f.relative_to(REPO_ROOT).as_posix()
            if f.is_file() and rel not in generated and not rel.endswith(".bak-pre-framework"):
                if af_render.has_framework_marker(f):
                    print(f"DRIFT: unmanifested generated-looking file: {rel} — stale framework "
                          f"output; delete it or re-render (it is NOT managed by the manifest)")
                    failed = True
                else:
                    print(f"WARN: unmanaged file in generated directory: {rel} "
                          f"(project-local additions belong in canonical/ or must be documented)")
    for d in (".agents/skills", ".claude/skills"):
        root = REPO_ROOT / d
        if not root.exists():
            continue
        for f in sorted(root.rglob("*")):
            rel = f.relative_to(REPO_ROOT).as_posix()
            if f.is_file() and rel not in generated and not rel.endswith(".bak-pre-framework"):
                if af_render.has_framework_marker(f):
                    print(f"DRIFT: unmanifested generated-looking file: {rel} — stale framework "
                          f"output; delete it or re-render (it is NOT managed by the manifest)")
                    failed = True
                else:
                    print(f"WARN: project-local skill file not managed by the framework: {rel}")

    if failed:
        print("\ncheck-drift: DRIFT DETECTED")
        return 1
    print("\ncheck-drift: OK — generated files match canonical sources and manifest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
