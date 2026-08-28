# Widget User Guide

**Work in progress** - This guide will be completed in Phase 3 (Core Widgets).

## Overview

Widgets are the building blocks of your dashboard. Each widget displays information or provides controls for a specific purpose.

## Widget Categories

### System Widgets
- **Clock** - Current time and date
- **CPU Usage** - CPU utilization and temperature
- **RAM Usage** - Memory utilization
- **Disk Usage** - Storage space per mount point
- **Network Throughput** - Upload/download speeds per interface
- **Systems Monitor** - Multi-system health, CPU, memory, disk, uptime and network throughput via Prometheus node_exporter

### Productivity Widgets
- **Focus Timer** - Countdown/up timer for focus sessions
- **Current Goal** - Single focused objective
- **Top-Three Priorities** - Editable checklist
- **Quick Note** - Auto-saving scratchpad
- **Break Reminder** - Periodic gentle reminders

### Media Widgets
- **Media Control** - Playback controls for any MPRIS player

### Control Widgets
- **Application Launcher** - Launch apps from .desktop entries
- **Page Switcher** - Navigate between dashboard pages
- **Lock Screen** - Lock the system

## Widget Interactions

### View Mode
- **Tap** - Primary widget action (e.g., pause timer, toggle view)
- **Long press** - Context menu (configure, remove, duplicate)
- **Swipe** - Scroll content within widget (if applicable)

### Edit Mode
- **Drag** - Move widget to a new position
- **Drag corner/edge** - Resize widget
- **Tap ⚙** - Open widget configuration
- **Tap ✕** - Remove widget

## Adding Widgets

1. Enter Edit Mode (tap ⚙ Edit button or long-press empty area).
2. Tap an empty grid cell's [+] button or the [+ Add] toolbar button.
3. Browse or search the widget catalog.
4. Tap [Add] on the widget you want.
5. Drag to position and resize as desired.
6. Exit Edit Mode.

## Configuring Widgets

1. Enter Edit Mode.
2. Tap the ⚙ icon on the widget.
3. Adjust settings in the configuration panel.
4. Tap [Save Changes].

## Removing Widgets

1. Enter Edit Mode.
2. Tap the ✕ icon on the widget.
3. Confirm removal.
4. (Or use Undo if you change your mind.)

## Locking Widgets

Locked widgets cannot be moved, resized, or removed without unlocking first.

1. Long-press widget → Lock Widget.
2. To unlock: Enter Edit Mode → tap lock icon → Unlock.

## Widget Errors

If a widget encounters an error:
- It will show an error placeholder.
- Options: Restart Widget, Disable Widget, Reset Settings.
- If a widget fails repeatedly, it will be automatically disabled.

## Dashboard Pages

- Swipe horizontally (landscape) or vertically (portrait) to switch pages.
- Page indicators show current position.
- Each page has its own widget layout.
- Add pages in Edit Mode.

