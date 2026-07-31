#!/usr/bin/env bash
# Claude Code shim. Headless: `claude -p` with JSON output and session resume.
# Docs (accessed 2026-07-18): code.claude.com/docs/en/headless — session_id captured
# from --output-format json; resume with --resume <id> from the same directory.
# Permissions: the repo's committed .claude/settings.json deny/ask rules always apply;
# this shim never uses --dangerously-skip-permissions.
#
# AF_COMMAND_MODE maps to an explicit --permission-mode, because a supervised run is
# NON-INTERACTIVE: under `claude -p` an "ask" rule has nobody to ask, so it resolves as
# a denial. Leaving workspace-write unmapped therefore denied every Write/Edit and made
# autonomous implementation impossible — the first live-provider run blocked with
# "needs-access: Write tool permission ... not granted in this non-interactive session".
#   read-only       -> plan        (no mutations at all)
#   workspace-write -> acceptEdits (file edits auto-accepted; deny rules still enforced,
#                                   and this is NOT --dangerously-skip-permissions:
#                                   settings.json deny entries continue to block)
source "$(dirname "$0")/provider-common.sh"
af_guard_real_run

cd "$AF_WORKDIR"
ARGS=(-p --output-format json --max-turns 80 --model "$AF_MODEL")
[[ -n "${AF_SESSION_REF:-}" ]] && ARGS+=(--resume "$AF_SESSION_REF")
[[ "${AF_COMMAND_MODE:-}" == "read-only" ]] && ARGS+=(--permission-mode plan)
[[ "${AF_COMMAND_MODE:-}" == "workspace-write" ]] && ARGS+=(--permission-mode acceptEdits)

RAW_FILE="$(af_mktemp_raw)"
trap 'rm -f "$RAW_FILE"' EXIT
set +e
af_with_timeout claude "${ARGS[@]}" <"$AF_PROMPT_FILE" >"$RAW_FILE" 2>>"${AF_LOG_FILE:-/dev/null}"
RC=$?
set -e

python3 - "$RC" "$RAW_FILE" <<'PY'
import json, sys
rc = int(sys.argv[1])
with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
    raw = f.read()
out = {"session_ref": None, "text": "", "cost_usd": 0.0, "tokens": 0, "exit_kind": "completed"}
try:
    d = json.loads(raw)
    out["session_ref"] = d.get("session_id")
    out["text"] = d.get("result", "")
    out["cost_usd"] = d.get("total_cost_usd") or 0.0
    usage = d.get("usage") or {}
    # Include cache tokens: they dominate long sessions and must count toward
    # max_total_tokens (review finding KF-L03).
    out["tokens"] = (usage.get("input_tokens") or 0) + (usage.get("output_tokens") or 0) \
        + (usage.get("cache_creation_input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0)
    if d.get("subtype") == "error_max_turns":
        out["exit_kind"] = "context-exhausted"
except Exception:
    out["text"] = raw
    out["exit_kind"] = "crashed" if rc != 0 else "completed"
if rc == 124:  # coreutils timeout: shim-level call bound hit (AF_CALL_TIMEOUT_SECONDS)
    out["exit_kind"] = "timeout"
elif rc != 0 and out["exit_kind"] == "completed":
    out["exit_kind"] = "crashed"
if not out["text"] and out["exit_kind"] == "completed":
    out["exit_kind"] = "crashed"  # empty output from a zero-exit call is not trustworthy
print(json.dumps(out))
PY
