# EdgeHub v1.1.1

Release version: `v1.1.1`
Release stage: stable

EdgeHub v1.1.1 brings Quick Actions host command macros, Systems Wake-on-LAN bursts with live boot timers, geometry-adaptive Calendar views, The Sky Tonight planetary ephemeris, Humble Bundle book monitoring, reactive screen alert surfacing, and rolling configuration backups.

## Highlights

### Quick Actions & Wake-on-LAN (WoL)
- **Host Control Cards**: Dedicated host tiles providing one-touch Ping, SSH, and Mosh macros with command-availability desktop alerts.
- **3-Packet Magic-Packet Burst**: Systems widget sends reliable 25 ms spaced UDP bursts for remote machine power-on.
- **Live Boot-Phase Timer**: Real-time 60-second boot-phase countdown with elapsed feedback while target nodes boot.
- **MAC Address Discovery**: Automatic discovery of MAC addresses from Quick Actions settings plus inline editing in Systems deep-dive view.

### Reactive Alert-Driven Screen Surfacing
- **Automatic Alert Focus**: Pauses idle screen cycling and automatically surfaces the affected dashboard screen when a fleet host drops offline or a reminder triggers.
- **Auto-Resume**: Gracefully resumes ambient idle cycling once active alerts are acknowledged or cleared.

### Geometry-Adaptive Calendar
- **Responsive Layout Modes**: Month grid for square tiles, 7-day Week view for wide horizontal tiles, and List/Agenda view for vertical tiles.
- **Extended Lookahead**: Extends lookahead horizon to 90 days with recurring-event cancellation and RECURRENCE-ID handling.
- **Day-Header Expander**: Tap any date header to expand single-day event drawers.

### The Sky Tonight & Moon Enhancements
- **Planetary Ephemeris**: Hourly sky clarity forecast bars and naked-eye planet rise/set rows (Mercury through Saturn).
- **Forecast Freshness**: Anchored date headers, active screen-revisit auto-refresh, and manual refresh button.
- **Centred Moon Layout**: Photorealistic phase-masked lunar texture with balanced metrics on 1x1 tiles.

### Humble Bundle Book Monitor
- **Live Bundle Tracking**: Real-time tracking of book, comic, sci-fi, and cookbook bundles with urgency countdowns.
- **Category Filter Pills**: Single-category toggle with instant All reset pills.
- **Full Tier Pricing**: Displays top-tier bundle prices alongside base tier options.

### Usability & Reliability
- **Custom Rotation Delay**: Dial arbitrary screen rotation delays (0–86,400 seconds) directly with numeric steppers.
- **Rolling Configuration Backup**: Automatically preserves `config.toml.bak` on every standard save.
- **Unlocked Themes**: All 9 premium and inspired themes (Synthwave, Cyberpunk, Vaporwave, Matrix, and more) unlocked for all users.
- **Media Fallback**: Graceful "Artwork unavailable" plate on corrupt or missing album covers.

## Installation & Artifacts

- **Arch Linux / CachyOS / Omarchy**: Native `.pkg.tar.zst` packages generated via `./scripts/update-local.sh`.
- **Standalone AppImage**: Self-contained executable with bundled Qt 6.9 and delta update support.
- **Debian / Ubuntu**: Native `.deb` package built for Ubuntu 26.04 LTS.
- **Fedora / RHEL**: Native `.rpm` package built for Fedora 43+.
