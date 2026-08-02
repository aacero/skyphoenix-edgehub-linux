# Backlog

Single list of what is open. Until now these were scattered across
`docs/BETA_PLAN.md` (the plan) and `docs/SESSION_HANDOFF.md` (the log), which
meant "what is left?" had no one answer. The plan still owns *strategy*; this
file owns *items*. Optional ideas land here instead of in the code.

Status re-verified 2026-07-17 against the tree, not against these docs - this
file had already drifted within a day (it still called `--reset` an open decision
after the fix shipped). If an entry here disagrees with the code, the code wins.

## Blocked on Simon (nothing proceeds without these)

| # | Decision | Why it blocks | Notes |
|---|---|---|---|
| D1 | Calm as the default theme? | Ships in the beta's first impression | Current default: dark |
| D2 | Default font: system vs Atkinson Hyperlegible | Same | Atkinson is the a11y-forward pick |
| D3 | Lawyer pass on distro theme naming | This is sold B2B | Partly de-risked already: `ui/qml/Theme.qml:334` keeps distro modes **colour-only** - no logos or wordmarks. The naming is the residual exposure. |
| D4 | ~~Payment provider~~ | **DECIDED: Lemon Squeezy / Gumroad.** Licensing system built (see below). Remaining Simon steps: run `keygen` to arm the issuer key, and create the store product wiring key delivery. |

## Licensing / Pro tier - BUILT 2026-07-17 (see docs/LICENSING.md)

The premium tier is complete end-to-end and CI-verified. Free stays fully
functional; Pro is a low-cost cosmetic "supporter" tier.

- **Mechanism:** offline ed25519 verify (Rust, fails-soft) → `license_key` in
  config → `LicenseBridge` (hub) / `ManagerBackend` (Manager) → QML `license.isPro`.
  A key pasted in the Manager pushes over IPC so the hub re-gates LIVE (single-writer).
- **UI:** Manager → About → licence card + paste-key dialog that verifies offline
  as you type (Activate only enables for a key that unlocks Pro).
- **Gate:** a premium theme pack (Synthwave, Cyberpunk, Vaporwave, Matrix + the 5
  distro themes) - free users hover to taste, a PRO badge + click-to-activate; ~20
  themes stay free. It's a `pro:` flag + one check, trivially adjustable.
- **Issuer tool:** `tools/license-tool` (keygen + mint) + `scripts/mint-license.sh`;
  crypto correctness gated in CI. NOT shipped in the app.

**Remaining Simon steps (like GPG signing):**
1. `cargo run --manifest-path tools/license-tool/Cargo.toml -- keygen` once; paste
   the public key into `core/src/license.rs` (arms verification - until then every
   key is free), store the private seed in Bitwarden.
2. Create the Lemon Squeezy / Gumroad product and wire key delivery (mint from the
   order). Set the price there.

Open (needs Simon's content call, not code): whether to also gate a **premium
PRESET pack** and **custom user widgets** - the flag infrastructure is the same
one line; just needs the "which items" decision.

## Beta workstreams (`docs/BETA_PLAN.md`)

- **W1 - sizing part 2. DONE.** Waves 1–3 landed; 31 widgets carry a `sizes:`
  declaration in `ui/qml/WidgetCatalog.qml`; `habit` gained `1x1.5` (a real
  transposed 4×7 map, not a stretch).
- **W2 - Manager UX clarity. DONE** (audit: `docs/ux/manager-audit-2026-07-16.md`).
  Scope vocabulary defined, copy made honest, and a silent data-loss bug fixed (a
  typed page name was destroyed because nothing in the pane took focus). Open
  items it raised are listed under "Known gaps" below rather than left implicit.
- **W3 - widget smoothness. DONE** (pending on-device verification). Sensors
  delegate-churn, the Dashboard reorder teleport, the EdgeClone reorder teleport,
  and PillButton's glyph scaling are all fixed. The Dashboard fades a removed tile
  out (`motionRemove`), fades an added tile in at its slot (`motionAdd`), and eases
  the edit-mode "Add widget" slot. The EdgeClone exit/entrance gap is ALSO closed
  now (`b7c023f` - a removed tile fades, an added one arrives; the earlier "still
  pops" note was stale). None of the motion work is verified on the real device -
  the offscreen harness cannot instantiate `qrc:` widgets, so delegate survival is
  asserted via the Loader, not the widget. **This is the one W-item that genuinely
  needs Simon's eyes on the panel.**
- **W4 - test growth.** Runtime E2E now at **9** scenarios (added: `--reset`
  flags, live-push single-writer over the real socket, page-dedup round-trip).
  Manager behavior tests landed with W2. Gates: matrix 100%, Rust+C++ ≥95%.
- **W5 - end-user validation.** Persona walkthroughs after each major merge;
  findings feed W2/W3 as concrete items.

## Known gaps (documented, non-blocking)

- ~~`--reset` destroys `config.toml` with no backup~~ - **FIXED** (`dcdc003`).
  It now copies to `config.toml.bak` first via the already-tested
  `backup_config_of()`, and REFUSES to reset if that copy fails (failing to reset
  is recoverable; resetting without the backup is not). The help text says it
  discards the layout and points at `--reset-wizard`; success names the backup
  path. **If you disagree** - i.e. `--reset` should mean "destroy it, I'm sure" -
  say so and I'll revert; that is the only part of this that was ever a decision.
- **`backup_config()` is still only reached via reset.** The public wrapper had
  ZERO production callers before `dcdc003`; `config.toml.bak` was never written,
  and the corrupt path's careful "never clobber the good .bak" guarded a file that
  did not exist. Reset now writes it, but nothing else does - so the "canonical
  good-config backup" is still not a routine safety net. Worth deciding whether a
  save should ever produce one.
- ~~The Manager half of the single-writer rule is unproven~~ - it is proven, the
  entry was stale. `tst_manager_backend_sync.cpp::connectedSaveIsIpcOnlyNoFileWrite`
  drives the real `ManagerBackend` against a `FakeHub` over the actual control
  socket, saves while connected, and asserts the push arrives over IPC AND
  `!QFile::exists(config.toml)` - i.e. the Manager did not write the file. Verified
  fail-on-violation 2026-07-17: reintroducing the second write in the connected
  branch makes the C++ suite go red (1/21 failed); removing it returns to 21/21.
  No GUI or product test-hook was needed - the backend save path is directly
  drivable headlessly. The B5 story is closed on both halves (hub side = runtime
  scenario 07).
- ~~`mpris_bridge.cpp` D-Bus fan-out is uncovered - needs a session bus.~~
  **Done 2026-07-17.** The "needs a bus" framing was wrong for most of it: the
  player-choice policy, the metadata/availability rules and the dirty-check were
  pure logic that merely *sat inside* bus-facing methods and an async lambda.
  They now live in `app/src/mpris_state.{h,cpp}` and are unit-tested with no bus
  at all (`tests/cpp/tst_mpris_state.cpp`, 35 cases, 100% line coverage on the
  extracted logic). No `QSKIP` was used - the test instead points
  `DBUS_SESSION_BUS_ADDRESS` at a nonexistent socket and *asserts* the bridge is
  offline, so it fails loudly rather than skipping if a bus ever appears.
  What genuinely still needs a bus, and is deliberately left to the on-device
  E2E: the async fan-out plumbing itself (`ListNames` → per-player
  `PlaybackStatus` → `GetAll` → `Position`), the `PropertiesChanged`
  subscribe/unsubscribe, the stale-reply identity guards (they need two real
  in-flight replies), and `callPlayer` transport control. Those are marked
  `GCOVR_EXCL` in `mpris_bridge.cpp` with that reason.
- ~~The Manager's About button opens `"#"`~~ - **FIXED** (`8fa67c9`), and guarded
  by `scripts/check_ui_links.sh`. Note the lint's first version was itself inert
  (it grepped `openUrlExternally("` and the call was line-wrapped); the negative
  control is the only reason that surfaced.
- ~~`HydrationWidget.qml:260` hard-codes `PillButton { implicitWidth: 170 }`~~ -
  **FIXED** (`b7ef100`), and my framing of it was wrong: the claimed "clips at
  textScale 1.6" does NOT reproduce with today's labels (measured: "Remove" is
  141px at 1.6 vs the 170 literal), which is exactly why the literal survived. The
  bug was latent, awaiting a translation or relabel. 170 was right in VALUE and
  wrong in KIND - the requirement was generosity, not a matched pair - so it is
  now a `PillButton.minWidth` FLOOR: identical rendering today, content wins when
  wider.
- ~~The `expanded`-vs-size conflation in 7 more widgets~~ - **FIXED** across
  EndOfDay/Focus/Moon/RightNow (`92a3d2e`) and Net/Tasks/Hydration (`e4db92b`),
  after Habit (`b7ef100`). Each mode-keyed SIZE now derives from the room; genuine
  mode-checks (a `showHeader`, an editor-vs-display view, a composition choice
  like which side peaks sit on) were deliberately KEPT and documented as such;
  several `expanded` terms were outright dead code and removed. `celebrateLabel`
  in Tasks and Hydration gained the missing `wrapMode`/`elide`/bounded width.
  Two honest non-guards were documented rather than faked: Tasks `rowFont` and its
  empty-state line both hit the same cap under the literal and the derived
  formula, so no test can tell them apart - the agents left a comment saying so
  instead of a green-either-way guard. **`full` is not a full screen** (the config
  preview is a pane ~941×456 / ~656×980) is now encoded in the tests.
- ~~HydrationWidget's expanded overlay overflows its box~~ - **FIXED** (`67052c6`).
  Was 612px (goal 8) / 812px (goal 20) of fixed literals spilling off the 456px
  preview pane AND the real 720px landscape screen (count clipped off the top, goal
  controls off the bottom). Now room-derived: an `ovlScale` from the box height
  drives the count/air, and the glass grid uses a closed-form AREA budget (~18% of
  the box) so 20 glasses fill more columns instead of a taller stack. Post-fix it
  fits every case (941×456, 2560×720, both goals) while portrait keeps its generous
  look. The agent caught a subtlety my repro missed: the real Dashboard overlay
  sets `showHeader=false` (Dashboard.qml:1531), so the guard measures the true
  on-device room. Guard proven fail-on-violation (restoring the literals reds it,
  and I re-verified independently: reverting just count+cell → top=-9 on the pane,
  top=-26 on the device). Not verified on the physical panel - margins left ≥11px
  to absorb font-metric differences.
- ~~`RamGbOverflow::test_gb_centre_text_fits_ring_interior` fails under a
  DejaVu-only fontconfig~~ - **FIXED** (`18c927f`). It was the real bug, not an
  env quirk: with `theme.fontMono` falling back to a proportional face the ring's
  centre reading rendered 265px into a 227px interior. `Layout.maximumWidth` alone
  is inert once implicitWidth exceeds it (and takes HorizontalFit + elide with it);
  paired with `preferredWidth` it binds. Both gauge texts fixed.
- ~~The identical inert-cap shape latent at BreakWidget/ClockWidget/KpiWidget~~
  - **FIXED** the three real ones (`KpiWidget:291`, `ClockWidget:178`,
  `BreakWidget:282`); `BreakWidget:268` was correctly a non-issue (it WRAPS, which
  binds the cap on its own). No automated guard: verified under a no-mono
  fontconfig, but un-guardable in the default DejaVu-mono suite because the value
  pre-fits by char count - a guard there is inert either way (I wrote one, my
  negative control passed, I removed it). This is the CI font blind spot below.
- **CI has a font blind spot for this class.** CI installs `fonts-dejavu-core`,
  which INCLUDES DejaVu Sans Mono, so a `theme.fontMono`-fallback overflow (the
  gauge bug above) does NOT reproduce in CI - only on a machine whose mono font is
  absent or wider. A width-fit test that is honest across fonts would need to
  either force a fallback or assert the structural cap directly rather than glyph
  width. Worth a decision.
- **Wallpaper/theme name collision - it is FIVE names, not three.** Measured
  2026-07-17: the overlap between `Theme.qml`'s modes and `WallpaperCatalog.qml`'s
  items is **aurora, ember, midnight, nebula, sunset**. The W2 audit reported
  Midnight/Nebula/Aurora, which understates it.
  The nuance that matters before anyone "fixes" this: `WallpaperCatalog.qml`'s
  header says the wallpapers are "tuned to the built-in themes", so a shared name
  may be a deliberate PAIRING, not an accident. But the correspondence is partial
  - only 5 of 12 wallpapers match a theme, and 19 of 24 themes have no wallpaper -
  so it reads as a systematic pairing that is not one. There are also THREE
  concepts in play, not two: themes (palettes), `WallpaperCatalog` (bundled
  images) and `BackgroundCatalog` (colour/animated tokens).
  Renaming either set rewrites persisted config values and needs a migration, so
  the cheap fix is UI disambiguation + honest copy about the pairing. **Decide the
  intent first** (is Midnight-the-wallpaper meant to go with Midnight-the-theme?);
  it is a copy question, not an engineering one.
- ~~`Theme.qml:209` `motionRemove` is unused~~ - now driving the Dashboard exit
  fade (`Dashboard.qml:764`) since the W3 exit-fade work landed.
- **AppImage zsync update path: audited 2026-07-17. It does not work today, and
  never has.** Still an **RC exit criterion**. What the audit established:
  - **No release has ever shipped an AppImage or a `.zsync`.** alpha.1 and
    alpha.2 assets confirm it (`gh release view`). The `zsyncmake` branch in
    `scripts/release.sh` has therefore never executed. CI builds an AppImage but
    only uploads it as an expiring workflow artifact; attaching it is a manual
    `--extra` step nobody has done. **Nothing about this path has ever run.**
  - FIXED: the artifact was named from `project(... VERSION 0.1.0)`, which
    CMakeLists.txt freezes across commits - every release would have published an
    identically-named `xeneon-edge-hub-0.1.0-x86_64.AppImage`. `release.sh`
    documents this exact trap for cpack and overrides it; build-appimage.sh had
    the same bug and did not.
  - FIXED: build-appimage.sh never passed `-DXENEON_VERSION_OVERRIDE`, so the
    binary's `appVersion()` came from `git describe` - and `actions/checkout@v4`
    fetches no tags at depth 1, so `--always` degraded it to a bare sha.
    `UpdateChecker.qml` cannot SemVer-order a sha, so it reports "no comparable
    version": **the AppImage could never tell a user an update existed** - in the
    one install kind pointed at the zsync path. Job now pins `fetch-depth: 0`.
  - OPEN (needs a product decision): the AppImage embeds no
    `X-AppImage-UpdateInformation`, so `AppImageUpdate`/`appimaged` cannot update
    it at all and there is no discovery path from an installed AppImage to the
    next `.zsync`. See docs/DISTRIBUTION.md "AppImage + zsync".
  - OPEN: a true download-and-patch test remains unrun. It needs `zsync` + a real
    AppImage; the AppImage build fails on modern-toolchain hosts (linuxdeploy's
    bundled `strip` cannot read `.relr.dyn`), so it can only live in the CI
    `appimage-smoke` job. `scripts/check_appimage_update_contract.sh` guards the
    cross-file invariants offline; it is not a substitute for the round trip.
- First-run wizard welcome still reads "Xeneon Edge Linux Hub" (nominative line
  kept per the rebrand decision - revisit only if a cleaner descriptor is wanted).
- E7 Phase B (keyring) parked by owner decision; branch kept.

## v1.1 (post-1.0, agreed scope)

- Fedora support; Ubuntu 26.04 LTS support.

- ~~C++-only line coverage was 91.70%.~~ **CLOSED 2026-07-20.** Meaningful
  ConfigBridge, ControlServer and Manager-backend tests raised the clean filtered
  result to **96.1%** (1118/1163 lines; 170/175 functions). The independently
  enforced developer ratchet now matches the release requirement at **95%**;
  no exclusions or threshold weakening were added.

- ~~`scripts/gen_widgets.py` silently overwrites hand-written widgets~~ -
  **FIXED** (`58a65ee`). It wrote every file with `open(path,'w')` unconditionally;
  a plain run replaced real ~92-line widgets with 20-line stubs (it did, once, to
  RamWidget). Now skips existing files and dead names by default; only `--force`
  overwrites. AGENTS.md's "re-run to regenerate" advice was corrected - it was the
  footgun's instruction manual.

## Test-integrity debt (opened 2026-07-16)

Three tests were found that had **never executed**: QtTest silently treats
`test_x_data()` as the data provider for `test_x()`. One was a weather-egress
guard whose entire job was to fail if the request grew an `&hourly=` series - a
deliberate sabotage proved it never fired; another had expectations stale since
the preset re-authoring and nobody noticed, because it never ran.

`scripts/check_live_tests.sh` now gates that exact class in CI and in
`run_all_tests.sh`. The **general** lesson is not gated and belongs here:

> A test that cannot fail is worse than no test - it spends review trust without
> earning it. A guard is not done until it has been **proven to fail** when the
> thing it guards is violated.

**The recurring shape (audited 2026-07-17): a gate reports SUCCESS for the state
where it did no work.** Six found, all green for a long time:

| Gate | How it was inert | Status |
|---|---|---|
| 3 QtTest cases | `test_x_data()` = data provider for a `test_x()` that never existed | fixed `2717f84` |
| `coverage.sh` C++ gate | gcovr arg misparse → `n/a` → the gate skipped **itself** | fixed `69a0484` |
| `qml_coverage.py` | empty matrix scored **100%**; a typo'd source dropped 24 behaviors with no coverage drop | fixed `8b09f9e` |
| `check_ui_links.sh` | grepped a pattern that was line-wrapped in its own target | fixed on arrival |
| `check_live_tests.sh`, `check_doc_links.sh` | reported OK on an **empty tree** | fixed `92490f9` |

**The fix is always the same: a gate must assert its own subjects exist.**
`scripts/check_no_raw_xhr.sh` is the model - it checks "the gate must still own
exactly one construction site", so it fails rather than going quiet if its pattern
stops matching. Count subjects; print the count in the OK line; make zero fatal.

Open follow-up: no mechanism forces the fail-on-violation proof for tests outside
the `_data` trap. Candidate: require new guards to record their evidence (the
sabotage tried, and that it went red) in the PR/commit body - every agent this
session was asked to do exactly that, and it caught real defects in *their own*
work four separate times.

## ~~Known flake: `test_focus_natural_goal` races the celebration banner~~ — FIXED

Opened and closed 2026-08-02. **The first diagnosis here was wrong and is worth
recording as such:** it said the assertion was "a 3 s window onto a state the
product deliberately shows for about a second", because `G.byText` requires
`n.visible`. But QML `visible` is not `opacity` — the celebration label animates
its *opacity* back to 0 while `visible` stays true and its `text` is never
cleared. The banner check was therefore durable all along.

The real race was upstream of the banner: expiry is noticed by the widget's own
repeating **1 s** timer (`FocusWidget.qml`: `Timer { interval: 1000; running:
w.active }`), and the test gave that timer a 3 s budget while the CI runner was
being starved by two hung compositor slots. The assertion conflated "the session
completed" with "the banner is on screen", so a slow tick read as a missing
banner.

Fixed by asserting the state the completion produces rather than a frame:

- `celebrateMsg` contains "Goal" — set by `celebrateNow()`, never cleared, and
  blanked per case by `prep()`, so it is a durable per-case witness. Bound
  raised to 8 s, which costs nothing on a healthy run because `tryVerify`
  returns the moment it is true.
- `points == 60` — 10 for the session plus the ONE-TIME 50 for crossing the
  goal. This is what actually distinguishes this case from
  `test_focus_natural_short`, and it is persisted state, so it cannot race.
- The banner is then checked as a *binding*, not a moment: the label carries the
  goal message and has a rendered box.

Negative controls, both proven by sabotaging the product and watching this test
go red: removing `+ (hitGoal ? 50 : 0)` fails "crossing the goal awarded the
one-time bonus"; announcing the ordinary message instead of the goal one fails
"the session that crossed the goal celebrated". Reverted, test green (123/123).

## ~~Known flake: `test_states(outside)` asserts a state the product contradicts~~ — FIXED

Opened and closed 2026-08-02, found on the post-merge `master` run
(`30761207111`). Same family as the Focus one above, and the more interesting
kind: the TEST was wrong and the product was right.

The `outside` row seeded `scheduleSuspended: true` while the surrounding patch
opened **every** weekday (`workDays: "0,1,2,3,4,5,6"`, `workStartHour ==
workEndHour`), so `withinSchedule()` was true. `BreakWidget`'s own 1 s timer
calls `applyScheduleState()`, sees that we ARE inside active hours, and correctly
clears the flag. The assertion therefore passed only when it beat that timer.

Fixed by making the row self-consistent: `workDays` now excludes today, so the
widget is genuinely outside its active hours, the product KEEPS the flag, and the
state is stable by construction rather than by timing. Negative control: dropping
the `scheduleSuspended` branch from `stateLabel` makes the row fail; reverted,
16/16 green.

## Known flake: the nested compositor occasionally never exposes a window

Opened 2026-08-02, on the first CI runs where the GUI suite could complete at all.

A slot can lose a whole file to this, once, without any product or test cause.
Qt prints it plainly and then does exactly what it says:

```
Test '.../tst_gui_w_media_data.qml' window was never exposed!
If the test case was expecting windowShown, it will hang.
```

`when: windowShown` never fires, the file hangs, and `run_bounded` kills it at
`RUN_TIMEOUT` — 540 s of a four-core runner spent on a file that produced nothing,
which also starves the three slots sharing it. Seen once (run 30753137211,
`tst_gui_w_media_data`, 89 s in the run immediately before and 32 s locally); the
same commit's other 21 files were within a few seconds of their previous timings,
so it is the exposure, not runner-wide slowness.

`.github/workflows/ci.yml` already forces `LIBGL_ALWAYS_SOFTWARE` +
`GALLIUM_DRIVER=llvmpipe` because Qt Quick's automatic Mesa selection "can still
pick Zink and leave Wayland windows permanently unexposed" — so this is the
residue of a hazard the workflow already knows about, not a new one.

**Handled 2026-08-02, and honestly rather than silently.** `run_one` detects that
exact Qt signature and re-runs the file ONCE, on a fresh slot number (the killed
compositor leaves its socket file behind, so reusing the name would let the
readiness check pass against a dead socket). The first attempt's log is kept as
`<file>.unexposed.log`, the summary line carries `(RETRIED: …)`, and the totals
block prints a `RETRIED (unexposed window, first attempt discarded)` list — a
silent retry is how a suite starts lying about what it ran. Proven both ways: a
test that emits the signature and then fails deterministically is retried AND
still reported as FAILURE, so the retry cannot rescue a real defect.

Waiting for a readiness *marker* in the compositor log was tried first and
rejected: KWin's banner depends on its backend, and this workstation's KWin uses
Vulkan (radv) and never prints the OpenGL line the CI runner does, so the gate
failed every local run. There is no portable "compositor is ready" event here
without adding a Wayland probe dependency.

**Fail-fast added the same day, and it was not optional.** Detecting the hang but
still waiting out the 540 s bound treated the symptom while amplifying the cause:
on run `30759072341` two slots spun for 540 s each and starved the rest badly
enough that unrelated 3 s `tryVerify` bounds began to fail
(`tst_gui_shell_orient_settings`, `tst_gui_w_focus_core`) — the retry was making
the runner worse. The slot now watches its own log for the marker Qt prints
*before* it blocks and aborts in seconds: measured end-to-end at **5 s** for a
probe that hangs twice, against 1080 s before.

**Mitigated 2026-08-02, still not root-caused.** It got worse as the suite got
healthier — up to three files a run, a different one each time, which points at
slot timing rather than at any test. Two timing mitigations, both stated as
mitigations rather than fixes because the race reproduces nowhere locally:

- **Compositor startup is staggered** (`XENEON_GUI_SLOT_STAGGER`, default 2 s).
  Every slot begins by launching its own `kwin_wayland`, and launching J of them
  in the same instant puts J compositors through initialisation simultaneously on
  a runner with J cores. That is the one moment all of them are doing heavy work
  at once.
- **The post-socket settle is 3 s, not 1 s.** It is the whole margin between "the
  socket exists" and "the compositor can expose a surface", and 1 s was not
  covering it under four-way contention.

The single retry stays as the safety net — and it is not always enough: on PR #10
`tst_gui_w_cal_weather` hit the same failure on BOTH attempts (each aborted in
seconds by the fail-fast, so it cost ~10 s rather than 18 min).

Still open:

- Understand why it happens at all. Both occurrences were at `-j4` on a
  four-core runner, i.e. four compositors initialising at once. If that is the
  trigger, the cheapest real fix may be staggering slot starts rather than
  detecting the symptom.

Not a product defect, and deliberately NOT worked around by widening the timeout:
a file that hangs is not a slow file.

## Candidates

Unapproved ideas, findings, and out-of-scope proposals land here. Nothing in this
section is implemented without explicit product-owner approval (scope-control policy).

- **`scripts/test.sh` is still the framework adoption scaffold stub.** Created 2026-07-31
  when the agent framework was adopted; it echoes "No test command configured" and exits
  0. Under the framework's evidence policy a stub proves nothing, so it must never be
  cited as passing validation. The real suites — ctest, `cargo test`, the QML tests and
  the enumerated-requirements job — run from `.github/workflows/ci.yml`, which installs
  Qt 6.7. `.github/workflows/quality.yml` therefore deliberately does not invoke
  `scripts/ci.sh` (which would end in `build.sh` + `test.sh`) and runs the framework gates
  directly instead. Options: point `test.sh` at the existing ctest/cargo invocations, or
  delete it and record in `project.yaml` that `ci.yml` owns testing.

- **The published AUR package has drifted ~7 months from `packaging/aur/`.**
  `aur.archlinux.org/xeneon-edge-hub` serves `pkgver=0.1.0 pkgrel=1` with
  `url=https://github.com/skyphoenix-it/XeneonEdge_Linux` (the pre-rename name), a
  single-entry `license=('MIT')`, and no `post_upgrade` notice. This repository's
  canonical `packaging/aur/PKGBUILD` is `epoch=1 pkgver=1.0.0beta1 pkgrel=2` with the
  current URL, the six-entry license list, and the upgrade notice. Nothing publishes
  `packaging/aur/` to the AUR remote, so the two drift silently. Options: a release step
  that pushes `packaging/aur/` to the AUR remote on tag, or a CI check that fails when the
  two diverge.

- **🔴 `check_ci_release_metadata_contract.py` fails on `master` and has since the v1.0.0
  publication commits.** Surfaced 2026-07-31 by the framework-adoption PR, which is the
  first run of these workflows since. **Pre-existing and not caused by that PR** — proved
  by running the script against a clean worktree of unmodified `origin/master` (`5eb04c9`):
  identical failure, `FAIL: README.md must state the unreleased release target exactly`.

  It fails **two** checks, because two workflows invoke the same script: `docs.yml` →
  "Check release documentation against build and CI truth", and `ci.yml`'s
  `qml-test` job → "CI, toolchain, packaging, and release metadata contract".

  The inconsistency: `release-metadata.toml` still carries `stage = "candidate"` with
  `target_version = "v1.0.0"`, so the script takes its unpublished branch and requires the
  README to state an unreleased target. But README was rewritten to *"Current public
  status: stable. `v1.0.0` is the first stable EdgeHub"*, its badge points at the v1.0.0
  release, and the "This checkout is unreleased and is not published or certified" marker
  is gone (0 occurrences).

  Nothing caught it because `5eb04c9`, `915b36c`, `d603bda` and `400f374` all carry
  `[skip ci]`, so no workflow has run on `master` since 2026-07-27.

  **FIXED 2026-07-31** (#3). The contradiction was one file: everything else had advanced
  to "v1.0.0 published" while `release-metadata.toml` still declared
  `stage = "candidate", target_version = "v1.0.0"`. Since the contract permits only
  `development` or `candidate` there, and both require README and ROADMAP to name a target
  strictly newer than the published release, there is no valid resting state after a
  publication until the next target is declared — rolling forward is the step the
  publication skipped. Set to `development` / `v1.0.1`, matching what the repository
  already said about itself (ROADMAP: "stable 1.0 maintenance on `master`"; CHANGELOG
  `[Unreleased]` empty), with the README/ROADMAP markers, SECURITY row and RELEASE_NOTES
  the contract requires. Verified in CI: `Docs` and `QML Tests + Enumerated Requirements`
  both green, and the contract passes on merged `master`.

  **STILL OPEN:** whether release-documentation commits should keep using `[skip ci]`.
  That is what let a red gate sit unnoticed on `master` from 2026-07-27 until the framework
  adoption PR ran the workflows again four days later.

- **`push`/`pull_request` dispatch stopped for ~45 minutes on 2026-07-31 — transient,
  since recovered.** Recorded because it was mistaken for a repository fault at the time.

  Window: every workflow's last event-triggered run was `e59e3d7` at 19:18. PR #3 (19:36)
  produced no `pull_request` runs, and pushes `641ca32` (20:12) and `9640c29` (20:13)
  produced no `push` runs. Only `workflow_dispatch` and CodeQL default setup fired.

  Resolved by itself. A probe push on 2026-08-01 06:23 (`8bd375d`) dispatched `Docs`,
  `Quality` and `Supply Chain` normally, all three green. `CI` correctly did not run: the
  probe touched only `BACKLOG.md` and `ci.yml`'s push trigger has `paths-ignore: '**.md'`.

  Not caused by the agent-framework adoption, despite the timing. The workflow files that
  landed at 19:18 (`framework-update.yml`, a new `quality.yml`) were already in place for
  the 19:18 run, which dispatched normally, and the other eleven repositories took the
  identical addition without losing their triggers. Ruled out during the investigation:
  path filters, workflow state (all `active`, all paths present), repository Actions
  settings (`enabled`, `allowed_actions: all`), a stuck queue (`queued`/`in_progress` both
  0), and an org-wide fault (`skyphoenix-company-website`'s scheduled `uptime` ran
  throughout). No GitHub incident was listed for the window, so it is most likely an
  unreported dispatch delay.

  Worth keeping only as precedent: if triggers appear dead again, check whether
  `workflow_dispatch` still works before assuming the workflows are broken.

- **🔴 370 accessibility assertions fail — newly visible, never seen before.** The QML
  compositor suite could not run at all (Xwayland crash, fixed separately), so these have
  been failing silently for as long as they have existed. First clean run: 22/22 files
  complete, **pass=2271 fail=370**.

  **368 of the 370 are one defect class: text clipping.** `tst_gui_widget_legibility`
  reports `contentHeight N > height M`, overwhelmingly by 2–4 px — 208 × `30 > 28`,
  164 × `24 > 21`, 146 × `28 > 24`. They cluster in the accessibility fonts
  (`hyperlegible`, `lexend`) at raised text scales (`text1.3`, `text1.45`) in the small
  tiles (`0.5x0.5`, `1x0.5`, `0.5x1`) — e.g. `'2 MINUTES HISTORY' (contentHeight 30 >
  height 28)`. That reads as one systemic layout rule, not 368 separate bugs: the label
  boxes do not grow with the user's text scale. 787 assertions in that same file pass.

  The other two:
  - `tst_gui_backdrop_contrast`: `dark/amber/orbs secondary pixel minimum=3.76:1, needs
    4.5:1` — a WCAG AA shortfall, the same class as the known white-on-orange CTA issue.
  - `tst_gui_shell_wallpaper_presets`: `the themed background differs from high-contrast`
    returned FALSE — the high-contrast preset is not actually distinct.

  Deliberately not "fixed" here. Every available shortcut — relaxing the clipping contract,
  lowering the 4.5:1 threshold, blacklisting the matrix cases — would disable the
  accessibility gates at the exact moment they started working. The real fixes are product
  decisions: how the tiles reflow at raised text scale, what `dark/amber/orbs` becomes to
  reach 4.5:1, and what the high-contrast preset should look like.

  **DIAGNOSIS CORRECTED 2026-08-02 — the clipping failures were not product defects, and
  neither the "systemic layout rule" above nor the "fontconfig hinting" theory from the
  font-stack fix (`541a9eb`) survives contact with the evidence.** They were a measurement
  race in the test itself. Three independent proofs:

  - **The failures are not stable.** Runs `9ab5ec7` and `d9ff376` are agent-framework
    commits that touch no file under `ui/`, `tests/gui/`, `assets/` or `ci.yml`, yet they
    disagree on **321 of the ~474 failing tags** (322 vs 305 failures, only 153 in common).
    No font metric and no layout rule can move half its failures between two runs of
    identical product code.
  - **The signature reproduces on demand.** `tst_gui_widget_legibility` drove 1152 rows
    through ONE harness and waited a flat `wait(32)` for each row's re-flow. Shortening
    that to `wait(0)` on a developer machine reproduces the CI failure signature exactly —
    487 failures, the same label strings, the same 2–4 px overflows — and restoring it
    clears them. QQuickLayout re-flows on the polish pass, so a Text still carrying the
    previous row's allocation while already reporting the new row's `contentHeight` reads
    exactly like a clipped label. 32 ms is enough on an idle workstation and not enough on
    a runner hosting four nested compositors.
  - **The font theories are disproved by measurement.** Ubuntu's `fonts-noto-core`
    `NotoSans-Regular.ttf` and this workstation's carry identical `hhea`/`OS/2` typo
    metrics (1069/−293 at 1000 upem), so the resolved face is the same on both sides. And
    installing Inter changes nothing, because `font.family` never selected it (below).

  Fixed in the tests, with no assertion relaxed: the matrix now waits for the re-flow to
  finish (signature unchanged across a presented frame, or no frame presented at all —
  both compositor-paced, so a slower machine waits longer instead of measuring earlier)
  and fails loudly if a row never settles. Negative control per the test-integrity rule
  above: `Layout.maximumHeight: 12` on the MetricGauge history caption makes the fixed gate
  report **96** genuine clipping failures, so the settle cannot mask a real defect.

  The other two entries were also mis-attributed:
  - `tst_gui_shell_wallpaper_presets::test_highcontrast_plain_gradient_grab` **never
    entered high-contrast.** QuickTest runs a TestCase's functions in ALPHABETICAL order,
    so it ran *before* `test_highcontrast_suppresses_backdrop`, and its "high-contrast"
    grab was whatever the previous test left on screen. It compared two frames of the same
    decorative theme and passed only when the animated backdrop had moved between them.
    Now enters high-contrast itself and waits for the backdrop to respond.
  - `tst_gui_shell_orient_settings::test_ori_b_landscape_grab_wider` asserted window
    geometry 120 ms after requesting a resize — a compositor round-trip timed with a
    stopwatch. Now polls the geometry.

  **CLOSED** (full local suite on Qt 6.11: 22 files, `pass=2641 fail=0`, SUCCESS; the two
  entries below are both resolved):
  - ~~**🔴 `tst_gui_backdrop_contrast`: the orbs backdrop draws HARD-EDGED RINGS on Qt 6.7.**~~
    `dark/amber/orbs secondary pixel minimum=3.76:1` on CI, **5.66:1** on this workstation,
    for the identical combination with motion already frozen. The saved frame (added for
    exactly this question, `gui-evidence/contrast-dark-amber-orbs.png`, PR #8 run
    30740217834) shows why: on CI the card carries three crisp circle OUTLINES, and those
    strokes are the pixels that fail. Where it renders correctly the same card is a smooth
    wash with no visible edge at all — which is why the passing minimum matches the `none`
    backdrop exactly.

    **It is the Qt version, not the renderer** — the first reading of this ("draws
    differently under CI's Mesa CPU rasteriser") was wrong, and the two-variable isolation
    says so plainly:

    | | real GPU | llvmpipe |
    |---|---|---|
    | **Qt 6.11.1** | 5.66:1 pass | pass |
    | **Qt 6.7.3** | 3.81:1 FAIL | 3.76:1 FAIL |

    **ROOT CAUSE + FIXED 2026-08-02.** It was never the gradient. `ShapePath.strokeColor`
    defaults to **white**, and Qt < 6.9 still rasterises a hairline for a zero-width
    stroke — so `strokeWidth: 0` alone left a white outline around every orb. Naming the
    stroke transparent removes it on every Qt version, and the same two lines were missing
    from all three `ShapePath` backdrops: `AnimatedBackground.qml` (orbs),
    `MeshGradientBackground.qml` (mesh) and `BokehBackground.qml` (bokeh). Verified on
    Qt 6.7.3 + llvmpipe — the whole 9251-combination matrix passes where it previously
    aborted at the first orbs entry — and still passes on 6.11.

    Owner decision the same day: **the supported Qt floor moves 6.5 → 6.9**, so neither
    this nor the SwipeView defect below can reach a supported user in the first place.
    `find_package(Qt6 6.9 REQUIRED …)`, the RPM `qt6-qtbase >= 6.9` requirement, both
    PKGBUILDs, the AppImage builder and every install/support doc now say 6.9, and CI
    pins **6.9.3** — the floor, deliberately, so CI keeps testing the oldest Qt the
    product claims to support. Costs nothing: Fedora 43 ships 6.10.3, Ubuntu 26.04 ships
    6.10.2, Arch is rolling, and Ubuntu 24.04 (6.4.2) was already excluded. The floor is
    enforced, not just documented: `find_package(Qt6 6.9 REQUIRED …)` against a 6.7.3 tree
    with no fallback path is rejected with "Could not find a configuration file for
    package Qt6 that is compatible", while the full project configures against 6.9.3.

    Note the hard technical minimum is still 6.5 (`QtQuick.Effects`); 6.9 is a *support*
    decision, and `docs/DISTRIBUTION.md` §1 states both so the number is not mistaken for
    a module requirement later.

    The measurement that got here, kept because it is the shape of this class of bug:

    | | real GPU | llvmpipe |
    |---|---|---|
    | **Qt 6.11.1** | 5.66:1 pass | pass |
    | **Qt 6.7.3** | 3.81:1 FAIL | 3.76:1 FAIL |

    Three follow-ups fell out of the matrix running to completion for the first time —
    it had always aborted within seconds at the first orbs entry, so its real cost had
    never been paid:

    - **It timed out CI, and took a bystander with it.** 9251 combinations × ~11k sampled
      pixels ran past the 540 s per-file bound, and because it then held a slot at full
      CPU on a four-core runner it dragged `tst_gui_w_cal_weather` from 62 s to a timeout
      as well. The measurement was doing four times the necessary work: it walked the
      image once per foreground, and recomputed the *foreground's* luminance for every
      pixel. One pass, both foregrounds, foreground luminance hoisted out — **186 s → 72 s**
      locally, and proven numerically identical (220 combinations across themes, accents
      and all 11 styles, exact `compare` of both minima against the old implementation).
    - A grab that comes back at the wrong size is retried against a presented frame (seen
      once in 9251 combinations under llvmpipe). Judging a frame that has not been
      presented says nothing about the product; the assertion itself is unchanged.
    - The failing frame is still saved to `gui-evidence/`, because that PNG is what turned
      this from "a contrast number is low" into "there is a white stroke here".

    Verified on a deliberately CI-shaped run — 4 cores (`taskset -c 0-3`), Qt 6.9.3,
    llvmpipe, `-j4`: 22 files, `pass=2641 fail=0`, RESULT: SUCCESS, no TIMEKILLs, slowest
    file 82 s.
  - ~~`tst_gui_shell_nav_edit`: 8 × `QML ListView: Binding loop detected for property
    "currentIndex"`~~ — **RESOLVED 2026-08-02: an upstream Qt < 6.9 defect, not ours.**
    The first guess (Qt's internal ListView fighting `Dashboard.qml`'s `_applyWant()` /
    `positionViewAtIndex`) was wrong, and so were two attempted product fixes — pinning
    the SwipeView's implicit size, and making the `PageIndicator` one-way — neither of
    which changed the count. Instrumenting `swipeView` showed the loops do not happen
    during the swipe at all: they land while `count` is collapsing and growing again
    (`3 → 1 → 2 …`, `currentIndex` passing through `-1`) as the test rebuilds its pages;
    QtTest merely attributes the warning to whichever function was running.

    Proved upstream by construction: a `SwipeView` holding four plain `Rectangle`s, with
    no product code anywhere near it, reproduces the warning on Qt 6.7.3 as soon as its
    `Repeater` count collapses and grows — and the identical file is clean on Qt 6.11.1.
    Upstream fixed it by routing `Container.content{Width,Height}` through
    `implicitContent{Width,Height}` (qtdeclarative, 2024-12-14, released in 6.9). Adding
    a page is not something this product can stop doing, and the loop lives inside a
    component we do not own.

    `scripts/check_qml_diagnostics.sh` now dispositions that exact line as external, and
    the disposition is **pinned to the versions that have the defect**: it is not
    installed on Qt ≥ 6.9, it only matches Qt's own `qrc:/qt-project.org/imports/…`
    copy of `SwipeView.qml`, and it does nothing at all if the log does not say which Qt
    produced it. All three limits are asserted in
    `scripts/check_release_gate_contract.sh`, so the suppression cannot outlive its cause
    or quietly widen. The warnings stay visible in the report (`known_external=8`) rather
    than being filtered out of existence.

    Reproduction recipe, since this class will recur — CI pins Qt 6.7.3 and this
    workstation runs 6.11: `aqt install-qt linux desktop 6.7.3 linux_gcc_64` into a
    scratch dir, configure a second build tree with `-DCMAKE_PREFIX_PATH=<that>`, build
    `xeneon-qmltestrunner`, then point the suite at it with `XENEON_TEST_BUILD_DIR` and
    the matching `LD_LIBRARY_PATH` / `QT_PLUGIN_PATH` / `QML2_IMPORT_PATH`. That turned a
    CI-only failure into a 70-second local loop; five attempts to reproduce it by making
    the machine slower had all come back clean, because it was never about speed.
  - `tst_gui_widget_legibility`: 1 × `There are still "2" items in the process of being
    created at engine destruction` — asynchronous creation still pending at teardown.

- ~~**The product's system font stack is inert — `font.family` never selects Inter.**~~
  **FIXED 2026-08-02.** `Theme.qml` declared `_fontDisplaySystem: "Inter, Segoe UI, Roboto,
  sans-serif"`. That reads like a CSS stack, but Qt does not split a comma-separated
  `font.family`: the whole string was matched as one family name, failed, and fell back to
  the machine's default sans. Measured with Inter installed — the exact package CI installs
  — "CPU" at `pixelSize: 20`:

  | `font.family` | contentWidth × contentHeight |
  |---|---|
  | `"Inter"` | 42.25 × 25 |
  | `"Inter, sans-serif"` | 39.33 × 28 |
  | `"Inter, Segoe UI, Roboto, sans-serif"` | 39.33 × 28 |
  | `"sans-serif"` | 39.33 × 28 |

  So no user had ever seen Inter, on any machine, whatever they had installed — and what
  they saw instead varied by distro. Same defect as `fontMono`, found the same way, fixed
  the same way: **Inter is now bundled** (OFL-1.1, no new licence identifier) and resolved
  through a `FontLoader` like the a11y and mono faces. Bundling rather than merely fixing
  the lookup is deliberate — a name list would still render differently on every machine
  that lacks Inter, which is most of them, and "system" here has always meant *the
  product's own look*, not *whatever this machine defaults to*.

  `tst_theme` now asserts the resolution rather than the spelling; comparing against the
  literal string passed happily while Qt rendered something else entirely.

  Full GUI suite green (22 files, `pass=2641 fail=0`) and the 50 reviewed visual baselines
  unchanged — expected, since the shipped default `fontChoice` is `hyperlegible`, so this
  changes what the *"system"* option renders, not the default look.
