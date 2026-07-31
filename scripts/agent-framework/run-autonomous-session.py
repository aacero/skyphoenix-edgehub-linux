#!/usr/bin/env python3
"""Provider-neutral autonomous-session supervisor.

Drives a long-running agent session against one provider CLI (claude | codex |
kimi | opencode) through the canonical state machine:

  INITIALIZE -> DISCOVER -> PLAN -> [ IMPLEMENT -> VERIFY -> REVIEW ->
  UPDATE_STATE -> SELECT_NEXT_TASK -> CONTINUE_OR_HANDOVER ]* -> FINAL_REPORT

Design contract: agent-framework/canonical/workflows/autonomous-session/WORKFLOW.md
Run config schema:  agent-framework/schemas/autonomous-run.schema.json
Run state schema:   agent-framework/schemas/run-state.schema.json

Usage:
  python3 scripts/agent-framework/run-autonomous-session.py --config run.json
  python3 scripts/agent-framework/run-autonomous-session.py --config run.json --dry-run
  python3 scripts/agent-framework/run-autonomous-session.py --config run.json \
      --dry-run --simulate-exit-at 3   # Nth provider call ends "context-exhausted"
  python3 scripts/agent-framework/run-autonomous-session.py --config run.json \
      --resume <run-id>                # reload a checkpointed run and continue

Dry-run never invokes a real provider: the shims are called with AF_DRY_RUN=1 and
return canned JSON, so the full state machine, restart, budget, deadline, kill-switch
and reporting logic execute for real at zero cost. Never run a multi-hour session
without an explicit human decision to do so.

Enforcement semantics (post v1.1.0 review remediation):
  * Deadline, kill switch, and signals are enforced IN-FLIGHT: provider calls run
    in their own process group, a poll loop checks the guards every ~0.5 s, and on
    trigger the whole process group receives SIGTERM then (after a grace period)
    SIGKILL. The per-call timeout is additionally bounded by the remaining run time.
  * Cost/token budgets are checked before every call and may therefore be exceeded
    by at most one in-flight provider call — they are soft thresholds. The hard
    caps are max_provider_calls and the deadline-bounded per-call timeout.
  * Session recovery model is handover-injection: after a session ends abnormally,
    the replacement session starts fresh and the handover content is embedded in
    its first prompt (recorded per session as recovery_model).
  * A phase that completes without an explicit PHASE_RESULT marker fails closed:
    it is retried once, then treated as blocked (tasks) or stops the run
    (DISCOVER/PLAN, stop_reason provider-output-invalid).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import time
import traceback
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _lib import FRAMEWORK_DIR, REPO_ROOT, SchemaError, load_json, validate_schema  # noqa: E402

SHIM_DIR = Path(__file__).resolve().parent
PHASES_PER_TASK = ["IMPLEMENT", "VERIFY", "REVIEW"]
PLANNED_STOPS = {"backlog-exhausted", "deadline", "kill-switch", "budget", "min-work-window"}
# Quality ladder: what an agent does with remaining time once the approved backlog is
# done (autonomy-policy continuation ladder). Never invents features.
QUALITY_LADDER = [
    ("ql-verify", "Re-run all deterministic verification (build, tests, validate scripts) and record evidence."),
    ("ql-tests", "Identify and add missing tests for behavior changed during this run, including failure paths."),
    ("ql-security", "Security review of this run's changes against docs/security/threat-model.md."),
    ("ql-accessibility", "Accessibility review of any UI touched during this run (ui-ux-review skill)."),
    ("ql-docs", "Validate and update documentation affected by this run's changes."),
    ("ql-packaging", "Validate packaging/install impact of this run's changes."),
    ("ql-usability", "Usability review of changed flows via persona-validation workflow (findings only)."),
    ("ql-backlog", "Triage BACKLOG.md candidates: dedupe, clarify, classify. Do not implement any."),
    ("ql-release", "Release-readiness assessment (release-readiness skill); report Go/Conditional-Go/No-Go."),
]


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(t: dt.datetime | None) -> str | None:
    return t.isoformat(timespec="seconds") if t else None


class Stop(Exception):
    def __init__(self, reason: str):
        self.reason = reason


# Curated shim environment: never inherit the operator's full environment (secrets,
# unrelated credentials) into provider CLIs — least privilege (security policy).
ENV_KEEP_COMMON = ["PATH", "HOME", "USER", "SHELL", "LANG", "LC_ALL", "TERM", "TMPDIR",
                   "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]
ENV_KEEP_PROVIDER = {
    "claude": ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"],
    "codex": ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_HOME"],
    # KIMI_MODEL_* is the documented Kimi env channel (prefix pass-through below);
    # legacy MOONSHOT_API_KEY/KIMI_API_KEY are inert in Kimi Code and are no
    # longer forwarded (review finding KF-M02, consolidated H8).
    "kimi": ["KIMI_CODE_HOME"],
    "opencode": ["OPENCODE_CONFIG"],
}


def curated_env(provider: str, environ: dict) -> dict:
    """Filter the environment for a provider shim: common vars, the provider's own
    credential channel, AF_DRYRUN_* eval knobs, and (Kimi only) the documented
    KIMI_MODEL_* prefix. Everything else — including other providers' credentials
    and legacy inert variables — is dropped (H8 regression-tested)."""
    keep = ENV_KEEP_COMMON + ENV_KEEP_PROVIDER[provider]
    prefixes = ["AF_DRYRUN_"]
    if provider == "kimi":
        prefixes.append("KIMI_MODEL_")
    return {k: v for k, v in environ.items()
            if k in keep or any(k.startswith(p) for p in prefixes)}


class Supervisor:
    def __init__(self, cfg: dict, runs_dir: Path, dry_run: bool, simulate_exit_at: int,
                 resume: str | None = None):
        self.cfg = cfg
        self.dry_run = dry_run or cfg.get("dry_run", False)
        self.simulate_exit_at = simulate_exit_at
        self.run_id = resume or cfg.get("run_id") or f"run-{now():%Y%m%d-%H%M%S}-{uuid.uuid4().hex[:6]}"
        ks_name = cfg.get("kill_switch_file", "STOP")
        ksp = Path(ks_name)
        if ksp.is_absolute() or ".." in ksp.parts:
            raise SystemExit(f"kill_switch_file must be a plain run-dir-relative path, got {ks_name!r}")
        runs_dir.mkdir(parents=True, exist_ok=True)
        self.dir = runs_dir / self.run_id
        self.pending_handover: str | None = None
        self.skip_initial_phases = False
        if resume:
            self._load_resumed_state()
        else:
            try:
                # Exclusive creation: duplicate run IDs are refused, and a pre-existing
                # symlink at the run path fails here instead of being followed
                # (review findings CXR-008/CXR-009).
                self.dir.mkdir(exist_ok=False)
            except FileExistsError:
                raise SystemExit(
                    f"run directory {self.dir} already exists — duplicate run IDs corrupt state. "
                    "Choose a new run_id or continue the old run with --resume "
                    f"{self.run_id}.")
            os.chmod(self.dir, 0o700)  # logs contain prompts and raw model output
            (self.dir / "logs").mkdir()
            start = now()
            self.state = {
                "run_id": self.run_id,
                "state": "INITIALIZE",
                "started_at": iso(start),
                "deadline_at": iso(start + dt.timedelta(hours=cfg["duration_hours"])),
                "last_heartbeat_at": None,
                "last_checkpoint_at": None,
                "provider": cfg["provider"],
                "model": cfg["model"],
                "sessions": [],
                "restarts_used": 0,
                "provider_calls": 0,
                "tasks": [{"id": t["id"], "status": "pending", "blocker_class": None, "evidence": []}
                          for t in cfg["approved_backlog"]],
                "budget_spent": {"cost_usd": 0.0, "total_tokens": 0},
                "stop_reason": None,
                "exec_plan_file": "exec-plan.md",
                "morning_report_file": None,
            }
        self.kill_switch = self.dir / ks_name
        self._acquire_lock()
        self._stopping = False
        signal.signal(signal.SIGTERM, self._on_signal)
        signal.signal(signal.SIGINT, self._on_signal)

    # ---------- resume / locking ----------

    @staticmethod
    def semantic_state_problems(state: dict, expected_run_id: str) -> list[str]:
        """Operational invariants a schema cannot express. A state violating any of
        them is one the supervisor cannot safely execute and must be quarantined,
        not resumed (verification finding 6, CXR-020/KF-M08 + CXR-016/KF-M29)."""
        problems = []
        if state["run_id"] != expected_run_id:
            problems.append(f"run_id {state['run_id']!r} does not match run directory {expected_run_id!r}")
        started = dt.datetime.fromisoformat(state["started_at"])
        deadline = dt.datetime.fromisoformat(state["deadline_at"])
        if deadline <= started:
            problems.append(f"deadline_at {state['deadline_at']} is not after started_at {state['started_at']}")
        sessions = state["sessions"]
        max_restarts_possible = max(0, len(sessions) - 1)
        if state["restarts_used"] > max_restarts_possible:
            problems.append(f"restarts_used={state['restarts_used']} is inconsistent with "
                            f"{len(sessions)} recorded session(s)")
        for t in state["tasks"]:
            if t["status"] == "done-verified" and not t["evidence"]:
                problems.append(f"task {t['id']!r} is done-verified without any evidence "
                                "(evidence policy: such a claim is invalid)")
            if t["status"] == "blocked" and not t.get("blocker_class"):
                problems.append(f"task {t['id']!r} is blocked without a blocker_class")
        return problems

    def _load_resumed_state(self):
        if self.dir.is_symlink() or not self.dir.is_dir():
            raise SystemExit(f"--resume {self.run_id}: {self.dir} is missing or a symlink — refusing")
        state_path = self.dir / "run-state.json"
        if not state_path.exists():
            raise SystemExit(f"--resume {self.run_id}: no run-state.json in {self.dir}")
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
            # Structural validation (types, required fields, enums, date-time
            # formats) followed by semantic validation (operational invariants).
            validate_schema(state, load_json(FRAMEWORK_DIR / "schemas" / "run-state.schema.json"))
            problems = self.semantic_state_problems(state, self.run_id)
            if problems:
                raise SchemaError("semantically corrupt state: " + "; ".join(problems))
        except (json.JSONDecodeError, SchemaError) as e:
            quarantine = state_path.with_name("run-state.json.corrupt")
            state_path.replace(quarantine)
            raise SystemExit(
                f"--resume {self.run_id}: run-state.json is corrupt ({e}); quarantined to "
                f"{quarantine.name}. Human review required — refusing to guess state.")
        if state["provider"] != self.cfg["provider"] or state["model"] != self.cfg["model"]:
            raise SystemExit(
                f"--resume {self.run_id}: state was recorded for provider/model "
                f"{state['provider']}/{state['model']} but the config declares "
                f"{self.cfg['provider']}/{self.cfg['model']} — refusing (fix the config "
                "or start a new run)")
        prior_state = state.get("state")
        # A finished run is not resumable — but crashes checkpoint as STOPPED only
        # after finalization succeeded, so refuse those explicitly.
        if prior_state == "STOPPED" and state.get("stop_reason") in PLANNED_STOPS:
            raise SystemExit(f"--resume {self.run_id}: run already completed "
                             f"(stop_reason={state.get('stop_reason')}) — start a new run instead")
        for t in state["tasks"]:
            if t["status"] == "in_progress":
                t["status"] = "pending"  # redo interrupted work; claims are unverified
        state["stop_reason"] = None
        self.skip_initial_phases = prior_state not in (None, "INITIALIZE", "DISCOVER", "PLAN")
        (self.dir / "logs").mkdir(exist_ok=True)
        self.state = state
        self.state["state"] = "INITIALIZE"

    def _acquire_lock(self):
        self.lock_path = self.dir / "supervisor.lock"
        for attempt in (1, 2):
            try:
                fd = os.open(self.lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.write(fd, str(os.getpid()).encode())
                os.close(fd)
                return
            except FileExistsError:
                try:
                    other = int(self.lock_path.read_text().strip() or "0")
                except (OSError, ValueError):
                    other = 0
                alive = False
                if other > 0:
                    try:
                        os.kill(other, 0)
                        alive = True
                    except (ProcessLookupError, PermissionError):
                        alive = other != 0 and False
                if alive:
                    raise SystemExit(
                        f"run {self.run_id} is already owned by live supervisor pid {other} "
                        f"({self.lock_path}) — refusing concurrent execution")
                self.lock_path.unlink(missing_ok=True)  # stale lock from a dead process
        raise SystemExit(f"could not acquire {self.lock_path}")

    def _release_lock(self):
        try:
            self.lock_path.unlink(missing_ok=True)
        except OSError:
            pass

    # ---------- persistence ----------

    def checkpoint(self, transition: str | None = None):
        if transition:
            self.state["state"] = transition
        self.state["last_heartbeat_at"] = iso(now())
        self.state["last_checkpoint_at"] = iso(now())
        # Unique temp name: concurrent supervisors on the same directory must never
        # race on one fixed temp file (review finding CXR-008).
        tmp = self.dir / f"run-state.json.tmp.{os.getpid()}"
        tmp.write_text(json.dumps(self.state, indent=2), encoding="utf-8")
        tmp.replace(self.dir / "run-state.json")

    def log(self, msg: str):
        line = f"[{iso(now())}] {msg}"
        print(line, flush=True)
        with open(self.dir / "logs" / "supervisor.log", "a", encoding="utf-8") as f:
            f.write(line + "\n")

    # ---------- guards ----------

    def _on_signal(self, *_):
        self._stopping = True

    def _interrupt_reason(self) -> str | None:
        """The reason an in-flight provider call must be terminated now, if any."""
        if self._stopping:
            return "signal"
        if self.kill_switch.exists():
            return "kill-switch"
        if now() >= dt.datetime.fromisoformat(self.state["deadline_at"]):
            return "deadline"
        return None

    def guard(self):
        """Checked before every provider call and state transition."""
        reason = self._interrupt_reason()
        if reason:
            raise Stop(reason)
        b = self.cfg["budget"]
        spent = self.state["budget_spent"]
        if "max_cost_usd" in b and spent["cost_usd"] >= b["max_cost_usd"]:
            raise Stop("budget")
        if "max_total_tokens" in b and spent["total_tokens"] >= b["max_total_tokens"]:
            raise Stop("budget")
        if "max_provider_calls" in b and self.state["provider_calls"] >= b["max_provider_calls"]:
            raise Stop("budget")

    def time_remaining_ok(self) -> bool:
        remaining = dt.datetime.fromisoformat(self.state["deadline_at"]) - now()
        return remaining >= dt.timedelta(minutes=self.cfg["min_useful_work_minutes"])

    # ---------- provider sessions ----------

    def current_session(self) -> dict | None:
        return self.state["sessions"][-1] if self.state["sessions"] else None

    def open_session(self, resume_handover: Path | None = None):
        idx = len(self.state["sessions"]) + 1
        self.state["sessions"].append({
            "index": idx, "provider_session_ref": None, "started_at": iso(now()),
            "ended_at": None, "exit_kind": None, "phase_at_exit": None,
            "handover_file": str(resume_handover.name) if resume_handover else None,
            "recovery_model": "handover-injection" if resume_handover else None,
        })
        self.log(f"session {idx} opened (handover: {resume_handover.name if resume_handover else 'none'})")
        self.checkpoint()

    def _terminate_group(self, proc: subprocess.Popen, reason: str):
        """Staged TERM -> KILL of the provider's whole process group.

        Escalation is decided by GROUP liveness, never by the leader's poll()
        alone: when the shim exits during the grace period while a descendant
        ignores SIGTERM, the group still receives SIGKILL (verification
        finding 4, CXR-005/KF-H05 residual)."""
        try:
            pgid = os.getpgid(proc.pid)
        except ProcessLookupError:
            # Leader already reaped; start_new_session made the leader the group
            # leader, so its pid is the pgid — descendants may still be members.
            pgid = proc.pid

        def group_alive() -> bool:
            try:
                os.killpg(pgid, 0)
                return True
            except ProcessLookupError:
                return False
            except PermissionError:
                return True

        self.log(f"terminating provider process group {pgid} ({reason})")
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            return
        grace_until = time.monotonic() + (1.0 if self.dry_run else 10.0)
        while time.monotonic() < grace_until:
            proc.poll()  # reap the leader so its zombie does not count as a live member
            if not group_alive():
                return
            time.sleep(0.05)
        proc.poll()
        if group_alive():
            try:
                os.killpg(pgid, signal.SIGKILL)
                self.log(f"provider process group {pgid} force-killed after grace period")
            except ProcessLookupError:
                pass

    def call_provider(self, phase: str, prompt: str) -> dict:
        """Invoke the provider shim once. Returns normalized dict:
        {session_ref, text, cost_usd, tokens, exit_kind}. Raises Stop via guard.
        The call runs in its own process group; deadline, kill switch and signals
        interrupt it in flight (review findings CXR-005/KF-H05)."""
        self.guard()
        self.state["provider_calls"] += 1
        n = self.state["provider_calls"]
        # Durable pre-launch reservation (verification finding 5, CXR-019/B3): the
        # incremented call count is checkpointed BEFORE the provider is launched,
        # so an abrupt supervisor death at any later point can never make a resumed
        # process under-count calls and exceed the max_provider_calls hard cap.
        self.checkpoint()
        sess = self.current_session()
        prompt_file = self.dir / "logs" / f"prompt-{n:03d}-{phase.lower()}.md"
        prompt_file.write_text(prompt, encoding="utf-8")
        shim = SHIM_DIR / f"provider-{self.cfg['provider']}.sh"
        env = curated_env(self.cfg["provider"], dict(os.environ))
        env.update({
            "AF_PROMPT_FILE": str(prompt_file),
            "AF_SESSION_REF": sess["provider_session_ref"] or "",
            "AF_MODEL": self.cfg["model"],
            "AF_WORKDIR": self.cfg["worktree"].get("path") or str(REPO_ROOT),
            "AF_PHASE": phase,
            "AF_NETWORK_MODE": self.cfg["network_policy"]["mode"],
            "AF_COMMAND_MODE": self.cfg["command_policy"]["mode"],
            "AF_LOG_FILE": str(self.dir / "logs" / "provider.stderr.log"),
            "AF_DRY_RUN": "1" if self.dry_run else "0",
            "AF_SIM_EXIT": "1" if (self.dry_run and n == self.simulate_exit_at) else "0",
        })
        out_path = self.dir / "logs" / f"out-{n:03d}-{phase.lower()}.json"
        remaining = (dt.datetime.fromisoformat(self.state["deadline_at"]) - now()).total_seconds()
        call_timeout = max(5.0, min(7200.0, remaining))
        # Defense in depth: the shim also bounds the provider CLI itself (coreutils
        # timeout). The poll loop below is the PRIMARY enforcement; the shim bound
        # gets 30 s slack so it only fires when the supervisor cannot (e.g. the
        # supervisor process itself died mid-call).
        env["AF_CALL_TIMEOUT_SECONDS"] = str(int(call_timeout) + 30)
        interrupted: str | None = None
        hb_interval = max(5, int(self.cfg.get("heartbeat_seconds", 30)))
        with open(out_path, "w", encoding="utf-8") as outf, \
                open(env["AF_LOG_FILE"], "a", encoding="utf-8") as errf:
            # stdin=DEVNULL: provider CLIs must never inherit (and block on) the
            # operator's terminal during an unattended run.
            proc = subprocess.Popen([str(shim)], env=env, stdin=subprocess.DEVNULL,
                                    stdout=outf, stderr=errf,
                                    text=True, start_new_session=True)
            started = time.monotonic()
            last_hb = started
            while proc.poll() is None:
                reason = self._interrupt_reason()
                if reason is None and time.monotonic() - started >= call_timeout:
                    reason = "timeout"
                if reason:
                    interrupted = reason
                    self._terminate_group(proc, reason)
                    try:
                        proc.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        self.log("WARN: provider process did not exit after SIGKILL wait")
                    break
                if time.monotonic() - last_hb >= hb_interval:
                    self.checkpoint()  # heartbeat during long in-flight calls (KF-M06)
                    last_hb = time.monotonic()
                time.sleep(0.05 if self.dry_run else 0.5)
        stdout = out_path.read_text(encoding="utf-8", errors="replace")
        if interrupted == "timeout":
            return {"session_ref": sess["provider_session_ref"], "text": stdout, "cost_usd": 0.0,
                    "tokens": 0, "exit_kind": "timeout"}
        if interrupted:
            sess["ended_at"] = iso(now())
            sess["exit_kind"] = "killed"
            sess["phase_at_exit"] = phase
            self.checkpoint()
            raise Stop(interrupted)
        result = self._parse_shim_output(stdout)
        if proc.returncode != 0 and result["exit_kind"] == "completed":
            result["exit_kind"] = "crashed"
        if result["session_ref"]:
            sess["provider_session_ref"] = result["session_ref"]
        self.state["budget_spent"]["cost_usd"] += result["cost_usd"] or 0.0
        self.state["budget_spent"]["total_tokens"] += result["tokens"] or 0
        self.checkpoint()
        return result

    @staticmethod
    def _parse_shim_output(stdout: str) -> dict:
        """Shims print exactly one JSON object on their last non-empty stdout line."""
        for line in reversed(stdout.strip().splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    d = json.loads(line)
                    return {"session_ref": d.get("session_ref"), "text": d.get("text", ""),
                            "cost_usd": d.get("cost_usd") or 0.0, "tokens": d.get("tokens") or 0,
                            "exit_kind": d.get("exit_kind", "completed")}
                except json.JSONDecodeError:
                    continue
        return {"session_ref": None, "text": stdout, "cost_usd": 0.0, "tokens": 0, "exit_kind": "crashed"}

    def handle_session_exit(self, result: dict, phase: str) -> bool:
        """Returns True if a restart was performed and the caller should retry the phase."""
        if result["exit_kind"] == "completed":
            return False
        sess = self.current_session()
        sess["ended_at"] = iso(now())
        sess["exit_kind"] = result["exit_kind"]
        sess["phase_at_exit"] = phase
        self.log(f"session {sess['index']} exited: {result['exit_kind']} during {phase}")
        if self.state["restarts_used"] >= self.cfg["max_restarts"]:
            raise Stop("max-restarts")
        # Report the truthful stop reason: a passed deadline is "deadline" even when
        # the session exit (e.g. the shim-level call timeout) arrives first.
        if now() >= dt.datetime.fromisoformat(self.state["deadline_at"]):
            raise Stop("deadline")
        if not self.time_remaining_ok():
            raise Stop("min-work-window")
        handover = self.write_handover(
            f"Provider session ended ({result['exit_kind']}) during {phase}.")
        # Recovery model: handover-injection — the replacement session starts fresh
        # and receives the handover content in its first prompt (CXR-006/KF-H04).
        self.pending_handover = handover.read_text(encoding="utf-8")
        self.state["restarts_used"] += 1
        self.open_session(resume_handover=handover)
        return True

    # ---------- prompts ----------

    def base_context(self) -> str:
        c = self.cfg
        tasks = "\n".join(f"- [{t['status']}] {t['id']}: {self._task_text(t['id'])}" for t in self.state["tasks"])
        return f"""You are one session of a supervised autonomous run ({self.run_id}).
Run objective: {c['objective']}
Scope boundary (do not exceed): {c['scope_boundary']}
Definition of Done: {c['definition_of_done']}
Approved backlog:
{tasks}

Binding policies (read if not already in context): agent-framework/canonical/policies/
(autonomy, scope-control, evidence, security). Key rules:
- Evidence policy: every completion claim needs command + actual output. Print lines
  starting with 'EVIDENCE: <command> => <result>' for each verification you run.
- Scope policy: unrelated ideas go to BACKLOG.md 'Candidates', never implemented.
- If blocked, print exactly one line 'BLOCKER: <needs-decision|needs-access|needs-approval|budget-exhausted>: <why>'.
- This session is NON-INTERACTIVE: nobody can answer a prompt. Interactive-only
  affordances (plan-mode hand-off, permission/approval prompts, confirmation dialogs)
  do not exist here. Their absence is NOT a blocker — deliver your output directly in
  this response instead. Only report BLOCKER when the WORK itself cannot proceed.
- When your assigned phase is complete, print 'PHASE_RESULT: ok' (or 'PHASE_RESULT: blocked').
  A phase without a PHASE_RESULT line is treated as FAILED, never as success.
- Never force-push, never merge, never release, never touch files outside the scope boundary.
"""

    def _task_text(self, task_id: str) -> str:
        for t in self.cfg["approved_backlog"]:
            if t["id"] == task_id:
                return t["task"]
        for qid, qtext in QUALITY_LADDER:
            if qid == task_id:
                return qtext
        return task_id

    def phase_prompt(self, phase: str, task_id: str | None) -> str:
        directives = {
            "DISCOVER": "Phase DISCOVER: inspect the repository state relevant to the objective. Output: a short factual survey of current state and constraints. Do not edit files.",
            "PLAN": "Phase PLAN: output the execution plan as your response text (the supervisor persists your PLAN output verbatim to the run directory's exec-plan.md). Order the approved backlog, note validation commands per task. Do not implement yet.",
            "IMPLEMENT": f"Phase IMPLEMENT for task '{task_id}': {self._task_text(task_id)}. Work only within the scope boundary and this task.",
            "VERIFY": f"Phase VERIFY for task '{task_id}': run the deterministic checks for this task and print EVIDENCE lines. Do not claim success without output.",
            "REVIEW": f"Phase REVIEW for task '{task_id}': self-review the change (correctness, security, scope). List findings; fix Blocking ones; put optional ideas in BACKLOG.md Candidates.",
        }
        parts = [self.base_context()]
        if self.pending_handover:
            parts.append(
                "RESUMED SESSION: a previous provider session of this run ended abnormally. "
                "The handover below is your starting state — continue from it, treat its claims "
                "as REPORTED, NOT INDEPENDENTLY VERIFIED, and do not repeat completed work.\n\n"
                + self.pending_handover.strip() + "\n")
            self.pending_handover = None
        parts.append(directives[phase] + "\nEnd with PHASE_RESULT: ok|blocked.\n")
        return "\n".join(parts)

    # ---------- outputs parsing ----------

    @staticmethod
    def parse_markers(text: str) -> dict:
        blocker = None
        m = re.search(r"^BLOCKER:\s*(needs-decision|needs-access|needs-approval|budget-exhausted)\s*:?\s*(.*)$",
                      text, re.M)
        if m:
            blocker = {"class": m.group(1), "detail": m.group(2).strip()}
        evidence = re.findall(r"^EVIDENCE:\s*(.+)$", text, re.M)
        result = None
        m = re.search(r"^PHASE_RESULT:\s*(ok|blocked)\s*$", text, re.M)
        if m:
            result = m.group(1)
        return {"blocker": blocker, "evidence": evidence, "phase_result": result}

    # ---------- artifacts ----------

    def write_handover(self, reason: str) -> Path:
        n = sum(1 for p in self.dir.iterdir() if p.name.startswith("handover-")) + 1
        path = self.dir / f"handover-{n}.md"
        done = [t for t in self.state["tasks"] if t["status"].startswith("done")]
        remaining = [t for t in self.state["tasks"] if t["status"] in ("pending", "in_progress")]
        blocked = [t for t in self.state["tasks"] if t["status"] == "blocked"]
        status = "blocked" if (blocked and not remaining) else ("partial" if remaining else "done")
        blocker_class = blocked[0]["blocker_class"] if blocked else "none"
        ev_rows = [f"| {t['id']} ({t['status']}) | agent-asserted | {'; '.join(t['evidence']) or 'NO EVIDENCE — treat as done-claimed'} |"
                   for t in done]
        lines = [
            "## Handover", "",
            f"- Task: {self.cfg['objective']} (run {self.run_id}; reason: {reason})",
            f"- Status: {status}",
            f"- Blocker class: {blocker_class}",
            f"- Branch/worktree: {self.cfg['worktree']['branch']}", "",
            "### Completed (with evidence)",
            "| Claim | Command | Result |",
            "|-------|---------|--------|",
            *ev_rows,
            "", "### Not done / remaining",
            *(f"- {t['id']}: {self._task_text(t['id'])}" for t in remaining),
            "", "### Blocked",
            *(f"- {t['id']} [{t['blocker_class']}]" for t in blocked),
            "", "### Decisions made",
            "- none recorded by the supervisor (see session logs)",
            "", "### New candidates / risks filed",
            "- none recorded by the supervisor (see BACKLOG.md diff)",
            "", "### Next action",
            (f"Resume task '{remaining[0]['id']}' at IMPLEMENT." if remaining else "Run FINAL_REPORT."),
        ]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def write_morning_report(self):
        path = self.dir / "morning-report.md"
        s, t = self.state, self.state["tasks"]
        counts = {}
        for x in t:
            counts[x["status"]] = counts.get(x["status"], 0) + 1
        worktree_status = "NOT CHECKED (dry run)"
        if not self.dry_run:
            wt = self.cfg["worktree"].get("path") or str(REPO_ROOT)
            try:
                p = subprocess.run(["git", "-C", wt, "status", "--porcelain"],
                                   capture_output=True, text=True, timeout=30)
                worktree_status = "clean" if (p.returncode == 0 and not p.stdout.strip()) else \
                    f"DIRTY or unavailable (rc={p.returncode}):\n{p.stdout.strip()[:2000]}"
            except OSError as e:
                worktree_status = f"unavailable: {e}"
        lines = [
            f"# Morning Report — {self.run_id}", "",
            f"- Objective: {self.cfg['objective']}",
            f"- Provider/model: {s['provider']} / {s['model']}" + ("  (DRY RUN — no real provider was invoked)" if self.dry_run else ""),
            f"- Window: {s['started_at']} -> {s['deadline_at']} (stopped: {iso(now())})",
            f"- Stop reason: {s['stop_reason']}",
            f"- Sessions: {len(s['sessions'])} (restarts used: {s['restarts_used']}/{self.cfg['max_restarts']})",
            f"- Provider calls: {s['provider_calls']}",
            f"- Budget spent: ${s['budget_spent']['cost_usd']:.2f}, {s['budget_spent']['total_tokens']} tokens "
            "(cost/token caps are inter-call thresholds; see workflow doc)",
            f"- Worktree end state: {worktree_status}",
            f"- Task status: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())), "",
            "## Tasks", "",
        ]
        lines += ["> EVIDENCE lines below are AGENT-ASSERTED (parsed from model output, not",
                  "> independently executed by the supervisor). Re-run them before trusting",
                  "> any done-verified status — evidence policy, and security review finding I4.", ""]
        for x in t:
            lines.append(f"### {x['id']} — {x['status']}" + (f" [{x['blocker_class']}]" if x["blocker_class"] else ""))
            lines.append(f"{self._task_text(x['id'])}")
            lines += [f"- EVIDENCE (agent-asserted): {e}" for e in x["evidence"]] or ["- (no evidence recorded)"]
            lines.append("")
        lines += ["## Human follow-ups needed", ""]
        lines += [f"- {x['id']}: blocked ({x['blocker_class']})" for x in t if x["status"] == "blocked"] or ["- none"]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        s["morning_report_file"] = path.name
        self.log(f"morning report: {path}")

    # ---------- main loop ----------

    def _run_phase(self, phase: str, task_id: str | None) -> dict:
        """One phase to completion: provider calls with restart handling."""
        while True:
            r = self.call_provider(phase, self.phase_prompt(phase, task_id))
            if not self.handle_session_exit(r, phase):
                return r

    def _phase_with_marker(self, phase: str, task_id: str | None) -> dict:
        """Run a phase; fail closed when the provider output carries no PHASE_RESULT
        marker (retry once, then report failure — review findings CXR-007/KF-M07)."""
        r = self._run_phase(phase, task_id)
        marks = self.parse_markers(r["text"])
        if marks["phase_result"] is None and marks["blocker"] is None:
            self.log(f"{phase}: provider output carried no PHASE_RESULT marker — retrying once (fail-closed)")
            r = self._run_phase(phase, task_id)
            marks = self.parse_markers(r["text"])
            if marks["phase_result"] is None and marks["blocker"] is None:
                marks["phase_result"] = "failed-no-marker"
        return {"result": r, "marks": marks}

    def run(self) -> int:
        crashed = False
        try:
            self._main_loop()
        except Stop as stop:
            self.state["stop_reason"] = stop.reason
            self.log(f"stopping: {stop.reason}")
        except BaseException:
            # Exception-safe finalization: any unexpected error still produces a
            # durable crash reason, handover and morning report (CXR-020/KF-M08).
            crashed = True
            self.state["stop_reason"] = "crashed"
            self.log("CRASH:\n" + traceback.format_exc())
        finally:
            try:
                sess = self.current_session()
                if sess and not sess["ended_at"]:
                    sess["ended_at"] = iso(now())
                    sess["exit_kind"] = sess["exit_kind"] or "completed"
                self.write_handover(f"Run stop: {self.state['stop_reason']}")
                self.checkpoint("FINAL_REPORT")
                self.write_morning_report()
                self.checkpoint("STOPPED")
                schema = load_json(FRAMEWORK_DIR / "schemas" / "run-state.schema.json")
                validate_schema(self.state, schema)  # supervisor output must satisfy its own contract
                self.log("run state validates against run-state.schema.json")
            except Exception:
                crashed = True
                print("FINALIZATION ERROR:\n" + traceback.format_exc(), file=sys.stderr)
            finally:
                self._release_lock()
        if crashed:
            return 1
        return 0 if self.state["stop_reason"] in PLANNED_STOPS else 1

    def _main_loop(self):
        self.log(f"run {self.run_id} starting (provider={self.cfg['provider']}, dry_run={self.dry_run}, "
                 f"resume={self.skip_initial_phases})")
        plan_path = self.dir / self.state["exec_plan_file"]
        if not plan_path.exists():
            plan_path.write_text(
                f"# ExecPlan — {self.run_id}\n\nObjective: {self.cfg['objective']}\n\n"
                + "\n".join(f"- [ ] {t['id']}: {t['task']}" for t in self.cfg["approved_backlog"]) + "\n",
                encoding="utf-8")
        self.checkpoint("INITIALIZE")
        self.guard()
        self.open_session(resume_handover=None)
        if self.skip_initial_phases:
            self.log("resume: DISCOVER/PLAN already completed in the prior supervisor process — skipping")
        else:
            for phase in ("DISCOVER", "PLAN"):
                self.checkpoint(phase)
                out = self._phase_with_marker(phase, None)
                if out["marks"]["phase_result"] in ("blocked", "failed-no-marker") or out["marks"]["blocker"]:
                    raise Stop("provider-output-invalid" if out["marks"]["phase_result"] == "failed-no-marker"
                               else "blocked-all-tasks")
                if phase == "PLAN":
                    # Persist the PLAN output verbatim (CXR-007: the prompt's promise
                    # "the supervisor persists it" must actually happen).
                    plan_path.write_text(
                        f"# ExecPlan — {self.run_id} (provider PLAN output)\n\n"
                        + out["result"]["text"].rstrip() + "\n", encoding="utf-8")
        while True:
            task = self.select_next_task()
            if task is None:
                raise Stop("backlog-exhausted")
            task["status"] = "in_progress"
            self.checkpoint()
            blocked = False
            for phase in PHASES_PER_TASK:
                self.checkpoint(phase)
                out = self._phase_with_marker(phase, task["id"])
                marks = out["marks"]
                task["evidence"].extend(marks["evidence"])
                if marks["blocker"] or marks["phase_result"] in ("blocked", "failed-no-marker"):
                    task["status"] = "blocked"
                    task["blocker_class"] = (marks["blocker"] or {}).get("class", "needs-decision")
                    detail = ("no PHASE_RESULT marker after retry"
                              if marks["phase_result"] == "failed-no-marker" else task["blocker_class"])
                    self.log(f"task {task['id']} blocked: {detail}")
                    blocked = True
                    break
            self.checkpoint("UPDATE_STATE")
            if not blocked:
                task["status"] = "done-verified" if task["evidence"] else "done-claimed"
                self.log(f"task {task['id']} -> {task['status']}")
            self.checkpoint("SELECT_NEXT_TASK")
            self.checkpoint("CONTINUE_OR_HANDOVER")
            if not self.time_remaining_ok():
                raise Stop("min-work-window")

    def select_next_task(self) -> dict | None:
        for t in self.state["tasks"]:
            if t["status"] == "pending":
                return t
        blocked = [t for t in self.state["tasks"] if t["status"] == "blocked"]
        if blocked and all(t["status"] in ("blocked", "skipped") for t in self.state["tasks"]):
            raise Stop("blocked-all-tasks")
        # Approved backlog complete -> extend with the quality ladder exactly once.
        existing = {t["id"] for t in self.state["tasks"]}
        for qid, _ in QUALITY_LADDER:
            if qid not in existing:
                self.state["tasks"].append({"id": qid, "status": "pending", "blocker_class": None, "evidence": []})
        for t in self.state["tasks"]:
            if t["status"] == "pending":
                self.log("approved backlog complete — continuing with quality ladder (no new features)")
                return t
        return None


# ---------- preflight gates ----------

def _git(args: list[str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(["git", "-C", str(cwd)] + args, capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout or "").strip()


def verify_worktree(cfg: dict) -> str | None:
    """Return an error string when the configured worktree is not a verified,
    isolated, clean linked git worktree on the declared branch (CXR-004/KF-H06)."""
    wt = cfg["worktree"]
    wt_path = wt.get("path")
    if not wt_path:
        return ("worktree.path is required for real runs — the supervisor never runs "
                "in the primary checkout implicitly (create one with scripts/create-worktree.sh)")
    p = Path(wt_path)
    if p.is_symlink():
        return f"worktree.path {wt_path} is a symlink — refusing"
    resolved = p.resolve()
    if not resolved.is_dir():
        return f"worktree.path {wt_path} does not exist"
    if resolved == REPO_ROOT.resolve():
        return ("worktree.path is the primary checkout — real runs must use an isolated "
                "linked worktree (never the user's primary checkout)")
    rc, toplevel = _git(["rev-parse", "--show-toplevel"], resolved)
    if rc != 0 or Path(toplevel).resolve() != resolved:
        return f"worktree.path {wt_path} is not the top level of a git worktree"
    rc, wt_list = _git(["worktree", "list", "--porcelain"], REPO_ROOT)
    if rc != 0:
        return "git worktree list failed — cannot verify worktree membership"
    listed = {Path(line.split(" ", 1)[1]).resolve()
              for line in wt_list.splitlines() if line.startswith("worktree ")}
    if resolved not in listed:
        return (f"worktree.path {wt_path} is not a linked worktree of this repository "
                "(git worktree list does not include it)")
    rc, branch = _git(["rev-parse", "--abbrev-ref", "HEAD"], resolved)
    if rc != 0 or branch != wt["branch"]:
        return (f"worktree {wt_path} is on branch {branch!r}, config declares "
                f"{wt['branch']!r} — refusing")
    rc, status = _git(["status", "--porcelain"], resolved)
    if rc != 0:
        return f"git status failed in {wt_path}"
    if status:
        return (f"worktree {wt_path} is not clean — commit or stash before an "
                f"autonomous run:\n{status[:1000]}")
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True, help="Path to run config JSON (autonomous-run.schema.json)")
    ap.add_argument("--runs-dir", default=str(FRAMEWORK_DIR / "runs"), help="Where run directories are created")
    ap.add_argument("--dry-run", action="store_true", help="Exercise the full loop with shim canned responses")
    ap.add_argument("--simulate-exit-at", type=int, default=0,
                    help="Dry-run only: Nth provider call returns exit_kind=context-exhausted")
    ap.add_argument("--resume", metavar="RUN_ID", default=None,
                    help="Reload the checkpointed state of an existing run and continue it")
    args = ap.parse_args()

    cfg = load_json(Path(args.config))
    schema = load_json(FRAMEWORK_DIR / "schemas" / "autonomous-run.schema.json")
    try:
        validate_schema(cfg, schema)
    except SchemaError as e:
        print(f"run config invalid: {e}", file=sys.stderr)
        return 2
    real_run = not args.dry_run and not cfg.get("dry_run")
    if real_run:
        shim = SHIM_DIR / f"provider-{cfg['provider']}.sh"
        if not shim.exists():
            print(f"missing provider shim: {shim}", file=sys.stderr)
            return 2
        # Enforceability gates (security review B2/B3/B4): refuse configurations whose
        # declared policies no provider-side mechanism actually enforces, unless a
        # human explicitly acknowledged the residual risk in the run config.
        ack = cfg.get("provider_risk_acknowledged", False)
        if cfg["command_policy"]["mode"] == "custom":
            print("REFUSED: command_policy.mode=custom is not implemented by any provider "
                  "shim — declared-but-unenforced policies are not accepted. Use read-only "
                  "or workspace-write.", file=sys.stderr)
            return 2
        if cfg["provider"] == "kimi" and cfg["command_policy"]["mode"] == "read-only":
            print("REFUSED: command_policy.mode=read-only is not enforceable on Kimi "
                  "(print mode forces auto permission policy).", file=sys.stderr)
            return 2
        if cfg["provider"] == "kimi" and not ack:
            print("REFUSED: Kimi permissions are advisory-only (user-level config; see "
                  ".kimi-code/README.md). Set provider_risk_acknowledged: true after "
                  "installing the permission profile, or use another provider.", file=sys.stderr)
            return 2
        mode = cfg["network_policy"]["mode"]
        if mode == "allowlist" and not ack:
            # No provider translates allowed_domains into enforcement — codex's sandbox
            # is a static binary off switch (review finding KF-M09).
            print("REFUSED: network_policy.mode=allowlist is not enforceable on any "
                  "provider (codex egress enforcement is a static off switch; "
                  "allowed_domains has no consumer). Set provider_risk_acknowledged: true "
                  "to accept declared-but-unenforced network policy.", file=sys.stderr)
            return 2
        if mode == "offline" and cfg["provider"] != "codex" and not ack:
            print(f"REFUSED: network_policy.mode=offline is not enforceable on provider "
                  f"'{cfg['provider']}' (only codex ships egress enforcement in "
                  ".codex/config.toml). Set provider_risk_acknowledged: true to accept "
                  "declared-but-unenforced network policy.", file=sys.stderr)
            return 2
        if mode == "open" and cfg["provider"] == "codex":
            print("NOTE: .codex/config.toml disables sandbox network access regardless of "
                  "network_policy.mode=open — the run will have LESS network access than "
                  "declared.", file=sys.stderr)
        if cfg["provider"] != "claude" and "max_provider_calls" not in cfg["budget"]:
            print(f"REFUSED: provider '{cfg['provider']}' does not report cost to the "
                  "supervisor, so max_cost_usd/max_total_tokens cannot trip. Set "
                  "budget.max_provider_calls as the enforceable cap.", file=sys.stderr)
            return 2
        err = verify_worktree(cfg)
        if err:
            print(f"REFUSED: {err}", file=sys.stderr)
            return 2
    sup = Supervisor(cfg, Path(args.runs_dir), args.dry_run, args.simulate_exit_at,
                     resume=args.resume)
    return sup.run()


if __name__ == "__main__":
    sys.exit(main())
