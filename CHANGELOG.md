# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [1.0.0-beta.2] - 2026-07-26

### Added

- Real widget and preset golden-image baselines, contrast scans, minimum type
  size checks, compiled-resource warning gates, and a 503-item enumerated QML
  behavior matrix.
- Focused physical-panel workflows for touch, Manager-to-Hub reflection,
  page mirroring, drag reorder, orientation, notification, and MPRIS checks.
- Instrumented resource, cold-start, and rotation frame measurements plus
  configuration, HTTP, and widget fault-injection coverage.
- An immersive Hub option that hides global navigation while preserving each
  widget's own settings access.

### Changed

- Every first-party widget now has a content hierarchy designed around its
  supported size instead of stretching one layout into every tile.
- Preset selection renders real widgets and explains the intended audience and
  purpose before adding a screen.
- Manager previews use the same theme, accent, wallpaper, orientation, packing,
  and active-screen state as the Hub.
- Text, secondary labels, controls, and backdrop treatments use shared
  readability and density rules across themes and accents.

### Fixed

- Text clipping and ancestor clipping across compact, wide, tall, portrait, and
  landscape widget layouts.
- Abrupt orientation changes, startup HID enumeration races, and stale Manager
  orientation reflection.
- Manager placement on the Edge panel under KDE Wayland.
- Missing bundled wallpapers in Manager previews.
- Pending widget data being lost during clean shutdown.
- A widget runtime exception affecting more than the throwing handler.
- Configuration recovery for truncated, invalid, and schema-mismatched files.
- Qt 6.7 compatibility in the compiled QML test and Manager preview adapters.
- The Weather no-egress attestation now supplies the explicit location required
  by the current widget contract.

### Security

- Strengthened control-socket permission tests, secret-reference handling,
  remote file-authority rejection, network containment, and bridge failure-path
  coverage.
- Owner-issued Pro keys continue to verify offline against the shipped issuer
  public key.

## [1.0.0-beta.1] - 2026-07-21

Stability, fidelity and correctness pass. Everything below is user-visible unless
marked *(internal)*.

### Fixed
- **The Edge now shows the screen you're editing.** Selecting a screen in the
  Manager - or adding one - left the panel stuck on the first screen. The Manager
  now tells the hub which screen is selected and the panel follows.
- **Landscape orientation is no longer shown as portrait in the Manager.** The hub
  reported its raw sensor rotation instead of what it was actually displaying, so
  with no sensor reading (the hub's landscape default) the Manager preview drew
  the panel upright. It now reports what the panel really shows.
- **The Manager preview no longer squeezes a landscape Edge.** In landscape the
  preview moves full-width above the controls instead of being crushed into a
  narrow column beside them; portrait keeps the preview alongside.
- **Animated backgrounds animate in the Manager preview.** Orbs, waves, aurora,
  starfield and friends were drawn as still images in the preview while moving on
  the panel. They now match, and still respect reduce-motion.
- **A widget can no longer be resized past the space left.** Dragging a widget
  larger on a full screen briefly showed it overflowing (and appearing to scroll)
  before snapping back. The resize now only offers sizes that fit, so a screen
  always stays one screen - while dragging, not just afterwards.
- **Version reporting.** Both apps always reported `0.1.0` regardless of the build,
  the Manager ignored `--version` entirely, and the hub answered it only when no
  other copy was running. As a direct consequence, **"Check for updates" could
  never detect a newer release** - it had no real version to compare. Fixed.
- **Memory.** Fixed leaks that could grow the app to many gigabytes: three
  scene-graph traversals that re-walked the same nodes exponentially, and dashboard
  rows that were never reclaimed when a removed widget's fade was interrupted.
- The preview has a **minimum size** so a narrow Manager window can't shrink it
  to nothing.

### Changed
- **Calm is the default look.** New installs start on the Nord palette rather than
  the previous dark default.
- **Inspired themes renamed.** The distro-flavoured palettes are now named after
  the idea rather than the project (Trilby, Keystone, Swirl, Cascade, Fizz) and
  grouped as "Inspired". Saved themes are unaffected.
- **The preset picker previews what you get** - each preset's layout is drawn with
  the real packer, colour-coded by widget category and labelled with the widget
  names, so you can tell the presets apart before adding one.

### Known issues
- **AppImage self-update is not verified.** An earlier unreleased draft listed it
  as delivered; the
  update *check* now works correctly, but the download-and-patch (zsync) path has
  never been exercised against a published release. Treat it as unproven until a
  release is cut and the round trip is tested.

### Candidate changes accumulated after alpha.2

#### Added
- **Pro tier (licensing).** Offline, signed Ed25519 licence keys (`XE1.…`),
  verified on-device with no network and no hardware fingerprint; any bad key
  fails soft to Free. A paste-your-key dialog in the Manager (About) verifies as
  you type and re-gates live over the control socket without a restart. The first
  premium content is a **premium theme pack** (Synthwave, Cyberpunk, Vaporwave,
  Matrix + the five distro themes); ~20 themes stay free and nothing functional is
  ever gated. Issuer tooling (`tools/license-tool`, `scripts/mint-license.sh`) and
  `docs/LICENSING.md` for selling via Lemon Squeezy / Gumroad.
- **W1 - per-size widget layouts.** Every widget genuinely designed for each size
  it declares, in both orientations, keyed off `sizeClass` (not the modal overlay).
  Waves 1–3 across all widgets; `habit` gained a real transposed `1x1.5` map.
- **W2 - Manager UX clarity.** A defined scope vocabulary with a tag on every
  control, honest copy, live Appearance preview, and a post-setup Screens picker
  so the preset library is no longer wizard-only.
- **W3 - widget smoothness.** Tile reorder MOVES instead of teleporting (Dashboard
  and the Manager's Edge clone), removed tiles fade out and added tiles arrive,
  eased gauges, and stable sensor rows that update values without rebuilding.
- **AppImage update metadata.** Embedded `X-AppImage-UpdateInformation`
  (gh-releases-zsync) for the intended discovery path. The published-artifact
  delta-update round trip remains a release blocker, as noted above.
- **Diagnostics:** the Network tab surfaces the NetHub egress counters.
- Nine runtime end-to-end scenarios (up from one) driving the real hub binary.

#### Changed
- **Accessibility-forward defaults:** Atkinson Hyperlegible is the default font,
  and a fresh install is calm/quiet (animated background and widget glow off).
  Motion transitions stay on; reduce-motion remains a separate, respected setting.
- `--reset` now backs up `config.toml` to `config.toml.bak` before clearing, and
  refuses if the backup fails - a mistyped `--reset` is no longer unrecoverable.
- The local update flow (`scripts/update-local.sh`) restarts BOTH the hub and the
  Manager onto the new build.

#### Fixed
- The RAM/gauge ring's centre reading overflowed when the mono font fell back to a
  proportional face (`Layout.maximumWidth` inert without a paired `preferredWidth`);
  fixed here and at three sibling sites.
- The Hydration expanded overlay overran its box in landscape (fixed literals);
  now room-derived.
- `tst_meds` failed every night between 00:00–00:10 (a bare `HH:mm` schedule read
  as a future dose); pinned to an injected clock.
- Three tests that never executed (QtTest's `test_*_data` data-provider trap),
  plus a family of gates that reported success while doing no work - all now
  assert their own subjects exist. A live-test lint (`check_live_tests.sh`) gates
  the class in CI.
- The Manager's About "GitHub" button opened `"#"` and did nothing.
- Security policy (`SECURITY.md`) pointed vulnerability reports at an unregistered
  domain; replaced with GitHub private vulnerability reporting.
- Docs CI had been red over a link that was actually valid; the checker now strips
  anchors and verifies them.
- The local dogfood build versioned *below* the installed release (a `pacman -U`
  downgrade); pkgver is now tag-derived.
- Removed ~202 MB of accidentally-committed makepkg build output.

#### Security
- Licence verification is offline and fails-soft; the private issuer seed is never
  in the repo or CI. GitHub private vulnerability reporting enabled.

---

## [1.0.0-alpha.2] - 2026-07-16
First signed release tag. Curated 15-screen preset library, HTTP/JSON
+ KPI primitive widgets behind the NetHub egress gate, org-managed policy, offline
licence-verification scaffolding, and the hardened control-socket / hermetic-test
foundations.

## [1.0.0-alpha.1] - 2026-07
Initial alpha: Rust core + Qt6/QML dashboard, first-run wizard, the widget set,
display matching, and the CI/coverage gates.

---

## Version History

| Version | Date | Description |
|---------|------|-------------|
| Unreleased | - | Development after beta.2 |
| 1.0.0-beta.2 | 2026-07-26 | Widget readability, Manager fidelity, hardware behavior and release evidence |
| 1.0.0-beta.1 | 2026-07-21 | Hub/Manager integration, hardware lifecycle, widget fidelity and release hardening |
| 1.0.0-alpha.2 | 2026-07-16 | First signed release tag |
| 1.0.0-alpha.1 | 2026-07 | Initial alpha |
| 0.0.0 | 2026-07-11 | Project inception - Phase 0 Discovery |
