# Provider Research Report — Cross-Provider Agent Framework v1.1.0

- Access date for all findings: **2026-07-18** (research performed via official documentation; individual doc pages rarely display update dates — where shown, noted inline).
- Method: primary official documentation only; secondary sources used solely to locate primaries and flagged as such. Unverifiable items are marked **UNKNOWN**, not guessed.
- Full capability matrix: `agent-framework/catalogs/provider-capability-matrix.yaml`.

## 1. Claude Code (Anthropic)

Primary source set: `https://code.claude.com/docs/en/{memory,skills,sub-agents,hooks,settings,permissions,sandboxing,headless,cli-reference,plugins}` (accessed 2026-07-18; pages display no update dates).

- **Instructions:** Reads `CLAUDE.md` (managed → user `~/.claude/CLAUDE.md` → project `./CLAUDE.md` or `./.claude/CLAUDE.md` → `CLAUDE.local.md`), concatenated not overriding. **Does NOT read AGENTS.md natively** — docs verbatim: "Claude Code reads CLAUDE.md, not AGENTS.md"; the officially documented bridge is a `CLAUDE.md` starting with `@AGENTS.md` (exactly this template's pattern) or a symlink. `@import` syntax recurses up to 4 hops. `.claude/rules/*.md` is officially supported, including `paths:` frontmatter for path-scoped rules and user-level `~/.claude/rules/`.
- **Skills:** `.claude/skills/<name>/SKILL.md`; follows the open Agent Skills standard (agentskills.io) plus Claude-specific extensions (`context: fork`, `paths`, `hooks`, `disable-model-invocation`, `allowed-tools`, `model`, `effort`). Precedence on name conflict: enterprise > personal > project. Slash-command and model-triggered invocation; works headless (`claude -p "/skill args"`). Claude Code does **not** document scanning `.agents/skills/` — project skills must land in `.claude/skills/` (adapter copy required).
- **Subagents:** `.claude/agents/*.md`, frontmatter `name`, `description` (required), `tools`, `disallowedTools`, `model` (`sonnet|opus|haiku|fable|inherit`), `permissionMode`, `maxTurns`, `skills`, `memory`, `isolation: worktree`, `background`. Body replaces the system prompt.
- **Hooks:** 30+ events (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`, `SubagentStop`, …) in settings files; exit code 2 blocks; JSON decision output (`permissionDecision: deny|allow|ask`). Docs position hooks/permissions, not prose, as the enforcement layer.
- **Permissions:** 4-layer settings (`managed` > CLI > `.claude/settings.local.json` > `.claude/settings.json` > `~/.claude/settings.json`); deny > ask > allow, first match; deny at any layer wins. Bash glob rules, gitignore-style file rules, `WebFetch(domain:…)`. OS sandboxing (Seatbelt/bubblewrap) with write/network/credential confinement.
- **Headless/supervisor:** `claude -p` with `--output-format json|stream-json` (returns `session_id`, `total_cost_usd`), `--resume <session_id>`, `--continue`, `--max-turns`, `--permission-mode`, `--allowedTools/--disallowedTools`, `--bare` (skips discovery; documented as recommended for scripted calls), `--json-schema` for structured output. Documented supervisor pattern: capture `session_id` from JSON, resume with follow-ups from the same directory. SIGTERM → SessionEnd hooks → exit 143.
- **Distribution:** plugin/marketplace system exists (skills, agents, hooks, MCP bundling) — relevant later for distributing this framework; not used in v1.1.0.

## 2. OpenAI Codex

Primary source set: `https://learn.chatgpt.com/docs/…` (canonical redirect target of `developers.openai.com/codex/…`, accessed 2026-07-18; no update dates displayed).

- **AGENTS.md: native.** Global `~/.codex/AGENTS.md` (or `AGENTS.override.md`); project files discovered walking git root → cwd, one file per directory, concatenated root-down (closer overrides). Combined cap `project_doc_max_bytes` default **32 KiB** — the rendered AGENTS.md managed block must stay well under this.
- **Config:** user `~/.codex/config.toml`; **project `.codex/config.toml` supported but trust-gated** (loaded only when the project is marked trusted). `approval_policy = untrusted|on-request|never`; `sandbox_mode = read-only|workspace-write|danger-full-access` (legacy `--full-auto` deprecated). Network: `[sandbox_workspace_write] network_access`, plus `features.network_proxy` domain allow/deny.
- **Skills: open-spec, native.** Docs state skills "build on the open agent skills standard" (agentskills.io). Discovery: `.agents/skills` (cwd → parents → repo root) → `~/.agents/skills` → `/etc/codex/skills` → built-ins. **Codex reads the vendor-neutral `.agents/skills/`, not `.codex/skills/`** (though JetBrains docs reference `~/.codex/skills` for its own Codex-agent integration — treat `.agents/skills/` as the project-level truth for Codex CLI). Optional OpenAI-specific `agents/openai.yaml` per skill.
- **Subagents: stable.** Built-ins `default|worker|explorer`; custom agents as **TOML** in `~/.codex/agents/` or project `.codex/agents/` (`name`, `description`, `developer_instructions` required; optional `model`, `model_reasoning_effort`, `sandbox_mode`, `mcp_servers`). `agents.max_depth` default 1, `agents.max_threads` default 6.
- **Long tasks:** `/goal` feature (`[features] goals = true`): set/pause/resume/clear durable objectives, "multiple hours without input". Headless resume: `codex exec resume --last | <SESSION_ID>`.
- **Headless:** `codex exec "task"`, `--json` (JSONL events incl. token usage), `--output-schema`, `-o last-message file`, `--ephemeral`, `--sandbox <mode>`, `--skip-git-repo-check`, stdin prompts. CI auth `CODEX_API_KEY`. CLI→cloud delegation: UNKNOWN (not documented on official pages).
  **(corrected 2026-07-18 post-review)** `--sandbox <mode>` belongs to the initial,
  non-resume `codex exec` invocation only. `codex exec resume` (used for the
  supervisor's follow-up calls in a session) accepts **no** `--sandbox` flag —
  verified against `codex-cli 0.144.6`: passing it errors
  `unexpected argument '--sandbox' found`, and `codex exec resume --help` does not
  list it. To carry sandbox intent into a resumed call, use the config override
  `-c sandbox_mode=<mode>` on the resume invocation instead.

## 3. Kimi Code (Moonshot AI)

Primary source set: `https://moonshotai.github.io/kimi-code/en/` + raw `github.com/MoonshotAI/kimi-code/docs/en/*` (accessed 2026-07-18; no dates displayed). **Product note:** the older `kimi-cli` is officially deprecated ("evolving into Kimi Code"); current binary is `kimi`, home `~/.kimi-code/` (`KIMI_CODE_HOME`), migration via `kimi migrate`.

- **AGENTS.md: native.** Global `~/.kimi-code/AGENTS.md` and cross-tool `~/.agents/AGENTS.md`; project `.kimi-code/AGENTS.md` or root `AGENTS.md`. Nesting/merge algorithm and size caps: UNKNOWN (undocumented).
- **Skills:** SKILL.md frontmatter `name` + `description` required; extensions `type: prompt|inline|flow`, `whenToUse`, `disableModelInvocation`, `arguments`. Discovery: project `.kimi-code/skills/` **and `.agents/skills/`** → user `~/.kimi-code/skills/` and `~/.agents/skills/` → extra dirs → built-ins. Current docs do not cite agentskills.io (deprecated kimi-cli docs did) → classify as *de-facto compatible, spec citation absent*.
- **Custom subagents: not supported as documented.** Built-in `coder`/`explore`/`plan` only; no user-defined agent file format. Roles must be adapted as prompt-type skills (role briefs) for Kimi.
- **Hooks:** `[[hooks]]` in `~/.kimi-code/config.toml` (user-level only): 16 events; `UserPromptSubmit`, `PreToolUse`, `Stop` blockable via exit 2; others observe-only; fail-open on timeout.
- **Config/permissions:** user `~/.kimi-code/config.toml`; project-side only `.kimi-code/local.toml` (machine-local, docs recommend gitignoring — so no committed project permission profile). `default_permission_mode = manual|auto|yolo`; `[[permission.rules]]` allow/deny/ask.
  **(corrected 2026-07-18 post-review)** Credentials are read only from `config.toml`
  — Kimi does **not** fall back to shell environment variables automatically. The
  documented env channel is the `KIMI_MODEL_*` family (e.g. `KIMI_MODEL_API_KEY`),
  which synthesizes a temporary provider entry; it is distinct from — and not the
  same mechanism as — any generic `*_API_KEY`/`*_HOME` variable a caller might set.
  The official `[[permission.rules]]` schema (moonshotai.github.io/kimi-code config
  docs, accessed 2026-07-18) is:
  ```toml
  [[permission.rules]]
  decision = "deny"                       # required: allow | ask | deny
  scope    = "project"                    # optional: project | global
  pattern  = "Bash(git push --force*)"    # required: "ToolName" or "ToolName(arg-pattern)"
  reason   = "Force-push is denied by policy"   # optional, human-readable
  ```
  There is **no** `tool =` field — the tool name is embedded in `pattern`, not a
  separate key. A rule using `tool = "Bash"` plus a bare `pattern = "git push --force*"`
  matches nothing and is silently inert (not rejected at load time), so adopters
  must verify an installed profile with `kimi doctor` rather than trusting that
  Kimi loaded without error.
- **Long tasks/headless:** `/goal` with queue (`/goal next`), states complete/paused/blocked; background tasks first-class. Headless `kimi -p` (forces `auto` permission policy; deny rules still apply), `--output-format stream-json`, `--continue`, `--session <id>`, print-mode background steering (`print_background_mode = steer`), goal exit codes 0/3/6. `kimi server` REST/WS daemon.
  **(corrected 2026-07-18 post-review)** `kimi -p` requires the prompt as the
  **option value** (`kimi -p "the prompt text"`) — there is no stdin-prompt
  invocation mode. Verified against the installed `kimi 0.27.0`: piping a prompt
  via stdin (`echo "..." | kimi -p`) fails deterministically with
  `error: argument missing` at argument-parse time, before any model call. Any
  shim or documentation that pipes the prompt to `kimi -p` on stdin is wrong for
  this CLI version; the prompt text must be passed as `argv`.

## 4. OpenCode

Primary source: `https://opencode.ai/docs/{rules,skills,agents,permissions,providers,cli,commands,plugins}` (accessed 2026-07-18; rules page showed "updated Jul 17, 2026").

- **AGENTS.md: native** (project root; global `~/.config/opencode/AGENTS.md`; reads `CLAUDE.md` as compatibility fallback). `opencode.json` `instructions` array supports globs and URLs.
- **Skills: open-spec adopter.** Discovery priority: `.opencode/skills/` → `.claude/skills/` → **`.agents/skills/`** → global. Spec frontmatter enforced (name matches dir, 1–64 chars; description ≤1024). Permission-gated `skill` tool.
- **Custom agents:** `.opencode/agents/*.md` (global `~/.config/opencode/agents/`); frontmatter `description` (required), `mode: primary|subagent|all`, `model`, `temperature`, `permission`, `hidden`; JSON alternative in `opencode.json`. Built-ins: Build, Plan, General, Explore, Scout.
- **Permissions:** `permission` config, `allow|ask|deny` per tool key (`edit`, `bash` with command patterns, `webfetch`, `skill`, …), per-agent overrides, `.env` read denied by default.
- **Local models: first-class.** `provider` block with `npm: @ai-sdk/openai-compatible`, `options.baseURL`, per-model `limit: {context, output}`. Documented for Ollama (`http://localhost:11434/v1`), LM Studio, llama.cpp — the generic pattern covers any OpenAI-compatible endpoint. This is the framework's designated local-LLM path.
- **Headless:** `opencode run --format json`, `--model`, `--agent`, `--session/-s`, `--continue`, `--auto`; `opencode serve` + `--attach` for warm CI runs.
  **(corrected 2026-07-18 post-review)** `--auto` approves **any** ask-level
  permission request that is not explicitly denied — it is not scoped to a
  pre-reviewed allowlist. `external_directory` (writes/reads outside the project
  root) defaults to `ask` when unset, so an `--auto` run with no explicit
  `external_directory: deny` rule will silently approve out-of-worktree access.
  Unattended/autonomous runs must set explicit deny rules (including
  `external_directory: deny`) in the permission profile before adding `--auto`;
  `--auto` alone is not a safe unattended default.
- **Hooks/plugins:** JS/TS plugin API (`tool.execute.before/after`, `session.*`, `permission.*`, `file.edited`, custom tools) in `.opencode/plugins/`.

## 5. JetBrains AI Assistant / Junie

Primary sources: `jetbrains.com/help/ai-assistant/{configure-project-rules,configure-agent-behavior,agent-skills,mcp,use-custom-models}.html` (2026.2 help, pages dated 27 May / 02 Jul / 15 Jul / 20 Apr 2026), `junie.jetbrains.com/docs/{guidelines-and-memory,agent-skills}.html` (accessed 2026-07-18).

- **Rules:** `.aiassistant/rules/*.md` with application modes Always / Manually (`@rule:`) / By model decision (needs Instruction field) / By file patterns / Off. Governs AI chat.
- **AGENTS.md:** supported for agent modes in AI Assistant; **Junie's default guidelines file is now AGENTS.md** (`.junie/AGENTS.md` → root `AGENTS.md` → legacy `.junie/guidelines.md`; global `~/.junie/AGENTS.md`; project wins on conflict).
- **Skills:** supported in AI Assistant chat for Claude Agent and Codex agents; project-level path is **`<project>/.agents/skills`** (plus agent-native `.claude/skills`, `.codex/skills`, IDE cache). Junie CLI scans `.junie/skills/` and `~/.junie/skills/` and can import from `.claude/skills/` etc. So the rendered `.agents/skills/` + `.claude/skills/` copies cover JetBrains with no extra render target; `.aiassistant/rules/` remains the chat-rules adapter.
- **No hooks, no custom subagents** documented. MCP supported (Beta; unavailable with local models). Local models: Ollama, LM Studio, OpenAI-compatible. Junie runs in IDE, CLI, and CI.

## 6. Open Agent Skills specification

Source: `https://agentskills.io/specification` and `/integrate-skills` (accessed 2026-07-18). Originally by Anthropic; published as open standard 2025-12-18 (date from secondary sources — flagged as secondary).

- Skill = directory with `SKILL.md` (+ optional `scripts/`, `references/`, `assets/`). Required frontmatter: `name` (1–64 chars, `[a-z0-9-]`, no leading/trailing/double hyphen, **must equal directory name**), `description` (1–1024 chars). Optional: `license`, `compatibility`, `metadata` (string map), `allowed-tools` (experimental). Body ≤ ~500 lines; progressive disclosure (metadata → body → resources).
- The spec does not mandate discovery paths; **`.agents/skills/` is the recommended cross-client project convention**, and clients also scan their native dirs. Project skills override user skills.
- Adopters (per agentskills.io client list, accessed 2026-07-18) include: Claude Code, OpenAI Codex, GitHub Copilot, VS Code, Cursor, Gemini CLI, Junie, OpenCode, Goose, Amp, and ~35 others. Kimi Code is de-facto compatible (paths + format) but its current docs don't cite the spec.
- Validation tooling: `skills-ref validate`.

## 7. Consequences for the framework design

1. **Single skill source, two rendered copies.** Canonical skills render to `.agents/skills/` (Codex, Kimi, OpenCode, JetBrains agents) and `.claude/skills/` (Claude Code; also raises OpenCode priority). Frontmatter stays within the open spec so one body serves all providers.
2. **AGENTS.md is the shared instruction spine** (native: Codex, Kimi, OpenCode, Junie/JetBrains agent modes; bridged: Claude Code via `@AGENTS.md`). It gets one managed block, generated from canonical policies, and must stay small (Codex 32 KiB combined cap; JetBrains/Junie merge global+project).
3. **Roles map per provider:** Claude → `.claude/agents/*.md`; OpenCode → `.opencode/agents/*.md`; Codex → `.codex/agents/*.toml`; Kimi → **adapter fallback**: role briefs as prompt skills under `.kimi-code/agents/` docs + skills (no native custom agents); JetBrains → no native subagents, roles documented in `.aiassistant/rules/` guidance.
4. **Permissions are enforceable on Claude (settings.json), OpenCode (opencode.json), Codex (sandbox/approval, trust-gated project config); advisory-only on Kimi (user-level config; project `local.toml` is machine-local/gitignored) and JetBrains** — the capability matrix records this so evals don't assume enforcement where none exists.
5. **Supervisor drives all four CLIs headless:** `claude -p --output-format json --resume`, `codex exec --json` / `codex exec resume`, `kimi -p "<prompt>" --output-format stream-json --session`, `opencode run --format json --session`. All four support session resume — the autonomous supervisor uses resume-first, restart-on-failure. **(corrected 2026-07-18 post-review)** The Kimi prompt must be passed as `-p`'s argument value, not piped via stdin (verified against `kimi 0.27.0` — see §3). **(corrected 2026-07-18 post-review)** `codex exec resume` accepts **no** `--sandbox` flag (verified against `codex-cli 0.144.6`: `error: unexpected argument '--sandbox' found`; `codex exec resume --help` lists no such flag — only the initial, non-resume `codex exec` has it). Sandbox behavior for a resumed session is controlled through the config override `-c sandbox_mode=<mode>` on the resume invocation, not a dedicated flag.
6. **Local LLMs** route through OpenCode's `@ai-sdk/openai-compatible` provider block (documented for Ollama/LM Studio/llama.cpp) — the `generic` provider adapter documents this instead of inventing a new mechanism.
7. **UNKNOWNs carried into the matrix:** Kimi AGENTS.md merge semantics and size caps; Codex CLI→cloud delegation; Codex hooks (none found); JetBrains permission-config file; per-adopter spec adoption dates.
