# Xeneon Edge - Development & Test Plan (Hub + Manager)

**Status:** Historical execution plan · **Created:** 2026-07-13 · **Owner:** engineering
**Goal at creation:** finish debugging the hub and manager, then bring the project
to a verifiable **≥95% aggregate coverage gate**.

> **Superseded as a current status document.** The baseline, waves, counts and
> results below are a point-in-time engineering record. They must not be used as
> evidence for the current candidate. Use
> [MVP scope and evidence status](product/mvp-scope.md) for current requirements,
> [the strict release gate](testing/release-gate.md) for the executable manifest,
> and `scripts/run_all_tests.sh` for the current development aggregate.

---

## Historical context - why this plan existed

At the 2026-07-13 baseline, the hub (`xeneon-edge-hub`) and companion
(`xeneon-edge-manager`) had received a large bug-fix sweep, but four gaps remained.
The present-tense statements below describe that old baseline and were later
resolved; the historical fix plan is preserved in `docs/BUG_FIX_PLAN.md`.

1. **The C++ layer has zero automated tests.** `control_server`, `orientation_sensor`,
   `ManagerBackend`, `ConfigBridge`, `mpris_bridge` - including the IPC protocol, the
   reconnect/reconcile state machine, path-sanitization, and orientation mapping - are
   only exercised indirectly by the on-device Python E2E script.
2. **Coverage is not measured anywhere.** `.gitignore` has `lcov.info`/`*.profdata`
   placeholders but nothing generates them. There is no numeric gate.
3. **CI never runs.** `.github/workflows/ci.yml` triggers on `main`; the repo lives on
   `master`. It also has no QML-test job, no C++ job, and no coverage step.
4. **`BUG_FIX_PLAN.md` has no authoritative done-list** - several systemic (S1–S12) and
   HIGH findings need re-verification against current code.

Baseline (verified 2026-07-13):

| Layer | Tests today | Coverage measured | Gap |
|---|---|---|---|
| Rust `core/` | 63 inline (`config` 11, `display` 15, `ffi` 14, `metrics` 23) | none | `logging.rs` untested; not all 54 FFI fns direct-tested |
| QML `ui/` + `manager/` | 45 `tst_*.qml`, ~832 fns | none | orchestrators, Manager, EdgeClone, several primitives, backgrounds, wizard, diagnostics untested |
| C++ `app/` + `manager/` | **0** | none | entire layer |

### Decisions locked with the user (2026-07-13)

- **QML verification = an enumerated behavior/function traceability matrix**
  (there is no trustworthy QML line-coverage tool). True line coverage is gated
  only on Rust + C++.
- **C++ becomes testable via header extraction** - pull the logic classes out of the
  `main.cpp` TUs into headers/free functions.
- **Deps approved:** QtTest (bundled), `cargo-llvm-cov`, `proptest` (Rust dev-dep).
  A fake `libxeneon_core` was **not** chosen - C++ tests link the **real**
  `libxeneon_core.a` against a temp `XDG_CONFIG_HOME` (the Rust config honors it).
- **Debug scope = full re-verification** of S1–S12 + all HIGH findings, each fix gated by
  a regression test.

---

## What "95%" means per layer (honest)

- **Rust:** true LLVM source-based **line coverage**, gated ≥95% via `cargo llvm-cov` JSON.
- **C++:** true **line coverage** (gcov/gcovr) over the *testable units* (extracted
  headers/free functions + `control_server.cpp`), gated ≥95%. Un-unit-testable glue
  (`main()`, live-`QScreen` matching, hardware ioctl loops, D-Bus fan-out) is **excluded
  from the denominator** and covered instead by offscreen smoke + the hardware E2E.
- **QML:** a finite enumerated-requirements checklist, enforced by
  `scripts/qml_coverage.py`. The gate requires `N/N` requirements to have
  assertion-backed claims. It is checklist completeness, not source coverage.
- **Genuinely unmeasurable (assert driving props, never output):** Canvas pixels
  (Sparkline/RingProgress/AnalogClock/Net/backgrounds), `MultiEffect` (AppIcon), real
  hardware (EDID/sensors), live network (Open-Meteo/geocode → FakeXHR + fixtures), MPRIS
  D-Bus (→ MockMedia).

---

## Part 1 - Finish the debugging sweep (full S1–S12 + HIGH re-verification)

Each item is **verified against current code**; if still open, fixed and gated by a
regression test (Rust `#[test]`, C++ QtTest, or QML `tst_`).

### C++ bugs to fix + pin (from the C++ audit)
- **Hub `XENEON_GRAB` UAF** - `app/src/main.cpp:714` lambda captures `&grabPath` by
  reference into a 2200 ms deferred `singleShot` (manager captures by value at `:497`).
  → capture by value. Regression = `smoke_hub` (ASan).
- **`metricsToJson` data race** - `main.cpp:77` `static bool warned` read/written from
  GUI thread (`:514`) and worker thread (`:104`). → `std::atomic<bool>`.
- **Hub `applyAutostart` optimistic return** - `main.cpp:271-273` disable path returns
  `true` even if `QFile::remove` fails (manager is honest at `:441-445`). → return real
  result. Regression in `tst_autostart`.
- **control_server honest-ack** (`control_server.cpp:120-129`) - verify the ack reflects
  `uiStateReceived`'s out-param; pin with `tst_control_server`.
- **Manager reconnect PULL-before-PUSH** ordering - pin via `tst_reconcile` +
  `tst_manager_backend_sync`.
- **EDID identity-hash duplication** - `main.cpp:158-166` vs `:206-214`; extract
  `screenIdentityHash(...)` and pin.

### Rust bugs (from `BUG_FIX_PLAN.md` §Rust core - verify each still open)
- `metrics.rs:44` `OnceLock` sensor/GPU path cache → permanent "unavailable" after a
  transient boot-time miss. Fix: bounded re-discovery when `None`.
- `metrics.rs:38` shared CPU/net delta baseline across GUI + worker → spurious spikes.
- `config.rs:179` corrupt-config full reset drops `ui_state`/overwrites `.bak`. Fix:
  timestamped backups, preserve `first_run_complete`/`ui_state` where possible.
- `ffi.rs:538` `-1.0` temp sentinel collides with real sub-zero readings.
- `display.rs:19` `parse_manufacturer` emits non-alpha garbage on zero group.
  (These already have `bug_*` encoding tests - flip them to passing.)

### Remaining items from `SESSION_HANDOFF.md`
- **S10** write-only FFI keys (`reconnect`, `notify_disconnect`, `fallback_behavior`) -
  wire the existing getters into hub behavior (disconnect handling).
- **Two-writer save race** - move to single-writer (hub owns file; Manager mutates via
  IPC only) or document as accepted.
- **Duplicate "Page 5" pages** - one-time prune in live config.

### QML systemic (S1–S12) - confirm each resolved with a `tst_` gate
Walk S1 (effAccent loop), S2 (control-binding self-destruct), S3 (`active`), S4 (metric
availability), S5 (shared history/peaks), S6 (DST day math), S7 (effAccent content),
S8 (settingsFor mutation), S9 (hotplug), S10, S11 (structureRevision), S12 (text overflow)
against current source; each must have at least one asserting test.

---

## Part 2 - C++ test harness (enabling refactor + QtTest)

### 2a. Enabling refactor (straight cut-paste into headers; AUTOMOC-safe)
New headers/free functions (production + tests compile identical code):
- `app/src/config_bridge.h` - `ConfigBridge`, `WizardBridge`.
- `app/src/autostart.{h,cpp}` - `applyAutostart` (temp-HOME testable; honest return).
- `app/src/display_match.{h,cpp}` - `screenIdentityHash(...)`, `orientationName(...)`,
  `metricsToJson()` (atomic warn). `findTargetScreen`/`screenToJson` stay in `main.cpp`
  (live `QScreen`) but delegate to `screenIdentityHash`.
- `app/src/metrics_worker.h` - `MetricsWorker`.
- `manager/src/manager_backend.h` - `ManagerBackend` (+ injectable clock, see below).
- `manager/src/reconcile.{h,cpp}` - pure `reconcileOnPull(pendingPush, nowMs,
  suppressUntilMs, pulled, lastHub, pendingPush) -> ReconcileAction`.
- `manager/src/path_sanitize.h` - `sanitizeImageName(name, imagesDir) -> optional<QString>`.
- `app/src/orientation_sensor.h` - make `byteToRotation` **public static**.
- **Injectable clock:** `ManagerBackend` gets `std::function<qint64()> m_nowMs` (default
  `QDateTime::currentMSecsSinceEpoch`) + `setClockForTest(...)`, replacing the 5 direct
  clock calls (`manager/src/main.cpp:112,121,381,411,422`) so the 1500 ms/900 ms
  suppression windows are testable with zero real waiting.

### 2b. Framework & build
- **QtTest** (`QTEST_GUILESS_MAIN` for logic/IPC, `QTEST_MAIN` only where a
  `QGuiApplication` is needed), all under `QT_QPA_PLATFORM=offscreen`.
- CMake: `option(XENEON_BUILD_TESTS OFF)`, `option(XENEON_COVERAGE OFF)`;
  `tests/cpp/CMakeLists.txt` with an `add_qt_test(...)` helper, per-test executables,
  `enable_testing()`, `add_test`, per-test `ENVIRONMENT` (`QT_QPA_PLATFORM=offscreen`,
  temp `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`). Run: `ctest --test-dir build`.
- C++ tests link the **real** `libxeneon_core.a`; each test uses a fresh temp
  `XDG_CONFIG_HOME` so config round-trips are hermetic.

### 2c. Test files (under `tests/cpp/`)
- **Unit (pure):** `tst_display_match`, `tst_metrics_json`, `tst_path_sanitize`
  (traversal matrix: `../`, absolute, `a/b`, `.`/`..`, empty, spaces/`#`),
  `tst_orientation_byte` (0x03→0/0x00→270/0x01→180/0x02→90/else→-1), `tst_reconcile`
  (decision table), `tst_autostart`.
- **Unit (event loop):** `tst_config_bridge`, `tst_metrics_worker` (QThread + QSignalSpy,
  clean teardown).
- **Integration (real QLocalSocket):** `tst_control_server` (ping/getUiState/setUiState
  ok+fail-ack/empty/malformed/unknown/shutdown-order/8 MiB cap/re-entrancy),
  `tst_manager_backend_sync` (PULL-before-PUSH, KeepAndPush/DropEdit/Adopt, suppression
  window via injected clock, deleteImage/importImage).
- **Smoke (real binaries, offscreen):** `smoke_hub` / `smoke_manager` via `XENEON_GRAB`
  → assert exit 0 + non-empty PNG (covers `main()`, screen matching, thread lifecycle;
  doubles as UAF regression; optionally under ASan/UBSan).
- **Headless negative:** `tst_orientation_reopen` (FIFO/closed fd → EOF/EAGAIN/error →
  retry-timer path, no hardware).
- **Coverage:** `-DXENEON_COVERAGE=ON` adds `--coverage`; `gcovr --filter app/src/
  --filter manager/src/ --exclude '.*main\.cpp' --fail-under-line 95` → `coverage/cpp-lcov.info`.

---

## Part 3 - Rust tests to ≥95%

- **Tool:** `cargo-llvm-cov` (LLVM source-based; accurate across `extern "C"`/`unsafe`).
  `cargo llvm-cov --lib --lcov --output-path coverage/rust-lcov.info` +
  `--json --summary-only` for the gate (`totals.lines.percent >= 95`).
- **`logging.rs`:** extract `fn level_filter(&str) -> LevelFilter`, unit-test the mapping;
  drive `init_logging` for each level + idempotency.
- **`ffi.rs`:** for all 54 `extern "C"` fns - null-pointer sentinel branch each;
  setter↔getter round-trips through `CString` (+ `xeneon_string_free`); handle lifecycle;
  invalid-UTF-8 input must not panic across the ABI; `xeneon_string_free(null)` no-op.
- **`proptest`** (`[dev-dependencies] proptest = "1"`): `compute_edid_hash`/`parse_*` on
  arbitrary bytes (no panic, bounded, deterministic); `Config` serde round-trip;
  `metrics` JSON round-trip + numeric clamps.

---

## Part 4 - QML tests for a complete enumerated-requirements matrix

New `tst_*.qml` (pattern: `import QtTest` + `WidgetHarness`, `findPred` tree helpers,
`tick`/store-epoch for time, props-not-pixels for Canvas):

- Orchestrators: `tst_dashboard.qml` (cfgAction/closeExpanded/applyExternalState/
  _tileExists/applyAppearance/injectWidget + 7 appearance→store Connections),
  `tst_main.qml` (bindStackItem + content rotation 0/90/180/270).
- Manager: `tst_manager.qml` (4 tabs, pageTiles/refreshImages/confirmDeleteImage/
  syncTheme, MButton/MSwitch - stubbed `backend`), `tst_edgeclone.qml`
  (wsrc/spanH/injectInto/targetAt + resize-drag).
- Primitives: `tst_sparkline`, `tst_ringprogress`, `tst_widgetchrome`,
  `tst_settings_panel`, `tst_widget_config_panel`, `tst_controls`
  (PillButton/SegmentedControl), `tst_appicon` (fallback props only).
- Backgrounds: `tst_backgrounds_components` (each of 7: `active`/`running` static-vs-
  animated + reduceMotion forces static).
- Catalogs/theme: `tst_widget_catalog`, `tst_theme`, `tst_catalogs`.
- Screens: `tst_diagnostics`, `tst_first_run_wizard`.
- Store IO: `tst_store_io` (`_persistableData` strips `hist`/`peakRx`/`peakTx`,
  `_isEphemeralKey`, `_hasBridge`, `flushNow` via injected fake `configBridge` spy).
- Network: `tst_weather_net`, `tst_calendar_net` using the **XHR factory seam**.

**XHR factory seam (small production change):** add `property var xhrFactory: null` to
`WeatherWidget.qml`, `CalendarWidget.qml`, and `manager/qml/WidgetConfigDialog.qml`;
`var xhr = w.xhrFactory ? w.xhrFactory() : new XMLHttpRequest()`. Tests inject a FakeXHR
+ fixtures (valid forecast/geocode + failure shapes: non-200, missing fields, malformed
JSON, empty results, timeout).

**Matrix enforcement:** `scripts/qml_coverage.py` derives a finite requirement
set from selected source functions, schema keys, widget types, backgrounds and
wallpapers. It reports how many of those enumerated requirements have a
`// COVERS:` claim backed by a real assertion, and exits nonzero unless all are
backed. This is checklist completeness, not QML source coverage. Changes to the
enumeration sources or rules require the CODEOWNER to review whether the
denominator itself has gaps.

---

## Part 5 - Coverage tooling & CI

- **`scripts/run_all_tests.sh`** - cargo test → run_ui_tests.sh → ctest → qml_coverage.py,
  aggregate pass/fail.
- **`scripts/coverage.sh`** - independently gates Rust and C++ at ≥95%, writes
  `coverage/merged-lcov.info` as a diagnostic only, and reports `N/M` enumerated
  QML requirements assertion-backed.
- **CI overhaul (`.github/workflows/ci.yml`):**
  - **Fix trigger:** `branches: [master]` (or `[main, master]`).
  - Keep `format`/`lint`/`audit`/`build`/`docs`.
  - Add **`qml-test`** (offscreen qmltestrunner plus an `N/N`
    assertion-backed requirements checklist),
    **`cpp-test`** (`-DXENEON_BUILD_TESTS=ON -DXENEON_COVERAGE=ON` + ctest + lcov capture),
    **`coverage`** (needs `[test, cpp-test]`; llvm-cov + merge + ≥95 gate; upload artifact).
  - `concurrency` to cancel superseded runs.
- Update `AGENTS.md` §Test & Lint and `docs/testing/test-strategy.md` to match reality.

---

## Part 6 - Multi-agent execution model

Concurrent writers use **git worktrees** (or strict file ownership) and integrate
frequently; shared files (`CMakeLists.txt`, `ci.yml`, `main.cpp`) are single-owner.

**Wave 0 - Foundation (single-owner, sequential on shared files):**
- `A0-refactor` - C++ header extraction + baked-in bug fixes (Part 1 C++ + 2a).
- `A0-cmake` - `tests/cpp/` scaffolding, `XENEON_BUILD_TESTS`/`XENEON_COVERAGE`.
- `A0-ci` - CI branch fix + new jobs + coverage scripts.

**Wave 1 - Builders (parallel, isolated ownership):**
- `A1-rust` - owns `core/` (logging refactor+tests, ffi boundary, proptest).
- `A2-cpp-tests` - owns `tests/cpp/*.cpp` (after A0-refactor lands).
- `A3-qml-orch` - owns `tst_dashboard/main/manager/edgeclone`.
- `A4-qml-prim` - owns primitives/backgrounds/catalogs/theme/store_io/diagnostics/wizard.
- `A5-qml-net` - owns XHR factory seam (3 source files) + `tst_weather_net/calendar_net`.
- `A6-bug-verify` - full S1–S12 + HIGH re-verification; hands fixes to layer owners.

**Wave 2 - Assurance (the "outstanders" and "rubber duckies"):**
- `V1-outstander-cpp`, `V2-outstander-qml`, `V3-outstander-rust` - adversarial review of
  each layer's tests: do they *assert*, or just execute? Any test that can't fail is rejected.
- `D1-rubber-duck` - explain-back each nontrivial fix/test to catch flawed reasoning.
- `C1-coverage-auditor` - runs `coverage.sh` plus `qml_coverage.py`, reports the
  independent Rust/C++ line percentages and QML `N/M` requirement count, lists
  missing assertion-backed requirements, and loops work back until Rust/C++ are
  each ≥95% and QML is `N/N`.
- `I1-integrator` - merges worktrees, resolves shared-file conflicts, runs
  `run_all_tests.sh` green, commits per Conventional Commits.

---

## Current verification entry points

The old six-step acceptance list has been replaced by maintained runners:

1. `./scripts/run_all_tests.sh` runs the development aggregate, including Rust,
   offscreen QML, C++, the enumerated-requirements matrix, runtime, Manager and
   compositor tiers.
2. `./scripts/coverage.sh` runs the independent Rust and C++ line-coverage
   gates plus the QML enumerated-requirements gate. The merged line report is
   diagnostic only.
3. Current real-device suites are `tests/hardware/edge_e2e.py`,
   `tests/hardware/e2e_buildup.py` and `tests/hardware/widget_render_matrix.py`;
   `edge_hw_test.py` is deprecated legacy coverage.
4. `./scripts/run_release_tests.sh` is the only complete strict pre-release entry
   point. It rejects missing prerequisites and hidden skips and adds exact-candidate
   hardware, performance and long-soak requirements.

A command existing or passing once does not certify a later candidate. Current
results belong in the release evidence, not in this historical plan.

---

## Historical results (executed 2026-07-13)

Delivered via a multi-agent fleet (7 builders → 6 assurance/remediation → 3 hardening →
coverage-wiring), each wave adversarially reviewed by "outstander" + rubber-duck agents.

**All gates GREEN** (`./scripts/run_all_tests.sh` → `RESULT: SUCCESS`):

| Layer | Tests | Coverage | Gate |
|---|---|---|---|
| Rust `core/` | 63 → **110** | **96.44%** line (logging 100, ffi 98.4, display 97.9, metrics 95.2, config 93.0) | ≥95 ✅ |
| C++ `app/`+`manager/` | 0 → **13 ctest** (unit+integration+smoke) | **97%** filtered line | ≥95 ✅ |
| QML | 45 → **68** files | **99.4%** behavior matrix (163/164) | ≥95 ✅ |

- **Enabling refactor** landed: `ConfigBridge`/`WizardBridge`/`MetricsWorker`/`ManagerBackend`
  + pure logic (`byteToRotation`, `reconcileOnPull`, `screenIdentityHash`, `sanitizeImageName`,
  `millideg_to_celsius`, `parse_cpu_line`) extracted to headers/free functions - all directly
  unit-tested; product Release build unchanged.
- **Debug sweep (full S1–S12 + HIGH re-verification):** S1–S9/S11/S12 + all discrete HIGH
  confirmed fixed with test gates. **Newly fixed this session:** S10 (added FFI getters +
  wired reconnect/notify/fallback into hub hotplug), two-writer save race (Manager is
  IPC-only writer when connected), page-name dedup on load, S5 RAM/GPU history sharing.
- **Bugs caught by the review agents and fixed:** XENEON_GRAB use-after-free; `metricsToJson`
  data race → atomic; hub `applyAutostart` optimistic return; EDID identity-hash duplication;
  a cross-module Rust test env-lock race; a non-monotonic-counter CPU overflow panic; the
  `-1.0`/NaN temp-sentinel semantic (real −1 °C no longer read as "unavailable"); **and the
  #7 single-writer edit-loss heisenbug** (live edit now supersedes a buffered offline edit) -
  its regression test was verified to fail without the fix.
- **Infra:** CI trigger fixed (`main`→`[main, master]`) + new `qml-test`/`cpp-test`/`coverage`
  jobs with ≥95 gates; `scripts/{run_all_tests,coverage,qml_coverage,run_cpp_tests}` added;
  coverage tooling (`cargo-llvm-cov`, `llvm-tools`, `gcovr`) installed without sudo.
- **Honest residuals:** `config.rs` 93% (below the per-file 95 but the total gate passes;
  a config corrupt-path IO test would close it); `fn:main.onContentRotationChanged` (input-method
  hide + fade restart - unobservable offscreen); `mpris_bridge.cpp`'s async D-Bus plumbing
  (genuinely needs a bus; its logic was extracted to `mpris_state.*` and is now 100% covered
  - see below) - all documented, none blocking.

## Historical residual notes

- The XHR factory seam and `level_filter`/`screenIdentityHash` extractions are small
  **production** changes made solely for testability - behavior-neutral, verified by the
  existing build + smoke.
- C++ coverage denominator excludes hardware/`main()`/live-`QScreen` paths by design; those
  are covered by smoke + the on-device Python E2E, which are not in the CI line-% math.
- `mpris_bridge.cpp`: the *decisions* (which player wins, what a reply means, whether QML is
  notified) were extracted to `app/src/mpris_state.{h,cpp}` and are unit-tested with no bus -
  `tests/cpp/tst_mpris_state.cpp`, 100% line coverage on `mpris_state.cpp`, `mpris_bridge.h`
  and the non-excluded part of `mpris_bridge.cpp`. Only the async D-Bus *plumbing* stays out
  of the denominator (`GCOVR_EXCL`, reason in-source): it needs a live bus and a live player,
  and is exercised by the on-device E2E. Note the marker is on the conversation, not the
  logic - a new decision belongs in `mpris_state.*`, not inside the excluded region.
