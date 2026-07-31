#!/usr/bin/env bash
# OpenAI Codex shim. Headless: `codex exec` / `codex exec resume <SESSION_ID>` with
# --json JSONL events. Docs (accessed 2026-07-18): learn.chatgpt.com/docs/non-interactive-mode.
# Sandbox mapped from AF_COMMAND_MODE. IMPORTANT (review finding CXR-002/KF-H13):
# `codex exec resume` does NOT accept -s/--sandbox; the sandbox for resumed sessions
# is set via the supported `-c sandbox_mode=...` config override. Verified against
# codex-cli 0.144.6 (`codex exec resume --help`). Network policy is enforced via
# Codex sandbox config (.codex/config.toml), not by this shim.
#
# SUPPORTED CLI VERSIONS: codex-cli 0.144.x only. The version gate below FAILS
# (exit 2) on any other installed version before invoking the CLI — resume argv
# is version-specific and a silent mismatch produced dead commands in the past
# (CXR-002/KF-H13). Override for attended pilots: AF_ACCEPT_UNSUPPORTED_CLI=1.
source "$(dirname "$0")/provider-common.sh"
af_guard_real_run
af_require_cli_version codex "0.144"

cd "$AF_WORKDIR"
SANDBOX="workspace-write"
[[ "${AF_COMMAND_MODE:-}" == "read-only" ]] && SANDBOX="read-only"

RAW_FILE="$(af_mktemp_raw)"
trap 'rm -f "$RAW_FILE"' EXIT
set +e
if [[ -n "${AF_SESSION_REF:-}" ]]; then
  af_with_timeout codex exec resume "$AF_SESSION_REF" --json -c "sandbox_mode=\"$SANDBOX\"" \
    -m "$AF_MODEL" - <"$AF_PROMPT_FILE" >"$RAW_FILE" 2>>"${AF_LOG_FILE:-/dev/null}"
else
  af_with_timeout codex exec --json --sandbox "$SANDBOX" -m "$AF_MODEL" - \
    <"$AF_PROMPT_FILE" >"$RAW_FILE" 2>>"${AF_LOG_FILE:-/dev/null}"
fi
RC=$?
set -e

python3 - "$RC" "$RAW_FILE" <<'PY'
import json, sys
rc = int(sys.argv[1]); ref = None; text = []; tokens = 0; kind = "completed"
with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type", "")
        if t == "thread.started":
            ref = ev.get("thread_id") or ev.get("session_id") or ref
        elif t.startswith("item.") and ev.get("item", {}).get("type") == "agent_message":
            text.append(ev["item"].get("text", ""))
        elif t == "turn.completed":
            u = ev.get("usage") or {}
            tokens += (u.get("input_tokens") or 0) + (u.get("output_tokens") or 0) \
                + (u.get("cached_input_tokens") or 0)
        elif t == "turn.failed":
            kind = "crashed"
if rc == 124:  # coreutils timeout: shim-level call bound hit (AF_CALL_TIMEOUT_SECONDS)
    kind = "timeout"
elif rc != 0 and kind == "completed":
    kind = "crashed"
if not text and kind == "completed":
    kind = "crashed"  # empty output from a "successful" call is not trustworthy
print(json.dumps({"session_ref": ref, "text": "\n".join(text), "cost_usd": 0.0,
                  "tokens": tokens, "exit_kind": kind}))
PY
