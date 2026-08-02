---
name: runtime-e2e-testing
description: How to drive the real hub binary headless in a runtime E2E test and assert on persisted config.toml — tests/runtime/ + its gotchas
metadata: 
  node_type: memory
  type: project
  originSessionId: 139278eb-bb8f-423b-b2ef-fffa145da6cd
---

Added 2026-07-14. `tests/runtime/` drives the ACTUAL hub binary headless
(offscreen QPA) and asserts on the state it PERSISTS to `config.toml` — a layer
below the QML unit harness ([[companion-and-testing]]). First case:
`run_focus_goal_bonus.sh` (Focus daily-goal bonus fires exactly once). Wired into
`scripts/run_all_tests.sh` as suite #5 (exit `77` = SKIP when no hub binary;
launch guarded in an `if` so `set -e` doesn't abort on fail/skip).

**The pattern**: seed an isolated `XDG_CONFIG_HOME` config where the widget is
one step from its trigger and RUNNING with an already-expired `endEpoch`, so the
hub's 1 s tick fires a natural completion on load; run the hub a few seconds; read
the persisted result back. `focus_seed_config.py` writes the config,
`focus_read_points.py` reads it. Binary resolution: `$XENEON_HUB` →
`./build/xeneon-edge-hub` → `xeneon-edge-hub` on PATH. Each run gets its OWN
`XDG_RUNTIME_DIR` (single-instance lock + control socket isolation).

**Gotchas (each cost real time):**
- **config.toml is NESTED, and the Rust `toml` crate is strict.** Required tables:
  `[display]` / `[theme]` / `[startup]` / `[widgets]`. A FLAT key layout
  deserialize-fails; the core reports it as `TOML parse error at line 1, column 1`
  (a serde error with no span — misleading), then `salvage_partial_config` SILENTLY
  falls back to the default starter layout, so your seed vanishes and you get
  `focus-0`/defaults. Emit the full nested structure (`focus_seed_config.py` has it).
- **`ui_state` must be a single-quoted TOML LITERAL string** (`ui_state = '{...}'`),
  exactly how the hub serializes it. The embedded JSON has double quotes; a basic
  `"..."` string with `\"`-escapes is rejected. JSON never contains a single quote,
  so a literal needs no escaping.
- **Kill the hub with SIGKILL (`timeout -s KILL 6`), not SIGTERM.** Its graceful
  shutdown handler can HANG on sensor/socket teardown, so plain `timeout` (SIGTERM)
  → the process lingers → the agent harness reaps the whole command as exit 144.
  The debounced store save writes config.toml ~1.5 s after the completion, long
  before the 6 s kill, so a hard kill is safe (we don't need clean shutdown).
- **NEVER `pkill -f xeneon-edge-hub` in a script/command that also NAMES the binary.**
  `pkill -f` matches the FULL command line — including the running shell's own argv
  (which contains "xeneon-edge-hub") → it SIGKILLs its own parent shell before doing
  anything (this is the OTHER common source of the mysterious exit 144, distinct from
  the SIGTERM-hang one). It also kills any real hub the user has open. `timeout -s
  KILL` reaps each isolated run; no manual pkill needed.
- **Discriminating test**: the crossing case (done 3→4 of 4 → 60 pts) passes under
  BOTH old (`>=`) and new (`===`) logic; only the PAST-goal case (done 4→5 → +10,
  not +60) distinguishes the fix. So `./build` being STALE (pre-fix) makes scenario
  B fail — a feature, proving the test bites. Rebuild `./build` or pin
  `XENEON_HUB=/usr/bin/xeneon-edge-hub` (the installed pkg).
- The agent-harness "GUI launch reaps as exit 144" note in [[companion-and-testing]]
  is the same reaper; the two fixes above (SIGKILL + no self-pkill) are what make a
  multi-launch script survive it. Running the hub headless itself works fine
  (`QT_QPA_PLATFORM=offscreen ... --windowed`, exit 124/137 on timeout is normal).
