# Test Strategy v2 - why we regress, and what to do about it

Status: Phase 0 APPROVED by Simon 2026-07-20 (CI on v1.0-alpha). Written at r230.

## CORRECTION (post-verification) - read this before acting on the tally

The 30/11/19 pinning tally below came from READING diffs and assertions, not
from reverting fixes and running the suite. A later verification pass using real
commands moved two verdicts, so treat the aggregates as directional only.

It also showed the diagnosis is **three problems, not one**:

- **Category A - absent pins.** Manager-opens-on-Edge (3x), wheel-scroll step
  (3x), glass border on light themes, resetConfirm binding loop. `screenIsEdge()`
  and `placeManagerOffEdge()` are `static` in `manager/src/main.cpp`, and
  `tests/cpp/CMakeLists.txt` pulls only `reconcile.cpp` + `manager_backend.h` -
  `main.cpp` is in no test target, so those symbols are **not linkable from a
  test at all**. CI would never have caught this. Needs Phase 2.7.
- **Category B - pins that cannot observe the failure.** Add-page snap-back is
  pinned in `tst_dashboard.qml` and regressed TWICE after the pin existed.
  qmltestrunner cannot load `main.qml`'s `qrc:` Dashboard, so the real stack is
  only reachable via `XENEON_QA_ADDPAGES`, and offscreen cannot reproduce the
  compositor timing. Needs the compositor tier, not more CI.
- **Category C - pins that work but never run.** The em-dash case. This is the
  only category Phase 0 closes.

Also corrected: the glass slider IS genuinely well pinned in the enforced suite
(`tst_manager.qml:764-788` asserts the handle does not move on a revision bump;
its comment states it bites on the old code). The claim that 5 PINNED verdicts
sat in the red suite was unverified and is at least partly wrong.

**Before Phase 3 acts on any individual line: revert the fix and run the suite.
That is the only thing that proves a pin bites.**

## The question

> "There are so many features already, but it seems we are regularly regressing
> on already 'good' features, by implementing new stuff, fixing other stuff, and
> then breaking stuff that was fixed dozens of versions ago."

## The answer: we do not have a coverage problem

Measured inventory of what already exists:

| Tier | Files | Test units | Assertions |
|---|---|---|---|
| Rust unit | 11 | 245 tests + 10 proptest properties | 697 |
| C++ ctest | 21 | 164 slots | 678 |
| QML offscreen `tests/ui` | 93 | 1797 fns | 5882 |
| QML compositor `tests/gui` | 20 | 739 fns | 2137 |
| Runtime E2E | 9 scripts | 9 scenarios | ~70 |
| Real hardware | 13 tests | ~110 check sites | - |
| Script guards | 9 | 9 invariants | - |
| **Total** | **176** | **~2955** | **~9464** |

Only 7 of 176 files are predominantly smoke-level. Assertion quality is high:
off-by-one boundary pairs, fractional-timezone arithmetic, pixel sampling to
prove arc geometry, non-overlap via `mapToItem`, exact rotation matrices.

**We have ~9,500 assertions. The problem is that a large fraction of them never
execute, and another fraction cannot fail.**

## Root causes, in order of damage

### RC1 - CI does not run on the branch we develop on

`.github/workflows/ci.yml` triggers on `master`/`main` only. `v1.0-alpha` is
**86 commits ahead of master** (master tip `c123212`, 2026-07-18).

The workflow's own comment concedes the risk:
> "If the alpha branch ever genuinely diverges again (it did once, and a real
> break hid there for 8 commits), re-add it - the lockstep is the precondition
> for this optimization."

The lockstep precondition is void. 31 of the last 62 fixes - 28 of them
user-visible - have had **zero CI runs**. Every recurring defect below sits
inside that window.

### RC2 - the suite that tests graphics is orphaned AND cannot fail AND is red

`tests/gui/` is 20 files, 739 test functions, 2137 assertions, driven under a
real `kwin_wayland` compositor at 2560x720 with real input and real pixels. It
holds the **only aspect-ratio assertions in the repo**.

Three independent defects:

1. **It cannot fail.** `run_gui_tests.sh` last line:
   ```sh
   [ "$TOTAL_FAIL" = 0 ] && [ -z "$FAILFILES" ] && echo "RESULT: SUCCESS" || echo "RESULT: FAILURE"
   ```
   `echo` always succeeds → prints `RESULT: FAILURE`, **exits 0**. Verified
   empirically. `run_one()` also ends `return 0`, swallowing per-file results.
2. **Nothing invokes it.** No reference in `scripts/` or `.github/`.
3. **It has never been green.** Its own baseline doc records pass=1356
   fail=210, with one segfault.

### RC3 - QML runtime errors are not failures anywhere

`QT_FATAL_WARNINGS` and `failOnWarning`: **zero occurrences in the repo.**
`run_ui_tests.sh` does not redirect stderr; QML warnings do not affect
`qmltestrunner`'s exit code. `tests/gui/validate_gui_file.sh:52` actively
filters out `conflicting anchors` and `Cannot open: qrc:`.

Demonstrated live this session: the `BackgroundPicker` self-binding bug threw
`TypeError: Cannot call method 'setAppearance' of undefined` on every
interaction and shipped. After fixing it I left a dangling `if (!store)`
reference - and `tst_background_picker` (5/5), `tst_hub_config_surfaces`
(16/16) and `tst_settings_panel` (16/16) returned **identical results with and
without the bug present**.

### RC4 - Manager and hub are never compared to each other

`Dashboard.sizeClassFor(size, landscape)` vs `EdgeClone.sizeClassFor(size)` -
a copy-paste duplicate hardcoding `halfUnits(size, false)`, i.e. portrait
always. `halfUnits` swaps w/h on that flag, so in landscape the hub returns
`wide` and the Manager returns `tall`: a different layout variant with
different information density. Exactly the reported symptom.

`tests/ui/tst_edgeclone.qml:157` "verifies" this by comparing to the **string
literal** `"large"` - never calling the hub's function. The two can diverge
arbitrarily and stay green. They have.

### RC5 - component tests call APIs instead of clicking controls

`tst_background_picker.qml` calls `gp.pickStyle("waves")` directly and supplies
its own correctly-bound store, so a mis-binding at the hub's real call site is
structurally unreachable. Only **19 of 93** `tests/ui/` files perform a real
`mouseClick`/`mouseDrag`; ~20 load a real composed screen.

### RC6 - silent skips

`tst_smoke_hub` / `tst_smoke_manager` `QSKIP` unless built with
`-DXENEON_QA_HOOKS=ON`. On a default build `ctest` reports 21/21 green having
never launched either binary. Runtime E2E, `check_appimage_update_contract.sh`
and `check_tree_walks.py` (which guards the 18.8 GB OOM that killed the IDE)
run only in `run_all_tests.sh`, never in CI.

### RC7 - no golden images; pixel assertions are extremely lossy

No `perceptualdiff` / `pixelmatch` / `ssim` / ImageMagick `compare` anywhere.
`widget_render_matrix.py` reduces a frame to a 32x32 grid; `e2e_harness.py:335`
reduces an entire frame to a **1x1 average pixel**; `GuiUtil.looksRendered`
samples 16 pixels. These detect "blank" and "colour changed". They cannot
detect wrong aspect, wrong position, overflow, truncation, or a missing preview
inside an otherwise-populated frame. `gui-evidence/` is `rm -rf`'d each run and
git-tracks nothing.

## Proven regressions - same symptom fixed repeatedly

All inside the un-CI'd window.

| # | Symptom | Commits | Times |
|---|---|---|---:|
| 1 | Widget sized by mode, not by room | `92a3d2e`→`e4db92b`→`b7ef100`→`67052c6`→`c1c323a` | 5 |
| 2 | Gate that runs but checks nothing | `69a0484`→`92490f9`→`8b09f9e`→`93bfd85` | 4 |
| 3 | Add-page snap-back to screen 1 | `e204aef`→`77f0fb8`→`93d5294` | 3 |
| 4 | Manager opens on the Edge, not main screen | `484bac1`→`80f4dac`→`f8b478a` | 3 |
| 5 | Mouse wheel scrolls ~10px/notch | `eb3e7c6`→`fede158`→`200b94e` | 3 |
| 6 | Manager scroll lag (continuous repaint) | `8f2737f`→`239dd27`→`a2da674` | 3 |
| 7 | Orientation wrong at startup | `dc89189`→`09828de`→`e09c7a2` | 3 |
| 8 | Landscape preview cut off / wrong size | `b099c7e`→`626f345` | 2 |
| 9 | Glass slider unusable | `f634d49`→`1ff58c7` | 2 |
| 10 | resetConfirm binding loop | `c933264`→`34af80b` | 2 |
| 11 | Tiles teleport on reorder | `6647490`→`43f55eb` | 2 |
| 12 | Gauge centre reading | `18c927f`→`935afcf` | 2 |
| 13 | Em-dash quote separator | broken `e4fd7d2` → restored `cb09d59` | 2 |

Two are self-documented as self-inflicted (`935afcf`: "regression from the
overflow fix"; `cb09d59` names `e4fd7d2`).

**#13 is the proof of RC1/RC2.** `tst_gen_quote.qml::test_emdash_separator`
already existed and asserted exactly the broken behaviour, in the *enforced*
suite, added long before. The break still shipped - because nothing ran it on
this branch. It surfaced only when someone ran the suite manually, much later.

Fix concentration: `Manager.qml` 19 fixes, `Dashboard.qml` 19, `EdgeClone.qml` 10.

Pinning verdict over 60 audited fixes: **30 PINNED, 11 WEAK, 19 UNPINNED** -
but 5 of the PINNED are pinned in the red, unexecuted `tests/gui/`, so
effective enforced pinning is **25 of 60**.

## The plan

### Phase 0 - make the existing 9,464 assertions able to fail (~half a day)

Highest leverage in the project. No new tests.

0.1 Enable CI on `v1.0-alpha` (or merge to master and keep lockstep honest).
0.2 Fix `run_gui_tests.sh` exit code; propagate `rc` from `run_one`.
0.3 Wire `tests/gui/` into `run_all_tests.sh` and CI.
0.4 `QT_FATAL_WARNINGS=1` (or a stderr deny-list: `TypeError`, `ReferenceError`,
    `is not a function`, `Unable to assign`, `Binding loop detected`,
    `Cannot open: qrc:`) across every runner. Stop filtering real warnings in
    `validate_gui_file.sh`.
0.5 Make `-DXENEON_QA_HOOKS=ON` the default for test builds, or fail loudly
    when the smoke tests skip.
0.6 Wire runtime E2E, `check_appimage_update_contract.sh` and
    `check_tree_walks.py` into CI.
0.7 Add `timeout-minutes:` to every CI job.

**Exit criterion:** a deliberately reverted fix turns CI red.

### Phase 1 - drive `tests/gui/` green (~1-2 days)

~210 failures. Triage each into: real bug / stale test / intentionally-failing
documentation. Several `tst_gen_*` headers and
`tests/hardware/manager_reflection_test.py` are written to fail on purpose -
these must be converted to `expectFail` so red means red.

**This is where the real bug list comes from**, including #5, #6 and #8 above,
which already have correct pins sitting unexecuted.

### Phase 2 - close the detection gaps (~2-3 days)

2.1 **Differential Manager↔hub.** Delete `EdgeClone.sizeClassFor`; call the
    hub's with a real orientation. Add a cross-product test over
    type x size x orientation asserting the two agree. *(Fixes the reported
    WYSIWYG bug at the source.)*
2.2 **Golden images.** Commit per-widget/per-screen baselines; diff with SSIM
    or bounded per-pixel tolerance; `--update-baselines` path. Retire the 1x1
    average-pixel metric.
2.3 **Animation as motion.** `grabImage()` twice ~200 ms apart; assert frames
    differ when `animatedBg` is on and are identical when off.
2.4 **Capacity on the push path.** `store.applyExternal` performs no capacity
    check, while `Dashboard.qml:1033` sets `interactive: longExtent > longHalves`
    - so an over-capacity page silently becomes scrollable. Re-validate in
    `applyExternal`; assert `interactive === false` after every resize on every
    path, and that no page-N+1 tile maps into page N's viewport.
    *(Candidate mechanism for both resize bugs - needs on-device confirmation.)*
2.5 **Screen-composed geometry invariant.** One pass over `GuiUtil.eachItem`
    asserting bounds containment and no unintended sibling overlap, run after
    every state change.
2.6 **Real input at real call sites.** Make `tst_hub_config_surfaces.qml` the
    template: one real-input test per interactive control, inside its real
    containing screen.
2.7 Extract `isEdgeScreen()` from `manager/src/main.cpp` into `display_match.h`
    - it is file-static, so regression #4 is not even linkable from `tests/cpp`.
    That is why it recurred three times.

### Phase 3 - pin what is unpinned (~1-2 days)

19 UNPINNED + 11 WEAK, prioritised by the 13 proven regressions. Use the
size/mode cluster as the template: paired tests that hold the mode fixed while
moving the box and vice versa, asserting rendered `font.pixelSize` rather than
the feeding property - a re-frozen literal cannot pass both.

Method note: verdicts came from reading diffs and assertions, not from
reverting. **Revert-and-run confirmation before acting on any individual line.**

### Phase 4 - the full run

Only meaningful after Phase 0. Estimated wall clock:

| Tier | Estimate | Source |
|---|---|---|
| Guards | seconds | ordered first deliberately |
| Rust | ~1 min | - |
| C++ ctest | <1 min | slowest ~3 s |
| Runtime E2E | ~2.5 min | summed `timeout` windows |
| QML offscreen (93 files) | ~20-40 min | `-j8` |
| QML compositor `tests/gui` | ~30 min at `-j8` | script comment: "hours" sequentially |
| Hardware (device-gated) | ~30-60 min | 7 suites, real Edge |
| Golden-image pass (new) | ~15 min | - |
| **Total** | **~2-3 h** | |

3-4 hours is the right order of magnitude once Phase 2 lands.

## The honest recommendation

Running a 4-hour suite **today** would mostly re-run assertions that already
pass. The bugs are sitting behind gates that do not execute: a suite that exits
0 regardless, a branch CI ignores, and runtime errors nobody listens for.

Phase 0 is roughly half a day and will surface more real defects than any
amount of new test writing. Do it first.

---

## Appendix A - the coverage denominator

Read from source registries, not docs. This is what "EVERYTHING" means.

| Surface | Count |
|---|---:|
| Widget types | 30 (6 categories) |
| Legal sizes | 7 (`0.5x0.5` … `1x3`); per-type lists vary (2–7) |
| Legal type x size combinations | ~145 |
| **x 2 orientations** | **~290** - the same size is a different aspect per rotation |
| Config field types | 12 (`text`…`accent`); `action` implemented once (weather geocode, 8 statuses) |
| Universal per-widget options | title, accent, cardBackdrop (8 of 11 styles), reset |
| Screen/page operations | 7 (add, remove, rename, columns, per-page bg, preset-append, reset) |
| Presets | 19 (catalog); PresetPicker comment still says 15 |
| Themes | 29 (19 free, 9 Pro, 1 accessibility) |
| Accents | 22 exposed (14 house + 8 Okabe–Ito); 29 defined |
| Background styles | 11 (10 animated + gradient) |
| Bundled wallpapers | 18 (+ user imports, Manager only) |
| Effect knobs | 4 (glass, glow, animatedBg, reduceMotion) |
| Motion tokens collapsing under reduce-motion | 7 |
| Manager tabs / dialogs | 5 / 9 |
| Hub panels+overlays | 8 |
| SettingsPanel tap targets | ~65 across 8 sections |
| Wizard steps | 4 |
| Diagnostics tabs | 5 |
| Orientation modes | 5 (+4 valid sensor bytes +1 invalid) |
| IPC message types | 8 client->server, 4 server->client |
| CLI flags | hub 7, Manager 2 |
| Config schema | 8 top-level fields, 4 sections |
| Persisted appearance keys | 12 |

## Appendix B - findings from the denominator sweep

### B1. Pro gating is bypassable (matters - this is the paid boundary)

Gated features are **exactly 9 themes and nothing else**. Enforcement is
QML-only at **two points** (`SettingsPanel.qml:203`, `Manager.qml:406`).
Writing `themeMode: "synthwave"` directly into `ui_state` bypasses both.
Presets, user widgets, backgrounds, wallpapers, accents and widget types are
all ungated. Needs a decision before launch, and a test either way.

### B2. Seven shipped-but-unreachable features

No UI control exists for any of these; several are tested and fully working:
`fontChoice` (2 bundled a11y fonts, default silently `hyperlegible`),
`textScale` (0.8–1.6, every font token derives from it),
`reduceMotionPreference` (the documented "explicit beats OS" precedence cannot
be expressed), `enableUserWidgets` (the whole Tier-0 subsystem), `netOffline`
(the global egress kill switch), 7 accent presets with no swatch, and
`applyPreset()` (implemented, zero call sites).

Three of these are **accessibility** features - a11y that ships switched off
and unreachable is worse than not shipping it.

### B3. Hub<->Manager asymmetries

Rename page, page columns, per-page background, image import and layout reset
are **Manager-only**. The wizard tells the user they can "choose a display
later from Settings" - the hub has no display picker. Remove-widget confirms
nowhere; remove-page confirms in the Manager but not the hub. `cardBackdrop`
offers 8 of 11 styles.

### B4. The test-seam gap that makes GUI tests brittle

`objectName` coverage is near zero. Named: `managerTabs, scopePill,
themeDropdownField, presetMini, screensEmpty, resetLayoutBtn, addPickerTarget,
imagesModel, scopeTag, closeBtn, previewClip, previewScaler, cfgScroll,
field-<key>, pageSwipe, screensEntry, presetPickerClose, presetCard-<id>,
presetConfirmBar/Cancel/Apply`.

**Everything else** - all of Diagnostics, all of FirstRunWizard, every
SettingsPanel control, every Dashboard bar button, and all of EdgeClone
(which has *no* objectNames at all) - must be reached by structural traversal.
That is why GUI tests break whenever layout changes, and it is a prerequisite
for Phase 2. **Add to Phase 0.8: name every interactive control.**

### B5. Stale/incorrect

`PresetPicker.qml` header says 15 presets (actual 19).
`SettingsPanel.qml:255` says Auto follows "the system" (actual: the Edge's
vendor HID sensor, falling back to aspect ratio).
`orientation.state` survives `--reset` and restores a stale rotation.
`likelyXeneonEdge` (loose 4-way OR) disagrees with `findTargetScreenStrict`
(5-step cascade) - a Corsair non-Edge monitor is highlighted in the wizard but
can never be auto-selected.
Manager has no `--help` and silently swallows unknown args.

### B6. Hidden QA hooks compiled into shipped QML

`XENEON_EXPAND, XENEON_QA_ADDPAGES, XENEON_CFG, XENEON_TAB, XENEON_GRAB`
(+`_W`/`_H`, which **bypasses the single-instance guard**). Plus Ctrl+D,
Ctrl+Q (quits with no confirm) and F11 - undiscoverable on a touchscreen.
Decide before GA: keep behind a build flag, or accept as shipped.
