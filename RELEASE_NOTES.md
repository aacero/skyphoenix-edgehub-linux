# EdgeHub v1.1.0

Release version: `v1.1.0`
Release stage: stable

EdgeHub v1.1.0 introduces enhanced information density for widgets, in-place note management, multi-node Prometheus fleet monitoring, real-time Grafana/Prometheus vector charting, and idle screen cycling.

## Highlights

### Moon Phase Widget: Rich 2x2 Information Density
- **Expanded Information Layout**: 2x2 and wider tiles now display moonrise and moonset times, lunar age in days, phase percentage, and upcoming full and new moon dates.
- **Smart Location Inheritance**: Automatically inherits geographical coordinates from dashboard store settings (configured via Weather), with an explicit manual override toggle.
- **Dynamic Two-Column Display**: Automatically adapts layout geometry to prevent visual clipping while maintaining comfortable touch ergonomics.

### Braindump Widget: Direct In-Place Note Management
- **One-Touch Actions**: Items on compact tiles can now be clicked directly to edit in place or removed using a dedicated trashcan icon.
- **Frictionless Capture**: Add new notes and ideas directly from the dashboard tile without navigating into widget settings.

### Prometheus Fleet Monitor (Systems Widget)
- **Multi-Node Fleet Tracking**: Monitor multiple Prometheus `node_exporter` targets across your local network and homelab infrastructure.
- **Robust Networking**: Includes IPv6 host parsing, latency tracking, settling-time buffers, and cold-start fallback recovery.

### Prometheus & Grafana PromQL Vector Charting
- **Native PromQL Vector Visualizations**: Real-time vector-based time-series metrics directly from Grafana or Prometheus endpoints.
- **Precision Controls**: Configurable Y-axis bounds, optional zero-baseline anchoring, custom legends, and grid labels.

### Dashboard Usability & Navigation
- **Idle Screen Cycling**: Automatically swipe between active dashboard screens after a configurable idle period, bringing ambient awareness to unattended displays.
- **Double-Tap / Double-Click Expansion**: Quickly double-tap or double-click any tile to open its expanded detail view.
- **Native Omarchy Integration**: Automatic desktop environment detection and system menu shortcut integration.

## Installation & Artifacts

- **Arch Linux / CachyOS / Omarchy**: Native `.pkg.tar.zst` packages generated via `./scripts/update-local.sh`.
- **Standalone AppImage**: Self-contained executable with bundled Qt 6.9 and delta update support.
- **Debian / Ubuntu**: Native `.deb` package built for Ubuntu 26.04 LTS.
- **Fedora / RHEL**: Native `.rpm` package built for Fedora 43+.
