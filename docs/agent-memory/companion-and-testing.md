---
name: companion-and-testing
description: "Xeneon Edge Manager companion app, hub control-socket IPC, and the QML GUI test harness"
metadata: 
  node_type: memory
  type: project
  originSessionId: 59076df8-2015-4bf2-9a34-fa4a0f7bc65f
---

Added mid-2026 (same effort that hardened the widgets):

- **Companion app `xeneon-edge-manager`** (`manager/`): standalone Qt6/QML desktop
  app to manage the hub — layout (pages/tiles: add/reorder/resize/remove via the
  add-picker), appearance (theme/accent/glass/glow/reduce-motion), image upload,
  and display/autostart. It **reuses** `DashboardStore.qml` + `WidgetCatalog.qml`
  (aliased into `manager/manager.qrc` under `qrc:/manager/`) by having C++
  `ManagerBackend` present the SAME surface the hub's `ConfigBridge` does
  (`uiState/saveUiState/starterLayout/configJson`), exposed as context prop
  `configBridge`. So every edit flows through the shared, already-tested store.
- **Live IPC**: hub runs `ControlServer` (`app/src/control_server.{h,cpp}`), a
  `QLocalServer` on socket `xeneon-edge-hub-ctl` (filesystem path `/tmp/xeneon-edge-hub-ctl`
  on this box), newline-delimited JSON (`getUiState`/`setUiState`/`ping`). Manager's
  `saveUiState` persists via the Rust config AND pushes `setUiState` over the socket.
  ⚠️ CRITICAL FOR TESTING: on the hub, `setUiState` **PERSISTS TO DISK** — C++
  `ConfigBridge::applyExternalUiState` (main.cpp) calls `xeneon_config_set_ui_state` +
  `xeneon_config_save` AND applies live via QML `DashboardStore.applyExternal` (which
  itself does not re-save, but the C++ already did). So pushing test values over the
  socket OVERWRITES the user's real `~/.config/xeneon-edge-hub/config.toml`. ALWAYS
  `getUiState` and save a backup JSON before poking settings via IPC, and restore
  after (preserve `pages`/`settings`; reset only the keys you changed). Needs `Qt6::Network`.
- **QML GUI test harness** (`tests/ui/`, run `./scripts/run_ui_tests.sh`, offscreen):
  `WidgetHarness.qml` loads a widget by file via a `Loader` **URL** (so it inherits
  the harness context and resolves `theme`/`store`/`media` by scope, exactly like
  Dashboard). `HarnessTheme.qml` mirrors main.qml's `_theme` tokens; `MockMedia.qml`
  stands in for the MPRIS bridge. GOTCHA: seed the store with `store.load("blank")`
  BEFORE the widget loads (gate the Loader on a flag) — the store's `data` is only a
  mutable JS object after `load()`; mutating the initial literal throws
  "Cannot assign to non-existent property". 250+ tests: per-widget smoke×boundary,
  logic, real mouse/key input, touch-target sizes. `qmltestrunner`/`qmllint` live in
  `/usr/lib/qt6/bin` (not on PATH).

Key widget fix (systemic): in `Dashboard.qml` the tile tap-to-expand `MouseArea`
(`tapMA`) is declared **before** the widget `Loader` so it sits UNDERNEATH it —
widget controls (small MouseAreas on top) handle their taps; inert areas fall
through to expand. Previously it was on top and swallowed every compact control.
Any widget with a FULL-tile compact MouseArea (e.g. old HydrationWidget) would trap
the expand gesture — use a bounded button instead. See [[dashboard-architecture]].

GOTCHA (hub-polish pass, cost a 164-test cascade): `qmllint --bare` AND even
`qmllint -I ui/qml -I ui/qml/widgets` do NOT catch an `on<Prop>Changed:` handler
for a property the object doesn't actually have (e.g. `onTintChanged:` on a Canvas
whose `tint` lives on the parent `Item` — "Cannot assign to non-existent property").
Only `qmltestrunner`'s `compile()` (i.e. real instantiation) surfaces it, as
"Type X unavailable" — and since WidgetChrome embeds a BackdropLayer, one broken
background type cascades to EVERY widget test failing to load (null `item`). ALWAYS
run `scripts/run_ui_tests.sh` after QML edits, not just qmllint. Related: a child
Rectangle that is NOT a delegate/component root can't reference its OWN `property`
from a child by BARE name ("sel is not defined") — give it an `id` and use `id.sel`
(delegate roots + the file root DO resolve bare names; plain intermediate objects don't).

REAL-EDGE E2E TESTING (2026-07, works headless as a bg agent, no sudo):
- **Display**: the Edge is DP-3, geometry from `kscreen-doctor -o` (was `4400,2880 720x2560`;
  the full compositor canvas is 5120×5440). Launch the hub normally (NOT --windowed) → it
  auto-detects "XENEON EDGE" and goes fullscreen on DP-3. Orientation sensor logs
  "watching /dev/hidraw5".
- **Screenshots of the LIVE panel**: `spectacle -b -n -f -o full.png` works non-interactively
  on this KWin/Wayland session (captures the whole 5120×5440 canvas, no portal prompt), then
  crop the Edge region `img.crop((4400,2880,5120,5440))` with PIL. (grim/`import` FAIL — no
  wlr, X-auth.) For a single static native render, the built-in `XENEON_GRAB` hook is cleaner.
- **Synthetic TOUCH without sudo/ydotool**: `/dev/uinput` is writable by simon via an ACL
  (`user:simon:rw-`, set by the openlinkhub/Corsair daemon — verify with `getfacl`). Create a
  pure-python uinput ABSOLUTE POINTER (INPUT_PROP_POINTER, ABS_X/ABS_Y range 0..65535, BTN_LEFT)
  — see `uinput_touch.py` (VPointer). Its 0..65535 range maps to the FULL canvas, so
  canvas(x,y)→abs = x/5120*65535, y/5440*65535; Edge-local (0..720,0..2560) = +4400,+2880.
  TWO CRITICAL gotchas: (1) input_event struct on 64-bit is 24 bytes — pack `'=qqHHi'` (NOT
  `'=llHHi'`; standard-mode 'l' is 4 bytes → EINVAL). (2) a single abs-jump+click does NOT
  register on Wayland — must SETTLE: move→sleep .2→move→sleep .2→BTN down→hold .14→up. With
  that, taps land pixel-accurate (verified: tapping the 4 Focus preset segments changed
  cfg.preset exactly, confirmed via IPC getUiState). Swipes = press+incremental moves+release.
- **VERIFY touch via IPC, not just screenshots**: drive the control socket (`getUiState`) to
  confirm a tap's effect on ui_state (e.g. preset/dailyGoal/running changes) — the strongest
  proof. Socket path: `/tmp/xeneon-edge-hub-ctl`. ALWAYS back up + restore config.toml around
  touch/IPC tests (setUiState persists to disk).
- **Measured baselines (real Edge, 2026-07)**: IPC getUiState p50 0.02ms / p99 0.08ms over 300
  round-trips, 0 fails; 25 concurrent conns all answered; 500 connect/disconnect cycles clean;
  worst-case CPU with ALL animations on = 3.5% (0.5% with reduceMotion); RSS ~378MB steady
  (plateaus — second-half growth negative over a 3-min soak, no leak); malformed/9MB-oversized/
  partial input all survived; 40-tap storm no crash. Clean SIGTERM/shutdown, exit 0.

HUB GRAB HOOK (added hub-polish pass): the hub now has `XENEON_GRAB=<path>` like the
Manager (Qt-internal `QQuickWindow::grabWindow` → PNG → quit; needs the REAL display
`DISPLAY=:0`, NOT offscreen which returns null; no X-auth/screenshot-tool needed —
`import`/`spectacle` FAIL here on Wayland X-auth). Optional `XENEON_GRAB_W`/`_H`
resize the window first so the 720×2560 portrait shell renders fully on a smaller dev
monitor (e.g. 394×1400). Combine with `XENEON_EXPAND=<type>` to grab the expanded
config overlay. Launch via `setsid env XENEON_GRAB=… DISPLAY=:0 ./build/xeneon-edge-hub
--windowed & disown` then poll for the PNG. Metrics now run on a worker thread and
MPRIS is fully async D-Bus (QDBusPendingCallWatcher) — neither blocks the GUI thread.

GOTCHA (cost a rebuild): the `qmltestrunner` suite loads widgets from the SOURCE
tree via `-I` import paths, so it does NOT catch a new widget file missing from
`ui/qml.qrc` — the real app loads from qrc and fails with "<Type> is not a type".
When adding any `ui/qml/widgets/*.qml`, add a `<file alias="qml/X.qml">` line to
`ui/qml.qrc` too (e.g. Sparkline/MetricGauge). Verify by actually launching the
built hub and grepping the log for "is not a type", not just by running the suite.

Fancy themes: `main.qml` `applyTheme()` now has vivid gradient modes
(midnight/aurora/sunset/nebula) using a 3-stop bg (`backgroundColor/2/3`); the
Dashboard bg renders the 3-stop gradient + an optional wallpaper Image (appearance
key `wallpaper`, a file path set from the Manager's Images tab) with a scrim.
Metric tiles (CPU/GPU/RAM/Disk) use `MetricGauge.qml` (ring + centred value +
`Sparkline.qml` history). Touch tokens bumped (primary 76/secondary 60/tertiary 52)
+ `iconLg/Md/Sm` glyph tokens; header icons and bottom-bar buttons enlarged.

Column count is now an OPTION: `appearance.gridCols` (global, default 1) with
per-page override `page.cols` (0 = use global); store setters `setPageColumns` /
`pageColumns`. Dashboard `pageItem.cols` = clamp(perPage||global, floor(width/300),
6). At 720px this allows 1 or 2 columns, so tile width (`w`, columnSpan) finally
matters. Pickers: on-device SettingsPanel ("Layout Columns"), Manager Appearance
(global default) + Layout tab (per-page). EdgeClone is a GridLayout (`columns:
clone.cols`); resize is a bottom-right ⤡ corner handle that previews via per-tile
`pvW`/`pvH` (no mid-drag reload) and commits `setTileSize(w,h)` on release; move is
hit-test `targetAt()` over the grid children, commit `moveTile` on drop.

Design-system unification + icons (P0 of the approved UI/UX plan): (1) ONE shared
`ui/qml/Theme.qml` (was duplicated in main.qml `_theme` + manager `AppTheme` +
tests `HarnessTheme`, all deleted/aliased). main.qml does `Theme{id:_theme}` +
`property alias theme/accentName/glassOpacity/showWidgetGlow/reduceMotion` onto it.
Namespaced test imports need `App.Theme` not `Theme`. (2) Professional icons: 44
Phosphor SVGs (MIT) fetched to `assets/icons/`, `currentColor`→`#FFFFFF` normalized,
bundled via `assets/icons.qrc` (prefix `/icons`, paths relative to `assets/`), on
BOTH targets; needs `Qt6::Svg`. `ui/qml/widgets/AppIcon.qml` renders `qrc:/icons/
<name>.svg` tinted with `QtQuick.Effects` MultiEffect (colorization; SVGs are white
so tint→any color; game-logo via `iconSource`+`tint:false`). SVG file names == widget
TYPE, so `AppIcon{name:type}` needs no catalog lookup. WidgetChrome has `iconName`
(renders AppIcon tinted `accentColor`, emoji `icon` as fallback); each widget sets
`iconName:"<type>"`. STILL TODO in P0-2: swap chrome/action/nav emoji (bottom bar,
edit overlay, expand ⤢, Manager nav + add-picker + config header) to AppIcon.

Orientation-aware layout (P0-3): C++ `main.cpp` connects `QScreen::orientationChanged`
(NO setOrientationUpdateMask — removed in Qt6) on the target screen → sets root
`sensorOrientation` (portrait/landscape/inverted-*); pushes initial only if
`orientation()!=PrimaryOrientation`. main.qml: `orientationMode` (appearance
`orientation`, "auto" follows sensor else fixed) → `effectiveOrientation` →
`contentRotation` (0/90/180/270). A `contentRoot` Item wraps StackView+InputPanel,
`rotation: contentRotation`, and SWAPS width/height when 90/270 so the dashboard
inside lays out for the effective aspect. Dashboard `cols`: landscape (width>height)
→ `min(floor(w/300),4)` to fill; portrait → user's gridCols. Controls in on-device
SettingsPanel + Manager Display tab (write appearance.orientation). On this dev
desktop the sensor reports PrimaryOrientation (no rotation), so "auto"=portrait;
verified the pipeline by forcing landscape (content rotates 90° + reflows). Persist
via the animatedBackground pattern (root prop + applyAppearance + Connections).

Per-widget config editor (SHARED, on-device + Manager; rebuilt late 2026): the schema
`ui/qml/WidgetConfigSchema.qml`, field renderer `ui/qml/ConfigField.qml`, and sectioned
scrollable form `ui/qml/widgets/WidgetConfigPanel.qml` all live in `ui/qml` and are used
by BOTH apps (manager.qrc aliases them to `../ui/qml/…`; ui/qml.qrc adds them for the hub).
ConfigField takes a `col` token object (keys: textPrimary/textSecondary/bg/accent/border/
panelAlt + optional `ctlH`/`fontBase` for touch sizing) so the SAME control renders in the
desktop Manager (`col: m`, ctlH 46) and the on-device touch view (Dashboard `cfgCol`, ctlH 58).
The HUB expanded view (`Dashboard.qml` overlay) is now a full-screen **live preview + config
panel** (GridLayout: portrait stacks, landscape side-by-side) — not a big sparse widget.
Field types: text/textarea/number-stepper/slider/toggle/segmented/date/hour/tasks/action/info;
fields may carry `help`; every widget gets a General (custom title) + About section.
⚠️ EVERY schema option MUST be honoured by its widget — no decorative toggles. Widgets read
live config via `readonly property var cfg: { var _=store?store.revision:0; return (store&&
instanceId)?store.settingsFor(instanceId):({}) }` + `readonly property` helpers with defaults
that MATCH the schema `dflt`. Metrics available are limited (cpu/gpu/ram/net-aggregate/disk-root
only — no per-interface, no arbitrary mount), so don't add options the Rust metrics can't back.
Universal "Custom title" via `WidgetChrome.titleOverride`. Weather has a geocode action; on the
hub `Dashboard.cfgAction("geocode")` calls the preview widget's `geocode()`.
QA hook: launch hub with `XENEON_EXPAND=<type>` to auto-open that widget's expanded config view
(mirrors the Manager's `XENEON_CFG`); context prop `_expandType` read in Dashboard.onCompleted. GOTCHA (cost ~an hour): a
delegate binding `store: store` where the delegate TYPE also has a `property var
store` SELF-BINDS to its own null property (name collision with the outer id), with
NO error logged — the control silently reads nothing. Fix: name the passed-in
property differently (used `st: store`). Watch for any `X: X` where X is both an
outer id and the component's own property.

WYSIWYG clone (`manager/qml/EdgeClone.qml`, in the Manager's Layout tab): renders
the REAL widgets of the current page in a device frame. The Edge is SINGLE-COLUMN
at 720px (`cols = floor(720/380) = 1`), so the clone is a vertical stack; drag =
reorder (whole-tile MouseArea, `preventStealing:true` so the Flickable doesn't
steal it → `store.moveTile` on drop), resize = ⇕ handle → `store.setTileSize` (h
1↔2). To render real widgets the Manager qrc aliases ALL widget + shared-component
files under `qrc:/manager/`; `EdgeClone.wsrc()` maps `catalog.source(type)`
("qrc:/qml/…") → "qrc:/manager/…". Manager provides `AppTheme{id:theme}` (full
theme copy, driven from store appearance via `syncTheme()` on `store.onChanged`)
and `MockMedia{id:media}`; live metrics via `backend.metricsJson()`
(`xeneon_metrics_collect`+`xeneon_metrics_to_json`, same JSON shape the hub uses)
polled every 2s. Widgets resolve `theme`/`media`/`store` because EdgeClone is
instantiated INLINE in Manager.qml (shares its scope) and the tile Loaders inherit
that context. Per-widget config form is still a stub popup (next pass).

Capture the Manager UI headlessly: `QT_QPA_PLATFORM=offscreen XENEON_GRAB=/path.png
XENEON_TAB=<0-3> ./build/xeneon-edge-manager` — C++ `QQuickWindow::grabWindow()`
renders + saves + quits (QML `grabToImage` did NOT fire in the headless/bg-job
context; the C++ grab is reliable). NB: offscreen shows only an 800x800 virtual
screen in the Display tab; real monitors appear when run on the actual display.
Also: `pgrep -c -f 'build/xeneon-edge-hub'` over-counts (matches the invoking
shell) — use `ps -eo pid,cmd | grep` to count app processes truthfully.
GOTCHA (widgets-polish pass): `XENEON_CFG=<type>` only auto-opens that widget's config
dialog if a tile of `<type>` is actually PLACED on some page (Manager.qml Timer scans
all pages for a matching tile; no match = silent no-op, stays on the Layout tab). Since
the Manager live-syncs the RUNNING hub's layout, you can only grab config dialogs for
widget types currently on the device — grabbing an unplaced type's dialog needs the hub
stopped + the type added first. The real-display grab needs `DISPLAY=:0` (offscreen
`grabWindow` returns null); launch with `setsid env … & disown` and poll for the PNG
(GUI launch via the Bash tool otherwise reaps as exit 144).
Background styles: `BackdropLayer.qml` (a Loader) selects among `AnimatedBackground`
(orbs), `WavesBackground`, `StarfieldBackground`, or none/gradient. Style resolves
PER PAGE: `page.bg.style` → global `appearance.bgStyle` (default "orbs"); wallpaper
likewise `page.bg.wallpaper` → `appearance.wallpaper`. Dashboard's `pageBg` binding
reads `swipeView.currentIndex` so the backdrop follows the current page. Store:
`setPageBackground(idx,key,val)` / `pageBackground(idx)`. Motion honours
`animatedBg` + reduceMotion (styles render static otherwise). Perf: Waves = a
Canvas drawn ONCE then GPU-translated (no per-frame repaint); Stars = static canvas
layers + a few opacity-twinkling dots. Pickers: on-device SettingsPanel (global) +
Manager (global default in Appearance, per-page in the Layout tab). NB SettingsPanel
is instantiated INLINE in Dashboard.qml, so it CAN reference the `store` id directly.

Visible backgrounds (late-2026 fix — "page backgrounds do nothing" was really occlusion):
cards are now FROSTED GLASS so the backdrop/wallpaper reads THROUGH them, not just in
the gaps. `Theme.cardFill()` = `cardBackground` at alpha `0.22 + (1-glassOpacity)*0.62`
(more glass ⇒ more transparent; opaque when `!decorative`, e.g. high-contrast); default
`glassOpacity` 0.6. Animated backdrops made more prominent (waves op ~0.3-0.42, orbs
strength up, ~2× stars). Bundled "standard" wallpapers: 7 PNGs in `assets/wallpapers/`
(720×2560, generated with ImageMagick `magick`), bundled via `assets/wallpapers.qrc`
(prefix `/wallpapers`) on BOTH targets, listed by `ui/qml/WallpaperCatalog.qml`
(`{name,label,source:"qrc:/wallpapers/X.png"}`). `appearance.wallpaper` (global) or
`page.bg.wallpaper` (per-page) accepts a `qrc:/…` or absolute path; Dashboard's
`wallpaperSource` prefixes only leading-`/` with `file://`. Wallpaper scrim dropped to
0.28 so images stay vivid. Pickers: hub SettingsPanel "Wallpaper" (None + swatches),
Manager Images tab ("Standard wallpapers" + uploaded), Manager Layout tab per-page.

Background SELECTION MODEL (fixed late-2026 — "animated styles don't show when selected"):
the real bug was that a wallpaper OCCLUDES the animated backdrop (`BackdropLayer.visible:
wallpaperSource===""`), so with a wallpaper set, picking Orbs/Waves/etc did nothing. Now a
background is ONE coherent choice — wallpaper OR animated style. (1) `Dashboard.pageBg` resolver:
a per-page override wins fully — `if pbg.wallpaper → wallpaper; elif pbg.style → {wallpaper:"",
style} (suppresses the GLOBAL wallpaper on that page); else inherit global`. (2) All style pickers
are mutually exclusive with wallpaper: tapping an animated style also clears the wallpaper at that
scope (`setAppearance("bgStyle",v); setAppearance("wallpaper","")`), and a style shows "active"
only when no wallpaper is set. Style list centralised in `ui/qml/BackgroundCatalog.qml` (shared by
both pickers + BackdropLayer's style→component map). EIGHT animated styles now: none(Gradient),
orbs, mesh, aurora, waves, stars, bokeh, grid — components in ui/qml/widgets/ (Mesh/Aurora/Bokeh/
GridBackground.qml, same `active`-gates-only-animation convention; Grid uses a capped 20fps Canvas
repaint, ~7% CPU). 12 bundled wallpapers. Also fixed: the empty-page hint (`Dashboard.qml`) now
gates on `pageItem.index === swipeView.currentIndex` — after a live `applyExternal` state-swap an
off-screen empty page's delegate could momentarily sit at x=0 and overlap the current page.

QML PROPERTY-NAME TRAP (cost a rebuild + a confusing debug — mid-2026): a `property`
whose name begins with `on` + an uppercase letter (e.g. `readonly property color
onAccent: "#0D1117"`) is parsed as a SIGNAL HANDLER, so QML fails to load the whole
component with "Cannot assign a value to a signal (expecting a script to be run)".
Worse, on `QT_QPA_PLATFORM=offscreen` the QML load error prints NOTHING to stderr
by default — the app just exits 1 silently. To surface it, run with
`QT_LOGGING_RULES='*=true'` and grep for "failed to load component". Never name a
property `on<Capital>…` (this one was renamed to `textOnAccent`).

MANAGER LIVE-SYNC OVERRIDES FILE EDITS (since the task-22 full-live-sync backend):
when the hub is RUNNING, the Manager pulls the hub's in-memory `getUiState` over the
control socket (on focus + periodic 4s timer) and adopts it, so editing
`~/.config/xeneon-edge-hub/config.toml` on disk and then launching a Manager grab
does NOT take effect — the Manager re-syncs to the hub's (unchanged) state. To
headless-grab the Manager against a specific config (e.g. to show a 2-column clone
or a tall-tile page), you must STOP the hub first so the Manager falls back to the
file. This is by design (it's the overwrite-race fix), not a bug.

MANAGER-ONLY STYLED CONTROLS: `Manager.qml` defines inline `component MButton`/
`component MSwitch` (accent-following, token-coloured, replacing default Fusion
Switch/Button + emoji glyphs). They MUST be inline components (not separate .qml
files) because they reference the `m`/`theme` ids, which are lexically scoped to
Manager.qml and invisible to a separate file. `resetSettings(id, defaults)` in
DashboardStore deep-clones defaults (was aliasing array/object defaults across
resets); the config dialog's geocode now aborts in-flight XHRs + has an 8s timeout.

Build note: `cmake` may be absent (install `sudo pacman -S cmake`). Without it you
can still: `cargo test` the core, run the QML suite, `qmllint`, and `g++
-fsyntax-only` the C++ (Qt inc dirs under `/usr/include/qt6/Qt*`; NB the Bash tool's
zsh does NOT word-split unquoted `$VAR` — pass g++ flags inline).

MANAGER UI/UX + ROBUSTNESS PASS (2026-07-13, later same day, all merged to master):
- **THE config bug**: `WidgetConfigPanel`'s store property was named `store`, and the
  call sites (`WidgetConfigDialog`, hub `Dashboard`) passed `store: store` → the RHS
  self-bound to the panel's OWN null property (the classic `X:X` trap — same one fixed
  earlier for ConfigField's `store`→`st`, but the PANEL was missed). Result: the ENTIRE
  per-widget config form (hub AND Manager) showed defaults + silently dropped edits.
  Fixed by renaming the panel prop to `st`. Gate: `tst_config_panel_wiring.qml`. Tests
  missed it because they passed the store under a different id (`cstore`), dodging the
  collision — WATCH for any `prop: id` where `prop`==an outer id AND the component's own.
- **Dark QPalette required**: both apps `QQuickStyle::setStyle("Fusion")` + a dark
  `QPalette` (`darkPalette()` in each main.cpp). WITHOUT the palette, every Qt Quick
  control not hand-restyled (config Switch/Slider/Button/ScrollBar/Dialog button-boxes)
  renders in Fusion's default LIGHT gray on the dark UI. The hub previously set NO style
  at all — now Fusion+palette (verified: config/wizard/diagnostics/dashboard all fine).
- **Single-instance guard**: `app/src/single_instance.h` (QLockFile via
  `xeneon::acquireSingleInstance("hub"|"manager", grabMode)`), used in both main()s.
  Multiple hubs/managers writing config.toml concurrently RACE and corrupt it (empty
  appearance / shuffled layout — seen live with 2 hubs + 3 managers up). Guard exits a
  2nd instance. **Skipped when XENEON_GRAB is set** so headless grabs run alongside a
  real instance (critical: my grabs all set XENEON_GRAB). The guard message uses
  fprintf(stderr) not qWarning — Qt's default handler routes to journald when stderr
  isn't a TTY (the manager has no qtLogBridge, unlike the hub).
- **Config preview scale**: the Manager config dialog's live preview injects
  `expanded=true` (720px-designed) into a ~340px pane → multi-button action rows clipped.
  Fixed by rendering at Edge width + `scale`-to-fit (EdgeClone approach) in
  WidgetConfigDialog. The hub's on-device preview already fits at 720px (left alone).
- **Themes 8→16, accents 8→14** (Theme.qml applyTheme + accentPresets). Registration:
  Theme.qml + Manager theme model + SettingsPanel model; LIGHT themes also need the
  label-color ternary in both pickers. ui_state is opaque so NO Rust/schema change.
- **Version in UI**: CMake `git describe --tags --always --dirty` → `-DXENEON_VERSION`
  compile-def → `appVersion()` on ConfigBridge/ManagerBackend → Manager nav + hub
  Diagnostics. PKGBUILD passes `-DXENEON_VERSION_OVERRIDE=$pkgver-$pkgrel`.
- **isolated GUI grabs**: to grab a config/theme without touching the user's live config
  OR display-stealing, use a temp `XDG_CONFIG_HOME` (+ hand-written config.toml with the
  desired ui_state/themeMode/tiles) AND a temp `XDG_RUNTIME_DIR` (so the manager can't
  connect to the user's running hub and adopt its state). `_normaliseDoc` is now a strict
  validator (drops non-object pages, non-string tile ids, coerces non-array pages/tiles).

95%-COVERAGE TEST PUSH (2026-07-13, working tree — NOT committed; plan+results in
`docs/DEV_AND_TEST_PLAN.md`): brought all three layers to ≥95%. **Rust** 63→110 tests,
96.44% line (`cargo llvm-cov --lib --summary-only`; config.rs the lone laggard at 93%).
**C++ went from ZERO tests to a QtTest harness** in `tests/cpp/` (13 ctest: unit+IPC-
integration+offscreen smoke), 97% filtered line via `gcovr` — enabled by EXTRACTING the
logic classes out of the `main.cpp` TUs into headers (`app/src/config_bridge.h`,
`display_match.*`, `autostart.*`, `metrics_worker.h`, `manager/src/manager_backend.h`,
`reconcile.*`, `path_sanitize.h`); `main.cpp` is now bootstrap-only, `#include "main.moc"`
dropped where no Q_OBJECT remains. C++ tests link the REAL `libxeneon_core.a` + temp
`XDG_CONFIG_HOME` (no fake core). `ManagerBackend` got an injectable clock
(`m_nowMs`/`setClockForTest`) so the 1500/900ms reconcile windows are testable without
waits; `reconcileOnPull(...)` is a pure free fn. **QML** 45→68 files; there is NO QML
line-coverage tool, so coverage = a BEHAVIOR MATRIX: `scripts/qml_coverage.py` enumerates
164 behaviors (`fn:Comp.name`/`schema:key`/`widget:type`/`bg:*`/`wallpaper:*`) and credits
a `// COVERS:` header only when the id's leaf token appears in a real assertion (has a
`--selftest`; 99.4%). Tooling installed WITHOUT sudo: `cargo-llvm-cov`+`llvm-tools-preview`
(via cargo/rustup), `gcovr` via **`uv tool install gcovr`** (pip/pip3 both absent on this
box — `uv` works). Runners: `scripts/run_all_tests.sh`, `scripts/coverage.sh`,
`scripts/run_cpp_tests.sh`. CI (`ci.yml`) trigger was on `main` while repo is `master` (so
it NEVER ran) — fixed to `[main, master]` + added qml-test/cpp-test/coverage jobs.
Bugs fixed this pass: S10 (added `get_reconnect`/`get_notify_disconnect` FFI getters + wired
disconnect behavior), two-writer save race (Manager IPC-only when hub connected), page-name
dedup in `_normaliseDoc`, S5 RAM/GPU history mirroring, XENEON_GRAB use-after-free, a
cross-module Rust test env-lock race (unified `TEST_ENV_LOCK` in lib.rs), a non-monotonic
CPU-counter overflow panic, the `-1.0`/NaN temp sentinel (None→NaN, real −1°C passes
through; C++ must check `isnan()`), and a #7 single-writer edit-loss heisenbug (a live edit
must clear the buffered offline `m_pendingPush` or the older edit wins after reconnect).
