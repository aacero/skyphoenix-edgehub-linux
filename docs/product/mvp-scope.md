# MVP scope and evidence status

**Product baseline:** `v1.0.0-beta.1`
**Document status:** active requirements audit
**Last updated:** 2026-07-27

## Authority and historical documents

This file is the authoritative product/release scope for the next public
milestone. The Phase-0 product vision, use cases and wireframes are retained as
discovery history; they are not a second, parallel release contract. If a
historical document conflicts with this file, this file wins.

The distinction matters because the discovery drafts described a larger product
than the implemented MVP and marked several ideas as "MVP" before feasibility or
release evidence existed. The disposition matrix below makes those differences
explicit instead of silently treating an absent feature as complete.

## Goal

Deliver a stable Linux dashboard for the Corsair Xeneon Edge that normal users
can install, operate by touch in portrait and landscape, manage from a desktop
companion, and remove cleanly. Release support claims require evidence for the
exact candidate; a source file or package recipe alone is not evidence.

## Implemented scope

The development branch currently contains:

- the native Rust core, Qt 6/QML Hub and standalone Manager;
- persistent multi-page layouts with add/remove/move/resize and per-widget
  configuration;
- display selection, fail-closed target matching, hot-plug handling and Xeneon
  Edge orientation-sensor support;
- guarded touch interactions and 48 px minimum-target checks;
- 30 first-party widgets, 19 presets, 29 themes, 29 accents and 10 animated
  backgrounds plus Gradient;
- local configuration, diagnostics, offline/egress controls and an opt-in update
  check;
- CMake install/CPack, AUR, AppImage and Flatpak recipes;
- Rust, C++, QML, compositor-backed GUI, runtime, Manager and physical-hardware
  test layers.

This list describes code present in the branch. It does **not** declare the MVP
released, frozen, supported on every desktop, or within its performance targets.

## Release requirements still needing evidence or closure

| Requirement | Current status |
|---|---|
| CachyOS/Arch install, upgrade and uninstall | Local staged lifecycle evidence exists; exact public package route must be verified |
| Ubuntu/Fedora native packages | CPack recipes and distro workflow exist; exact-candidate distro jobs are still required |
| Ubuntu 24.04 | Distro Qt 6.4.2 is below the Qt 6.9 floor; no native-support claim |
| KDE/Wayland | Primary real-hardware environment; final candidate run pending |
| GNOME and X11 | Do not claim release support without candidate evidence |
| AppImage | Recipe exists; no published AppImage/zsync round trip has been exercised |
| Flatpak/Flathub | Recipe exists; no Flathub publication or supported-store claim |
| Correct-display and reconnect safety | Automated and real-device coverage exists; final candidate run pending |
| Primary-desktop disconnect notice and selection guidance | Window hiding is implemented, but the promised user-visible notification/guidance is not; release-blocking product gap |
| Touch-only add/move/resize/configure | Covered across GUI/Manager/hardware layers; final integrated run pending |
| Idle CPU <1% and RAM <150 MiB | **Current development candidate fails:** CPU 0.120%, peak RSS 408.094 MiB |
| Active CPU <5% and RAM <250 MiB | **Current development candidate fails:** CPU 2.053%, peak RSS 472.820 MiB with the exact 10-widget load |
| Startup <2 s and bounded growth during the accepted observation | Historical development startup passed at 0.223 s; exact-candidate measurement is pending |
| Stability observation | The owner waived the historical 48-hour soak. A literal 30-minute, 14-widget instrumented substitute is required; it does not support a long-duration stability claim |
| Qt Virtual Keyboard distribution choice | **Resolved by removal; clean-candidate package evidence pending** |
| Legal review of Inspired premium themes | **Open** |
| Store, pricing, refunds, support and key delivery | **Open; no live-store claim permitted** |

## MVP success gate

1. The exact candidate builds from a clean source snapshot.
2. Rust, C++, QML, Hub GUI, Manager GUI, runtime and integrated physical-Edge
   suites pass with no failure or hidden skip.
3. Display targeting never falls back to the wrong monitor; disconnect/reconnect
   and rotation evidence is attached.
4. Native package and portable artifact install/upgrade/uninstall paths are
   exercised on every advertised platform.
5. Performance limits and the owner-approved stability observation are measured
   and pass without being presented as long-duration evidence.
6. Documentation, legal/product decisions and support boundaries match reality.
7. The immutable final candidate passes the strict release gate, is signed, is
   published, and its downloaded artifacts verify in a clean environment.

None of these criteria may be checked merely because an implementation or CI
workflow exists. Until all seven are satisfied, status remains beta/development.

### Current performance evidence is a failed development measurement

The 2026-07-21 short formal profile used a CMake `Release` binary with coverage
and QA hooks off. Its binary SHA-256 was
`224efa6580b41da832b8edc6da5e37f91b0ad837ae08fc576982f3f5cdac89ce`; the
embedded version was `v1.0.0-alpha.2-246-g684cddb-dirty`. Startup qualified, and
both CPU averages qualified, but both RSS limits failed. The aggregate result was
therefore **FAIL**.

This is evidence about that dirty development binary, not an immutable release
candidate and not a publishable performance claim. A clean candidate must still
pass the short profiles and the owner-approved literal 30-minute, 14-widget
instrumented substitute. That substitute is not long-duration evidence.

## Requirements disposition

| Discovery-era item | Current disposition |
|---|---|
| Add/remove/move/resize/configure widgets | **MVP required and implemented**; final exact-candidate touch run remains required |
| Duplicate widgets and edit-session undo/redo | **Deferred**; not part of the current MVP contract |
| Hide on target loss; never take over primary; reconnect safely | **MVP required** |
| Primary-desktop disconnect notification and `ask` guidance | **MVP release blocker**; hiding works, but the user-facing notice/guidance is not implemented |
| Configurable core metric polling interval | **Deferred**; the core currently uses a fixed two-second interval |
| AMD/NVIDIA/Intel detailed GPU integrations | **Deferred**; current GPU support is AMD-oriented |
| MPRIS metadata plus play/pause/previous/next | **MVP required and implemented** |
| Media scrubbing, volume control and a measured <200 ms response SLA | **Deferred** |
| Fixed accessible accent palette | **MVP required and implemented** |
| Arbitrary custom-hex accent editor | **Deferred** |
| Application launcher / arbitrary command execution | **Deferred** |
| Current on-device settings and diagnostics surfaces | **MVP required** |
| Search across a full settings taxonomy, diagnostics ZIP export and persistent safe mode | **Deferred**; the implemented `--safe-mode` is session-only and leaves all widget QML unloaded without changing the saved layout |
| Unknown/policy-disabled widget fallback | **MVP required and implemented** |
| Per-widget CPU budgets, restart/disable/reset error UI and three-strike isolation | **Deferred** with the third-party sandbox/runtime work |
| Pixel-golden visual regression, touch-to-photon latency and 25/50-widget stress profiles | **Deferred**; they are not implied by the current behavior and resource gates |
| KDE/Wayland on the recorded Edge setup | **Release evidence required** |
| GNOME, X11 and broad arbitrary-display support | **Evidence-gated future support claim**, not assumed by the MVP |

## Deferred work

Community widget SDK/marketplace, third-party sandboxing, edit undo/redo,
application launching, media scrubbing/volume, custom-hex accents, searchable
full settings, diagnostics export, persistent safe mode, game-profile switching,
deep vendor-specific GPU integrations, OBS/Discord integrations, embedded web
content, multi-touch gestures and additional distribution stores remain post-MVP
possibilities without committed dates.

See [the roadmap](../../ROADMAP.md), [beta/release gate](../BETA_PLAN.md), and
[distribution status](../DISTRIBUTION.md).
