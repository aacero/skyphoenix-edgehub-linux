#!/usr/bin/env bash
# Shared shim helpers. Shim contract (see run-autonomous-session.py):
#   env in:  AF_PROMPT_FILE AF_SESSION_REF AF_MODEL AF_WORKDIR AF_PHASE
#            AF_NETWORK_MODE AF_COMMAND_MODE AF_DRY_RUN AF_SIM_EXIT AF_LOG_FILE
#            AF_CALL_TIMEOUT_SECONDS (optional; default 7200 — shim-level hard bound
#            on the provider CLI, defense in depth under the supervisor's watchdog)
#   stdout:  last non-empty line = one JSON object:
#            {"session_ref":str|null,"text":str,"cost_usd":num,"tokens":int,"exit_kind":
#             "completed"|"context-exhausted"|"crashed"|"timeout"}
# Provider raw output is exchanged via a temp file, never via the environment
# (large outputs would exceed the kernel per-env-string limit and crash the
# python exec with E2BIG — review finding KF-M31).
set -euo pipefail

af_dry_run_response() {
  # Deterministic canned response so the supervisor's state machine, restart, budget
  # and reporting logic can be exercised end-to-end without any provider.
  local exit_kind="completed"
  [[ "${AF_SIM_EXIT:-0}" == "1" ]] && exit_kind="context-exhausted"
  local ref="${AF_SESSION_REF:-}"
  [[ -z "$ref" ]] && ref="dry-$(basename "${AF_PROMPT_FILE}" | tr -dc '0-9')"
  python3 - "$ref" "$exit_kind" "${AF_PHASE:-?}" "${AF_DRYRUN_OMIT_EVIDENCE:-0}" "${AF_DRYRUN_OMIT_PHASE_RESULT:-0}" "${AF_DRYRUN_FABRICATE_EVIDENCE:-0}" "${AF_DRYRUN_EMIT_BLOCKER:-0}" <<'PY'
import json, sys
ref, exit_kind, phase, omit, omit_pr, fabricate, blocker = sys.argv[1:8]
text = f"SIMULATED {phase}\nEVIDENCE: dry-run simulated check => ok\nPHASE_RESULT: ok\n"
if omit == "1":  # evals: a session that claims completion without evidence
    text = f"SIMULATED {phase}\nPHASE_RESULT: ok\n"
if omit_pr == "1":  # evals: marker-free output must fail closed (KF-M07/CXR-007)
    text = f"SIMULATED {phase} with no markers at all\n"
if fabricate == "1":  # evals: fabricated evidence stays agent-asserted (KF-M24)
    text = f"SIMULATED {phase}\nEVIDENCE: pytest -q => 42 passed (FABRICATED — command never ran)\nPHASE_RESULT: ok\n"
if blocker == "1" and phase in ("IMPLEMENT", "VERIFY", "REVIEW"):
    # evals: task phases block -> blocked-all-tasks stop path (KF-M10 / E26).
    # DISCOVER/PLAN stay ok so the run reaches task selection.
    text = f"SIMULATED {phase}\nBLOCKER: needs-decision: simulated blocking condition\nPHASE_RESULT: blocked\n"
if exit_kind != "completed":
    text = f"SIMULATED {phase} (interrupted)\n"
print(json.dumps({"session_ref": ref, "text": text, "cost_usd": 0.01,
                  "tokens": 1000, "exit_kind": exit_kind}))
PY
}

af_guard_real_run() {
  # Refuse to run a real provider against dirty preconditions.
  if [[ "${AF_DRY_RUN:-0}" == "1" ]]; then
    af_dry_run_response
    exit 0
  fi
  [[ -f "${AF_PROMPT_FILE:?AF_PROMPT_FILE required}" ]]
  [[ -d "${AF_WORKDIR:?AF_WORKDIR required}" ]]
}

af_version_note() {
  # Version-aware command construction: shim argv is built against a pinned, tested
  # CLI version. Warn loudly (never silently proceed as if verified) when the
  # installed version differs from the tested one (review findings CXR-002/KF-H01).
  local cli="$1" tested="$2" installed
  # </dev/null: the probe must never block on an inherited interactive stdin
  installed="$(af_with_timeout_secs 10 "$cli" --version </dev/null 2>/dev/null | head -1 || echo unknown)"
  if [[ "$installed" != *"$tested"* ]]; then
    echo "WARN: $cli version '$installed' differs from tested '$tested' — command" \
         "syntax was verified against the tested version only" >&2
  fi
}

af_require_cli_version() {
  # Fail-closed version GATE (verification finding 7, CXR-002/KF-H13/B5): where the
  # shim's argv contract is version-specific (e.g. `codex exec resume` options), an
  # installed CLI outside the tested series must fail VISIBLY before any provider
  # invocation — a warning-and-continue path is not sufficient. Deliberate pilot
  # override: AF_ACCEPT_UNSUPPORTED_CLI=1 (recorded loudly on stderr).
  local cli="$1" tested="$2" installed
  installed="$(af_with_timeout_secs 10 "$cli" --version </dev/null 2>/dev/null | head -1 || echo unknown)"
  if [[ "$installed" == *"$tested"* ]]; then
    return 0
  fi
  if [[ "${AF_ACCEPT_UNSUPPORTED_CLI:-0}" == "1" ]]; then
    echo "WARN: $cli version '$installed' is outside the tested series '$tested' —" \
         "continuing ONLY because AF_ACCEPT_UNSUPPORTED_CLI=1 was set explicitly" >&2
    return 0
  fi
  echo "provider shim: REFUSED — installed $cli version '$installed' is not in the" \
       "supported series '$tested.x'. The command construction (including resume" \
       "argv) is verified against that series only. Install a supported version or" \
       "set AF_ACCEPT_UNSUPPORTED_CLI=1 to accept the risk for an attended pilot." >&2
  exit 2
}

af_with_timeout_secs() {
  # Run a command under coreutils timeout (TERM, then KILL after 15 s grace).
  # Exit 124 = timed out. Falls back to running unbounded where coreutils timeout
  # is unavailable (the supervisor's process-group watchdog still bounds the call).
  # --foreground is REQUIRED: without it timeout moves the provider CLI into its
  # own process group, so the supervisor's group-wide TERM/KILL escalation could
  # never reach the CLI or its descendants (verification finding 4). Under
  # --foreground, timeout's own expiry signals only the direct child; the
  # supervisor's group watchdog remains the enforcement for descendants.
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground --kill-after=15 "$secs" "$@"
  else
    "$@"
  fi
}

af_with_timeout() {
  # Shim-level hard bound on the provider CLI (defense in depth: a hung provider is
  # terminated by the shim itself even when invoked outside the supervisor).
  af_with_timeout_secs "${AF_CALL_TIMEOUT_SECONDS:-7200}" "$@"
}

af_mktemp_raw() {
  mktemp "${TMPDIR:-/tmp}/af-raw.XXXXXXXX"
}
