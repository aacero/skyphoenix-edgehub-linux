# EdgeHub roadmap

**Last updated:** 2026-07-28
**Public baseline:** `v1.0.0`
**Release target:** `v1.0.1`
**Development status:** stable 1.0 maintenance on `master`

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

---

*EdgeHub is an independent product of SKYPhoenix IT and is not affiliated with Corsair.*
