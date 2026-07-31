# Claude Agent Instructions

Read and follow `AGENTS.md` as the primary repository instruction file before
planning, editing, running commands, or reviewing code.

The following are additional Claude-specific constraints:

- Use Plan mode before repository-wide or architectural changes.
- Do not expand a bounded task into a repository rewrite.
- Ask before adding dependencies, changing public APIs, modifying packaging, or
  executing system-wide commands.
- Prefer focused diffs and focused test execution.
- Report changed files, executed commands, actual results, remaining risks, and
  unresolved uncertainty.

<!-- AGENT-FRAMEWORK:BEGIN — GENERATED from agent-framework/canonical/. Do not edit inside this block; edit canonical sources and run: python3 scripts/agent-framework/render.py -->
@AGENTS.md

## Claude Code specifics (generated)

- Framework roles are installed as subagents in `.claude/agents/` (generated from `agent-framework/canonical/roles/`). Delegate through them; the orchestrator pattern and task contract apply.
- Plan-first triggers are defined once in the autonomy policy (digest in the AGENTS.md managed block imported above). Routine bounded edits need no plan phase.
- `.claude/settings.json` permissions enforce the security policy (no force-push, no secret reads). Do not weaken them without approval; validate.py pins the security-critical subset.
- Skills live in `.claude/skills/` (generated). Load only domain skills relevant to the task.
<!-- AGENT-FRAMEWORK:END -->
