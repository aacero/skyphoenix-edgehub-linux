# EdgeHub v1.1.2

Release version: `v1.1.2`
Release stage: stable

EdgeHub v1.1.2 is a major reliability, performance, and feature release resolving continuous memory growth, FFI C-logging boundary panics, font glyph churn, and USB controller detachment, while introducing multi-habit 2x2 heatmap mini-grids with touch check-in sheets and enhanced astronomical observation telemetry in The Sky Tonight.

## Highlights

### Memory Leak & Stability Fixes
- **QNetworkReply Lifecycle Management**: Explicitly cleans up network replies across long-running daemon polling cycles, completely resolving gradual memory accumulation.
- **FFI Boundary Panic Protection**: Safely catches unhandled unwinding panics at the C logging boundary, preventing process termination during high-frequency diagnostics.
- **Clean USB Controller Teardown**: Properly closes and detaches USB `hidraw` device descriptors on exit, preventing xHCI host controller resets.
- **Glibc Heap Arena Bounding & Glyph Font Caching**: Eliminates continuous distance-field texture allocations in dynamic Sparkline graphs and sets sensible glibc malloc arena boundaries to minimize heap fragmentation over days of continuous uptime.

### Multi-Habit Heatmap & Touch Ergonomics
- **2x2 Heatmap Mini-Grid**: Track up to four distinct daily habits simultaneously per day cell with dedicated high-contrast quadrant indicators.
- **Touch-First Check-In Drawer**: Expandable modal sheet allows rapid, single-tap toggling of individual daily habits directly on secondary touchscreens.
- **Rebalanced Widget Geometry**: Expanded heatmap cells (up to 48 px) and multi-habit quadrants (21 px) with proportional spacing, streak counts in legends, and automatic multi-column flow for wide widgets.
- **Midnight Cell Rollover**: Scheduled reactive rollover ensures visual date progress transitions automatically at midnight without requiring manual refresh.

### The Sky Tonight Stargazing & Weather Alerts
- **Observing Conditions Telemetry**: Live ambient temperature and overnight low readings directly on the observing window timeline.
- **Dew & Frost Hazard Warnings**: Intelligent optical dew and frost hazard warnings when ground temperature approaches the dew point.
- **Interactive Unit Toggle**: Instant one-tap switching between Fahrenheit (°F) and Celsius (°C).
- **All-Dark Observing Horizon**: Expanded celestial ephemeris tracking all dark hours from dusk to dawn, complete with planetary constellation mappings.

### Widget Enhancements & CPU Reductions
- **Background Rendering Throttling**: Automatically gates off-screen backdrops, halves ambient bokeh particles, and pauses inactive sparkline tickers to preserve CPU and GPU cycles.
- **Humble Books Hobbies & SF Heuristics**: Added dedicated Hobbies filtering and improved Open Road Media sci-fi detection.
- **Braindump Date Formatting**: Formats notes older than one week as `MMM dd HH:mm` for quick temporal orientation.

## Installation & Artifacts

- **Arch Linux / CachyOS / Omarchy**: Native `.pkg.tar.zst` packages generated via `./scripts/update-local.sh`.
- **Standalone AppImage**: Self-contained executable with bundled Qt 6.9 and delta update support.
- **Debian / Ubuntu**: Native `.deb` package built for Ubuntu 26.04 LTS.
- **Fedora / RHEL**: Native `.rpm` package built for Fedora 43+.
