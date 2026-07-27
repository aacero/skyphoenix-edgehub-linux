# Real-hardware tests (Xeneon Edge)

Headless end-to-end tests that run against the **actual Edge panel** - interaction
(synthetic touch), live IPC, performance, and stability. Complements the offscreen
`tests/ui` qmltest suite, which can't exercise the real compositor, touch input, or
the C++ backend on-device.

## Synthetic-input safety (READ THIS FIRST)

These suites can emit **real input events into a live desktop session**. That
is never allowed to be a surprise side effect of "run the tests", and it is
structurally impossible for events to land outside the Edge:

1. **Opt-in gate** - all synthetic input is **SKIPPED unless
   `XENEON_HW_INPUT=1`** is explicitly set. Without it, `edge_e2e.py` runs
   everything IPC/grab-driven and loudly skips the interaction suite;
   creating a real uinput device raises `InputGateError` before the device
   node is even opened. (`edge_hw_test.py`, the deprecated legacy script,
   additionally requires `XENEON_HW_LEGACY=1`.)
2. **Confinement to the Edge rect, at the event-synthesis layer** -
   preferred injector is `VTouch`, a true multitouch (ABS_MT) touchscreen
   that KWin **physically maps to the Edge output** (the writable
   `org.kde.KWin.InputDevice.outputName` DBus property, readback-verified;
   the Edge's own "wch.cn TouchScreen" is mapped the same way). Its events
   *cannot* land on another monitor. The fallback `VPointer` clamps every
   coordinate to the Edge rect inside the single emit path - there is no
   unclamped API. Both are unit-tested via a capture sink
   (`test_input_safety.py`) without injecting anything.
3. **Target-window verification before the first event** - the harness
   render-probes the hub (two opposite wallpaper states must show up in
   grabs of exactly the Edge rect) and then requires an **IPC-verified
   landing probe** (a tapped hydration counter must actually increment).
   No verification → no injection, loud skip.
4. **User-activity kill switch** - a pure-python Wayland
   `ext-idle-notify-v1` monitor (`input_guard.py`; `/dev/input` is not
   readable by regular users here) watches for REAL input-device activity.
   Injection never starts until the owner has been hands-off for
   `XENEON_HW_IDLE_SECONDS` (default **3 s** - longer than any intra-burst
   typing/mousing gap, short enough not to stall the suite), and any real
   event mid-run raises `UserActivityAbort` and disables injection for the
   rest of the run. Known limit: an event landing within ~350 ms right
   after one of our own writes is masked until the next idle cycle
   (~100 ms) - the per-event abort checks keep that exposure well under a
   second.
5. **Stale-geometry defense** - `XENEON_EDGE_GEOM`/`XENEON_CANVAS`
   overrides are cross-checked against live `kscreen-doctor` output and
   **rejected** on mismatch (only `XENEON_GEOM_TRUST=1` skips the check,
   for non-KDE setups).

Measured on this box (2026-07-16, KWin 6.7.3): the VTouch axis transform is
`rot270` - KWin scales the MT device in the panel's native landscape axes
and then applies DP-3's 270° output transform; the harness probes this per
run, so it is measured, never assumed. Side effect to know about: KWin
persists the device→output binding in `~/.config/kcminputrc` as
`[Libinput][4660][22136][xeneon-virt-touch] OutputUuid=…` - scoped to the
virtual device's vendor/product/name, inert for every real device, and it
makes the mapping automatic on future runs.

Unit tests for all of the above (no injection, no compositor traffic):

```sh
python3 tests/hardware/test_input_safety.py
```

## Requirements

- The Edge connected and enabled (normally DP-3). The hub auto-detects it.
- A release build: `./scripts/build.sh release` (produces `build/xeneon-edge-hub`).
- `/dev/uinput` writable by your user - for synthetic touch. On this box the
  openlinkhub/Corsair daemon grants it via an ACL (`getfacl /dev/uinput` should show
  `user:<you>:rw-`). Otherwise add yourself to the `input` group.
- `python3` with `PIL` (Pillow) only if you want screenshots; the test itself needs
  no third-party packages. `kscreen-doctor` (KDE) is used to auto-detect geometry;
  override with `XENEON_EDGE_GEOM="x,y,w,h"` and `XENEON_CANVAS="w,h"` on other setups.
- For `edge_hw_test.py`: no hub already running (that older script still uses
  the real config + runtime dir). `edge_e2e.py` isolates both, so a live hub is
  no longer stranded or required to be stopped - but both hubs will fight over
  the Edge panel visually, so stopping the live one is still *recommended* for
  clean grabs.

## Run

```sh
XENEON_HW_INPUT=1 python3 tests/hardware/edge_e2e.py        # the current suite

# disruptive KDE/Wayland display lifecycle; no input, separate explicit gate:
commit="$(git rev-parse HEAD)"
mkdir -p "artifacts/$commit"
XENEON_RELEASE_GATE=1 \
    bash tests/performance/prepare_release_candidate.sh
XENEON_HW_DISPLAY_LIFECYCLE=1 \
    python3 tests/hardware/display_lifecycle_test.py \
      --hub "$PWD/cmake-build-release-performance/xeneon-edge-hub" \
      --evidence-dir "$PWD/artifacts/$commit/display-lifecycle-$(date -u +%Y%m%dT%H%M%SZ)"

# legacy, DEPRECATED (real config + runtime dir; double opt-in required):
XENEON_HW_INPUT=1 XENEON_HW_LEGACY=1 python3 tests/hardware/edge_hw_test.py
```

`edge_hw_test.py` **backs up and restores** `~/.config/xeneon-edge-hub/config.toml`
(a live `setUiState` persists to disk), so your layout/appearance is untouched.
Without both env vars it prints a deprecation banner and exits 2.

## What it covers (`edge_hw_test.py`, legacy)

- **Launch/placement** on the Edge + control socket comes up.
- **IPC**: `ping`, 300 `getUiState` round-trips (latency p50/p99), 25 concurrent
  connections, 500 connect/disconnect cycles - no drops.
- **Robustness**: malformed JSON, a >8 MB oversized message, and a partial message
  are all handled without crashing the hub.
- **Synthetic touch** (real events via a pure-python uinput virtual pointer): opens a
  tile's expanded overlay, taps the Focus preset segments and **verifies via
  `getUiState` that `cfg.preset` changed** (skipped if page 0 has no Focus tile),
  closes via the Done bar, swipes between pages, and runs a 40-tap storm.
- **Stability/perf**: no fd/thread leak, RSS reported, clean shutdown (exit 0).

## Files

- `uinput_touch.py` - reusable pure-python synthetic touch/pointer (no sudo, no
  ydotool), gated + confined as described above. `VTouch` (ABS_MT, output-bound)
  + `VPointer` (clamped) + `detect_edge_ex()`. See its header for the two Wayland
  gotchas (24-byte `input_event` packing; the move→settle→click sequence).
- `input_guard.py` - the user-activity kill switch (Wayland ext-idle-notify-v1).
- `test_input_safety.py` - injection-free unit tests for gate/clamp/kill switch/
  geometry.
- `edge_hw_test.py` - the consolidated legacy test above (DEPRECATED - prefer
  `edge_e2e.py`).
- `display_lifecycle_test.py` - separately gated real KDE/Wayland output test:
  restart, portrait/landscape, 125% scale, primary swap, disable/re-enable, and
  missing-target startup. It captures the full KScreen baseline before changing
  anything and restores enabled state, mode, position, rotation, scale, and
  priority for every output on every exit path, then verifies the restored state.
  It refuses a dirty source tree and requires a new, absolute, non-symlink
  `artifacts/<exact-full-sha>/<run>` evidence directory. Baseline/final KScreen
  state, Hub logs, screenshots, per-check results, and any error are retained
  there. `--hub` must identify the exact executable regular non-symlink
  candidate being certified and its adjacent CMake cache must prove a Release
  build with coverage, tests, and QA hooks disabled. It creates no synthetic
  input and uses an isolated Hub config/runtime directory. The display will
  visibly rotate, resize, and blank while it runs; use only on an attended
  session.

## Not covered (needs a human)

- **Physical rotation → auto-rotate**: the sensor is read from `/dev/hidraw5` and the
  pipeline is wired + debounced, but only a person can physically turn the panel.
- Subjective feel (animation smoothness, readability at arm's length).

---

## `edge_e2e.py` - comprehensive E2E suite (hub + Manager)

The big one. Drives the **real hub on the Edge** and the **Manager**, covering
"everything", and reports a single pass/fail. Uses an **isolated
`XDG_CONFIG_HOME`** *and* an **isolated `XDG_RUNTIME_DIR`** per spawned hub, so
the live config, the single-instance lock and the control socket of a running
hub are never touched - no backup/restore needed, and the suite can no longer
strand a live hub's Manager connection.

### How the runtime-dir isolation works (and why)

The hub binds `$XDG_RUNTIME_DIR/xeneon-edge-hub-ctl`
(`app/src/control_socket_path.h`). The harness used to keep the REAL
`XDG_RUNTIME_DIR` because Wayland's compositor socket lives there - which
meant the spawned hub bound the REAL control socket, and the harness cleanup
`os.remove()`d it, silently stranding any live hub (it keeps its listening fd,
so it *looks* healthy while the Manager can never reach it again).

`e2e_harness.E2E` now gives every spawned hub:

- a private, short (`sockaddr_un` ≈107-byte cap), 0700 `XDG_RUNTIME_DIR`
  (`self.run_dir`), where its control socket (`self.sock`) and lock land;
- `WAYLAND_DISPLAY` rewritten to an **absolute path** into the real runtime
  dir - Wayland resolves an absolute `WAYLAND_DISPLAY` without consulting
  `XDG_RUNTIME_DIR`, so the hub still reaches the compositor and renders on
  the Edge. Verified on the real session: absolute path → renders
  (grab-confirmed) with its socket in the isolated dir; relative name under
  the same isolation → cannot connect to the compositor;
- a **removal guard**: cleanup refuses to delete any socket outside its own
  private runtime dir, so no code path can unlink a live hub's socket;
- `cleanup()` (stop + remove the private dir) - `edge_e2e.py` calls it.

There is no module-level `SOCK` any more, on purpose: anything still
importing it operated on the live hub's socket and should break loudly.
Use `h.sock`. (`edge_hw_test.py`, the older standalone script, still runs
against the real config/runtime dir with its own backup/restore - don't run
it against a session with a hub you care about; `edge_e2e.py` is the safe,
current suite.)

```sh
python3 tests/hardware/edge_e2e.py                 # full run (~20–30 min)
E2E_SOAK_SECONDS=5 python3 tests/hardware/edge_e2e.py   # quick smoke (~2 min)
```

**Coverage (~199 checks):**
- **Widget lifecycle** - add / render / no-error / resize (1↔2) / remove for **every
  type in `WidgetCatalog.qml`** (30 today) via IPC `setUiState`/`getUiState` + Edge
  screenshots. The list is asserted against the catalog first, so a new widget can't
  go silently unexercised. `httpjson` is seeded with **no URL** (the shipping preset
  state, and it keeps the run offline); `kpi` uses its **local-file** source.
- **Theming** - every theme (29: 21 classics + 7 distro palettes + default dark),
  every background style (11, incl. the arch/fedora/aubergine character styles),
  per-widget accent override, glass/glow, each verified in state + grabbed. The
  `THEMES`/`BG_STYLES` lists are drift-checked against `ui/qml/Theme.qml` and
  `ui/qml/BackgroundCatalog.qml` first (same contract as the widget list), and the
  soak rotation reuses them, so a new theme or style can't go silently unexercised.
- **Interaction (synthetic touch)** - compact widget controls (Focus Start/Pause,
  Hydration ±, Task toggle) verified over IPC; **page-swipe navigation** verified
  by distinct per-page wallpapers (average-colour distance). **Opt-in only**
  (`XENEON_HW_INPUT=1`) and preceded by window verification + landing probe +
  kill-switch arming - see "Synthetic-input safety" above. Skipped loudly
  otherwise; the soak's periodic swipes obey the same gate.
- **IPC** - malformed/partial/oversized input (no crash), latency p50/p99 over 200
  round-trips, 20 concurrent connections.
- **Soak** - sustained **mixed** operations (add/remove/resize/theme/background/
  multi-page + periodic swipes) for `E2E_SOAK_SECONDS` (default 1200 → ~20 min);
  the bulk of the runtime and the real stability signal.
- **Manager** - Dark / Light / Default chrome all render with 0 QML errors.

Modules: `e2e_harness.py` (launch/IPC/touch/grab primitives), `e2e_widgets.py`,
`e2e_theming.py`, `e2e_interaction.py`, orchestrated by `edge_e2e.py`.

The Manager's **drag-reorder** logic (incl. the "name-tag stuck in air" regression)
is covered deterministically offscreen by `tests/ui/tst_edgeclone_drag.qml`.
