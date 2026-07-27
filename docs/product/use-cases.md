# Use Cases

**Version:** 0.1.0-draft
**Status:** Historical Phase-0 discovery draft - superseded
**Last Updated:** 2026-07-11

> **Historical document.** This captures early product intent and is not the
> current release contract. MVP labels and acceptance criteria below were written
> before implementation and feasibility review. See the authoritative
> [MVP scope and requirements disposition](mvp-scope.md) for what is required,
> deferred or still blocking the next release.

---

## UC-01: First-Run Setup and Display Selection

**Actor:** Any user (first launch)
**Priority:** Critical (P0)
**Precondition:** Application installed, at least two displays connected (one is Xeneon Edge).

### Main Flow
1. User launches the application for the first time.
2. Application detects all connected displays.
3. Application presents a first-run wizard showing each display with:
   - Name (e.g., "Corsair Xeneon Edge")
   - Manufacturer and model (from EDID)
   - Connector (e.g., "DP-1", "HDMI-1")
   - Physical size (if available from EDID)
   - Resolution (e.g., "2560×720")
   - Scale factor
   - Current orientation
   - Refresh rate
4. Application highlights displays matching the Xeneon Edge profile (2560×720 or 720×2560, Corsair EDID).
5. User selects the dashboard display.
6. User chooses starter layout (productivity, gaming, minimal, or blank).
7. User optionally enables autostart.
8. User optionally enables automatic reconnection after display plug/unplug.
9. Application stores display identity using EDID hash + connector fallback.
10. Application opens the dashboard on the selected display.

### Alternate Flows
- **A1: Only one display detected** - warn user, still allow selection, suggest connecting secondary display.
- **A2: No Xeneon-like display detected** - show all displays, let user manually select.
- **A3: User skips wizard** - open on primary display in windowed mode, show setup reminder.
- **A4: Touchscreen not detected** - warn that touch input may not work, proceed anyway.

### Acceptance Criteria
- Wizard is fully usable via touch.
- Display information is accurate and readable.
- Wizard can be reopened from settings.
- Selection persists across application restarts.

---

## UC-02: Dashboard in Landscape Orientation

**Actor:** Any user
**Priority:** Critical (P0)
**Precondition:** Dashboard display selected, display in landscape (2560×720).

### Main Flow
1. Application opens borderless fullscreen window on selected display.
2. Dashboard renders widgets in a responsive grid optimized for 2560×720.
3. Widgets are arranged left-to-right, utilizing the wide aspect ratio.
4. Touch input maps correctly to widget positions.
5. User can swipe between dashboard pages horizontally.
6. All widgets are readable from typical viewing distance.

### Acceptance Criteria
- Window is borderless and fills the entire display.
- No window decorations, taskbar entry, or pager entry.
- Widgets are not stretched or distorted.
- Touch targets are at minimum 48×48 logical pixels.
- Layout adapts if display resolution differs from 2560×720.

---

## UC-03: Dashboard in Portrait Orientation

**Actor:** Any user
**Priority:** Critical (P0)
**Precondition:** Dashboard display selected, display in portrait (720×2560).

### Main Flow
1. Application detects portrait orientation.
2. Dashboard renders widgets in a vertical-responsive grid optimized for 720×2560.
3. Widgets are arranged top-to-bottom.
4. Layout differs from landscape - not merely a rotated landscape layout.
5. Touch input maps correctly.
6. Swiping navigates between pages vertically.

### Acceptance Criteria
- Portrait layout is purpose-designed, not a rotation hack.
- Widget aspect ratios are appropriate for narrow vertical space.
- All interactions function identically to landscape mode.

---

## UC-04: Add, Move, Resize, and Configure Widgets (Edit Mode)

**Actor:** Any user
**Priority:** Critical (P0)
**Precondition:** Dashboard is running in view mode.

### Main Flow
1. User enters Edit mode (long-press on empty area or tap edit button).
2. Dashboard shows a grid overlay with widget boundaries.
3. User taps "Add Widget" to open widget catalog.
4. Widget catalog shows available widgets grouped by category.
5. User selects a widget; it appears on the dashboard at default size.
6. User drags widget to desired position; other widgets reflow.
7. User resizes widget by dragging corner/edge handles.
8. User taps widget settings icon to open configuration panel.
9. User configures widget (e.g., clock format, metric selection).
10. User exits Edit mode; dashboard returns to view mode.

### Alternate Flows
- **A1: Remove widget** - long-press widget in edit mode, tap remove.
- **A2: Duplicate widget** - long-press, tap duplicate.
- **A3: Undo/Redo** - available during edit session.
- **A4: Accidental action prevention** - widget actions (taps) are disabled in edit mode.

### Acceptance Criteria
- All edit operations work via touch.
- Drag-and-drop provides visual feedback.
- Resize respects minimum/maximum widget sizes.
- Undo/redo stack is maintained during edit session.
- Exiting edit mode discards undo stack.

---

## UC-05: Display Disconnection and Reconnection

**Actor:** Any user
**Priority:** Critical (P0)
**Precondition:** Dashboard running on selected display.

### Main Flow (Disconnect)
1. User physically disconnects the dashboard display (unplug cable, power off, etc.).
2. Application detects display removal.
3. Dashboard window is hidden/minimized.
4. Application shows a notification on the primary display: "Dashboard display disconnected. Waiting for reconnection..."
5. Application does NOT open the dashboard on the primary monitor.
6. Application begins polling for display reconnection (with backoff).

### Main Flow (Reconnect)
1. User reconnects the display (same physical port or different port).
2. Application detects display appearance.
3. Application matches display by EDID hash or user-assisted identification.
4. If match found: dashboard reopens on the display.
5. If no match: notification guides user to re-run display selection.

### Alternate Flows
- **A1: Same display, different connector** - match by EDID hash, reopen.
- **A2: Different display of same model** - prompt user to confirm or re-select.
- **A3: User dismisses notification** - application remains hidden until manually reopened.
- **A4: User explicitly opens on primary** - allowed only via settings override.

### Acceptance Criteria
- Dashboard never silently appears on primary monitor.
- Reconnection works within 5 seconds of display detection.
- Notification is non-intrusive.
- Application does not crash or leak during disconnect/reconnect cycles.

---

## UC-06: System Metrics Display

**Actor:** Alex, Marcus
**Priority:** High (P1)
**Precondition:** Dashboard running, system metrics widget added.

### Main Flow
1. User adds a CPU usage widget.
2. Widget displays current CPU utilization as a percentage and/or graph.
3. Data updates at a configurable interval (default: 2 seconds).
4. User taps widget to cycle through detail views (per-core, temperature, etc.).
5. Widget shows "N/A" when data source is unavailable (graceful degradation).

### Acceptance Criteria
- CPU, RAM, disk, and network metrics are available.
- GPU metrics (AMD, NVIDIA, Intel) are available where supported.
- Temperature sensors are read from hwmon/sysfs.
- Metrics update without blocking the UI thread.
- Polling does not cause unnecessary wakeups.
- Metrics gracefully degrade when sources are unavailable.

---

## UC-07: Focus Timer (Pomodoro)

**Actor:** Alex, Jordan
**Priority:** High (P1)
**Precondition:** Dashboard running, focus timer widget added.

### Main Flow
1. Widget displays a large, readable countdown/up timer.
2. User taps to start a focus session (default: 25 minutes).
3. Timer counts down with minimal visual animation (no distracting effects).
4. At session end, a gentle visual indicator appears (no aggressive alarm).
5. User can tap to start a break (default: 5 minutes).
6. Widget tracks sessions completed.

### Alternate Flows
- **A1: Configure duration** - tap settings to adjust focus/break durations.
- **A2: Pause** - tap timer to pause/resume.
- **A3: Skip** - tap skip to move to next phase.
- **A4: Reset** - long-press to reset session count.

### Acceptance Criteria
- Timer is accurate to within 1 second.
- Visual design is calm and non-distracting.
- Configurable durations persist across restarts.
- Session count is stored.

---

## UC-08: Media Controls via MPRIS

**Actor:** Alex, Taylor, Marcus
**Priority:** High (P1)
**Precondition:** Dashboard running, MPRIS-compatible media player active.

### Main Flow
1. Media widget detects active MPRIS player (e.g., Spotify, Firefox, VLC).
2. Widget displays:
   - Track title and artist
   - Album art (when available)
   - Playback progress bar
   - Play/Pause, Previous, Next buttons
3. User taps Play/Pause; command sent via D-Bus MPRIS.
4. User scrubs progress bar via drag.
5. Volume control available (via MPRIS or PipeWire).
6. When no player is active, widget shows "No media playing."

### Acceptance Criteria
- Works with Spotify, Firefox (YouTube), VLC, and other MPRIS players.
- Responds within 200ms of user interaction.
- Handles player connect/disconnect gracefully.
- Album art loads asynchronously without blocking UI.

---

## UC-09: Gaming Profile Auto-Switch

**Actor:** Marcus
**Priority:** Medium (P2)
**Precondition:** Gaming profile configured, game process names defined.

### Main Flow
1. Application monitors process list (configurable polling interval, default: 5s).
2. User-defined game process is detected (e.g., "cs2", "steam").
3. Application switches dashboard to gaming profile.
4. Gaming dashboard shows: GPU/CPU temps, FPS (if available), network latency, session timer.
5. Gaming dashboard uses minimal polling and rendering overhead.
6. Game process exits.
7. After a configurable delay (default: 10s), application restores previous dashboard.

### Acceptance Criteria
- Process monitoring uses minimal CPU.
- Dashboard switch is seamless (no flicker).
- Does not inject code into any game process.
- Does not bypass any anti-cheat system.
- User can disable process monitoring entirely.

---

## UC-10: Theme Configuration

**Actor:** Sam, Jordan
**Priority:** Medium (P2)
**Precondition:** Dashboard running.

### Main Flow
1. User opens Settings → Appearance.
2. User selects theme: Dark, Light, OLED Black, or High Contrast.
3. Dashboard and all widgets update immediately.
4. User selects accent color from palette or custom hex.
5. User toggles reduced motion.
6. Changes persist.

### Acceptance Criteria
- Theme change is instant (no restart required).
- All built-in widgets respect the theme.
- OLED Black uses true #000000 background.
- High Contrast meets WCAG AA minimum contrast ratios.
- Reduced motion disables all non-functional animations.

---

## UC-11: Multiple Dashboard Pages

**Actor:** All users
**Priority:** Medium (P2)
**Precondition:** Dashboard running.

### Main Flow
1. User enters Edit mode.
2. User adds a new dashboard page.
3. User names the page (e.g., "Work", "Gaming", "Entertainment").
4. User adds widgets to the page.
5. In View mode, user swipes horizontally (landscape) or vertically (portrait) to switch pages.
6. Page indicators show current page position.

### Acceptance Criteria
- Page switching is smooth and via swipe.
- Each page has independent widget layout.
- Page count is unlimited (practical limit: 20).
- Page state persists across restarts.

---

## UC-12: Application Launcher Widget

**Actor:** All users
**Priority:** Medium (P2)
**Precondition:** Dashboard running, launcher widget added.

### Main Flow
1. User adds application launcher widget.
2. User configures which applications to show (browse .desktop entries or manual path).
3. Widget displays application icons in a grid.
4. User taps an icon to launch the application.
5. Application launches on the primary display (not the dashboard).

### Acceptance Criteria
- Integrates with .desktop entry system.
- Custom commands require explicit user approval with warning.
- Launch failures show meaningful error.
- Icons load from system icon theme.

---

## UC-13: Settings and Diagnostics

**Actor:** All users
**Priority:** High (P1)
**Precondition:** Dashboard running.

### Main Flow
1. User opens Settings (from dashboard menu or primary window).
2. Settings are organized into categories: Display, Appearance, Dashboards, Widgets, Integrations, Input, Startup, Security, Performance, Diagnostics, Updates, About.
3. User can search within settings.
4. Diagnostics screen shows: version, build info, distribution, kernel, DE, session type, display list, touch devices, loaded widgets, integration status, recent errors, resource usage.
5. User can export diagnostics bundle (with secrets redacted).
6. User can launch `xeneon-edge-hub --safe-mode` for a recovery session. All
   first-party and user widget QML stays unloaded, while the dashboard shell,
   settings, diagnostics, and saved layout remain available.

### Acceptance Criteria
- Settings are navigable by touch.
- Search filters settings in real time.
- Diagnostics export is a zip file with JSON logs.
- Safe mode is session-only. It does not remove widgets, seed widget defaults,
  or persist a disabled layout; the next normal launch loads the saved widgets.

---

## UC-14: Widget Failure Handling

**Actor:** Any user
**Priority:** High (P1)
**Precondition:** Dashboard running, widget misbehaving.

### Main Flow
1. A widget exceeds its CPU time budget or crashes.
2. Application detects the failure via timeout or error boundary.
3. Widget is replaced with an error placeholder: "Widget encountered an error."
4. Placeholder offers: Restart Widget, Disable Widget, Reset Settings.
5. If a widget fails 3 times within 5 minutes, it is automatically disabled.
6. Notification is logged in diagnostics.

### Acceptance Criteria
- Widget failure does not crash the application.
- Main UI remains responsive during widget failure.
- Error placeholder is clear and actionable.
- Repeated-failure auto-disable works correctly.

---

## UC-15: Configuration Import/Export

**Actor:** Sam, Alex
**Priority:** Low (P3)
**Precondition:** Dashboard configured.

### Main Flow
1. User opens Settings → Dashboards → Export.
2. Application serializes all dashboard layouts, widget configurations, and settings.
3. User chooses save location.
4. File is saved as JSON or YAML.
5. On another installation, user imports the file.
6. Application validates and applies the configuration.
7. Incompatible settings are reported and skipped.

### Acceptance Criteria
- Export includes all user-configurable state.
- Import validates schema version.
- Import reports incompatible or unknown settings.
- Sensitive data (tokens, API keys) is excluded from export.

---

## Priority Summary

| ID | Use Case | Priority | MVP |
|----|----------|----------|-----|
| UC-01 | First-run setup & display selection | P0 | Yes |
| UC-02 | Landscape dashboard | P0 | Yes |
| UC-03 | Portrait dashboard | P0 | Yes |
| UC-04 | Widget add/move/resize/config | P0 | Yes |
| UC-05 | Display disconnect/reconnect | P0 | Yes |
| UC-06 | System metrics | P1 | Yes |
| UC-07 | Focus timer | P1 | Yes |
| UC-08 | Media controls (MPRIS) | P1 | Yes |
| UC-09 | Gaming profile auto-switch | P2 | No (v1.0) |
| UC-10 | Theme configuration | P2 | Yes |
| UC-11 | Multiple dashboard pages | P2 | Yes |
| UC-12 | Application launcher | P2 | Yes |
| UC-13 | Settings & diagnostics | P1 | Yes |
| UC-14 | Widget failure handling | P1 | Yes |
| UC-15 | Config import/export | P3 | No (v1.0) |
