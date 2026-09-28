# Backlog - Xeneon Edge Linux Hub

> **Note on Project Fork & Archive:**
> Historical backlog items, pre-v1.0.0 development notes, and legacy upstream decisions (prior to this fork) have been archived to [`docs/archive/BACKLOG_HISTORICAL.md`](file:///home/acero/src/skyphoenix-edgehub-linux/docs/archive/BACKLOG_HISTORICAL.md).
> This backlog tracks active development, upcoming releases, approved enhancements, and candidate ideas for the SkyPhoenix EdgeHub fork.

---

## Structure & Policies

Backlog items follow the framework's Scope Control Policy (`agent-framework/canonical/policies/scope-control-policy.md`):
- **Now**: Active release baking and immediate delivery items.
- **Next**: Approved work queued for the next point release (v1.1.2).
- **Later**: Approved strategic features for future milestones (v1.2+).
- **Candidates**: Unapproved ideas, community proposals, and exploratory features requiring product-owner approval.
- **Risks and debt**: Technical debt, deprecated upstream code, and test/platform maintenance.

---

## Now — v1.1.1 Release Finalization (Bake-in)

- [ ] **Bake-in of v1.1.1 Enhancements**:
  - Verify live stability across daily desktop sessions on the physical Xeneon Edge display (`DVI-I-1`, `2560x720`).
  - Implemented features under bake-in:
    - **Wake-on-LAN**: 3-packet burst transmission spaced by 25ms and realistic 60s boot phase timer with live countdown/feedback.
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
  - Example commands: `hyprctl dispatch workspace <N>`, `swaymsg workspace <N>`.
  - Configurable in widget actions / quick action macros with execution status feedback.
- [ ] **MediaWidget Artwork Load Error Handling**:
  - Handle cases where local `file://` album artwork fails to load (corrupt image, missing path, unsupported format) via `Image.status === Image.Error`.
  - Render an elegant fallback disc icon / "Artwork unavailable" plate rather than leaving an empty black rectangle.
- [ ] **Custom Screen Rotation Fine-tuning**:
  - Address any ergonomics or edge cases surfaced during the v1.1.1 bake-in period.

---

## Later — Future Milestones (v1.2+)

- [ ] **Home Assistant / Local IoT Control Widget**:
  - Dedicated first-party widget providing direct integration with local Home Assistant instances (REST API / WebSocket).
  - Displays live entity states: room temperature, humidity, air quality, power consumption.
  - Touch toggles for smart plugs, desk lighting, and scene presets.
- [ ] **Reactive 'Alert-Driven' Screen Surfacing**:
  - Dynamically alert or switch screens when noteworthy conditions occur:
    - Homelab node drops offline or exceeds resource alert thresholds (CPU, RAM, Disk).
    - Calendar event begins in $< 5$ minutes.
    - Countdown timer or break reminder expires.
  - Visual attention indicators: subtle pulse on the page indicator dots or a non-intrusive alert banner with tap-to-jump.
- [ ] **Routine Configuration Backup Safety Net (`config.toml.bak`)**:
  - Extend the existing backup mechanism (`backup_config_of()`) from `--reset` to standard UI saves, keeping a rolling `.bak` file before atomic overwrite.

---

## Candidates (Unapproved Ideas & Proposals)

*Ideas requiring product-owner approval before implementation:*

- **Generic Touch Macro & Webhook Deck**:
  - Configurable grid of quick-action buttons capable of firing arbitrary shell scripts, HTTP POST webhooks, or MQTT messages.
- **AUR Package Automation**:
  - Automated workflow to update the Arch Linux AUR `PKGBUILD` upon GitHub release tags.
- **Weather Widget Multi-Location Cycling**:
  - Allow configuring multiple cities/locations and cycling through them or tapping the header to switch.

---

## Risks and Debt

- **Legacy Upstream Licensing Code**:
  - The repository contains upstream references to commercial payment providers (Lemon Squeezy, Gumroad) and keygen tooling from before the fork.
  - Evaluate cleanly removing or deprecating unused commercial licensing scaffolding while preserving offline theme unlocks.
- **Dead Code Pruning**:
  - Remove dead `notificationBridge.send` fallback in `FocusWidget.qml`, `BreakWidget.qml`, and `MedsWidget.qml` (the `sendPriority` method is implemented by all bridges and doubles).
- **Mesa Driver / Zink Warning Logging**:
  - Monitor offscreen OpenGL/Zink fallback warnings in logs (`copy boxes detected`) on newer Mesa packages.
