"""Provider shim command-construction regressions (CXR-002/KF-H13, KF-H01,
CXR-003/KF-H14, KF-M02, KF-M31).

Each test installs a mock provider CLI on PATH that records its argv and stdin,
then invokes the real shim. No live provider is ever contacted.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import SCRIPTS, scratch_dir, write_mock_cli  # noqa: E402

RECORDER = r'''
REC="${MOCK_RECORD_DIR:?}/argv"
printf '%s\0' "$@" > "$REC"
cat > "${MOCK_RECORD_DIR}/stdin"
'''


class ShimTestBase(unittest.TestCase):
    shim: str
    cli: str
    cli_response: str = ""
    # Prepended BEFORE the recorder: lets a mock answer the `--version` probe
    # without recording it (the codex shim's fail-closed version gate needs a
    # supported version answer to proceed).
    cli_prelude: str = ""

    def setUp(self):
        self.tmp = scratch_dir()
        self.bin = self.tmp / "bin"
        self.record = self.tmp / "rec"
        self.record.mkdir()
        self.prompt = self.tmp / "prompt.md"
        self.prompt.write_text("Test prompt content\nwith two lines\n")
        self.workdir = self.tmp / "wd"
        self.workdir.mkdir()
        write_mock_cli(self.bin, self.cli, self.cli_prelude + RECORDER + self.cli_response)
        write_mock_cli(self.bin, self.cli + "-version-stub", "true")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_shim(self, session_ref: str = "", command_mode: str = "workspace-write",
                 extra_env: dict | None = None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "MOCK_RECORD_DIR": str(self.record),
            "AF_PROMPT_FILE": str(self.prompt),
            "AF_SESSION_REF": session_ref,
            "AF_MODEL": "test-model",
            "AF_WORKDIR": str(self.workdir),
            "AF_PHASE": "TEST",
            "AF_NETWORK_MODE": "open",
            "AF_COMMAND_MODE": command_mode,
            "AF_DRY_RUN": "0",
        })
        if extra_env:
            env.update(extra_env)
        # stdin=DEVNULL pins the test regardless of how the runner was launched: a
        # TTY/held-open stdin must never be inheritable by shim or fake CLI (the
        # inherited-stdin hang is regression-tested separately below).
        return subprocess.run([str(SCRIPTS / self.shim)], env=env,
                              stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)

    def run_shim_with_held_stdin(self, command_mode: str = "workspace-write",
                                 timeout: int = 30) -> subprocess.CompletedProcess:
        """Launch the shim with a stdin pipe that is NEVER closed — the exact
        environment (interactive TTY / held-open pipe) that made unredirected
        provider stdin block forever. Post-fix, shims must not read stdin at all."""
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "MOCK_RECORD_DIR": str(self.record),
            "AF_PROMPT_FILE": str(self.prompt),
            "AF_SESSION_REF": "",
            "AF_MODEL": "test-model",
            "AF_WORKDIR": str(self.workdir),
            "AF_PHASE": "TEST",
            "AF_NETWORK_MODE": "open",
            "AF_COMMAND_MODE": command_mode,
            "AF_DRY_RUN": "0",
        })
        r, w = os.pipe()
        try:
            return subprocess.run([str(SCRIPTS / self.shim)], env=env, stdin=r,
                                  capture_output=True, text=True, timeout=timeout)
        finally:
            os.close(r)
            os.close(w)  # only closed AFTER the shim finished — no EOF was ever sent

    def argv(self) -> list[str]:
        raw = (self.record / "argv").read_text()
        return raw.split("\0")[:-1] if raw else []

    @staticmethod
    def last_json(p: subprocess.CompletedProcess) -> dict:
        for line in reversed(p.stdout.strip().splitlines()):
            if line.startswith("{"):
                return json.loads(line)
        raise AssertionError(f"no JSON in shim output: {p.stdout!r} / {p.stderr!r}")


class TestCodexShim(ShimTestBase):
    shim = "provider-codex.sh"
    cli = "codex"
    cli_prelude = 'if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.144.6"; exit 0; fi\n'
    cli_response = (
        'printf \'{"type":"thread.started","thread_id":"th-1"}\\n\'\n'
        'printf \'{"type":"item.completed","item":{"type":"agent_message","text":"PHASE_RESULT: ok"}}\\n\'\n'
        'printf \'{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":3}}\\n\'\n')

    def test_initial_call_uses_sandbox_flag(self):
        p = self.run_shim()
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[0], "exec")
        self.assertIn("--sandbox", argv)
        self.assertNotIn("resume", argv)
        out = self.last_json(p)
        self.assertEqual(out["session_ref"], "th-1")
        self.assertEqual(out["tokens"], 18)  # includes cache tokens (KF-L03)

    def test_resume_never_passes_sandbox_flag(self):
        """CXR-002/KF-H13: `codex exec resume` rejects --sandbox; the shim must use
        the supported -c sandbox_mode=... override instead."""
        p = self.run_shim(session_ref="th-1", command_mode="read-only")
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[:3], ["exec", "resume", "th-1"])
        self.assertNotIn("--sandbox", argv)
        self.assertIn("-c", argv)
        self.assertIn('sandbox_mode="read-only"', argv)

    def test_empty_output_reports_crashed(self):
        write_mock_cli(self.bin, "codex", self.cli_prelude + RECORDER)  # emits nothing
        p = self.run_shim()
        self.assertEqual(self.last_json(p)["exit_kind"], "crashed")

    def test_unsupported_cli_version_refused_before_invocation(self):
        """Verification finding 7 (CXR-002/KF-H13/B5): an unsupported Codex CLI
        version must FAIL visibly before the CLI is invoked — a warning-and-continue
        path is not sufficient."""
        write_mock_cli(self.bin, "codex",
                       'if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.200.0"; exit 0; fi\n'
                       + RECORDER + self.cli_response)
        p = self.run_shim()
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn("REFUSED", p.stderr)
        self.assertIn("0.200.0", p.stderr)
        self.assertFalse((self.record / "argv").exists(),
                         "the provider CLI was invoked despite the unsupported version")

    def test_unsupported_version_explicit_override_continues(self):
        """The only path past the gate is the explicit, logged override env."""
        write_mock_cli(self.bin, "codex",
                       'if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.200.0"; exit 0; fi\n'
                       + RECORDER + self.cli_response)
        p = self.run_shim(extra_env={"AF_ACCEPT_UNSUPPORTED_CLI": "1"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("AF_ACCEPT_UNSUPPORTED_CLI", p.stderr)
        self.assertEqual(self.last_json(p)["session_ref"], "th-1")

    def test_completes_with_held_open_stdin(self):
        """Codex reads the prompt FROM stdin (redirected from the prompt file), so its
        main call was always safe — but the version probe was not; it must also be
        bounded/closed so a held-open launcher stdin cannot delay or hang the shim."""
        import time
        t0 = time.monotonic()
        p = self.run_shim_with_held_stdin()
        elapsed = time.monotonic() - t0
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.last_json(p)["session_ref"], "th-1")
        self.assertLess(elapsed, 8, f"version probe blocked on inherited stdin ({elapsed:.1f}s)")


class TestKimiShim(ShimTestBase):
    shim = "provider-kimi.sh"
    cli = "kimi"
    cli_response = (
        'printf \'{"session_id":"kimi-1","role":"assistant","content":"PHASE_RESULT: ok"}\\n\'\n')

    def test_prompt_passed_as_option_value_not_stdin(self):
        """KF-H01: kimi -p requires the prompt as the option VALUE."""
        p = self.run_shim()
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[0], "-p")
        # $(cat file) strips only the trailing newline; the full prompt body must
        # arrive as ONE argv value, never via stdin.
        self.assertEqual(argv[1], self.prompt.read_text().rstrip("\n"))
        self.assertEqual((self.record / "stdin").read_text(), "")
        out = self.last_json(p)
        self.assertEqual(out["session_ref"], "kimi-1")

    def test_read_only_mode_fails_visibly(self):
        """KF-L07: unenforceable read-only mode must not be silently ignored."""
        p = self.run_shim(command_mode="read-only")
        self.assertEqual(p.returncode, 2)
        self.assertIn("not enforceable", p.stderr)

    def test_empty_output_reports_crashed(self):
        write_mock_cli(self.bin, "kimi", RECORDER)
        p = self.run_shim()
        self.assertEqual(self.last_json(p)["exit_kind"], "crashed")

    def test_completes_with_held_open_stdin(self):
        """Root-cause regression: prompt goes via argv, so the shim must redirect the
        provider's unused stdin (</dev/null) — pre-fix this hung until timeout."""
        p = self.run_shim_with_held_stdin()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.last_json(p)["session_ref"], "kimi-1")
        self.assertEqual((self.record / "stdin").read_text(), "")


class TestOpenCodeShim(ShimTestBase):
    shim = "provider-opencode.sh"
    cli = "opencode"
    cli_response = (
        'printf \'{"sessionID":"oc-1","part":{"type":"text","text":"PHASE_RESULT: ok"}}\\n\'\n')

    def test_workspace_write_uses_supervised_writer_agent_and_no_auto(self):
        """CXR-003/KF-H14: no --auto; explicit-policy agent profile instead."""
        p = self.run_shim()
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertNotIn("--auto", argv)
        self.assertIn("--agent", argv)
        self.assertIn("af-supervised-writer", argv)

    def test_read_only_uses_supervised_readonly_agent(self):
        p = self.run_shim(command_mode="read-only")
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertIn("af-supervised-readonly", argv)
        self.assertNotIn("--auto", argv)

    def test_unknown_mode_fails_visibly(self):
        p = self.run_shim(command_mode="custom")
        self.assertEqual(p.returncode, 2)
        self.assertIn("unsupported", p.stderr)

    def test_completes_with_held_open_stdin(self):
        """Root-cause regression: prompt goes via argv, so the shim must redirect the
        provider's unused stdin (</dev/null) — pre-fix this hung until timeout."""
        p = self.run_shim_with_held_stdin()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.last_json(p)["session_ref"], "oc-1")
        self.assertEqual((self.record / "stdin").read_text(), "")


class TestClaudeShim(ShimTestBase):
    """Claude shim argv/resume/read-only construction — previously asserted for the
    other three shims only (final-report accuracy finding: 'argv contracts for all
    four shims' was overstated)."""
    shim = "provider-claude.sh"
    cli = "claude"
    cli_response = (
        'printf \'{"session_id":"cl-1","result":"PHASE_RESULT: ok","total_cost_usd":0.02,'
        '"usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":2}}\\n\'\n')

    def test_initial_argv_contract_and_stdin_prompt(self):
        p = self.run_shim()
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[0], "-p")
        self.assertIn("--output-format", argv)
        self.assertEqual(argv[argv.index("--output-format") + 1], "json")
        self.assertEqual(argv[argv.index("--model") + 1], "test-model")
        self.assertNotIn("--resume", argv)
        self.assertNotIn("--dangerously-skip-permissions", argv)
        self.assertEqual((self.record / "stdin").read_text(), self.prompt.read_text())
        out = self.last_json(p)
        self.assertEqual(out["session_ref"], "cl-1")
        self.assertEqual(out["tokens"], 12)  # includes cache tokens (KF-L03)

    def test_resume_argv_contract(self):
        p = self.run_shim(session_ref="cl-9")
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[argv.index("--resume") + 1], "cl-9")

    def test_read_only_maps_to_plan_mode(self):
        p = self.run_shim(command_mode="read-only")
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "plan")

    def test_workspace_write_maps_to_accept_edits(self):
        """A supervised run is NON-INTERACTIVE: under `claude -p` an "ask" rule has
        nobody to ask and resolves as a denial. Leaving workspace-write unmapped denied
        every Write/Edit, so the first live-provider run blocked with "needs-access:
        Write tool permission ... not granted in this non-interactive session" and no
        autonomous task could be implemented at all. Still never
        --dangerously-skip-permissions: settings.json deny rules keep applying."""
        p = self.run_shim(command_mode="workspace-write")
        self.assertEqual(p.returncode, 0, p.stderr)
        argv = self.argv()
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "acceptEdits")
        self.assertNotIn("--dangerously-skip-permissions", argv)

    def test_empty_output_reports_crashed(self):
        """A zero-exit call with empty output must not parse as 'completed'
        (final-verification accuracy row: Claude empty-output honesty)."""
        write_mock_cli(self.bin, "claude", RECORDER)  # records but emits nothing
        p = self.run_shim()
        self.assertEqual(self.last_json(p)["exit_kind"], "crashed")


class TestLargeOutputViaFile(ShimTestBase):
    """KF-M31: >128 KiB provider output must not crash the shim (env-size limit)."""
    shim = "provider-claude.sh"
    cli = "claude"
    cli_response = (
        'python3 -c \'import json; print(json.dumps({"session_id":"big-1",'
        '"result":"x"*300000 + "\\nPHASE_RESULT: ok","total_cost_usd":0.01,'
        '"usage":{"input_tokens":1,"output_tokens":1}}))\'\n')

    def test_large_output_handled(self):
        p = self.run_shim()
        self.assertEqual(p.returncode, 0, p.stderr)
        out = self.last_json(p)
        self.assertEqual(out["exit_kind"], "completed")
        self.assertGreater(len(out["text"]), 250_000)
        self.assertEqual(out["session_ref"], "big-1")


class TestShimLevelTimeout(ShimTestBase):
    """Shim-level hard bound (AF_CALL_TIMEOUT_SECONDS): a hung provider CLI is
    terminated by the shim itself and reported as exit_kind timeout — defense in
    depth under the supervisor's process-group watchdog."""
    shim = "provider-claude.sh"
    cli = "claude"
    cli_response = "sleep 30\nprintf '{}'\n"

    def test_hung_cli_times_out_with_timeout_exit_kind(self):
        import time
        t0 = time.monotonic()
        p = self.run_shim(extra_env={"AF_CALL_TIMEOUT_SECONDS": "2"})
        elapsed = time.monotonic() - t0
        self.assertEqual(p.returncode, 0, p.stderr)
        out = self.last_json(p)
        self.assertEqual(out["exit_kind"], "timeout")
        self.assertLess(elapsed, 25, f"shim did not enforce the call bound ({elapsed:.1f}s)")


class TestSupervisedProfiles(unittest.TestCase):
    """The generated OpenCode supervised profiles contain only explicit allow/deny
    decisions and deny external-directory access."""

    def test_profiles_explicit_and_contained(self):
        import yaml
        root = Path(__file__).resolve().parent.parent.parent
        for name in ("af-supervised-writer", "af-supervised-readonly"):
            f = root / ".opencode" / "agents" / f"{name}.md"
            fm = yaml.safe_load(f.read_text().split("---")[1])
            perm = fm["permission"]
            self.assertEqual(perm["external_directory"], "deny", name)
            self.assertEqual(perm["webfetch"], "deny", name)
            decisions = [perm["edit"], perm["external_directory"], perm["webfetch"],
                         *perm["bash"].values()]
            self.assertTrue(all(d in ("allow", "deny") for d in decisions),
                            f"{name}: unattended profile must not contain 'ask': {decisions}")
        ro = yaml.safe_load((root / ".opencode" / "agents" / "af-supervised-readonly.md")
                            .read_text().split("---")[1])
        self.assertEqual(ro["permission"]["edit"], "deny")
        self.assertEqual(ro["permission"]["bash"]["*"], "deny")


if __name__ == "__main__":
    unittest.main()
