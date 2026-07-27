# EdgeHub roadmap

**Last updated:** 2026-07-27
**Public baseline:** `v1.0.0-beta.1`
**Release target:** `v1.0.0`
**Development status:** stable 1.0 candidate hardening on `release/1.0.0`;
publication is not certified and no code freeze is declared

Beta.1 is the latest published milestone. The current branch is a candidate work
area, not a stable release. A stable milestone changes only when its evidence is
complete and an actual tag is published.

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

## Gate to the next public milestone

- [ ] Resolve every P0/P1 and every release-blocking requirement finding.
- [ ] Complete the final Manager, Hub and integrated physical-Edge suites with
      zero failures and zero hidden skips.
- [ ] Run required Fedora/Ubuntu native-package jobs for the exact candidate.
- [ ] Exercise AppImage discovery and zsync update against published artifacts.
- [ ] Record reproducible idle/active CPU, RSS, startup and growth measurements.
- [ ] Complete the owner-approved literal 30-minute, 14-widget instrumented
      substitute. The historical 48-hour soak was waived, so no long-duration
      stability claim may be made from this release evidence.
- [ ] Close the Qt Virtual Keyboard distribution choice and the remaining
      legal/trademark and payment/delivery decisions.
- [ ] Limit the release branch to release blockers, evidence work and
      owner-approved corrections.
- [ ] Fix release-blocking defects and re-run the affected gates.
- [ ] Enter code freeze only with a clean, reviewed, immutable candidate.
- [ ] Run the final strict suite from that candidate, then sign, publish and
      verify the release assets.

Until every item is complete, marketing copy must say **beta/development
candidate**, must not advertise unsupported distro/store availability, and must
not quote unverified performance or long-duration stability numbers.

## After a verified 1.0

Potential, demand-driven work includes OBS/MangoHud/Prometheus/smart-home
integrations, a sandboxed widget SDK, marketplace governance and localization.
None has a committed delivery date.

See [the beta/release gate](docs/BETA_PLAN.md), [distribution status](docs/DISTRIBUTION.md)
and [the changelog](CHANGELOG.md).

---

*EdgeHub is an independent product of SKYPhoenix IT and is not affiliated with Corsair.*
