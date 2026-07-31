"""Supervisor lifecycle regressions (CXR-004/005/006/007/008/019/020, KF-H04/H05/H06,
KF-M06/M07/M08, KF-L13/L14/L46).

Real-mode tests use a mock `claude` CLI on PATH plus a throwaway linked git worktree
of this repository (created in setUpModule, removed in tearDownModule). No real
provider is ever invoked.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import REPO_ROOT, SCRIPTS, base_run_config, scratch_dir, supervisor, write_mock_cli  # noqa: E402

WT_PATH: Path | None = None
WT_BRANCH = f"af-test-{uuid.uuid4().hex[:8]}"
MOCK_BIN: Path | None = None

FAST_CLAUDE = r'''
# mock claude: instant benign JSON with markers
cat > /dev/null  # consume stdin prompt
printf '{"session_id":"mock-1","result":"SIMULATED\nEVIDENCE: mock => ok\nPHASE_RESULT: ok\n","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5}}\n'
'''

SLOW_CLAUDE = r'''
# mock claude: sleeps far longer than any test window
cat > /dev/null
sleep 300 &
CHILD=$!
trap 'kill $CHILD 2>/dev/null; exit 143' TERM INT
wait $CHILD
printf '{"session_id":"mock-slow","result":"PHASE_RESULT: ok\n","total_cost_usd":0.0,"usage":{}}\n'
'''


def setUpModule():
    global WT_PATH, MOCK_BIN
    base = scratch_dir()
    WT_PATH = base / "worktree"
    subprocess.run(["git", "-C", str(REPO_ROOT), "worktree", "add", "-b", WT_BRANCH,
                    str(WT_PATH)], check=True, capture_output=True, text=True)
    MOCK_BIN = base / "bin"
    write_mock_cli(MOCK_BIN, "claude", FAST_CLAUDE)


def tearDownModule():
    subprocess.run(["git", "-C", str(REPO_ROOT), "worktree", "remove", "--force", str(WT_PATH)],
                   capture_output=True, text=True)
    subprocess.run(["git", "-C", str(REPO_ROOT), "branch", "-D", WT_BRANCH],
                   capture_output=True, text=True)
    shutil.rmtree(WT_PATH.parent, ignore_errors=True)


def real_cfg(**overrides):
    cfg = base_run_config(**overrides)
    cfg["worktree"] = {"branch": WT_BRANCH, "path": str(WT_PATH)}
    return cfg


def mock_env(extra: dict | None = None) -> dict:
    env = {"PATH": f"{MOCK_BIN}:{os.environ['PATH']}"}
    if extra:
        env.update(extra)
    return env


class TestWorktreeGate(unittest.TestCase):
    """CXR-004/KF-H06: table-driven refusal tests. All must exit 2 (REFUSED)."""

    def _refused(self, cfg, needle: str):
        runs = scratch_dir()
        try:
            p = supervisor(cfg, runs)
            self.assertEqual(p.returncode, 2, p.stderr + p.stdout)
            self.assertIn("REFUSED", p.stderr)
            self.assertIn(needle, p.stderr)
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_omitted_path_refused(self):
        cfg = base_run_config(run_id="wt-omit")
        cfg["worktree"] = {"branch": WT_BRANCH}
        self._refused(cfg, "worktree.path is required")

    def test_primary_checkout_refused(self):
        cfg = base_run_config(run_id="wt-primary")
        cfg["worktree"] = {"branch": WT_BRANCH, "path": str(REPO_ROOT)}
        self._refused(cfg, "primary checkout")

    def test_arbitrary_sibling_refused(self):
        sib = scratch_dir()
        try:
            cfg = base_run_config(run_id="wt-sib")
            cfg["worktree"] = {"branch": WT_BRANCH, "path": str(sib)}
            self._refused(cfg, "not the top level of a git worktree")
        finally:
            shutil.rmtree(sib, ignore_errors=True)

    def test_wrong_branch_refused(self):
        cfg = real_cfg(run_id="wt-branch")
        cfg["worktree"]["branch"] = "definitely-not-this-branch"
        self._refused(cfg, "config declares")

    def test_dirty_worktree_refused(self):
        marker = WT_PATH / "dirty-marker.txt"
        marker.write_text("dirty")
        try:
            self._refused(real_cfg(run_id="wt-dirty"), "not clean")
        finally:
            marker.unlink()

    def test_valid_worktree_accepted(self):
        runs = scratch_dir()
        try:
            p = supervisor(real_cfg(run_id="wt-ok", budget={"max_provider_calls": 3}),
                           runs, env=mock_env())
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            state = json.loads((runs / "wt-ok" / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "budget")
            self.assertEqual(state["provider_calls"], 3)  # persisted hard cap (CXR-019)
        finally:
            shutil.rmtree(runs, ignore_errors=True)


class TestInFlightEnforcement(unittest.TestCase):
    """CXR-005/KF-H05: deadline, kill switch, and SIGTERM interrupt in-flight calls."""

    @classmethod
    def setUpClass(cls):
        cls.slow_bin = scratch_dir() / "bin"
        write_mock_cli(cls.slow_bin, "claude", SLOW_CLAUDE)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.slow_bin.parent, ignore_errors=True)

    def slow_env(self):
        return {"PATH": f"{self.slow_bin}:{os.environ['PATH']}"}

    def test_deadline_interrupts_in_flight_call(self):
        runs = scratch_dir()
        try:
            cfg = real_cfg(run_id="if-deadline", duration_hours=6 / 3600,  # 6 s
                           min_useful_work_minutes=0.01)
            t0 = time.monotonic()
            p = supervisor(cfg, runs, env=self.slow_env(), timeout=90)
            elapsed = time.monotonic() - t0
            state = json.loads((runs / "if-deadline" / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "deadline", p.stderr)
            self.assertEqual(p.returncode, 0)
            self.assertLess(elapsed, 45, f"deadline overran: {elapsed:.1f}s (call sleeps 300s)")
            # Two independent enforcement layers race at the deadline: the supervisor's
            # process-group kill records "killed"; the shim-level AF_CALL_TIMEOUT_SECONDS
            # bound records "timeout". Either proves the in-flight call was interrupted.
            self.assertIn(state["sessions"][-1]["exit_kind"], ("killed", "timeout"))
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_kill_switch_interrupts_in_flight_call(self):
        runs = scratch_dir()
        try:
            cfg = real_cfg(run_id="if-kill")
            cfg_path = runs / "cfg.json"
            runs.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(cfg))
            env = os.environ.copy()
            env.update(self.slow_env())
            proc = subprocess.Popen(
                [sys.executable, str(SCRIPTS / "run-autonomous-session.py"),
                 "--config", str(cfg_path), "--runs-dir", str(runs)],
                cwd=REPO_ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            run_dir = runs / "if-kill"
            deadline = time.monotonic() + 20
            while not run_dir.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            time.sleep(2)  # let the slow call start
            (run_dir / "STOP").write_text("stop")
            t0 = time.monotonic()
            proc.communicate(timeout=45)  # also closes the captured pipes
            latency = time.monotonic() - t0
            state = json.loads((run_dir / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "kill-switch")
            self.assertEqual(proc.returncode, 0)
            self.assertLess(latency, 30, f"kill-switch latency {latency:.1f}s")
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_sigterm_interrupts_in_flight_call(self):
        runs = scratch_dir()
        try:
            cfg = real_cfg(run_id="if-term")
            cfg_path = runs / "cfg.json"
            runs.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(cfg))
            env = os.environ.copy()
            env.update(self.slow_env())
            proc = subprocess.Popen(
                [sys.executable, str(SCRIPTS / "run-autonomous-session.py"),
                 "--config", str(cfg_path), "--runs-dir", str(runs)],
                cwd=REPO_ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            run_dir = runs / "if-term"
            deadline = time.monotonic() + 20
            while not run_dir.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            time.sleep(2)
            proc.send_signal(signal.SIGTERM)
            t0 = time.monotonic()
            proc.communicate(timeout=45)  # also closes the captured pipes
            latency = time.monotonic() - t0
            state = json.loads((run_dir / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "signal")
            self.assertEqual(proc.returncode, 1)  # signal stop is not a planned stop
            self.assertLess(latency, 30)
            self.assertIsNotNone(state["morning_report_file"])  # finalization still ran
        finally:
            shutil.rmtree(runs, ignore_errors=True)


class TestNonInteractiveContract(unittest.TestCase):
    """Live pilot 2026-07-20 (reports/pilot-live-providers.md, F-P1).

    Every session runs headless, so interactive-only affordances do not exist. Claude's
    first live DISCOVER response opened with "ExitPlanMode isn't available in this
    non-interactive supervised run context, so I can't complete that hand-off step" —
    it reached for plan-mode hand-off, found it missing, and spent a turn on it. It
    recovered and still returned PHASE_RESULT: ok, but a model that instead emitted
    'BLOCKER: needs-access' would abort an overnight run over a tool that was never
    needed. The same failure shape was independently seen for permission 'ask' rules,
    which under `claude -p` have nobody to ask.

    The prompt must therefore state the session is non-interactive and that a missing
    interactive affordance is not a blocker.
    """

    def test_prompt_declares_the_session_non_interactive(self):
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="noninteractive")
            p = supervisor(cfg, runs, "--dry-run")
            self.assertEqual(p.returncode, 0, p.stderr)
            prompt = (runs / "noninteractive" / "logs" / "prompt-001-discover.md").read_text()
            self.assertIn("NON-INTERACTIVE", prompt,
                          "the session prompt must declare that nobody can answer a prompt")
            low = prompt.lower()
            self.assertIn("not a blocker", low,
                          "a missing interactive affordance must be named as NOT a blocker, "
                          "or a session can abort the run over an unavailable tool")
            for affordance in ("plan-mode", "permission", "approval"):
                self.assertIn(affordance, low, f"prompt should name {affordance!r} explicitly")

        finally:
            shutil.rmtree(runs, ignore_errors=True)


class TestDryRunStateMachine(unittest.TestCase):
    def test_restart_injects_handover_into_next_prompt(self):
        """CXR-006/KF-H04: the replacement session's first prompt embeds the handover."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sm-restart")
            p = supervisor(cfg, runs, "--dry-run", "--simulate-exit-at", "3")
            self.assertEqual(p.returncode, 0, p.stderr)
            d = runs / "sm-restart"
            state = json.loads((d / "run-state.json").read_text())
            s2 = state["sessions"][1]
            self.assertEqual(s2["recovery_model"], "handover-injection")
            self.assertEqual(s2["handover_file"], "handover-1.md")
            retry_prompt = (d / "logs" / "prompt-004-implement.md").read_text()
            self.assertIn("RESUMED SESSION", retry_prompt)
            self.assertIn("## Handover", retry_prompt)
            self.assertIn("Next action", retry_prompt)
            self.assertIn("REPORTED, NOT INDEPENDENTLY VERIFIED", retry_prompt)
            next_prompt = (d / "logs" / "prompt-005-verify.md").read_text()
            self.assertNotIn("RESUMED SESSION", next_prompt)
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_missing_phase_result_fails_closed(self):
        """CXR-007/KF-M07: marker-free output must never register as success."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sm-nomarker")
            p = supervisor(cfg, runs, "--dry-run", env={"AF_DRYRUN_OMIT_PHASE_RESULT": "1"})
            self.assertEqual(p.returncode, 1)
            state = json.loads((runs / "sm-nomarker" / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "provider-output-invalid")
            self.assertEqual(state["provider_calls"], 2)  # one retry, then fail closed
            self.assertFalse(any(t["status"].startswith("done") for t in state["tasks"]))
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_no_evidence_yields_done_claimed(self):
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sm-noev")
            p = supervisor(cfg, runs, "--dry-run", env={"AF_DRYRUN_OMIT_EVIDENCE": "1"})
            self.assertEqual(p.returncode, 0, p.stderr)
            state = json.loads((runs / "sm-noev" / "run-state.json").read_text())
            self.assertTrue(all(t["status"] == "done-claimed" for t in state["tasks"]))
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_duplicate_run_id_refused(self):
        """CXR-008: exclusive run-directory creation."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sm-dup")
            self.assertEqual(supervisor(cfg, runs, "--dry-run").returncode, 0)
            p2 = supervisor(cfg, runs, "--dry-run")
            self.assertNotEqual(p2.returncode, 0)
            self.assertIn("already exists", p2.stderr)
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_min_work_window_has_own_stop_reason(self):
        """KF-L13: a planned early stop is not mislabeled as deadline."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sm-minwork", duration_hours=0.02,
                                  min_useful_work_minutes=10)
            p = supervisor(cfg, runs, "--dry-run")
            self.assertEqual(p.returncode, 0, p.stderr)
            state = json.loads((runs / "sm-minwork" / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "min-work-window")
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_kill_switch_path_traversal_rejected(self):
        """KF-L14: kill_switch_file must be a plain run-dir-relative name."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sm-ksbad", kill_switch_file="../evil")
            p = supervisor(cfg, runs, "--dry-run")
            self.assertEqual(p.returncode, 2)
            self.assertIn("kill_switch_file", p.stderr)
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_blocker_regex_accepts_budget_exhausted(self):
        """KF-L46: all four canonical blocker classes parse."""
        marks = _supervisor_module().Supervisor.parse_markers("BLOCKER: budget-exhausted: out of budget\n")
        self.assertEqual(marks["blocker"]["class"], "budget-exhausted")


def _supervisor_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("af_sup", SCRIPTS / "run-autonomous-session.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestCuratedEnvironment(unittest.TestCase):
    """H8 regression (KF-M02/KF-H01 env leg): the documented KIMI_MODEL_* channel
    survives the environment scrub; inert legacy variables and other providers'
    credentials are dropped."""

    def test_kimi_model_prefix_survives_and_legacy_vars_dropped(self):
        env = _supervisor_module().curated_env("kimi", {
            "PATH": "/bin", "KIMI_CODE_HOME": "/home/x/.kimi-code",
            "KIMI_MODEL_NAME": "kimi-k2", "KIMI_MODEL_BASE_URL": "https://example",
            "MOONSHOT_API_KEY": "legacy-inert", "KIMI_API_KEY": "legacy-inert",
            "ANTHROPIC_API_KEY": "other-provider", "GITHUB_TOKEN": "unrelated-secret",
        })
        self.assertEqual(env.get("KIMI_MODEL_NAME"), "kimi-k2")
        self.assertEqual(env.get("KIMI_MODEL_BASE_URL"), "https://example")
        self.assertEqual(env.get("KIMI_CODE_HOME"), "/home/x/.kimi-code")
        self.assertIn("PATH", env)
        for dropped in ("MOONSHOT_API_KEY", "KIMI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN"):
            self.assertNotIn(dropped, env)

    def test_provider_credentials_do_not_cross_providers(self):
        env = _supervisor_module().curated_env("claude", {
            "PATH": "/bin", "ANTHROPIC_API_KEY": "mine",
            "KIMI_MODEL_NAME": "kimi-k2", "OPENAI_API_KEY": "not-mine",
        })
        self.assertEqual(env.get("ANTHROPIC_API_KEY"), "mine")
        self.assertNotIn("KIMI_MODEL_NAME", env)
        self.assertNotIn("OPENAI_API_KEY", env)


class TestResumeAndRecovery(unittest.TestCase):
    def test_sigkill_then_resume_completes(self):
        """CXR-020/KF-M08: after an unclean death, --resume reloads the validated
        checkpoint and finishes the run."""
        runs = scratch_dir()
        try:
            cfg = real_cfg(run_id="rc-resume",
                           approved_backlog=[{"id": f"task-{i}", "task": f"Simulated task {i}"}
                                             for i in range(4)])
            cfg_path = runs / "cfg.json"
            runs.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(cfg))
            env = os.environ.copy()
            env["PATH"] = f"{MOCK_BIN}:{env['PATH']}"
            proc = subprocess.Popen(
                [sys.executable, str(SCRIPTS / "run-autonomous-session.py"),
                 "--config", str(cfg_path), "--runs-dir", str(runs)],
                cwd=REPO_ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            state_file = runs / "rc-resume" / "run-state.json"
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if state_file.exists():
                    try:
                        s = json.loads(state_file.read_text())
                        if s.get("provider_calls", 0) >= 4:
                            break
                    except json.JSONDecodeError:
                        pass
                time.sleep(0.1)
            proc.kill()  # SIGKILL: no finalization possible
            proc.communicate(timeout=10)  # reap and close the captured pipes
            p2 = supervisor(cfg, runs, "--resume", "rc-resume",
                            env={"PATH": f"{MOCK_BIN}:{os.environ['PATH']}"})
            self.assertEqual(p2.returncode, 0, p2.stderr + p2.stdout)
            state = json.loads(state_file.read_text())
            self.assertEqual(state["stop_reason"], "backlog-exhausted")
            self.assertNotIn("in_progress", {t["status"] for t in state["tasks"]})
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_corrupt_state_quarantined_on_resume(self):
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="rc-corrupt")
            self.assertEqual(supervisor(cfg, runs, "--dry-run").returncode, 0)
            state_file = runs / "rc-corrupt" / "run-state.json"
            state_file.write_text("{ this is not json")
            p = supervisor(cfg, runs, "--dry-run", "--resume", "rc-corrupt")
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("quarantined", p.stderr)
            self.assertTrue((runs / "rc-corrupt" / "run-state.json.corrupt").exists())
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_live_lock_blocks_second_supervisor(self):
        """CXR-008: a live lock holder refuses a concurrent supervisor."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="rc-lock", duration_hours=0.02,
                                  min_useful_work_minutes=10)
            self.assertEqual(supervisor(cfg, runs, "--dry-run").returncode, 0)
            # make the checkpoint look interrupted (resumable), then hold the lock
            state_file = runs / "rc-lock" / "run-state.json"
            state = json.loads(state_file.read_text())
            state["stop_reason"] = None
            state["state"] = "IMPLEMENT"
            state_file.write_text(json.dumps(state))
            (runs / "rc-lock" / "supervisor.lock").write_text(str(os.getpid()))
            p = supervisor(cfg, runs, "--dry-run", "--resume", "rc-lock")
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("already owned by live supervisor", p.stderr)
        finally:
            shutil.rmtree(runs, ignore_errors=True)


STUBBORN_CLAUDE = r'''
# mock claude: the leader exits promptly on TERM while a descendant IGNORES TERM —
# the exact scenario where leader-poll-based escalation skipped SIGKILL
# (verification finding 4, CXR-005/KF-H05 residual).
cat > /dev/null
( trap '' TERM; while :; do sleep 1; done ) &
echo $! > "$TMPDIR/stubborn.pid"
trap 'exit 143' TERM INT
sleep 300 &
C=$!
wait $C
'''

COUNTING_SLOW_CLAUDE = r'''
# mock claude: records every invocation and its pid, then blocks like a long call
cat > /dev/null
echo x >> "$TMPDIR/calls.log"
echo $$ >> "$TMPDIR/pids.log"
sleep 300 &
C=$!
trap 'kill $C 2>/dev/null; exit 143' TERM INT
wait $C
printf '{"session_id":"mock-slow","result":"PHASE_RESULT: ok\n","total_cost_usd":0.0,"usage":{}}\n'
'''


class TestProcessGroupEscalation(unittest.TestCase):
    """Verification finding 4: SIGKILL escalation must be decided by process-GROUP
    liveness, not the leader's poll() state."""

    def test_stubborn_descendant_killed_after_leader_exits(self):
        runs = scratch_dir()
        tdir = scratch_dir()
        bin_dir = tdir / "bin"
        write_mock_cli(bin_dir, "claude", STUBBORN_CLAUDE)
        stubborn_pid = None
        try:
            cfg = real_cfg(run_id="pg-stubborn")
            cfg_path = runs / "cfg.json"
            runs.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(cfg))
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["TMPDIR"] = str(tdir)  # TMPDIR survives the supervisor's env curation
            with subprocess.Popen(
                    [sys.executable, str(SCRIPTS / "run-autonomous-session.py"),
                     "--config", str(cfg_path), "--runs-dir", str(runs)],
                    cwd=REPO_ROOT, env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True) as proc:
                pid_file = tdir / "stubborn.pid"
                deadline = time.monotonic() + 30
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertTrue(pid_file.exists(), "mock provider never started")
                stubborn_pid = int(pid_file.read_text().strip())
                (runs / "pg-stubborn" / "STOP").write_text("stop")
                proc.communicate(timeout=60)
            state = json.loads((runs / "pg-stubborn" / "run-state.json").read_text())
            self.assertEqual(state["stop_reason"], "kill-switch")
            gone = False
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(stubborn_pid, 0)
                except ProcessLookupError:
                    gone = True
                    break
                time.sleep(0.2)
            self.assertTrue(gone, f"TERM-ignoring descendant {stubborn_pid} survived — "
                                  "process-group SIGKILL escalation did not happen")
        finally:
            if stubborn_pid is not None:
                try:
                    os.killpg(os.getpgid(stubborn_pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
            shutil.rmtree(runs, ignore_errors=True)
            shutil.rmtree(tdir, ignore_errors=True)


class TestProviderCallReservation(unittest.TestCase):
    """Verification finding 5 (CXR-019/B3): the provider-call count is durably
    checkpointed BEFORE launch, so an abrupt supervisor death plus --resume can
    never exceed the max_provider_calls hard cap."""

    def test_reservation_durable_across_abrupt_death_and_resume(self):
        runs = scratch_dir()
        tdir = scratch_dir()
        slow_bin = tdir / "bin"
        write_mock_cli(slow_bin, "claude", COUNTING_SLOW_CLAUDE)
        mock_pids: list[int] = []
        try:
            # huge heartbeat: the ONLY checkpoint that can persist the count before
            # the abrupt death is the pre-launch reservation itself
            cfg = real_cfg(run_id="cap-res", budget={"max_provider_calls": 1},
                           heartbeat_seconds=100000)
            cfg_path = runs / "cfg.json"
            runs.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(cfg))
            env = os.environ.copy()
            env["PATH"] = f"{slow_bin}:{env['PATH']}"
            env["TMPDIR"] = str(tdir)
            calls_log = tdir / "calls.log"
            with subprocess.Popen(
                    [sys.executable, str(SCRIPTS / "run-autonomous-session.py"),
                     "--config", str(cfg_path), "--runs-dir", str(runs)],
                    cwd=REPO_ROOT, env=env, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL) as proc:
                deadline = time.monotonic() + 30
                while not calls_log.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertTrue(calls_log.exists(), "mock provider never invoked")
                state_file = runs / "cap-res" / "run-state.json"
                state = json.loads(state_file.read_text())
                self.assertEqual(state["provider_calls"], 1,
                                 "the in-flight call must be durably reserved in the "
                                 "checkpoint BEFORE the provider is launched")
                proc.kill()  # abrupt death: reservation made, call incomplete
                proc.wait(timeout=10)
            mock_pids = [int(x) for x in (tdir / "pids.log").read_text().split()]
            for pid in mock_pids:  # reap the orphaned in-flight call before resuming
                try:
                    os.killpg(os.getpgid(pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
            p2 = supervisor(cfg, runs, "--resume", "cap-res",
                            env={"PATH": f"{MOCK_BIN}:{os.environ['PATH']}",
                                 "TMPDIR": str(tdir)})
            self.assertEqual(p2.returncode, 0, p2.stderr + p2.stdout)
            state = json.loads(state_file.read_text())
            self.assertEqual(state["stop_reason"], "budget")
            self.assertEqual(state["provider_calls"], 1)
            self.assertEqual(len(calls_log.read_text().splitlines()), 1,
                             "resume issued a provider call beyond the hard cap")
        finally:
            for pid in mock_pids:
                try:
                    os.killpg(os.getpgid(pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
            shutil.rmtree(runs, ignore_errors=True)
            shutil.rmtree(tdir, ignore_errors=True)


class TestSemanticResumeValidation(unittest.TestCase):
    """Verification finding 6: syntactically valid but operationally corrupt
    resume state must be quarantined, never executed."""

    def _quarantined(self, name: str, mutate) -> None:
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id=f"sq-{name}")
            self.assertEqual(supervisor(cfg, runs, "--dry-run").returncode, 0)
            state_file = runs / f"sq-{name}" / "run-state.json"
            state = json.loads(state_file.read_text())
            state["stop_reason"] = None  # make the checkpoint look interrupted
            state["state"] = "IMPLEMENT"
            mutate(state)
            state_file.write_text(json.dumps(state))
            p = supervisor(cfg, runs, "--dry-run", "--resume", f"sq-{name}")
            self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn("quarantined", p.stderr)
            self.assertTrue((runs / f"sq-{name}" / "run-state.json.corrupt").exists())
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_missing_budget_field_quarantined(self):
        self._quarantined("bud", lambda s: s["budget_spent"].pop("total_tokens"))

    def test_invalid_datetime_quarantined(self):
        self._quarantined("date", lambda s: s.update(started_at="not-a-timestamp"))

    def test_negative_budget_quarantined(self):
        self._quarantined("neg", lambda s: s["budget_spent"].update(total_tokens=-5))

    def test_done_verified_without_evidence_quarantined(self):
        def mutate(s):
            s["tasks"][0]["status"] = "done-verified"
            s["tasks"][0]["evidence"] = []
        self._quarantined("ev", mutate)

    def test_inconsistent_restart_counter_quarantined(self):
        self._quarantined("restart", lambda s: s.update(restarts_used=7))

    def test_run_id_mismatch_quarantined(self):
        self._quarantined("runid", lambda s: s.update(run_id="a-different-run"))

    def test_provider_mismatch_refused_without_quarantine(self):
        """A state/config disagreement is refused, but the state itself is not
        corrupt and must NOT be quarantined."""
        runs = scratch_dir()
        try:
            cfg = base_run_config(run_id="sq-prov")
            self.assertEqual(supervisor(cfg, runs, "--dry-run").returncode, 0)
            state_file = runs / "sq-prov" / "run-state.json"
            state = json.loads(state_file.read_text())
            state["stop_reason"] = None
            state["state"] = "IMPLEMENT"
            state_file.write_text(json.dumps(state))
            cfg2 = dict(cfg)
            cfg2["provider"] = "codex"
            p = supervisor(cfg2, runs, "--dry-run", "--resume", "sq-prov")
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("fix the config", p.stderr)
            self.assertTrue(state_file.exists())
            self.assertFalse((runs / "sq-prov" / "run-state.json.corrupt").exists())
        finally:
            shutil.rmtree(runs, ignore_errors=True)


class TestEnforceabilityGates(unittest.TestCase):
    def _refused(self, cfg, needle):
        runs = scratch_dir()
        try:
            p = supervisor(cfg, runs)
            self.assertEqual(p.returncode, 2, p.stderr + p.stdout)
            self.assertIn(needle, p.stderr)
        finally:
            shutil.rmtree(runs, ignore_errors=True)

    def test_custom_command_policy_refused(self):
        cfg = real_cfg(run_id="g-custom", command_policy={"mode": "custom"})
        self._refused(cfg, "custom")

    def test_kimi_readonly_refused(self):
        cfg = real_cfg(run_id="g-kimiro", provider="kimi",
                       command_policy={"mode": "read-only"},
                       provider_risk_acknowledged=True)
        self._refused(cfg, "read-only is not enforceable on Kimi")

    def test_allowlist_requires_ack_on_every_provider(self):
        """KF-M09: allowlist is unimplemented everywhere, including codex."""
        cfg = real_cfg(run_id="g-allow", provider="codex",
                       network_policy={"mode": "allowlist", "allowed_domains": ["example.com"]})
        self._refused(cfg, "allowlist")


if __name__ == "__main__":
    unittest.main()
