# Campaign brief

## Objective

Introduce the next verified EdgeHub release to Linux users who own a Corsair
Xeneon Edge and want a native, touch-first dashboard rather than an Electron or
browser-based workaround.

The campaign should earn trust through a clear product demonstration and
inspectable facts. It should not use release-readiness as a marketing adjective;
the signed artifact and evidence page provide that proof.

## Primary audience

1. Linux users with a Corsair Xeneon Edge on KDE Plasma/Wayland.
2. Developers, homelab users, and gamers who want glanceable system and workflow
   information on the panel.
3. Open-source contributors interested in Rust, Qt 6/QML, touch UI, display
   lifecycle, or Linux hardware integration.

Platform claims must be narrowed to the exact tested release matrix before
publication. Do not generalize from the primary KDE Wayland test host.

## Positioning

**Category:** native Linux dashboard for the Corsair Xeneon Edge.

**One-line value proposition:**

> Turn the Xeneon Edge into a native Linux dashboard you can arrange by touch or
> edit live from your desktop.

**Technical one-liner:**

> EdgeHub combines a Rust core with a Qt 6/QML Hub and companion Manager, with
> local configuration and a central egress gate for network-capable features.

## Message hierarchy

### 1. The panel becomes useful on Linux

- Swipeable dashboard pages built for the Edge's unusual aspect ratio.
- Portrait and landscape layouts.
- Touch-sized controls and per-size widget layouts.

### 2. The Manager and Hub stay in sync

- Arrange, resize, reorder, and restyle from the desktop Manager.
- The running Hub receives changes over a local socket.
- Screen selection, orientation, and layout are reflected both ways.

### 3. Useful without an account

- 30 first-party widgets and 19 preset screens in the current source.
- Local TOML configuration.
- No account requirement and no telemetry implementation.
- Network-capable widgets and the opt-in update check pass through a central
  egress gate.

### 4. Free is the complete functional product

- All widgets, presets, backgrounds, wallpapers, layout features, and the
  Manager are in Free.
- Pro currently adds nine optional colour themes.
- No price or sales claim is allowed until the store and fulfilment path are
  real and tested.

## Approved factual inventory

Use these counts only if the final candidate still matches the catalogs:

- 30 first-party widgets;
- 19 preset screens;
- 29 themes: 20 Free and 9 Pro;
- 29 accents;
- 10 animated backgrounds plus Gradient;
- 18 bundled wallpapers;
- MIT OR Apache-2.0 source licensing.

Run the catalog tests and repeat the count audit before publication.

## Tone

- Native, calm, direct, and technically credible.
- Show the actual product doing useful work.
- Prefer “local”, “inspectable”, and “tested on [matrix]” over absolute claims.
- Explain Free vs Pro plainly.
- Avoid hype words such as “revolutionary”, “flawless”, “zero impact”, and
  “universal”.

## Required trademark wording

> EdgeHub is an independent product by SKYPhoenix IT. It is not affiliated with,
> sponsored by or endorsed by Corsair. “Corsair” and “Xeneon Edge” are used only
> to describe hardware compatibility.

## Explicitly prohibited before evidence exists

- “Released beta”, “release ready”, “shipping quality”, “feature frozen”, or
  “code frozen” before the signed candidate passes.
- CPU, memory, startup, leak, or battery numbers.
- Availability through AUR, AppImage, Flatpak, DEB, RPM, or another channel
  unless that exact artifact is published and verified.
- Automatic or one-click update claims before the published zsync round trip.
- GNOME, X11, arbitrary-display, or broad distro support beyond the final test
  matrix.
- Price, discount, refund, SLA, instant delivery, or live-checkout language.
- A 48–72-hour stability claim before the qualifying physical-hardware soak.

## Calls to action

Use one primary action per placement:

- **Download v1.0.0-beta.1** - only after artifacts are live and verified.
- **Read the release evidence** - link to checksums, signatures, test matrix,
  package lifecycle, performance, and soak results.
- **View the source** - suitable before commercial delivery is available.
- **Report an issue** - point to the repository's issue template/support route.
