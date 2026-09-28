# Session handoff - continue from here

> Historical record only. Do not use the test counts or release status below as
> current evidence. The active stable-release status is maintained in
> `docs/releases/v1.0.0-readiness.md`, and current results must name a clean
> commit-keyed artifact run.

## 2026-07-17 (overnight) - READ `docs/reports/overnight-report.md` FIRST

Full report: `docs/reports/overnight-report.md`. Open items now live in one place:
**`BACKLOG.md`** (they used to be split between BETA_PLAN and this log, so "what is
left?" had no single answer).

Wave 3 merged + pushed; W2/W3/W4 merged. Full suite green (17 suites, 9 runtime
E2E, matrix 100%). Headline: **three tests had never executed** - QtTest reads
`test_X_data()` as the data provider for `test_X()`, so a weather egress guard
whose whole job was to fail on `&hourly=` was inert, and a stale preset pin had
never run. `scripts/check_live_tests.sh` gates that class now; see
[[test-integrity]] and the report for the general rule.

Also fixed, none of it on any backlog: the vulnerability-reporting address pointed
at an **unregistered domain** (squattable - anyone could have received private
0-day reports); docs CI had been **red on master** over a link that was actually
valid; `--reset` **destroyed the layout with no backup** while the tested
`backup_config_of()` was called by nothing but a test; **202MB** of makepkg output
was committed under `packaging/aur/`; the local dogfood build **versioned below
the release**, so `yay -Syu` would have silently reverted Simon to alpha.2; and
`tst_meds` **failed nightly between 00:00 and 00:10**.

**Unverified:** CI on the final commit - GitHub's API went 503 mid-session. Local
suite is green. Check before trusting the tree.

_Last updated: 2026-07-16 (beta runway). `v1.0.0-alpha.2` is SIGNED and published;
the AUR package is LIVE (`yay -S xeneon-edge-hub`, maintainer SKYPhoenix_IT,
validpgpkeys-verified). Everything below the next section is historical log._

## State: all v1.0 MUST epics (E1–E11) + blockers (B1–B7) DONE
- Parked by owner decision: **E7 Phase B** (keyring; branch kept). **Payments** deferred to beta.
- Signing: key `93CDC77EACF98990` (fp `2F0CAD36DC1D46F3347B7EF293CDC77EACF98990`),
  on both keyservers, revocation cert in the owner's Bitwarden (shredded locally).
  `scripts/release.sh` = the interactive signed-release flow (refuses without the key).
- Local dogfood: `./scripts/update-local.sh` (owner runs r149+; hub owns the
  $XDG_RUNTIME_DIR control socket - the /tmp socket era is over).
- Tests: hermetic guard (`tests/cpp/hermetic.h`) makes raw test-binary runs abort;
  ctest is the only runner. 20/20 C++, 234 Rust, QML matrix 100% (235 ids), 3 CI
  workflows (10+7+4 jobs) all green.
- **Beta**: see `docs/BETA_PLAN.md`. Five workstreams in flight (sizing wave 1,
  Manager UX clarity, widget smoothness incl. the owner-reported SensorsWidget
  delegate-churn bug, runtime-E2E battery + harness hazard fix, end-user
  walkthrough). Owner decisions open: Calm default, font default, lawyer pass on
  distro theme names, payment provider.

_Last updated: 2026-07-16 (B5 two-writer-race fix merged onto master - see the
"Resolved: B5" entry below). The alpha track is merged into `master`; `v1.0-alpha`
stays alive for E4–E9._

## v1.0 ALPHA - in progress (branch `v1.0-alpha`)

Plan: `~/.claude/plans/glittery-sauteeing-sonnet.md` (approved). Building the alpha
epics in sequence; Sequence-0 (licensing/docs/QA-hook guard) already landed.

- **E2 - curated preset library - DONE** (`917ca25`). `ui/qml/PresetCatalog.qml`: 15
  purpose-built, non-overloaded preset screens (calm-focus, home-ambient, remote-work,
  developer, homelab, gaming, trading-desk, health, creator, system-monitor, minimal,
  analyst, study, productivity, enterprise). `buildDoc(id)` materialises a full
  `ui_state` with freshly-minted `type-N` tile ids + per-tile settings; appearance sets
  only bg/motion/glow (never theme/accent, to preserve user colours). `DashboardStore.seed()`
  routes through it (unknown→productivity, blank→blank). `FirstRunWizard.qml` picker is now
  a scrollable grid of all presets. Registered in both qrc files.
  - Tests: new `tests/ui/tst_preset_catalog.qml` (well-formed / real widget types / 1–6
    tiles per page / applies through the real store). Updated `tst_store_tiles.qml` +
    `tst_gen_shared_DashboardStore.qml` for the new preset-backed seed mechanism. Full
    suite green (`run_all_tests.sh` → SUCCESS).
  - **Verified on the real Edge**: 6 presets grabbed populated + calm + not overloaded, plus
    the first-run wizard (fixed a `pixelSize: 12.5`→`13` int-assignment bug in the wizard
    that had broken the QML suite). Grab recipe: `XDG_CONFIG_HOME` pointed at a temp config
    built from the real `~/.config/.../config.toml` (strict deser needs `schema_version` +
    `first_run_complete` + all sections) with `ui_state` swapped in; launch with
    `--windowed` (avoids fullscreen-hijacking the live Edge) + `XENEON_GRAB` (grab mode
    bypasses the single-instance lock). Force qml console output with
    `QT_ASSUME_STDERR_HAS_CONSOLE=1`.
  - Presets marked "⟶ enrich" (developer, homelab, trading-desk, analyst, enterprise)
    used system/time primitives only; they gained HTTP/JSON + KPI tiles once **E1**
    landed - done in `7025bd2`, see the E1-follow-up entry below.
  - Follow-up noted: first-run wizard welcome still reads "Xeneon Edge Linux Hub" (nominative
    line kept per rebrand decision - revisit if a cleaner descriptor is wanted).
- **E1 - generic primitive widgets + egress gate - DONE** (`eb552c1`, verified on real Edge).
  - `ui/qml/widgets/NetHub.qml`: the single egress choke point - the ONLY place a QML
    `XMLHttpRequest` may be constructed. `request()` enforces offline kill-switch →
    host allowlist → local-file bypass, counts requests per host (attestation), returns
    the XHR for abort. Dashboard injects one app-global instance into every net widget
    (`injectWidget`, keyed on `hasOwnProperty("netHub")`); a per-widget fallback keeps
    widgets self-contained in tests.
  - `HttpJsonWidget`: poll URL → dot/bracket JSON path → value/gauge/list, warn/crit
    threshold colouring, Bearer-token → Authorization header.
  - `KpiWidget`: one number from HTTP **or a local file** (JSON or bare number, works
    offline), label/unit/normal+inverted thresholds.
  - Live poll results are stored EPHEMERAL in shared per-instance settings (`httpVal/
    httpText/httpErr/httpList/httpAt` added to `DashboardStore._ephemeralKeys`) → no
    config.toml churn per poll, compact+overlay share one reading.
  - Egress lint `scripts/check_no_raw_xhr.sh` (wired into run_all_tests as its own suite)
    fails on any raw XHR outside NetHub; Weather/Calendar/Manager-preview-dialog are
    grandfathered pending their **E8** migration onto NetHub.
  - `app/manager main.cpp`: `qputenv("QML_XHR_ALLOW_FILE_READ","1")` so the KPI local-file
    source works (Qt gates file:// XHR behind it; local read only, opens no network path).
  - Tests: `tst_nethub` (13), `tst_httpjson_net` (16+schema), `tst_kpi_net` (11+schema);
    behavior matrix back at 100%. Full suite green. Real-Edge grab showed live GitHub
    stars/forks + a local-file KPI colouring amber past its threshold.
- **E1 follow-up - data-connected presets + icon lint - DONE** (`7025bd2`). Closes the
  E1/E2 loop: the primitives existed but nothing used them, and both new types shipped
  with **no icon** (the picker rendered blank tiles - visible only as a
  `Cannot open: qrc:/icons/<type>.svg` warning in a real-device grab).
  - Presets developer / homelab / trading-desk / analyst / enterprise now carry
    httpjson/kpi tiles with a purposeful `title` but a **blank url/filePath**: the
    endpoint is the one thing only the user can supply, so a tile ships as a labelled,
    self-explaining slot rather than a wrong guess - and nothing polls until connected.
    (A preset must never guess a URL: first run would poll a stranger's host.)
  - `assets/icons/httpjson.svg` + `kpi.svg`, both registered in `assets/icons.qrc`.
  - **`scripts/check_widget_icons.sh`** (new suite in `run_all_tests.sh`): every
    `WidgetCatalog` type must have an SVG on disk AND a qrc line. The QML suite is
    structurally blind to this - it runs source-tree with no qrc - so nothing else
    catches a missing icon short of a grab.
  - `MetricGauge`: value capped to the ring's inner diameter (`HorizontalFit` + elide).
    System tiles only pass short readings ("42%"); an HTTP/JSON gauge shows arbitrary
    values ("128ms") that used to spill over the ring.
  - Tests: preset settings keys must be real (universal or in that type's schema - a
    typo like `listmax` would silently ship a no-op tile); data presets must ship
    labelled-but-unconnected. `PresetCatalog.qml` added to the coverage matrix.
- **SECURITY - config.toml was world-readable - FIXED** (`9f68706`). `save_config()` used
  `fs::File::create()` → 0666 & ~umask → **0644**, and `ui_state` carries secrets (the E1
  Bearer token, the calendar's secret ICS URL) - every local account could read them. The
  temp file is now created 0600 (not chmod'd after, which leaves an exposure window) and
  the mode re-asserted on the handle (`.mode()` only applies at creation, so a stale
  `config.tmp` from a SIGKILL would leak 0644 through the rename). Both gates fail against
  the old code with "was 644". **A running OLD binary re-saves at 0644** - the fix only
  takes effect once a build containing it is installed.
- **E7 Phase A - credential refs - DONE** (`98cb081`). A stored token is now a REFERENCE,
  resolved per-request and never persisted: `${env:VAR}`, `file:/path` (trimmed - a
  trailing newline silently breaks auth), `secret://` (Phase B, errors today), or a legacy
  plaintext literal (still honoured + warned once; breaking a configured widget is worse
  than the exposure they already have).
  - `core/src/secrets.rs` (classify/resolve/is_plaintext) → FFI `xeneon_secret_resolve`
    (two allocations: value AND error, both caller-freed) → `ConfigBridge.resolveSecret()`
    → `{ ok, value, error, plaintext }`. QML **cannot read the environment**, which is why
    this lives in the core; resolving behind the FFI also means the value exists only
    inside one `request()` call.
  - **NetHub owns resolution** (the plan assigns it "secret resolution"). Widgets pass the
    stored ref via `request({authToken})` and must NEVER build an Authorization header -
    a resolved secret in a widget property would ride `cfgKey`/settings onto disk.
    Resolution happens BEFORE any socket opens (an unresolvable secret is refused with
    `secret: <why>` rather than sent unauthenticated, which reads as a far-end 401), and a
    ref with no resolver **fails closed** (sending `${env:CI_TOKEN}` verbatim would leak
    the ref and fail confusingly).
  - Errors carry the var name/path, **never the value** - an error string is a place a
    secret must not reach, so that has its own test.
  - NetHub is now in the behavior matrix (**183 → 190 ids, all covered**): it is the choke
    point the "no telemetry" claim rests on, so every function must earn a COVERS claim.
- **NEXT** (alpha, plan §5): **E7 Phase B** (keyring: `core/src/secrets.rs` already has the
  `secret://` seam + `SecretError::KeyringUnsupported`; needs the `secret-service` dep,
  feature-gated, and a fallback for an appliance Edge with no D-Bus keyring daemon), then
  **E8** egress UI + Weather/Calendar migration (removes the last raw-XHR grandfathering),
  **E6** DST/world clocks, **E4** a11y foundation, **E5** wellness widgets, **E9**
  enterprise pack.
  - Note for E6: `trading-desk` ships a second clock as a **fixed UTC offset** (New York,
    -5) because that is all the world-clock model supports today - it does not follow US
    daylight-saving. E6 (DST/world clocks) should re-point that tile at a real zone.

### CI gotcha fixed this session (`b6d6183`) - read before trusting a green local run
The smoke tests drive the real binaries via `XENEON_GRAB`, which `a304d0b` (B7) compiled
out unless `-DXENEON_QA_HOOKS=ON`. `scripts/build.sh` passes that flag, so every local
`build/` dir had it cached ON and `run_cpp_tests.sh` stayed green; CI configures a fresh
tree without it → the binaries never exited → 30s timeouts. Now `run_cpp_tests.sh` + the
CI cpp-test job both configure `-DXENEON_QA_HOOKS=ON` (CI's `build` job still covers the
hooks-OFF product config), and the smoke tests `QSKIP` with the real reason instead of
timing out. **CI now also triggers on `v1.0-alpha`** - it previously ran only on
`[main, master]`, so the entire alpha track was unverified and this break rode it
invisibly for 8 commits, going red the moment alpha merged.
**Rule:** local green ≠ CI green. On a build-shaped CI-only failure, diff the cmake flags
(`grep XENEON build/CMakeCache.txt` vs the workflow) before anything else.

## Current state: GREEN - 95%+ coverage across all layers

Full plan + results: `docs/DEV_AND_TEST_PLAN.md`, `docs/MANAGER_UIUX_PLAN.md`. Run
everything: `./scripts/run_all_tests.sh` (→ `RESULT: SUCCESS`); coverage: `./scripts/coverage.sh`.

- **Build**: `./scripts/build.sh release` - clean (hub + manager).
- **QML**: `./scripts/run_ui_tests.sh` - ALL UI TESTS PASSED. Behavior matrix
  `python3 scripts/qml_coverage.py` - **100%** (190/190).
- **Real hardware**: `python3 tests/hardware/edge_e2e.py` - **212/212 in 22.2 min** on the
  real Edge (all 24 widget types, every theme/background, synthetic touch, IPC p50 0.02ms,
  a 1200s soak of 2156 mixed cycles, Manager chrome ×3). The type list is now gated against
  `WidgetCatalog.qml` (`test_catalog_drift`) - it had silently omitted httpjson/kpi while
  still reporting ~199 green checks.
- **Rust**: `cd core && cargo test` - **116 passed**; **97.4%** line (config.rs 98.3%).
- **C++**: `./scripts/run_cpp_tests.sh` - **15/15 ctest**; ~97% filtered line.
- **Runtime E2E**: `tests/runtime/run_focus_goal_bonus.sh` - drives the real hub
  binary headless (offscreen) and asserts on the state it persists to `config.toml`;
  proves the Focus daily-goal bonus fires exactly once. Wired into
  `run_all_tests.sh` as suite #5 (SKIPs if no hub binary is built/installed; pin
  one with `XENEON_HUB=…`). See `tests/runtime/README.md` for the config-schema /
  SIGKILL / `pkill` gotchas.

### Install the latest build
Package staged at **`~/xeneon-edge-hub-0.1.0.r61-1-x86_64.pkg.tar.zst`** (version
`v0.1.0-32-gaf048c7`, shown in the Manager nav + hub Diagnostics) - **installed**
this session (was r39). Rebuild/reinstall in your terminal (closes stray instances
first): `pkill -f xeneon-edge; sudo pacman -U
~/xeneon-edge-hub-0.1.0.r61-1-x86_64.pkg.tar.zst`.

### Overnight autonomous pass - real bugs fixed (adversarial reviews)
- **habit streak cap** (`7064c57`): streak was capped at 28 (heatmap-window prune);
  now a persisted number, milestones ≥30 fire, backward-compatible.
- **EOD overnight window** (`4e9265e`): night-shift (22→06) was wrong after midnight;
  now selects the day-earlier window candidate.
- **sensors 0% fabrication** (`40c4d93`): CPU/RAM no longer show a fake 0% before the
  first metrics frame (S4).
- **offline-edit loss** (`1f90515`, P1 data loss): a connected edit didn't update the
  reconcile baseline, so an offline edit after a hub restart could be dropped - fixed +
  regression test.
- **store hardening** (`8001ffc`): clamp tile w/h to [1,2], prototype-safe page-name
  dedup (`valueOf`/`toString`/… no longer spuriously renamed), no redundant flash-write
  from ensureSettings after applyExternal.

### Post-PR#1 work (newest first)
- **Manager UI/UX + themes + robustness** (`8df1ccc`/`fafb133` + follow-ups): dark
  `QPalette` on both apps (config Switch/Slider/Button/ScrollBar/dialog buttons no
  longer render as pale Fusion), restyled config controls, **config live-preview now
  scales to fit** (no clipped action rows), hover/cursor affordances. **Themes 8→22** (this batch 8→16;
  synthwave/cyberpunk/deep_forest/deep_ocean/ember/vaporwave/rose_gold/matrix; then +6 nord/dracula/solarized/gruvbox/catppuccin/tokyonight → 22),
  **accents 8→14**. `_normaliseDoc` is now a **validator** (corrupt/hostile pages/tiles/
  tasks can't blank the dashboard). IPC RX-cap, 25 MB image guard, saveError signal.
- **Single-instance guard** (`53e9dfa`): `app/src/single_instance.h` (QLockFile) on
  both apps - a 2nd hub/manager exits instead of racing config.toml (skipped when
  `XENEON_GRAB` set so QA grabs still work). This is the fix for the multi-writer
  config churn seen with several instances up at once.
- **Config self-binding fix** (`a11e24b`): `WidgetConfigPanel` property renamed
  `store`→`st` - `store: store` at the call sites self-bound to null, so the ENTIRE
  config form (hub + Manager) showed defaults + dropped edits. Regression gate
  `tst_config_panel_wiring.qml`.
- **Version in UI** (`0fb8ceb`): git-describe → `XENEON_VERSION` → `appVersion()` →
  Manager nav + hub Diagnostics. PKGBUILD passes `-DXENEON_VERSION_OVERRIDE`.
- New tests: `tst_config_panel_wiring`, `tst_all_widget_configs` (all 23 types render),
  `tst_store_validation`, `tst_single_instance` (C++), `tst_rx_cap` (C++).

### Resolved: B5 two-writer race on display/autostart (was: needs a design decision)
- **FIXED** (`d8338bb`, merged onto the socket-path/hermetic-guard master in `11911c2`):
  the design decision went to **per-field control-socket setters**, not `reloadConfig` -
  a reload of a file the hub is about to overwrite would only move the race. New
  `setTargetDisplay`/`setAutostart` requests make the hub adopt the value into its LIVE
  config, apply the side effect (strict display re-match + window migration; XDG
  autostart `.desktop` entry), persist, and ack (`{"type":"ok"|"error","for":…}`).
  While connected the Manager is IPC-only for these fields and blocks (bounded, 1 s)
  on the ack because the QML re-reads effective state on the next line; offline it
  remains the sole writer and persists directly, as before. Regression gates:
  `tst_manager_backend_sync` (`targetDisplaySurvivesHubSave`/`autostartSurvivesHubSave`
  drive the REAL `ControlServer` + `ConfigHandle`, plus honest-failure and bounded-
  timeout cases) and `tst_control_server` (ack protocol, empty-target and non-bool
  `enabled` rejection). Both regressions fail against the pre-fix Manager.

### Resolved: FocusWidget goal bonus now fires once
- **FocusWidget goal bonus/celebration is now ONE-TIME.** Previously it re-fired every
  session past the daily goal (`done >= dailyGoal`). Changed to `done === dailyGoal` in
  `FocusWidget.advance()`, so the +50 bonus + "🎯 Goal reached!" fire only on the session
  that crosses the goal; later sessions get the ordinary +10. Regression gates:
  `tst_gen_focus.qml::test_reaching_goal_awards_bonus` (crossing → +60) and
  `test_goal_bonus_does_not_refire_when_exceeding` (past goal → +10, no re-celebration);
  `tst_focus.qml::test_reward_points_and_goal_bonus` still green.

### Prior test-push (PR #1)
- **On-device**: hub dashboard, Manager, and an expanded widget config all verified
  via `XENEON_GRAB` captures on the real Edge (DP-3). Wallpaper with spaces + `#`
  in the path loads correctly through `configBridge.imageUrl()`.

## What the last few commits did (newest first)

- **`736ba9f` - stop rewriting config.toml every 2s.** Metric widgets (cpu/gpu/ram/net)
  mirror sparkline history (`hist`/`peakRx`/`peakTx`) into the store every sample; the
  store used to persist every write → the hub rewrote `config.toml` ~every 2s forever
  (flash wear + a two-writer atomic-rename race with the Manager: "Failed to save
  config: No such file or directory"). Those keys are now **ephemeral** in
  `DashboardStore.qml` (`_ephemeralKeys`): kept in memory for compact↔expanded sparkline
  sharing, but a volatile-only write bumps `revision` without scheduling a save, and
  `_persistableData()` strips them from disk. Idle saves: ~1/2s → 0. 2 new regression
  tests in `tst_store_tiles.qml`.
- **`7cd491e` - shell/manager bug sweep + cross-file wiring.** Integrated the 8-agent
  QML fixes (Manager S2/S11/imageUrl/syncTheme guard/tall-tile clone/dialog/wizard; hub
  Dashboard S7/gridCols/expand/overlay-close, SettingsPanel S2, Diagnostics scroll+labels,
  main.qml keyboard-lift+diagnostics bindings). Plus the cross-file bits the agents could
  not do: `ConfigBridge::imageUrl()` on the **hub** (hub exposes `configBridge`, NOT the
  Manager's `backend`), S9 screen-hotplug rebuild+push of `screensData`, S7 accent on
  `WidgetChrome`'s BackdropLayer.
- **`ee63764`** - the big Phase 0–3 widget/shared-infra/Rust/C++ bug fixes.
- **`a5a742a`** - generated regression suites + `docs/BUG_FIX_PLAN.md` (the master plan).

## Remaining work (prioritized)

The three former items are now **DONE** this session:
1. ~~**S10 - write-only FFI config keys**~~ ✅ Added `xeneon_config_get_reconnect` +
   `get_notify_disconnect` to `ffi.rs`/`xeneon_core.h`, exposed all three via `ConfigBridge`
   (`reconnectOnHotplug`/`notifyOnDisconnect`/`fallbackBehavior`), and wired the hub
   `screenAdded`/`screenRemoved` handlers to honor them (reconnect→re-match+migrate window;
   notify→disconnect notice; fallback=="hide"→blank). Gated by `tst_config_bridge`.
2. ~~**Two-writer atomic-save race**~~ ✅ Single-writer: when the hub is connected the Manager
   pushes `setUiState` over IPC only and does NOT write `config.toml`; it writes directly only
   when offline. Gated by `tst_manager_backend_sync` (+ the #7 edit-loss fix).
3. ~~**Duplicate "Page 5" pages**~~ ✅ `_normaliseDoc` now de-dupes `pages[].name` on
   `load`/`applyExternal` (appends " 2", " 3", …). Gated by `tst_store_dedup`.

Still open (documented, non-blocking): `mpris_bridge.cpp` D-Bus fan-out uncovered (needs a
session bus; the review confirmed the rest of the C++/core is solid). (config.rs was raised
to 98.3% this session.)

### CI is now live (first real run this session)
The trigger was fixed (`main`→`[main, master]`), so CI ran for the first time and surfaced
five environment/latent issues, all fixed in PR #1: Qt ≥6.5 via `jurplel/install-qt-action`
(apt Qt 6.4.2 lacks `MultiEffect`/`QtQml.WorkerScript`); a JS reserved-word (`float`) var
Qt 6.7 rejects; a font-metric test made deterministic (assert bounded box, not glyph ink) +
fonts installed; a **real widget bug** - `CountdownWidget` used `Layout.maximumWidth` which
Qt 6.7 ignores for oversized text, so a 5-digit day count could overflow (fixed with
`Layout.preferredWidth`); and `pipx gcovr` so CI honors the `GCOVR_EXCL` hardware-exclusion
markers (apt gcovr didn't → understated C++ coverage → merged 94.10%). CI runs Qt 6.7.3 via
aqt (older than the dev box's 6.11) on purpose - it catches exactly this class of bug.

## Key context for continuing

- **The plan**: `docs/BUG_FIX_PLAN.md` (systemic S1–S12 + discrete findings, phased).
- **Manager plan**: `.claude/plans/crystalline-mixing-hopper.md` (detailed Manager findings
  A1–A21 / B1–B18 / C P1–P3). Most are done; cross-check before re-doing.
- **CRITICAL runtime distinction**: the **hub** process exposes `configBridge` (no
  `backend`); the **Manager** process exposes `backend` (`ManagerBackend`, has `imageUrl`,
  `screensJson`, autostart, IPC). QML shared by both must feature-detect.
- **Config sync (already implemented, `manager/src/main.cpp`)**: pushLive buffers +
  flushes on `connected`, 2s reconnect timer, getUiState pull heartbeat with reconnect
  conflict-resolution (`m_pendingPushAwaitingHub`), `QFileSystemWatcher` on config.toml,
  `screensChanged` NOTIFY.
- **On-device capture**: `DISPLAY=:0 XENEON_GRAB=/path/out.png XENEON_GRAB_W=720
  XENEON_GRAB_H=2560 ./build/xeneon-edge-hub --windowed` (renders one frame → PNG → quits).
  `XENEON_EXPAND=<type>` auto-opens that widget's expanded config. Manager: same
  `XENEON_GRAB` env. Test against a temp `XDG_CONFIG_HOME` to avoid touching the live config.
- **Synthetic touch / hardware E2E**: `tests/hardware/edge_hw_test.py` (+ `uinput_touch.py`).
- Auto-memory (persists across sessions): `dashboard-architecture`, `product-decisions`,
  `companion-and-testing`, `packaging`, `ci-setup`, `runtime-e2e-testing` - read the
  index at `~/.claude/projects/-home-simon-IdeaProjects-XeneonEdge-Linux/memory/MEMORY.md`.
  A version-controlled MIRROR lives at `docs/agent-memory/` (source of truth is the
  `~/.claude/…/memory/` dir). Re-sync after any memory change, then commit:
  `cp ~/.claude/projects/-home-simon-IdeaProjects-XeneonEdge-Linux/memory/*.md docs/agent-memory/`
