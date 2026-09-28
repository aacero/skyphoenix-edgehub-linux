# Backlog - Xeneon Edge Linux Hub

> **Project Fork & History:**
> This repository was forked from upstream (`skyphoenix-it/XeneonEdge_Linux`) after v1.0.0.
> Historical pre-fork backlog notes (Simon Kreitmayer's pre-1.0.0 decisions, commercial payment provider stubs, and legacy test post-mortems) have been archived to [`docs/archive/BACKLOG_HISTORICAL.md`](file:///home/acero/src/skyphoenix-edgehub-linux/docs/archive/BACKLOG_HISTORICAL.md).

---

## Now — v1.1.1 Release Finalization (Bake-in)

- [ ] **Bake-in of v1.1.1 Enhancements**:
  - Verify live stability across daily desktop sessions on the physical Xeneon Edge display (`DVI-I-1`, `2560x720`).
  - Completed items under active bake-in:
    - **Wake-on-LAN**: 3-packet burst transmission spaced by 25ms and realistic 60s boot phase timer with live elapsed feedback (`core/src/wol.rs`, `ui/qml/widgets/SystemsWidget.qml`).
    - **Screen Rotation**: Arbitrary custom delay in seconds (0..86400) with dedicated stepper/input controls in Hub and Manager.
    - **Sky Tonight Widget**: Freshness timestamp, date header anchoring, active screen-revisit auto-refresh, and manual `↻` refresh button.
    - **Calendar Widget**: Geometry-adaptive views (List/Agenda for vertical, Month grid for square, 7-day Week for wide horizontal), extended 90-day horizon, interactive header view switcher, and clickable day expander drawer.
    - **Humble Bundle Widget**: Single-category filter toggle and "All" reset pills, plus top-tier bundle price resolution.
- [ ] **v1.1.1 Release Execution**:
  - Version bump to `1.1.1` in `CMakeLists.txt` and `core/Cargo.toml`.
  - Update `CHANGELOG.md` with release notes.
  - Tag release `v1.1.1` and build release artifacts.

---

## Next — v1.1.2 Scope

- [ ] **Tiling Window Manager / Workspace Targeting (`hyprctl` / `swaymsg`)**:
  - Support triggering workspace navigation or window focus on Wayland tiling window managers directly from touch macro tiles or widgets.
  - Commands: `hyprctl dispatch workspace <N>`, `swaymsg workspace <N>`.
  - Configurable in widget actions with tactile status feedback.
- [ ] **MediaWidget Artwork Load Error Handling**:
  - *(Inherited from upstream backlog finding)*: When local `file://` album artwork fails to load (corrupt image, missing path, unsupported format) or passes policy but cannot be rendered, QML leaves a blank black box.
  - Wire `Image.status === Image.Error` to display the default album disc fallback icon or "Artwork unavailable" plate.

---

## Later — Future Milestones (v1.2+)

- [ ] **Home Assistant / Local IoT Control Widget**:
  - Dedicated first-party widget providing direct integration with local Home Assistant instances (REST API / WebSocket).
  - Displays live entity states: room temperature, humidity, air quality, power consumption.
  - Touch toggles for smart plugs, desk lighting, and scene presets.
- [ ] **Routine Configuration Backup Safety Net (`config.toml.bak`)**:
  - *(Inherited from upstream backlog finding)*: Currently `--reset` makes a backup, but normal UI saves do not keep a rolling `.bak`.
  - Automatically write a rolling `config.toml.bak` on standard saves for easy rollback if manually edited or corrupted.

---

## Completed in Earlier Fork Iterations

- [x] **⚡ Quick Actions & Wake-on-LAN**: Configurable touch actions, fleet MAC targeting, 3-packet UDP burst, live boot phase timer.
- [x] **🚨 Reactive Alert-Driven Screen Surfacing**: Built into `Dashboard.qml` (`syncReactiveAlerts`, `evaluateAlertSurfacing`, `test_reactive_alerts_pause_and_surface`). Fleet offline events pause idle cycle and surface the alert.
- [x] **Continuous Widget Refinements**:
  - Moon widget: Centered layout with enlarged ~295px lunar disc and stacked info on 1x1 tiles.
  - The Sky Tonight: Responsive 2-column layout with hourly Sky Clarity bars and 5-planet ephemeris rows.
  - Systems widget: Full-screen `1x3` panoramic layout support across 2560px.
  - Orientation calibration: Synchronized landscape 2560x720 panel detection and rotation handling.
  - Calendar widget: Adaptive month/week/agenda views, 90-day horizon, day expanders.
  - Humble Bundle: Top-tier price detection and single-category toggle pills.

---

## Candidates & Technical Debt

- **Prune Upstream Commercial Licensing**:
  - The upstream codebase included Lemon Squeezy / Gumroad commercial payment stubs, webhooks, and key generation tooling.
  - Cleanly prune unused commercial payment files while keeping the offline local theme unlock system intact.
- **Dead Code Pruning**:
  - Remove dead `notificationBridge.send` fallback in `FocusWidget.qml`, `BreakWidget.qml`, and `MedsWidget.qml` (all bridges implement `sendPriority`).
- **Wallpaper / Theme Name Collision**:
  - `Theme.qml` and `WallpaperCatalog.qml` share 5 identical names (`aurora`, `ember`, `midnight`, `nebula`, `sunset`) where only 5 of 12 wallpapers match a theme. Decide if UI copy disambiguation is needed.
- **AUR Package Automation**:
  - Synchronize Arch Linux AUR `PKGBUILD` upon GitHub release tags.
