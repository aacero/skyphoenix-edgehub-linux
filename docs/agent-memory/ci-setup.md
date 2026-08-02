---
name: ci-setup
description: "GitHub Actions CI structure, coverage gates, and the Qt/gcovr/parser gotchas found when CI first ran"
metadata: 
  node_type: memory
  type: project
  originSessionId: 24803e10-a7cf-4b4e-8964-f63f8db8828e
---

CI lives in `.github/workflows/ci.yml` (added/fixed 2026-07-13, PR #1). It had NEVER
run before because it triggered only on `main` while the repo is on `master` — fixed to
`branches: [main, master]` on push + pull_request. `concurrency` cancels superseded runs.

**9 jobs:** `format` (cargo fmt), `lint` (clippy -D warnings), `test` (cargo test),
`audit` (cargo-audit), `build` (cmake Release), `docs` (md link check), `qml-test`
(offscreen qmltestrunner + `scripts/qml_coverage.py` gate), `cpp-test` (cmake
`-DXENEON_BUILD_TESTS=ON -DXENEON_COVERAGE=ON` + ctest + gcovr → uploads `cpp-lcov`
artifact), `coverage` (needs `[test, cpp-test]`: cargo-llvm-cov for Rust, downloads
cpp-lcov, `lcov` merge, gates **Rust ≥95 AND merged Rust+C++ ≥95** via a DA-line count).
Measured green: Rust 96.04%, merged 96.64%, QML behavior-matrix 99.4%. See
[[companion-and-testing]] for the test suites themselves.

GOTCHAS (each cost a red CI run the first time CI ever executed — the dev box is Qt
**6.11.1**, CI runs the supported FLOOR — Qt **6.9.3** since 2026-08-02, Qt 6.7.3 before
that — so version-specific issues ONLY show in CI):

1. **apt Qt on ubuntu-24.04 is 6.4.2 — too old.** The supported floor is Qt **6.9**
   (`CMakeLists.txt` `find_package(Qt6 6.9 …)`; the hard technical minimum is 6.5 for
   `QtQuick.Effects`/MultiEffect), and the minimal `qt6-declarative-dev` also lacks
   bundled QML modules the widgets pull in (`QtQml.WorkerScript` — "module … is not
   installed"). FIX: install Qt via `jurplel/install-qt-action@v4` `version: '6.9.3'`
   `modules: 'qtvirtualkeyboard'` `cache: true` in the build/qml-test/cpp-test jobs (NOT
   apt qt6-*-dev). It ships a full Qt with all QML modules + `qmltestrunner` (added to
   PATH, so `run_ui_tests.sh` finds it). Pinning the FLOOR rather than the newest Qt is
   deliberate — it catches #3/#4 below. To reproduce a CI-only failure locally, install
   that exact Qt with `aqt install-qt linux desktop <ver> linux_gcc_64` into a scratch
   dir, configure a second build tree with `-DCMAKE_PREFIX_PATH`, build
   `xeneon-qmltestrunner`, and point the suite at it with `XENEON_TEST_BUILD_DIR` plus
   the matching `LD_LIBRARY_PATH`/`QT_PLUGIN_PATH`/`QML2_IMPORT_PATH`. That is how the
   Qt<6.9 SwipeView binding loop and the ShapePath hairline were both found — see
   [[no-saturation-load-tests]] for what NOT to do instead.

2. **gcovr MUST come from pipx, not apt.** The C++ sources mark hardware/QScreen/QProcess
   glue with in-source `// GCOVR_EXCL_START/STOP/LINE`. apt gcovr does NOT honor them, so
   it counts those lines (e.g. `orientation_sensor.cpp` 57% / 114 lines instead of the
   excluded ~100% / fewer lines) → C++ ~85% → **merged coverage 94.10% < 95, gate fails**.
   FIX: `pipx install gcovr` (preinstalled on the runner) + `echo "$HOME/.local/bin" >>
   $GITHUB_PATH`; matches the local gcovr 8.x → excluded lines dropped → C++ 96.7% → merged
   96.64%. Locally: gcovr installed via `uv tool install gcovr` (pip/pip3 are BOTH absent
   on this CachyOS dev box — `uv` works).

3. **Qt 6.7 V4 parser is stricter than 6.9+** in ways that pass locally but fail CI:
   (a) a JS reserved word used as an identifier — `var float = …` — is rejected with
   "Expected token `identifier'" (6.9 tolerated it). Never name a var `float`/`int`/`char`
   /etc. (b) `Layout.maximumWidth` is IGNORED for an oversized `implicitWidth` on 6.7, so a
   shrink-to-fit Text (`fontSizeMode: HorizontalFit`) overflows — a REAL widget bug on
   older Qt. FIX: use `Layout.preferredWidth` (forces the layout to allocate exactly that
   box) alongside maximumWidth. (Found in `CountdownWidget` — the number could overflow.)

4. **Headless font metrics are non-deterministic.** Under `QT_QPA_PLATFORM=offscreen` with
   NO font installed, `Text.fontSizeMode` fit and `paintedWidth` produce meaningless values
   (the countdown fit test failed only on CI). FIX (both): install `fonts-dejavu-core`
   `fontconfig` (+ `fc-cache -f`) on the qml-test job, AND assert the STRUCTURAL guarantee
   (the layout-bounded box `num.width <= avail`) rather than glyph ink (`paintedWidth`),
   which is what `docs/DEV_AND_TEST_PLAN.md` calls "genuinely unmeasurable headless".

5. **A STALE LOCAL CMAKE CACHE CAN HIDE A REAL BREAK — the local suite is not CI.**
   `scripts/build.sh` configures `-DXENEON_QA_HOOKS=ON`, so every local `build/` dir has it
   cached ON forever; `run_cpp_tests.sh` reused that cache and went green. CI configures a
   FRESH tree and (until 2026-07-14) did not pass the flag → default OFF → `XENEON_GRAB`
   compiled out (a304d0b/B7) → the smoke tests, which drive the real binaries via
   XENEON_GRAB expecting render-one-frame-and-exit, hung until a 30s timeout. FIX
   (`b6d6183`): `run_cpp_tests.sh` + the CI cpp-test job both pass `-DXENEON_QA_HOOKS=ON`
   (CI's separate `build` job still covers the hooks-OFF product config), and the smoke
   tests `QSKIP` on `QA_HOOKS_BUILD == 0` instead of timing out uselessly.
   RULE: when local is green and CI is red on a BUILD-shaped failure, diff the cmake flags
   first (`grep XENEON build/CMakeCache.txt` vs the workflow's configure line) — a
   long-lived local build dir does not represent a fresh clone.

5b. **Run the CI COMMAND, not your own shorthand.** CI runs `cargo clippy --all-targets
   -- -D warnings`; `cargo clippy --lib` never compiles the test target, so a lint in a
   `#[cfg(test)]` block (e.g. `unused_unsafe` on a safe `extern "C"` fn) passes locally
   and fails CI. Same root cause as #5 — local invocation ≠ CI invocation. Before
   pushing Rust: `cd core && cargo clippy --all-targets -- -D warnings && cargo fmt
   --check`.

6. **CI only triggers on `[main, master]`, so branch work is UNVERIFIED until it merges.**
   The whole `v1.0-alpha` epic track (Sequence-0/E1/E2) never ran CI once; gotcha #5 rode
   the branch invisibly for 8 commits and went red the instant alpha merged to master. If a
   release/epic branch is going to live for more than a session, add it to the trigger (or
   expect the merge itself to be the first real test).

RULE: because the dev box (Qt 6.11) is far ahead of CI (Qt 6.7), always assume CI can catch
parser/layout/coverage-tool differences the local suite can't. When a CI-only QML failure
appears, suspect (in order) missing Qt module → reserved-word/parser strictness → Layout
cap-vs-preferred → font/offscreen metrics → gcovr version → stale local cmake cache (#5).
[[packaging]] covers the runtime Qt deps; [[dashboard-architecture]] the widget contract.

## Quota optimization (2026-07-16) — the shape changed
Owner hit the free-Actions limit. Root cause: master and v1.0-alpha are pushed in
ff-only LOCKSTEP (same SHA), and all three workflows triggered on both — every
merge ran all 18 jobs TWICE for zero information. Now: workflows trigger on
master only (re-add v1.0-alpha ONLY if it ever truly diverges again); ci.yml is 5
jobs (fmt+clippy+test folded into one `rust` job — three toolchain setups
wrapped ~90s of work; Security Audit DELETED as fully redundant with cargo-deny's
advisory check in supply-chain; Docs & Links moved to paths-filtered docs.yml);
ci ignores docs/**+*.md; distro.yml runs on packaging paths + weekly cron +
manual dispatch (RELEASE CHECKLIST: dispatch it before tagging); supply-chain
runs on code paths + weekly cron (advisories arrive without pushes).
Per-merge cost: ~36 job-runs → ~5-8; docs-only → 1.
