# EdgeHub roadmap

**Last updated:** 2026-07-28
**Public baseline:** `v1.0.0`
**Release target:** `v1.0.1`
**Development status:** stable 1.0 maintenance on `main`

Version 1.0.0 is the latest published milestone. Its supported download channels
are the AppImage, Ubuntu 26.04 DEB, and Fedora 43 RPM attached to the signed
GitHub release. Work on `master` targets `v1.0.1`, for which
publication is not certified and no release claim is made yet.

## Current implementation

- Native Rust core with a hand-written C ABI and Qt 6/QML Hub and Manager.
- Multi-page, touch-first dashboards with display targeting, hot-plug handling,
  orientation support, local TOML state and Manager-to-Hub live updates.
- **30** first-party widgets registered in `ui/qml/WidgetCatalog.qml`.
- **19** ready-made screens registered in `ui/qml/PresetCatalog.qml`.
- **29** themes and **29** accents in `ui/qml/Theme.qml`.
- **10** animated backgrounds plus the static Gradient style in
  `ui/qml/BackgroundCatalog.qml`, and 18 bundled wallpapers.
- Rust, C++, QML, compositor-backed GUI, runtime, Manager and physical-hardware
  test layers, with release-gate and package-contract tooling.

These are implementation facts, not a statement that every release requirement
has passed.

## Version 1.0 release status

- [x] Publish the signed `v1.0.0` tag and signed checksum manifest.
- [x] Publish and lifecycle-test the AppImage, Ubuntu 26.04 DEB, and Fedora 43
      RPM from the exact stable tag.
- [x] Pass the Rust, C++, compiled-resource QML, coverage, security, network,
      package, and local compositor gates described in the release notes.
- [x] Remove Qt Virtual Keyboard from the product, packages, and build pipeline.
- [ ] Record reproducible idle/active CPU, RSS, startup, and growth
      measurements. The release owner waived this for 1.0, so no formal
      performance claim is made.
- [ ] Complete the scripted physical-touch certificate. Physical panel input
      was owner-confirmed, but 1.0 does not report a certified manual audit.
- [ ] Run a long-duration soak. The release owner waived this for 1.0, so no
      long-duration stability claim is made.

## After a verified 1.0

Post-1.0 work includes stable AUR publication, Flatpak validation, the deferred
performance and physical-touch evidence, and fixes driven by real-world release
feedback. Potential, demand-driven work includes OBS, MangoHud, Prometheus,
smart-home integrations, a sandboxed widget SDK, marketplace governance, and
localization. None has a committed delivery date.

See [the historical beta/release gate](docs/BETA_PLAN.md), [distribution status](docs/DISTRIBUTION.md)
and [the changelog](CHANGELOG.md).

## Future Features Backlog & Candidates

The following features have been proposed for post-1.0 development:

### 1. Alert-Driven Reactive Screen Surfacing
- Dynamically navigate or highlight a dashboard screen when a monitored node (via Systems widget) triggers a warning/critical threshold (CPU > 95%, disk space low, node unreachable), or when a countdown/calendar event requires urgent attention.

### 2. Quick Actions & Wake-on-LAN (WoL) Tile
- A dedicated touch control widget with one-tap action macros:
  - Wake-on-LAN magic packet triggers for offline/sleeping lab nodes.
  - Home automation webhook triggers.
  - Quick command / restart triggers.

### 3. DDC/CI Hardware Display Brightness & Sleep Scheduling
- Hardware brightness control via `ddcutil` / DPMS for the Corsair Xeneon Edge display directly through touch controls or an automated sleep schedule (e.g. dimming late at night or upon workstation lock).

### 4. Docker / Podman / systemd Service Health Monitor
- Service status tile tracking critical daemon/container states (`active`, `failed`, `restarting`) across the fleet.

### 5. Home Assistant / Local IoT Control Widget
- Touchscreen control tile connecting directly to local Home Assistant instances for room temperatures, smart lighting, and energy monitoring.

---

*EdgeHub is an independent open-source project.*
