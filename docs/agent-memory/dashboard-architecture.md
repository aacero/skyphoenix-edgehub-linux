---
name: dashboard-architecture
description: "How the rebuilt Xeneon dashboard is structured — registry, store, widget contract, persistence"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7a2d60a1-8c95-41e6-8b0e-230373ba9231
---

The dashboard was rebuilt (mid-2026) from hardcoded inline widgets into a
registry-driven, persistent, touch-editable system. Key pieces:

- **`ui/qml/DashboardStore.qml`** (Item, id `store`): single source of truth. Owns
  the `ui_state` JSON doc `{version, appearance, pages:[{name,tiles:[{id,type}]}], settings:{id:{...}}}`.
  Reactivity via `revision` counter (bump on every mutation). Structural changes clone
  `data` (`_commitStructure`); settings changes mutate in place (`_touchSettings`).
  Persists (debounced 400ms) through `configBridge.saveUiState(JSON)`.
  **EPHEMERAL keys (2026-07, commit 736ba9f):** `_ephemeralKeys` = `{hist,peakRx,peakTx}`
  are volatile per-session metric state (cpu/gpu/ram/net sparkline history + peaks).
  Metric widgets mirror them into the store every ~2s sample for compact↔expanded sharing.
  RULE: a write touching ONLY ephemeral keys bumps `revision` (live sparkline redraw) but
  passes `persist=false` to `_touchSettings` so it does NOT schedule a disk save; and
  `_persistableData()` STRIPS them before serializing. Without this the hub rewrote
  config.toml every 2s forever (flash wear on the appliance + a two-writer atomic-rename
  race with the Manager → intermittent "Failed to save config: No such file or directory").
  Do NOT add a metric widget that persists per-sample state through a non-ephemeral key.
  `_savePending` (alias of the save Timer's `running`) exists for test introspection.
- **`ui/qml/WidgetCatalog.qml`** (QtObject, id `catalog`): registry — each widget defined
  once as `{type,title,icon,category,source(qrc path),defaults}`. Drives grid, expanded
  overlay, and the edit-mode add-picker.
- **Widget contract** (each `ui/qml/widgets/*Widget.qml` root is a `WidgetChrome`): injected
  props `metrics, expanded, active, store, instanceId` (+ `tick`/`titleOverride` if declared).
  (Widgets read config via `cfg`/`settingsFor(id)` — the old injected `settings` prop was dead
  and was removed mid-2026; do NOT re-add it.) Icons are professional monochrome Phosphor SVGs
  in `assets/icons/<name>.svg` (bundled via `assets/icons.qrc`), rendered by
  `ui/qml/widgets/AppIcon.qml` (MultiEffect colorization) — `WidgetChrome.iconName` == widget
  `type`. The legacy emoji `icon` fallback path was removed; MultiEffect does NOT render under
  the offscreen platform, so icon tinting only shows on real hardware / a real GPU.
  `big: expanded`. Persistent widgets read reactively via
  `cfg: { store.revision; return JSON.parse(JSON.stringify(store.settingsFor(instanceId))) }`
  (clone-on-read is required or nested QML var changes don't propagate) and write via
  `store.setSetting(id,key,val)`. `active` is the single-driver flag (tile timers pause
  when an overlay is open).
- **Per-widget APPEARANCE contract (widgets-polish pass, 2026-07):** `WidgetChrome` exposes
  `accentName`/`cardBackdrop`/`titleOverride` (host-injected generically in `Dashboard.injectWidget`,
  ~Dashboard.qml:239-251) and readonly `effAccent` = `accentName ? theme.accentPresets[accentName].a
  : accentColor`. RULE: a widget's primary HIGHLIGHT content (rings, bars, big numbers, checkboxes,
  droplets, sparklines, field-focus borders, primary pill tints) MUST use `w.effAccent`, NOT hardcoded
  `theme.cat*`/`theme.accent` — else the config Accent picker only recolours the header icon/glow,
  breaking the "recolours highlights" promise ("no decorative toggles"). effAccent DEFAULTS to
  accentColor so default looks are unchanged. EXCEPTIONS (keep semantic colour): warn/error escalation
  (temp>warnTemp, disk critical), FocusWidget phase colours, download=success green. For Canvas content
  (AnalogClock hands, Net sparkline) also add `onEffAccentChanged: cv.requestPaint()` (a Canvas won't
  repaint on a colour-prop change alone). ADHD "dopamine" celebration pattern (Focus is the reference):
  a full-card `Rectangle{color:w.effAccent;opacity:0;z:5}` flashed via SequentialAnimation + a centered
  scale/fade `celebrateLabel` Text; reused in Tasks/Hydration/Habit/RightNow. Compact tiles must place
  only BOUNDED action targets (PillButton) — a full-tile MouseArea swallows host tap-to-expand (fixed in
  Tasks via `enabled: w.expanded` on the row MouseAreas).
- **`revision` vs `structureRevision` (hub-polish pass, 2026-07):** the store bumps
  `revision` on EVERY mutation (settings + structural), but ALSO bumps a separate
  `structureRevision` only in `_commitStructure`/`load`/`applyExternal` (structural
  changes: pages/tiles add/remove/move/resize, page rename/bg/cols). Dashboard's
  page+tile Repeater binds to `store.structureRevision`, NOT `revision` — otherwise a
  per-widget settings edit (which fires `_touchSettings`→`revision++` on every
  keystroke/toggle in the expanded config) tears down and rebuilds every tile Loader,
  destroying transient state + janking the device. Bind heavy structural Repeaters to
  structureRevision; cheap computed props (pageBg, cols, the bottom-bar page name) can
  still read `revision`/`structureRevision` as needed.
- **`Dashboard.qml`**: SwipeView of pages → responsive GridLayout of tiles; each tile is a
  SINGLE `Loader { anchors.fill: parent; source: catalog.source(wType) }` with `wId`/`wType`
  bound directly to `modelData` and `active: wId!=="" && wType!==""`. Bindings are injected in
  `onLoaded` via `dashboard.injectWidget(item,id,type,expanded)`. The expanded overlay uses its
  own identical single Loader with the same instanceId → shared state. Edit mode = move ◀▶ /
  remove / add-picker / add-remove page (the add-tile placeholder must be `visible: editMode`
  so GridLayout skips it and tiles fill the page).
  PITFALL (cost hours): do NOT nest Loaders (a Loader whose sourceComponent is another Loader).
  The inner item stays 0×0 and every widget renders invisible — with ZERO QML errors. Headless
  offscreen smoke will NOT catch this; only a real screenshot does. Always screenshot the Edge
  (`spectacle -f -b -n -o f.png` then `convert f.png -crop 720x2560+5120+2880 c.png`) to verify.
- **C++ `ConfigBridge`** (`app/src/main.cpp`, context prop `configBridge`): `uiState()`,
  `saveUiState()`, `starterLayout()`, `configJson()`. Backed by FFI
  `xeneon_config_get/set_ui_state`, `xeneon_config_get_starter_layout` in [[xeneon-ffi-conventions]].

**Orientation (hard-won, do NOT regress):** `main.qml` has `orientationMode` (persisted
appearance) = "auto" or a fixed value, and `contentRotation` (0/90/180/270) driving a rotating
`contentRoot`. "auto" MUST return rotation 0 and let the grid reflow to the real root aspect
(width vs height) — this trusts the compositor. Do NOT feed the raw `QScreen` orientation sensor
into QML to rotate content: it double-rotates on the real Edge to an upside-down UI. The C++
sensor-push pipeline (`sensorOrientation` property) was removed mid-2026 for exactly this reason.
If the compositor can't rotate a given mounting, the user picks a fixed mode in SettingsPanel.

**Why "auto" can't follow the sensor (hardware, confirmed 2026-07):** this Linux box exposes
NO orientation sensor — `/sys/bus/iio/devices/` is empty, `iio-sensor-proxy` is inactive/dead,
`qt6-sensors` isn't installed — so `QScreen::orientation()` never changes. The Edge (USB
`1b1c:1d0d`) only exposes a locked-down vendor HID node (`/dev/hidraw5`, root-only 0600).
True auto-rotate would require reverse-engineering Corsair's vendor HID orientation report off
hidraw5 (needs a root udev rule for read access; uncertain the Edge even emits orientation over
HID under Linux). HID AUTO-ROTATE SHIPPED & WORKING (2026-07, commit 9964e5f) — despite the earlier
"not achievable" reading below, a live `sudo cat /dev/hidraw5 | xxd` while rotating REVEALED
the sensor. The Edge pushes an unsolicited 64-byte report on the vendor pipe the instant the
panel turns: **report id `0x01`, header byte `0x11`, byte[7] = orientation** — `0x03` upright
portrait, `0x00` +90°CW, `0x02` -90°CW, `0x01` 180°. Calibrated on-device → content rotation
(CW deg) that keeps the UI upright: {0x03→0, 0x00→270, 0x01→180, 0x02→90} (the two landscapes
had to be swapped; portraits were right first try). Implemented in
`app/src/orientation_sensor.{h,cpp}`: finds the Edge hidraw by USB id (1b1c:1d0d) via
`/sys/class/hidraw/*/device/uevent`, watches it with a QSocketNotifier (event-driven, filters
buf[0]==0x01 && buf[1]==0x11, reads buf[7]), pushes the mapped rotation to QML root
`sensorRotation`; main.qml "auto" mode = `sensorRotation`. Needs the udev rule
`packaging/udev/99-xeneon-edge.rules` (GROUP="users", the login user's group here) — installed
it grants read access; without it auto-rotate stays off and manual modes are used. The rotation
transition is a shortest-path RotationAnimation + fade/scale dip; `Qt.inputMethod.hide()` +
`InputPanel.visible: active` on rotation stop the on-screen keyboard flashing mid-turn.

Widget-authoring FRAMEWORK (commit 4827784): `docs/widgets/authoring.md` is the guide;
`scripts/new-widget.sh <type> "<Title>" [Category]` scaffolds the QML + placeholder icon and
wires all three qrcs, printing the WidgetCatalog + WidgetConfigSchema snippets to paste.
`docs/DISTRIBUTION.md` covers build/install (sudo only for system-install + the udev rule),
packaging (AppImage/AUR/deb/rpm/Flatpak), MIT+Qt-LGPL licensing, and monetization. Project is
MIT (`LICENSE`); build+run needs NO sudo.

Superseded pre-discovery note (kept for context): the report DESCRIPTOR (32 bytes, readable at
`/sys/class/hidraw/hidraw5/device/report_descriptor`) exposes ONLY a single vendor-defined usage
page `0xFF1B` with one 63-byte in/out raw report ("Bragi"/Corsair Protocol V2 pipe) — NO standard
Sensors (0x20)/accelerometer/orientation usage at all. The most thorough public Linux RE
(github.com/aabdelghani/corsair-xeneon-edge-linux) decodes brightness/DDC-CI/screen-power/firmware
/touchscreen — and NO orientation/accelerometer. Strong evidence the Edge does NOT report
orientation over USB on Linux (auto-rotate is likely a Windows-iCUE-only feature or a manual iCUE
setting). Definitive confirmation would need root read of hidraw5 (0600 root:root — needs a udev
rule `KERNEL=="hidraw*", ATTRS{idVendor}=="1b1c", ATTRS{idProduct}=="1d0d", MODE="0660",
TAG+="uaccess"`) + capturing the 63-byte reports while PHYSICALLY rotating the panel — but the pipe
is command-response, so a passive read likely shows nothing even if a sensor existed. Conclusion:
true sensor auto-rotate is not achievable without cracking an unknown vendor query command; the
reliable answer is the manual orientation modes.

That was the queued "HID next" step per Simon's choice — manual modes shipped now.
The SettingsPanel/Manager labels are honest ("Auto" + a note that it follows the system only
when a sensor is present); the 4 fixed modes (Portrait/Landscape + flipped) rotate reliably.

Verify UI changes with: `QT_QPA_PLATFORM=offscreen ./build/xeneon-edge-hub --windowed` and
assert zero `qrc:/` diagnostic lines in stderr.
