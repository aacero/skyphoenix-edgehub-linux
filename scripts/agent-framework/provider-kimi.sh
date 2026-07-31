#!/usr/bin/env bash
# Kimi Code shim. Headless: `kimi -p <prompt>` (print mode; provider forces 'auto'
# permission policy — static deny rules from user config still apply per docs, but
# this is UNVERIFIED against a live run: treat headless Kimi as experimental).
# IMPORTANT (review finding KF-H01): the prompt is a REQUIRED OPTION VALUE of -p —
# there is no stdin prompt mode. Verified against kimi 0.27.0: a stdin invocation
# fails at argument parsing ("option '-p, --prompt <prompt>' argument missing").
# Session resume via --session <id>. Docs (accessed 2026-07-18):
# github.com/MoonshotAI/kimi-code docs/en/reference/kimi-command.md.
source "$(dirname "$0")/provider-common.sh"
af_guard_real_run
af_version_note kimi "0.27"

if [[ "${AF_COMMAND_MODE:-}" == "read-only" ]]; then
  # Kimi print mode has no mechanism to enforce a read-only command policy
  # (permissions are user-level and print mode forces auto approval). Fail visibly
  # instead of silently running unenforced (review finding KF-L07).
  echo "provider-kimi.sh: AF_COMMAND_MODE=read-only is not enforceable on Kimi" >&2
  exit 2
fi

cd "$AF_WORKDIR"
ARGS=(-p "$(cat "$AF_PROMPT_FILE")" --output-format stream-json -m "$AF_MODEL")
[[ -n "${AF_SESSION_REF:-}" ]] && ARGS+=(--session "$AF_SESSION_REF")

RAW_FILE="$(af_mktemp_raw)"
trap 'rm -f "$RAW_FILE"' EXIT
set +e
# </dev/null: the prompt travels as the -p argv value; stdin is unused and must be
# explicitly closed — an inherited interactive stdin would let the CLI block forever
# waiting for EOF (root cause of the shim-test hangs; see final report).
af_with_timeout kimi "${ARGS[@]}" </dev/null >"$RAW_FILE" 2>>"${AF_LOG_FILE:-/dev/null}"
RC=$?
set -e

python3 - "$RC" "$RAW_FILE" "${AF_SESSION_REF:-}" <<'PY'
import json, sys
rc = int(sys.argv[1]); ref = sys.argv[3] or None
text = []; kind = "completed"
# stream-json event schema (session_id / role / content fields) is taken from the
# framework's provider research and is UNVERIFIED against a live run — the parser
# fails closed: no parsed text from a zero-exit call is reported as crashed.
with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict):
            continue
        ref = ev.get("session_id") or ref
        role = ev.get("role") or ev.get("type")
        if role in ("assistant", "Assistant", "assistant_message"):
            c = ev.get("content")
            if isinstance(c, str):
                text.append(c)
            elif isinstance(c, list):
                text += [b.get("text", "") for b in c if isinstance(b, dict)]
if rc == 124:  # coreutils timeout: shim-level call bound hit (AF_CALL_TIMEOUT_SECONDS)
    kind = "timeout"
elif rc != 0:
    kind = "crashed"
if not text and kind == "completed":
    kind = "crashed"  # empty/unparseable output must not look like success (KF-H01 guard)
print(json.dumps({"session_ref": ref, "text": "\n".join(text), "cost_usd": 0.0,
                  "tokens": 0, "exit_kind": kind}))
PY
