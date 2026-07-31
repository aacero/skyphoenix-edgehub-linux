#!/usr/bin/env python3
"""Validate the agent framework: canonical structure, role/skill/persona/workflow
contracts, catalogs consistency, spec compliance of skills, provider adapter
presence, GENERATED-ARTIFACT PARSE GATE (every generated agent/TOML/JSON artifact
must parse with a standards-compliant parser), security-critical permission
pinning, and basic secret hygiene.

Exit 0 = valid (warnings allowed). Exit 1 = violations. Dependency: PyYAML.
"""
from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _lib import FRAMEWORK_DIR, REPO_ROOT  # noqa: E402

try:
    import yaml
except ImportError:
    print("validate.py requires PyYAML", file=sys.stderr)
    sys.exit(2)

CANON = FRAMEWORK_DIR / "canonical"
ERRORS: list[str] = []
WARNINGS: list[str] = []

ROLE_KEYS = ["id", "title", "purpose", "decision_role", "invoke_when", "do_not_invoke_when",
             "inputs", "outputs", "permitted_tools", "prohibited_actions", "write_ownership",
             "read_only", "collaboration_boundaries", "acceptance_criteria", "stopping_condition",
             "handover_format", "task_weight", "model_class", "fallback_model_class",
             "skills_default", "notes"]
DECISION_ROLES = {"orchestrator", "advisor", "builder", "reviewer", "researcher", "simulator"}
TOOLS = {"read", "search", "edit", "bash", "bash-readonly", "web", "delegate"}
MODEL_CLASSES = {"premium", "standard", "economy"}
MODEL_TIER_ORDER = {"economy": 0, "standard": 1, "premium": 2}
TASK_WEIGHTS = {"trivial", "light", "standard", "heavy"}
WRITE_OWNERSHIP = {"none", "task-assigned", "reports-only"}
SKILL_FM_KEYS = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
MATRIX_STATUSES = {"supported", "supported-through-adapter", "experimental", "unsupported", "unknown"}

# Security-critical permission subset: weakening any of these must fail CI
# (review finding CXR-013/KF-H12; owner decisions D2/D4 — pin, don't generate).
REQUIRED_CLAUDE_DENY = [
    "Read(./.env)",
    "Read(./secrets/**)",
    "Read(./credentials/**)",
    "Bash(git push --force *)",
    "Bash(git push -f *)",
]
REQUIRED_CLAUDE_ASK = [
    "Bash(git reset --hard *)",
    "Bash(rm -rf *)",
]
REQUIRED_OPENCODE_BASH_DENY = ["git push --force*", "git push -f*"]
REQUIRED_KIMI_DENY_PATTERNS = ["Bash(git push --force*)", "Bash(git push -f*)", "Read(**/.env*)"]

# Advisory scan only — CI should additionally run a maintained scanner (gitleaks or
# trufflehog); documented in the security review. Patterns cover common token shapes
# including unquoted assignments.
SECRET_PATTERNS = [
    re.compile(r"(?i)(api[_-]?key|secret|token|passwd|password)\s*[:=]\s*['\"]?[A-Za-z0-9+/_\-]{16,}"),
    re.compile(r"\bsk-(proj-)?[A-Za-z0-9_\-]{20,}"),
    re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}"),
    re.compile(r"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]


def err(msg):
    ERRORS.append(msg)


def warn(msg):
    WARNINGS.append(msg)


def read_text_checked(path: Path, context: str) -> str | None:
    """Guarded read: a missing file is a clean validation error, not a traceback
    (review finding KF-L45)."""
    try:
        return path.read_text(encoding="utf-8")
    except OSError as e:
        err(f"{context}: cannot read {path.relative_to(REPO_ROOT) if path.is_absolute() else path}: {e}")
        return None


def split_frontmatter(text: str) -> str | None:
    m = re.match(r"\A---\s*\n(.*?)\n---\s*\n", text, re.S)
    return m.group(1) if m else None


def check_structure():
    required = [
        CANON / "core-instructions.md",
        *(CANON / "policies" / f"{n}.md" for n in
          ("autonomy-policy", "delegation-policy", "evidence-policy", "research-policy",
           "scope-control-policy", "security-policy")),
        *(CANON / "contracts" / f"{n}.md" for n in
          ("agent-task-contract", "agent-handover-contract", "definition-of-done-contract")),
        FRAMEWORK_DIR / "schemas" / "autonomous-run.schema.json",
        FRAMEWORK_DIR / "schemas" / "run-state.schema.json",
        FRAMEWORK_DIR / "catalogs" / "provider-capability-matrix.yaml",
        FRAMEWORK_DIR / "design-system" / "tokens" / "base.json",
        FRAMEWORK_DIR / "design-system" / "references" / "source-ledger.md",
        # Adoption/upgrade path for downstream repositories: the updater installs this
        # workflow, so a missing asset would silently disable auto-updates everywhere.
        FRAMEWORK_DIR / "templates" / "framework-update.yml",
        FRAMEWORK_DIR / "reports" / "migration-guide.md",
    ]
    for p in required:
        if not p.exists():
            err(f"missing required file: {p.relative_to(REPO_ROOT)}")
    for shim in ("provider-claude.sh", "provider-codex.sh", "provider-kimi.sh", "provider-opencode.sh",
                 "run-autonomous-session.py", "render.py", "check-drift.py", "update-framework.py"):
        p = Path(__file__).parent / shim
        if not p.exists():
            err(f"missing script: scripts/agent-framework/{shim}")


def check_roles() -> set[str]:
    ids = set()
    role_meta: dict[str, dict] = {}
    for p in sorted((CANON / "roles").glob("*.yaml")):
        r = yaml.safe_load(p.read_text(encoding="utf-8"))
        rel = p.relative_to(REPO_ROOT)
        missing = [k for k in ROLE_KEYS if k not in r]
        if missing:
            err(f"{rel}: missing keys {missing}")
            continue
        ids.add(r["id"])
        role_meta[r["id"]] = r
        if r["id"] != p.stem:
            err(f"{rel}: id '{r['id']}' != filename")
        if r["decision_role"] not in DECISION_ROLES:
            err(f"{rel}: bad decision_role {r['decision_role']}")
        bad_tools = set(r["permitted_tools"]) - TOOLS
        if bad_tools:
            err(f"{rel}: unknown tools {bad_tools}")
        if r["model_class"] not in MODEL_CLASSES or r["fallback_model_class"] not in MODEL_CLASSES:
            err(f"{rel}: bad model class")
        elif MODEL_TIER_ORDER[r["fallback_model_class"]] > MODEL_TIER_ORDER[r["model_class"]]:
            # Fallback is availability-only and must be same-or-lower tier
            # (review finding KF-L23; delegation policy).
            err(f"{rel}: fallback_model_class '{r['fallback_model_class']}' exceeds "
                f"model_class '{r['model_class']}' (fallback must be same-or-lower tier)")
        if r["task_weight"] not in TASK_WEIGHTS:
            err(f"{rel}: bad task_weight")
        if r["write_ownership"] not in WRITE_OWNERSHIP:
            err(f"{rel}: bad write_ownership {r['write_ownership']}")
        if r["read_only"]:
            if "edit" in r["permitted_tools"]:
                err(f"{rel}: read_only role has 'edit' tool")
            if r["write_ownership"] == "task-assigned":
                err(f"{rel}: read_only role with task-assigned ownership")
            if not any("edit" in str(x).lower() for x in r["prohibited_actions"]):
                warn(f"{rel}: read_only role without explicit edit prohibition")
        for k in ("invoke_when", "do_not_invoke_when", "inputs", "outputs", "prohibited_actions",
                  "collaboration_boundaries", "acceptance_criteria"):
            if not r[k]:
                err(f"{rel}: empty {k}")
            for x in r[k]:
                if isinstance(x, dict):
                    warn(f"{rel}: {k} bullet parsed as dict (unquoted 'Key: value') — renderer normalizes, but quote it")
        if r["permitted_tools"] and "delegate" in r["permitted_tools"] and r["id"] != "orchestrator":
            err(f"{rel}: non-orchestrator role has the 'delegate' tool")
    cat = yaml.safe_load((FRAMEWORK_DIR / "catalogs" / "role-catalog.yaml").read_text(encoding="utf-8"))
    cat_ids = {x["id"] for x in cat["roles"]}
    if cat_ids != ids:
        err(f"role-catalog.yaml out of sync: only-in-catalog={sorted(cat_ids - ids)}, only-in-files={sorted(ids - cat_ids)}")
    # Field-level catalog sync (review finding KF-L10): the catalog is what
    # orchestrators read — its metadata must match canonical.
    for entry in cat["roles"]:
        r = role_meta.get(entry["id"])
        if not r:
            continue
        for field in ("read_only", "model_class", "decision_role"):
            if field in entry and entry[field] != r[field]:
                err(f"role-catalog.yaml: {entry['id']}.{field}={entry[field]!r} diverges from "
                    f"canonical {r[field]!r}")
        if not str(entry.get("summary", "")).strip():
            warn(f"role-catalog.yaml: {entry['id']} has no summary (used as subagent description)")
    return ids


def check_skills() -> set[str]:
    dirs = {p.name for p in (CANON / "skills").iterdir() if p.is_dir()}
    for name in sorted(dirs):
        skill_md = CANON / "skills" / name / "SKILL.md"
        rel = skill_md.relative_to(REPO_ROOT)
        if not skill_md.exists():
            err(f"{rel}: missing SKILL.md")
            continue
        text = skill_md.read_text(encoding="utf-8")
        fm_text = split_frontmatter(text)
        fm = yaml.safe_load(fm_text) if fm_text else None
        if not isinstance(fm, dict):
            err(f"{rel}: no valid frontmatter")
            continue
        if fm.get("name") != name:
            err(f"{rel}: frontmatter name '{fm.get('name')}' != directory '{name}' (open spec requires match)")
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", str(fm.get("name", ""))) or len(str(fm.get("name", ""))) > 64:
            err(f"{rel}: name violates open-spec pattern")
        desc = str(fm.get("description", ""))
        if not desc or len(desc) > 1024:
            err(f"{rel}: description empty or >1024 chars")
        extra = set(fm) - SKILL_FM_KEYS
        if extra:
            err(f"{rel}: non-open-spec frontmatter keys {sorted(extra)} (provider-specific fields are not portable)")
        if len(text.splitlines()) > 500:
            err(f"{rel}: SKILL.md exceeds 500 lines (open-spec guidance)")
    cat = yaml.safe_load((FRAMEWORK_DIR / "catalogs" / "skill-catalog.yaml").read_text(encoding="utf-8"))
    cat_ids = {s["id"] for s in cat["skills"]}
    if cat_ids != dirs:
        err(f"skill-catalog.yaml out of sync: only-in-catalog={sorted(cat_ids - dirs)}, only-in-dirs={sorted(dirs - cat_ids)}")
    default = set(cat.get("default_install", []))
    bad_defaults = default - dirs
    if bad_defaults:
        err(f"default_install references missing skills: {sorted(bad_defaults)}")
    domain = {s["id"] for s in cat["skills"] if s.get("kind") == "domain"}
    if domain & default:
        err(f"domain skills must not be default_install: {sorted(domain & default)}")
    for s in cat["skills"]:
        flag = s.get("default_install")
        if flag is not None and bool(flag) != (s["id"] in default):
            err(f"skill-catalog.yaml: {s['id']}.default_install={flag} contradicts the "
                f"top-level default_install list")
    return cat_ids


def check_role_skill_refs(skill_ids: set[str]):
    """Role skills_default entries must exist in the skill catalog (KF-L10)."""
    for p in sorted((CANON / "roles").glob("*.yaml")):
        r = yaml.safe_load(p.read_text(encoding="utf-8"))
        for s in r.get("skills_default") or []:
            if s not in skill_ids:
                err(f"{p.relative_to(REPO_ROOT)}: skills_default references unknown skill '{s}'")


def check_personas():
    ids = set()
    for p in sorted((CANON / "personas").glob("*.yaml")):
        d = yaml.safe_load(p.read_text(encoding="utf-8"))
        rel = p.relative_to(REPO_ROOT)
        for k in ("id", "title", "profile", "goals", "frustrations", "behavior_traits",
                  "probes", "finding_types", "read_only", "prohibited_actions", "output_format"):
            if k not in d:
                err(f"{rel}: missing key {k}")
        if d.get("id") != p.stem:
            err(f"{rel}: id '{d.get('id')}' != filename")
        ids.add(d.get("id"))
        if d.get("read_only") is not True:
            err(f"{rel}: personas must be read_only: true")
        if not any("edit" in str(x).lower() for x in d.get("prohibited_actions", [])):
            err(f"{rel}: personas must prohibit editing product code")
    # Persona catalog sync (review finding CXR-017/KF-M25): the catalog is read by
    # humans/orchestrators and must not drift from the persona files.
    cat_path = FRAMEWORK_DIR / "catalogs" / "persona-catalog.yaml"
    cat = yaml.safe_load(cat_path.read_text(encoding="utf-8")) if cat_path.exists() else None
    if not isinstance(cat, dict) or "personas" not in cat:
        err("persona-catalog.yaml: missing or malformed (no 'personas' key)")
        return
    cat_ids = {x["id"] for x in cat["personas"] if isinstance(x, dict) and "id" in x}
    if cat_ids != ids:
        err(f"persona-catalog.yaml out of sync: only-in-catalog={sorted(cat_ids - ids)}, "
            f"only-in-files={sorted(ids - cat_ids)}")


def check_workflows(role_ids: set[str]):
    expected = {"software-lifecycle", "deep-research", "market-research", "persona-validation",
                "autonomous-session"}
    found = {p.name for p in (CANON / "workflows").iterdir() if p.is_dir()}
    if expected - found:
        err(f"missing workflows: {sorted(expected - found)}")
    wf_ids = set()
    for wf in sorted(found):
        f = CANON / "workflows" / wf / "WORKFLOW.md"
        rel = f.relative_to(REPO_ROOT)
        if not f.exists():
            err(f"{rel}: missing WORKFLOW.md")
            continue
        # Parse frontmatter with a real YAML parser: block lists must be visible so the
        # unknown-role check actually fires (review finding KF-M20).
        fm_text = split_frontmatter(f.read_text(encoding="utf-8"))
        fm = yaml.safe_load(fm_text) if fm_text else None
        if not isinstance(fm, dict):
            err(f"{rel}: no valid frontmatter")
            continue
        for k in ("id", "title", "description", "roles", "entry_criteria", "exit_criteria"):
            if k not in fm:
                err(f"{rel}: frontmatter missing {k}")
        wf_ids.add(fm.get("id"))
        roles = fm.get("roles", [])
        if not isinstance(roles, list) or not roles:
            err(f"{rel}: roles must be a non-empty list")
        else:
            unknown = set(map(str, roles)) - role_ids
            if unknown:
                err(f"{rel}: unknown roles {sorted(unknown)}")
    cat_path = FRAMEWORK_DIR / "catalogs" / "workflow-catalog.yaml"
    cat = yaml.safe_load(cat_path.read_text(encoding="utf-8")) if cat_path.exists() else None
    if not isinstance(cat, dict) or "workflows" not in cat:
        err("workflow-catalog.yaml: missing or malformed (no 'workflows' key)")
    else:
        cat_ids = {x["id"] for x in cat["workflows"] if isinstance(x, dict) and "id" in x}
        unknown = cat_ids - wf_ids
        if unknown:
            err(f"workflow-catalog.yaml lists unknown workflows: {sorted(unknown)}")


ALL_PROVIDERS = ("claude", "codex", "kimi", "opencode", "jetbrains", "generic")
# Providers where 'bash-readonly' has NO mechanical command-class boundary: their
# matrix entry must document the waiver and must never claim full support
# (review finding KF-H08, consolidated H7; owner decision D6).
BASH_READONLY_WAIVER_PROVIDERS = ("claude", "kimi", "jetbrains")


def check_matrix():
    m = yaml.safe_load((FRAMEWORK_DIR / "catalogs" / "provider-capability-matrix.yaml").read_text(encoding="utf-8"))
    for cap, providers in m["capabilities"].items():
        for prov, entry in providers.items():
            if entry["status"] not in MATRIX_STATUSES:
                err(f"capability-matrix: {cap}.{prov} bad status {entry['status']}")
    # H7 (KF-H08): the bash_readonly_enforcement row is the binding record of what
    # is mechanically enforced vs a documented waiver. Removing it, dropping a
    # provider, or falsely strengthening a waiver provider must fail validation.
    row = m["capabilities"].get("bash_readonly_enforcement")
    if not isinstance(row, dict):
        err("capability-matrix: bash_readonly_enforcement row missing — every provider "
            "must document its bash-readonly enforcement level or waiver (KF-H08/H7)")
    else:
        for prov in ALL_PROVIDERS:
            if prov not in row:
                err(f"capability-matrix: bash_readonly_enforcement has no entry for {prov} (KF-H08/H7)")
        for prov in BASH_READONLY_WAIVER_PROVIDERS:
            entry = row.get(prov) or {}
            note = str(entry.get("note", "")).lower()
            if entry.get("status") == "supported":
                err(f"capability-matrix: bash_readonly_enforcement.{prov} claims 'supported' "
                    "but no command-class boundary is mechanically configured on this "
                    "provider — document the waiver honestly instead (KF-H08/H7)")
            elif entry and not ("waiver" in note or "prose" in note):
                err(f"capability-matrix: bash_readonly_enforcement.{prov} must state its "
                    "prose-only waiver explicitly in the note (KF-H08/H7)")
    # KF-M05: model tiering is mechanically applied only by the Claude adapter.
    tier = m["capabilities"].get("model_tiering")
    if not isinstance(tier, dict):
        err("capability-matrix: model_tiering row missing (KF-M05)")
    else:
        for prov, entry in tier.items():
            if prov != "claude" and (entry or {}).get("status") == "supported":
                err(f"capability-matrix: model_tiering.{prov} claims 'supported' but only "
                    "the Claude adapter renders per-role model pins (KF-M05)")
    # Consistency: a provider claimed to support supervised long-running tasks must be
    # accepted by the run schema and have a shim (review finding KF-L02).
    schema = json.loads((FRAMEWORK_DIR / "schemas" / "autonomous-run.schema.json").read_text(encoding="utf-8"))
    enum = set(schema["properties"]["provider"]["enum"])
    for prov, entry in m["capabilities"].get("long_running_tasks", {}).items():
        if entry["status"] in ("supported", "supported-through-adapter"):
            if prov not in enum:
                err(f"capability-matrix: long_running_tasks.{prov} claims {entry['status']} but "
                    f"the run schema provider enum {sorted(enum)} does not accept it")
            elif not (Path(__file__).parent / f"provider-{prov}.sh").exists():
                err(f"capability-matrix: long_running_tasks.{prov} claims {entry['status']} but "
                    f"scripts/agent-framework/provider-{prov}.sh does not exist")


# H9 (KF-H07): every domain skill must carry the research-delegation guidance so
# roles without the `web` tool route official-source lookups through the
# orchestrator to deep-researcher instead of citing from memory.
DOMAIN_SKILL_DELEGATION_PHRASES = (
    "lacks the `web` tool",
    "deep-researcher task via the orchestrator",
    "UNKNOWN",
)


def check_domain_skill_research_delegation():
    cat = yaml.safe_load((FRAMEWORK_DIR / "catalogs" / "skill-catalog.yaml").read_text(encoding="utf-8"))
    for s in cat["skills"]:
        if s.get("kind") != "domain":
            continue
        skill_md = CANON / "skills" / s["id"] / "SKILL.md"
        text = read_text_checked(skill_md, "domain-skill research delegation")
        if text is None:
            continue
        missing = [p for p in DOMAIN_SKILL_DELEGATION_PHRASES if p not in text]
        if missing:
            err(f"canonical/skills/{s['id']}/SKILL.md: research-delegation guidance missing "
                f"or reworded (required phrases absent: {missing}) — every domain skill must "
                "route no-web roles to deep-researcher via the orchestrator (KF-H07/H9)")


def check_canonical_paths():
    """Backtick-quoted repo paths in canonical sources must exist, and canonical text
    must not cite provider-artifact paths (review findings KF-M01/KF-L18).
    The security policy's protected-directory list is the one legitimate exception."""
    provider_prefixes = (".claude/", ".codex/", ".kimi-code/", ".opencode/", ".aiassistant/")
    checked_prefixes = ("agent-framework/", "docs/", "scripts/")
    for f in sorted(CANON.rglob("*")):
        if not f.is_file() or f.suffix not in (".md", ".yaml"):
            continue
        rel = f.relative_to(REPO_ROOT)
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(r"`([^`\s]+)`", text):
            token = m.group(1)
            if any(c in token for c in "<>*{}$()|"):
                continue  # templates/globs/code, not concrete paths
            if token.startswith(provider_prefixes):
                if f.name != "security-policy.md":
                    err(f"{rel}: cites provider-artifact path `{token}` — canonical sources "
                        "must stay provider-neutral (cite canonical policies instead)")
                continue
            if token.startswith(checked_prefixes) and "/" in token:
                if not (REPO_ROOT / token).exists():
                    err(f"{rel}: cites nonexistent path `{token}`")


def check_generated_artifacts():
    """Parse gate (review findings KF-B01/CXR-001/CXR-018): every generated artifact
    must be loadable by a standards-compliant parser. This is the single check that
    prevents the invalid-generated-artifact defect class from shipping green."""
    claude_agents = sorted((REPO_ROOT / ".claude" / "agents").glob("*.md"))
    opencode_agents = sorted((REPO_ROOT / ".opencode" / "agents").glob("*.md"))
    if not claude_agents:
        warn(".claude/agents/ has no generated agents (run render.py)")
    for f in claude_agents + opencode_agents:
        rel = f.relative_to(REPO_ROOT)
        fm_text = split_frontmatter(f.read_text(encoding="utf-8"))
        if fm_text is None:
            err(f"{rel}: missing frontmatter block")
            continue
        try:
            fm = yaml.safe_load(fm_text)
        except yaml.YAMLError as e:
            err(f"{rel}: frontmatter is not valid YAML: {str(e).splitlines()[0]}")
            continue
        if not isinstance(fm, dict) or not str(fm.get("description", "")).strip():
            err(f"{rel}: frontmatter must be a mapping with a non-empty description")
    for f in sorted((REPO_ROOT / ".codex").rglob("*.toml")):
        rel = f.relative_to(REPO_ROOT)
        try:
            tomllib.loads(f.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as e:
            err(f"{rel}: invalid TOML: {e}")
    for name in ("opencode.json", "agent-framework/generated-manifest.json"):
        p = REPO_ROOT / name
        if p.exists():
            try:
                json.loads(p.read_text(encoding="utf-8"))
            except json.JSONDecodeError as e:
                err(f"{name}: invalid JSON: {e}")
    for p in sorted((FRAMEWORK_DIR / "design-system" / "tokens").glob("*.json")):
        try:
            json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            err(f"{p.relative_to(REPO_ROOT)}: invalid JSON: {e}")
    # Kimi permission profile: the embedded TOML block must parse and use only the
    # documented [[permission.rules]] schema (review finding KF-H02).
    readme = REPO_ROOT / ".kimi-code" / "README.md"
    if readme.exists():
        m = re.search(r"```toml\n(.*?)```", readme.read_text(encoding="utf-8"), re.S)
        if not m:
            err(".kimi-code/README.md: permission profile TOML block missing")
        else:
            try:
                prof = tomllib.loads(m.group(1))
                rules = (prof.get("permission") or {}).get("rules") or []
                if not rules:
                    err(".kimi-code/README.md: profile defines no [[permission.rules]]")
                for i, r in enumerate(rules):
                    extra = set(r) - {"decision", "scope", "pattern", "reason"}
                    if extra:
                        err(f".kimi-code/README.md: rule {i} has undocumented keys {sorted(extra)}")
                    if not re.fullmatch(r"[A-Za-z]+(\(.*\))?", str(r.get("pattern", ""))):
                        err(f".kimi-code/README.md: rule {i} pattern {r.get('pattern')!r} is not "
                            "of the documented form ToolName or ToolName(arg-pattern)")
                pats = [r.get("pattern") for r in rules if r.get("decision") == "deny"]
                for req in REQUIRED_KIMI_DENY_PATTERNS:
                    if req not in pats:
                        err(f".kimi-code/README.md: required deny rule missing: {req}")
            except tomllib.TOMLDecodeError as e:
                err(f".kimi-code/README.md: profile TOML invalid: {e}")


def check_permission_pinning():
    """Security-critical permission surfaces are pinned: removing or weakening a
    required rule fails validation (review finding CXR-013/KF-H12, KF-L01)."""
    sp = REPO_ROOT / ".claude" / "settings.json"
    text = read_text_checked(sp, "permission pinning")
    if text is not None:
        try:
            settings = json.loads(text)
            perms = settings.get("permissions") or {}
            deny = perms.get("deny") or []
            ask = perms.get("ask") or []
            allow = perms.get("allow") or []
            for rule in REQUIRED_CLAUDE_DENY:
                if rule not in deny:
                    err(f".claude/settings.json: required deny rule missing: {rule}")
            for rule in REQUIRED_CLAUDE_ASK:
                if rule not in ask and rule not in deny:
                    err(f".claude/settings.json: required ask rule missing (or stricter deny): {rule}")
            for rule in allow:
                if any(tok in str(rule) for tok in ("push --force", "push -f", ".env", "secrets", "credentials")):
                    err(f".claude/settings.json: allow rule undermines a pinned protection: {rule}")
        except json.JSONDecodeError as e:
            err(f".claude/settings.json: invalid JSON: {e}")
    oc = REPO_ROOT / "opencode.json"
    if oc.exists():
        try:
            cfg = json.loads(oc.read_text(encoding="utf-8"))
            bash = ((cfg.get("permission") or {}).get("bash")) or {}
            for pat in REQUIRED_OPENCODE_BASH_DENY:
                if bash.get(pat) != "deny":
                    err(f"opencode.json: required bash deny missing or weakened: {pat!r}")
            if (cfg.get("permission") or {}).get("external_directory") == "allow":
                err("opencode.json: external_directory must not be a blanket allow")
        except json.JSONDecodeError:
            pass  # already reported by the parse gate


ADAPTER_DOC_PATHS = {
    "claude": [".claude/agents/", ".claude/skills/", ".claude/rules/"],
    "codex": [".codex/config.toml", ".codex/agents/"],
    "kimi": [".kimi-code/agents/", ".kimi-code/README.md", ".kimi-code/AGENTS.md"],
    "opencode": [".opencode/agents/", "opencode.json"],
    "jetbrains": [".aiassistant/rules/"],
}


def check_adapter_docs():
    """Adapter documentation must mention every render target it maps — a light
    sync check so provider docs cannot silently drift from the renderer
    (review finding KF-L04)."""
    for prov, needles in ADAPTER_DOC_PATHS.items():
        doc = FRAMEWORK_DIR / "providers" / prov / "adapter.yaml"
        if not doc.exists():
            err(f"missing adapter doc: agent-framework/providers/{prov}/adapter.yaml")
            continue
        text = doc.read_text(encoding="utf-8")
        try:
            yaml.safe_load(text)
        except yaml.YAMLError as e:
            err(f"providers/{prov}/adapter.yaml: invalid YAML: {str(e).splitlines()[0]}")
            continue
        for needle in needles:
            if needle not in text:
                err(f"providers/{prov}/adapter.yaml does not document render target {needle!r}")


def check_managed_files():
    for name in ("AGENTS.md", "CLAUDE.md"):
        text = read_text_checked(REPO_ROOT / name, "managed files")
        if text is None:
            continue
        if "AGENT-FRAMEWORK:BEGIN" not in text or "AGENT-FRAMEWORK:END" not in text:
            err(f"{name}: managed markers missing")
    agents_md = REPO_ROOT / "AGENTS.md"
    if agents_md.exists():
        agents_size = agents_md.stat().st_size
        if agents_size > 24_000:
            err(f"AGENTS.md is {agents_size} bytes — too close to Codex's 32KiB combined project-doc cap")
    gi = read_text_checked(REPO_ROOT / ".gitignore", "managed files")
    if gi is not None:
        for pattern in ("agent-framework/runs/", ".claude/settings.local.json", ".env"):
            if pattern not in gi:
                err(f".gitignore missing: {pattern}")


def check_schemas():
    for p in (FRAMEWORK_DIR / "schemas").glob("*.json"):
        try:
            json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            err(f"{p.relative_to(REPO_ROOT)}: invalid JSON: {e}")


def check_secrets():
    scan_roots = [FRAMEWORK_DIR, REPO_ROOT / ".claude", REPO_ROOT / ".codex", REPO_ROOT / ".kimi-code",
                  REPO_ROOT / ".opencode", REPO_ROOT / ".agents", REPO_ROOT / ".aiassistant"]
    for root in scan_roots:
        if not root.exists():
            continue
        for f in root.rglob("*"):
            if not f.is_file() or f.suffix in {".png", ".jpg", ".svg"} or "runs" in f.parts:
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for pat in SECRET_PATTERNS:
                if pat.search(text):
                    err(f"possible secret in {f.relative_to(REPO_ROOT)} (pattern: {pat.pattern[:40]}...)")
                    break


def main() -> int:
    check_structure()
    role_ids = check_roles()
    skill_ids = check_skills()
    check_role_skill_refs(skill_ids)
    check_personas()
    check_workflows(role_ids)
    check_matrix()
    check_domain_skill_research_delegation()
    check_canonical_paths()
    check_generated_artifacts()
    check_permission_pinning()
    check_adapter_docs()
    check_managed_files()
    check_schemas()
    check_secrets()
    for w in WARNINGS:
        print(f"WARN  {w}")
    for e in ERRORS:
        print(f"ERROR {e}")
    print(f"\nvalidate: {len(ERRORS)} error(s), {len(WARNINGS)} warning(s)")
    return 1 if ERRORS else 0


if __name__ == "__main__":
    sys.exit(main())
