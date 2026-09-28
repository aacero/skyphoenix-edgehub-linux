# Press kit

> **Prepared beta.1 press material.** Publish after the signed artifacts are live.

## Short description

EdgeHub is a native Linux dashboard for the Corsair Xeneon Edge. It provides
touch-first widget pages and a companion desktop Manager for editing the running
panel.

## 80-word boilerplate

EdgeHub is an independent Linux application by SKYPhoenix IT for the Corsair
Xeneon Edge. A Rust core handles configuration and metrics while Qt 6/QML powers
the touch-first Hub and companion desktop Manager. The current product catalog
contains 30 first-party widgets and 19 preset screens, with portrait and
landscape layouts. Configuration stays in local TOML, no account is required,
and the application has no telemetry implementation. EdgeHub source is licensed
under MIT OR Apache-2.0.

## Release fact sheet

| Field | Verified release value |
|---|---|
| Product | EdgeHub |
| Publisher | SKYPhoenix IT |
| Version | v1.0.0-beta.1 |
| Release date | 2026-07-21 |
| Verified platforms | CachyOS/Arch Linux with KDE Plasma on Wayland; portable x86-64 builds require Qt 6.5 or newer |
| Published artifacts | signed source tarball and portable x86-64 tarball, with checksums and signatures |
| Source licence | MIT OR Apache-2.0 |
| Price/store | Not offered for sale in beta.1 |
| Download | https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0-beta.1 |
| Live product film | https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-live-product-film.mp4 |
| Release evidence | https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/v1.0.0-beta.1/docs/testing/hardware-validation-2026-07-21.md |
| Support | https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/issues |
| Contact | simon.kreitmayer@skyphoenix-it.com |

## Product facts

- 30 first-party widgets across System, Time, Focus, Media, Data, and Info.
- 19 preset screens.
- Multi-page portrait and landscape layouts.
- A separate desktop Manager with live local-socket synchronization.
- 29 themes, 29 accents, 10 animated backgrounds plus Gradient, and 18 bundled
  wallpapers in the current catalog.
- Local TOML configuration.
- No account requirement and no telemetry implementation.
- Central egress gate for configured network-capable features.
- Free contains every functional feature; Pro currently changes only access to
  nine optional themes.

## FAQ

### Is EdgeHub made by Corsair?

No. EdgeHub is an independent product by SKYPhoenix IT. It is not affiliated
with, sponsored by or endorsed by Corsair. The Corsair and Xeneon Edge names are
used only to describe hardware compatibility.

### Is it Electron or a browser dashboard?

No. The current implementation uses a Rust core and native Qt 6/QML
applications for the Hub and Manager.

### Does it require an account?

No account is required by the application.

### Does it send telemetry?

The application has no telemetry implementation. User-configured network
widgets and the opt-in update check are separate network-capable features and
pass through the application's central egress gate.

### What is paid?

The current code's Pro entitlement adds nine optional colour themes. All
widgets, presets, layout tools, backgrounds, wallpapers, accessibility features,
and the Manager remain in Free. Do not describe a price or purchase route unless
the final fact sheet contains verified commercial terms.

### Does it auto-update?

Answer only from the final artifact evidence. The source contains update-check
and AppImage metadata work, but the project does not claim a working published
delta-update flow until a real release-to-release round trip is verified.

### Which Linux distributions and desktops are supported?

The primary verified environment is CachyOS/Arch Linux with KDE Plasma on
Wayland. Portable x86-64 builds require Qt 6.5 or newer. Do not describe package
recipes as published repositories.

## Credits

- Product and publisher: SKYPhoenix IT.
- Technology: Rust, C++17, Qt 6, QML, CMake.
- Third-party licences and bundled font notices:
  <https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/tree/v1.0.0-beta.1/assets/fonts>.
- Contributors: Simon Kreitmayer and the EdgeHub hardware testers.

## Media asset rule

Only distribute the exact-candidate captures approved in
[`asset-plan.md`](asset-plan.md). Do not present development screenshots,
generated concepts, or third-party hardware branding as release evidence.

## Media files

- `edgehub-v1.0.0-beta.1-live-product-film.mp4`: 71-second captioned behavior
  film with animated display rotation, live Manager orientation reflection, and
  synchronized Manager-to-Hub edits.
- `edgehub-v1.0.0-beta.1-manager-hub-live-sync.png`: final film frame showing
  the matching three-widget Manager preview and Hub dashboard.
- `edgehub-v1.0.0-beta.1-live-theme-control.png`: final film frame showing
  Manager Look controls changing the live Hub.
- `edgehub-v1.0.0-beta.1-feature-tour.mp4`: earlier capture-led product tour.
- `edgehub-v1.0.0-beta.1-manager-theme-showcase.mp4`: 45-second captioned reel
  covering all 20 Free themes and ten accent colours.
- `edgehub-v1.0.0-beta.1-manager-theme-sheet.png`: complete Free theme sheet.
- `edgehub-v1.0.0-beta.1-manager-accent-sheet.png`: representative accent sheet.
- `edgehub-v1.0.0-beta.1-website-hero.png`: wide Hub and Manager hero.
- `edgehub-v1.0.0-beta.1-social-landscape.png`: 16:9 social image.
- `edgehub-v1.0.0-beta.1-social-square.png`: square social image.
- `edgehub-v1.0.0-beta.1-hub-portrait-hero-01.png`: native portrait Hub.
- `edgehub-v1.0.0-beta.1-hub-landscape-hero-01.png`: native landscape Hub.

All files are exact-candidate captures or compositions made from those captures.
Hashes and provenance are in the release media directory and the media
validation report.
