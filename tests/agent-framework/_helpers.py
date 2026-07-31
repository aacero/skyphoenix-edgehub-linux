"""Shared helpers for the agent-framework regression tests. Stdlib only."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPTS = REPO_ROOT / "scripts" / "agent-framework"
EXCLUDE = {".git", ".idea", "node_modules", "__pycache__", "runs"}


def copy_repo(dst: Path) -> Path:
    """Copy the repository (sans .git/runs/caches) so mutation tests never touch
    the real working tree."""
    def ignore(directory, names):
        return [n for n in names if n in EXCLUDE]
    shutil.copytree(REPO_ROOT, dst, ignore=ignore, symlinks=True)
    return dst


def run(cmd: list[str], cwd: Path, env: dict | None = None,
        timeout: int = 300) -> subprocess.CompletedProcess:
    e = os.environ.copy()
    if env:
        e.update(env)
    # stdin=DEVNULL: tests must behave identically under a TTY, a pipe, or CI.
    return subprocess.run(cmd, cwd=cwd, env=e, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=timeout)


def render(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return run([sys.executable, "scripts/agent-framework/render.py", *args], cwd=repo)


def validate(repo: Path) -> subprocess.CompletedProcess:
    return run([sys.executable, "scripts/agent-framework/validate.py"], cwd=repo)


def check_drift(repo: Path) -> subprocess.CompletedProcess:
    return run([sys.executable, "scripts/agent-framework/check-drift.py"], cwd=repo)


def scratch_dir() -> Path:
    return Path(tempfile.mkdtemp(prefix="af-test-"))


def write_mock_cli(bin_dir: Path, name: str, script: str) -> Path:
    """Install a mock provider CLI on PATH that records its argv."""
    bin_dir.mkdir(parents=True, exist_ok=True)
    p = bin_dir / name
    p.write_text("#!/usr/bin/env bash\n" + script)
    p.chmod(0o755)
    return p


def base_run_config(**overrides) -> dict:
    cfg = {
        "run_id": "t-run",
        "objective": "Regression-test run for the remediated supervisor",
        "provider": "claude",
        "model": "test-model",
        "duration_hours": 1,
        "min_useful_work_minutes": 0.01,
        "scope_boundary": "agent-framework tooling only",
        "definition_of_done": "all backlog tasks complete with evidence",
        "approved_backlog": [{"id": "task-a", "task": "First simulated task"}],
        "budget": {"max_provider_calls": 60},
        "network_policy": {"mode": "open"},
        "command_policy": {"mode": "workspace-write"},
        "max_restarts": 3,
        "heartbeat_seconds": 5,
        "checkpoint_interval_minutes": 5,
        "worktree": {"branch": "main"},
    }
    cfg.update(overrides)
    return cfg


def supervisor(cfg: dict, runs_dir: Path, *args: str, env: dict | None = None,
               timeout: int = 120) -> subprocess.CompletedProcess:
    cfg_path = runs_dir / f"cfg-{cfg.get('run_id', 'x')}.json"
    runs_dir.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text(json.dumps(cfg))
    return run([sys.executable, str(SCRIPTS / "run-autonomous-session.py"),
                "--config", str(cfg_path), "--runs-dir", str(runs_dir), *args],
               cwd=REPO_ROOT, env=env, timeout=timeout)
