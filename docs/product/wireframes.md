# Wireframe Descriptions - Xeneon Edge Linux Hub

**Version:** 0.1.0-draft
**Status:** Historical Phase-0 discovery draft - superseded
**Last Updated:** 2026-07-11

> **Historical document.** These sketches preserve early interaction intent; they
> do not describe the current UI pixel-for-pixel and are not a release checklist.
> See the authoritative [MVP scope and requirements disposition](mvp-scope.md).

> **Note:** These are textual wireframe descriptions. Visual mockups will be created in a design tool (Figma/Penpot) during Phase 0 design sprint. The descriptions below define layout, hierarchy, and interaction intent for the designer.

---

## 1. First-Run Wizard

**Purpose:** Guide new users through display selection and initial setup.

### Screen 1: Welcome
```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│                    [App Icon - Large]                     │
│                                                          │
│              Welcome to Xeneon Edge Linux Hub            │
│                                                          │
│          Set up your secondary touchscreen dashboard     │
│                                                          │
│                                                          │
│                     [  Get Started  ]                     │
│                                                          │
│           (Large touch-friendly button, 320×64)           │
└──────────────────────────────────────────────────────────┘
```

### Screen 2: Display Selection (Landscape: 2560×720)
```
┌──────────────────────────────────────────────────────────┐
│  Select Your Dashboard Display                           │
│                                                          │
│  ┌─────────────────────┐  ┌─────────────────────┐       │
│  │                     │  │                     │       │
│  │   [Display 1]       │  │   [Display 2]  ⭐    │       │
│  │   DELL U2723QE      │  │   Corsair Xeneon    │       │
│  │   3840×2160         │  │   2560×720          │       │
│  │   DP-1 (Primary)    │  │   DP-2 ← Detected!  │       │
│  │                     │  │                     │       │
│  │   [Select]          │  │   [✓ Selected]      │       │
│  └─────────────────────┘  └─────────────────────┘       │
│                                                          │
│  ┌─────────────────────┐                                │
│  │   [Display 3]       │                                │
│  │   ASUS VG27A        │                                │
│  │   2560×1440         │                                │
│  │   HDMI-1            │                                │
│  │   [Select]          │                                │
│  └─────────────────────┘                                │
│                                                          │
│  [?] Identify Displays (shows numbers on each screen)    │
│                                                          │
│  [Back]                              [Next: Layout →]    │
└──────────────────────────────────────────────────────────┘
```

### Screen 2b: Display Selection (Portrait: 720×2560)
```
┌──────────────┐
│ Select Your  │
│ Dashboard    │
│ Display      │
│              │
│ ┌──────────┐ │
│ │ Display 1│ │
│ │ DELL     │ │
│ │ 3840×2160│ │
│ │ DP-1     │ │
│ │ [Select] │ │
│ └──────────┘ │
│              │
│ ┌──────────┐ │
│ │ Display 2│ │
│ │ Corsair ⭐│ │
│ │ 720×2560 │ │
│ │ DP-2     │ │
│ │ [✓ Sel.] │ │
│ └──────────┘ │
│              │
│ ┌──────────┐ │
│ │ Display 3│ │
│ │ ASUS     │ │
│ │ 2560×1440│ │
│ │ HDMI-1   │ │
│ │ [Select] │ │
│ └──────────┘ │
│              │
│ [Back]       │
│ [Next →]     │
└──────────────┘
```

### Screen 3: Starter Layout
```
┌──────────────────────────────────────────────────────────┐
│  Choose a Starter Layout                                 │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ Productivity │  │   Gaming     │  │   Minimal    │   │
│  │              │  │              │  │              │   │
│  │ [clock]      │  │ [CPU temp]   │  │ [clock]      │   │
│  │ [CPU][RAM]   │  │ [GPU temp]   │  │              │   │
│  │ [focus timer]│  │ [FPS][RAM]   │  │              │   │
│  │ [goals]      │  │ [media]      │  │              │   │
│  │ [media]      │  │              │  │              │   │
│  │              │  │              │  │              │   │
│  │  [Select]    │  │  [Select]    │  │  [Select]    │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
│                                                          │
│  Or start with a blank dashboard:                        │
│  [  Start Blank  ]                                       │
│                                                          │
│  [Back]                              [Next: Options →]    │
└──────────────────────────────────────────────────────────┘
```

### Screen 4: Options
```
┌──────────────────────────────────────────────────────────┐
│  Almost Done!                                            │
│                                                          │
│  [✓] Start automatically when I log in                   │
│      (Adds to autostart)                                 │
│                                                          │
│  [✓] Reopen dashboard when display is reconnected        │
│      (Recommended)                                       │
│                                                          │
│  [✓] Show notification when display is disconnected      │
│                                                          │
│  Theme:  [● Dark]  [○ Light]  [○ OLED Black]            │
│                                                          │
│  You can change all of these later in Settings.          │
│                                                          │
│  [Back]                              [  Finish Setup  ]   │
└──────────────────────────────────────────────────────────┘
```

---

## 2. Dashboard - View Mode (Landscape: 2560×720)

```
┌──────────────────────────────────────────────────────────┐
│ [Clock]  [CPU Usage]  [RAM Usage]  [Focus Timer]         │
│ 14:32     ████░░ 34%   ███░░ 62%    24:17               │
│ Mon Jul   CPU 52°C     12.4/16 GB   ▸ Deep Work         │
│                                    [Pause]               │
│                                                          │
│ [Current Goal]        [Priorities]     [Media]           │
│ Finish Rust refactor  ☑ Review PR      ♫ Lo-fi Beats    │
│                       ☐ Write docs     ▶██░░░░░░░       │
│                       ☐ Deploy         ◁  ▸  ▷          │
│                                                          │
│ [••○] Page 1 of 3    [⚙ Edit]  [⋯ Menu]                 │
└──────────────────────────────────────────────────────────┘
```

**Key Design Elements:**
- Page indicator (••○) at bottom left or center
- Edit button (⚙) at bottom right
- Menu button (⋯) for settings, diagnostics, about
- Widgets have subtle rounded corners (8-12px radius)
- Widgets have a slight background card (semi-transparent in dark theme)
- Large, readable text for primary information
- Small, muted labels for secondary information

---

## 3. Dashboard - View Mode (Portrait: 720×2560)

```
┌──────────────┐
│ [Clock]      │
│  14:32       │
│  Mon Jul 11  │
│              │
│ [CPU Usage]  │
│  ████░░ 34%  │
│  CPU 52°C    │
│              │
│ [RAM Usage]  │
│  ███░░ 62%   │
│  12.4/16 GB  │
│              │
│ [Focus Timer]│
│  24:17       │
│  ▸ Deep Work │
│  [Pause]     │
│              │
│ [Current     │
│  Goal]       │
│  Finish Rust │
│  refactor    │
│              │
│ [Priorities] │
│  ☑ Review PR │
│  ☐ Write docs│
│  ☐ Deploy    │
│              │
│ [Media]      │
│  ♫ Lo-fi     │
│  ▶██░░░░     │
│  ◁  ▸  ▷     │
│              │
│ [••○]        │
│ [⚙]  [⋯]    │
└──────────────┘
```

**Key Differences from Landscape:**
- Widgets stack vertically instead of flowing horizontally
- Single-column layout for narrow width
- Widgets are taller to use available vertical space
- Page indicator and controls at bottom

---

## 4. Dashboard - Edit Mode (Landscape: 2560×720)

```
┌──────────────────────────────────────────────────────────┐
│ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────┐ │
│ │   Clock    │ │ CPU Usage  │ │ RAM Usage  │ │ Focus  │ │
│ │            │ │            │ │            │ │ Timer  │ │
│ │   [⚙][✕]  │ │   [⚙][✕]  │ │   [⚙][✕]  │ │ [⚙][✕] │ │
│ │  ╔══════╗  │ │            │ │            │ │        │ │
│ │  ║resize║  │ │            │ │            │ │        │ │
│ │  ╚══════╝  │ │            │ │            │ │        │ │
│ └────────────┘ └────────────┘ └────────────┘ └────────┘ │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐             │
│ │  Current   │ │ Priorities │ │   Media    │ [+ Add]     │
│ │   Goal     │ │            │ │            │             │
│ │   [⚙][✕]  │ │   [⚙][✕]  │ │   [⚙][✕]  │             │
│ │            │ │            │ │            │             │
│ └────────────┘ └────────────┘ └────────────┘             │
│                                                          │
│ [↩ Undo] [↪ Redo]    [••○] Pg 1/3  [✓ Done Editing]     │
└──────────────────────────────────────────────────────────┘
```

**Key Edit Mode Elements:**
- Grid overlay visible (dashed lines)
- Each widget has [⚙] configure and [✕] remove buttons
- Resize handles on corners/edges of selected widget
- [+ Add] button in an empty grid cell
- [↩ Undo] [↪ Redo] available for this edit session
- Widget content is dimmed or simplified (no live updates)
- Tapping a widget action (e.g., Pause timer) does NOT trigger it in edit mode

---

## 5. Add Widget Catalog

```
┌──────────────────────────────────────────────────────────┐
│  Add Widget                          [Search widgets...]  │
│                                                          │
│  Categories: [All] [System] [Productivity] [Media] [Ctl] │
│                                                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│  │  Clock   │ │ CPU      │ │ RAM      │ │ Disk     │   │
│  │  🕐      │ │ 📊       │ │ 💾      │ │ 💿      │   │
│  │          │ │          │ │          │ │          │   │
│  │ Shows    │ │ Shows    │ │ Shows    │ │ Shows    │   │
│  │ time and │ │ CPU usage│ │ memory   │ │ disk     │   │
│  │ date     │ │ and temp │ │ usage    │ │ usage    │   │
│  │          │ │          │ │          │ │          │   │
│  │  [Add]   │ │  [Add]   │ │  [Add]   │ │  [Add]   │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│  │ Network  │ │ Focus    │ │ Goal     │ │ Tasks    │   │
│  │ 🌐       │ │ ⏱️       │ │ 🎯      │ │ ☑️       │   │
│  │          │ │          │ │          │ │          │   │
│  │  [Add]   │ │  [Add]   │ │  [Add]   │ │  [Add]   │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │
│                                                          │
│  [← Back to Dashboard]                                   │
└──────────────────────────────────────────────────────────┘
```

---

## 6. Widget Configuration Panel (Example: CPU Widget)

```
┌──────────────────────────────────────────────────────────┐
│  Configure CPU Widget                          [✕ Close]  │
│                                                          │
│  Title:  [CPU Usage______________]                       │
│                                                          │
│  Display Mode:                                           │
│  [● Percentage]  [○ Graph]  [○ Both]                     │
│                                                          │
│  Show Details:                                           │
│  [✓] Temperature                                         │
│  [✓] Per-Core Usage                                      │
│  [ ] Load Average                                        │
│                                                          │
│  Update Interval:  [2 seconds ▼]                         │
│                     (1s, 2s, 5s, 10s)                    │
│                                                          │
│  Temperature Sensor:  [Auto-detect ▼]                    │
│                        (k10temp, coretemp, etc.)         │
│                                                          │
│  Appearance:                                             │
│  Accent Color:  [● Blue]  [○ Green]  [○ Orange]         │
│  Show Label:    [✓]                                      │
│                                                          │
│  [  Reset to Default  ]          [  Save Changes  ]       │
└──────────────────────────────────────────────────────────┘
```

---

## 7. Settings - Main Screen

```
┌──────────────────────────────────────────────────────────┐
│  Settings                               [Search settings] │
│                                                          │
│  ┌── Display ──────────────────────────────────────────┐ │
│  │ Target: Corsair Xeneon Edge (DP-2)     [Change...] │ │
│  │ Orientation: Landscape                  2560×720   │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── Appearance ───────────────────────────────────────┐ │
│  │ Theme: Dark  │  Accent: #4A90D9  │  Motion: Normal │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── Dashboards ───────────────────────────────────────┐ │
│  │ 3 dashboards configured               [Manage...]   │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── Widgets ──────────────────────────────────────────┐ │
│  │ 7 widgets active, 0 disabled          [Manage...]   │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── Integrations ─────────────────────────────────────┐ │
│  │ MPRIS: ✓ Connected │ Sensors: ✓ │ GPU: ⚠ Partial   │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── Startup ──────────────────────────────────────────┐ │
│  │ Autostart: On │ Reconnect: On                       │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── Diagnostics ──────────────────────────────────────┐ │
│  │ System: CachyOS │ KDE Plasma │ Wayland              │ │
│  │ Version: 0.1.0 │ 7 widgets │ 2h uptime             │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌── About ────────────────────────────────────────────┐ │
│  │ Xeneon Edge Linux Hub v0.1.0                        │ │
│  │ Licenses │ Contributors │ Website                   │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  [  Reset All Settings  ]        [  Export Diagnostics ]  │
└──────────────────────────────────────────────────────────┘
```

---

## 8. Diagnostics Screen

```
┌──────────────────────────────────────────────────────────┐
│  Diagnostics                              [Export Bundle] │
│                                                          │
│  Application:                                            │
│    Version: 0.1.0 (commit abc1234, 2026-07-10)          │
│    Build: Release, optimized                            │
│    Uptime: 2h 34m                                       │
│                                                          │
│  System:                                                 │
│    Distribution: CachyOS (Arch Linux)                    │
│    Kernel: 6.12.1-arch1-1                               │
│    Desktop: KDE Plasma 6.2.5                            │
│    Session: Wayland                                     │
│    Qt Version: 6.8.1                                    │
│                                                          │
│  Displays:                                               │
│    DP-1: DELL U2723QE (3840×2160 @ 60Hz) [Primary]     │
│    DP-2: Corsair Xeneon Edge (2560×720 @ 60Hz) ★ Target│
│    HDMI-1: ASUS VG27A (2560×1440 @ 144Hz)              │
│                                                          │
│  Touch Devices:                                          │
│    /dev/input/event5: Corsair Xeneon Edge Touchscreen   │
│    → Mapped to DP-2 ✓                                   │
│                                                          │
│  Widgets (7 active, 0 disabled):                         │
│    clock-1 (Clock) v1.0 - OK, 2h uptime                 │
│    cpu-1 (CPU Usage) v1.0 - OK, 2h uptime               │
│    ram-1 (RAM Usage) v1.0 - OK, 2h uptime               │
│    focus-1 (Focus Timer) v1.0 - OK, running 24m         │
│    goal-1 (Current Goal) v1.0 - OK, 2h uptime           │
│    priorities-1 (Priorities) v1.0 - OK, 2h uptime       │
│    media-1 (Media Control) v1.0 - OK, playing           │
│                                                          │
│  Integrations:                                           │
│    MPRIS: ✓ Connected (Spotify)                          │
│    PipeWire: ✓ Connected (alsa_output.pci-0000)         │
│    Sensors: ✓ 12 sensors detected                       │
│      - CPU: k10temp (Tctl: 52°C)                        │
│      - GPU: amdgpu (edge: 48°C, junction: 52°C)         │
│    GPU (AMD): ✓ via sysfs                               │
│    GPU (NVIDIA): ✗ No NVIDIA GPU detected               │
│    OpenLinkHub: ✗ Not installed                         │
│                                                          │
│  Resource Usage:                                         │
│    CPU: 0.3% (avg over last 5 min)                      │
│    RAM: 112 MB RSS, 98 MB PSS                           │
│    Threads: 8                                           │
│    File Descriptors: 47                                 │
│                                                          │
│  Recent Warnings/Errors (last 10):                       │
│    [WARN 14:32:01] MPRIS: player properties changed      │
│    (none)                                                │
│                                                          │
│  Configuration:                                          │
│    Path: ~/.config/xeneon-edge-hub/config.toml          │
│    Schema Version: 1                                     │
│    Size: 1.2 KB                                         │
│                                                          │
│  [  Export Diagnostics Bundle  ]  [  Clear Logs  ]        │
│  [  Restart Application  ]       [  Safe Mode  ]          │
└──────────────────────────────────────────────────────────┘
```

The Safe Mode button in this discovery-era wireframe is not implemented.
Current recovery is the session-only CLI command
`xeneon-edge-hub --safe-mode`; it leaves all widget QML unloaded and does not
change the saved layout. A persistent in-app control remains deferred.

---

## 9. Widget Error State

```
┌────────────┐
│ ⚠️          │
│ Widget     │
│ Error      │
│            │
│ "CPU Usage"│
│ encountered│
│ an error.  │
│            │
│ [Restart]  │
│ [Disable]  │
│ [Reset]    │
└────────────┘
```

---

## 10. Display Disconnected State

The dashboard window is hidden. On the primary display, a notification appears:

```
┌──────────────────────────────────────────┐
│  Xeneon Edge Linux Hub                   │
│                                          │
│  Dashboard display disconnected.         │
│  Waiting for "Corsair Xeneon Edge"       │
│  to reconnect...                         │
│                                          │
│  [ Open on Primary (not recommended) ]   │
│  [ Re-run Display Setup ]               │
│  [ Dismiss ]                             │
└──────────────────────────────────────────┘
```

---

## 11. Focus Timer Widget (Detail)

```
┌────────────────┐
│  ⏱ Deep Work   │
│                │
│    24:17       │  ← Large, monospaced digits
│    remaining   │
│                │
│  [ Pause ]     │  ← Primary action, large touch target
│  [ +5 min ]    │  ← Secondary action
│  [ Skip → ]    │
│                │
│  ████████░░ 76%│  ← Session progress
│  Session 3/4   │
└────────────────┘
```

---

## Design System Notes

### Typography
- Primary data: 36-48px, weight 600, tabular figures
- Secondary labels: 14-16px, weight 400, muted color
- Widget titles: 16-18px, weight 500
- Monospace for timers, metrics: JetBrains Mono or Fira Code

### Spacing
- Widget padding: 16-24px internal
- Widget gap (grid): 12-16px
- Touch targets: minimum 48×48 logical px
- Primary buttons: 48-64px height

### Touch Targets - Priority Hierarchy
1. Primary action: 64×64px (e.g., Play, Pause, Add)
2. Secondary action: 48×48px (e.g., Settings, Close)
3. Tertiary action: 44×44px minimum (e.g., small toggles)

### Colors (Dark Theme - Default)
- Background: #0D1117 (widget cards: #161B22)
- Text primary: #E6EDF3
- Text secondary: #8B949E
- Accent: #58A6FF (blue, user-configurable)
- Success: #3FB950
- Warning: #D29922
- Error: #F85149
- Widget card border: #30363D

### Colors (OLED Black Theme)
- Background: #000000
- Widget cards: #0A0A0A
- Text primary: #E0E0E0
- Reduced white point to prevent burn-in

### Animation Tokens
- Page transition: 250ms ease-out slide
- Widget add: 200ms scale-in (0.9→1.0)
- Widget remove: 150ms fade-out
- Edit mode enter/exit: 200ms crossfade
- Reduced motion: all durations → 0ms (instant)

### Breakpoints (Responsive)
- Landscape: width > height
- Portrait: height > width
- Narrow portrait (≤800px width): single column
- Wide landscape (≥2000px width): multi-column grid
