# EdgeHub marketing claim register

**Status:** beta.1 campaign and exact-candidate media complete
**Product status:** `v1.0.0-beta.1` - Ready with accepted risks

The release owner waived the planned 48-hour soak. Marketing may describe the
completed real-hardware and integration evidence, but must not claim a stability
duration, formal performance result, package repository, automatic update, or
commercial Pro availability.

A claim-controlled campaign pack is ready under
[`marketing/release-kit/`](marketing/release-kit/README.md). The 59-second live
product film, theme reel, website hero, social images, native captures, hashes,
and capture provenance are versioned with the documentation.

## Positioning

EdgeHub is a native Linux widget dashboard for the Corsair Xeneon Edge and other
secondary or portrait touch displays. A Rust core handles configuration and
metrics; Qt 6/QML renders the Hub and companion Manager.

Public wording must use “Corsair Xeneon Edge” only to describe compatibility and
must include that EdgeHub is independent and is not affiliated with, sponsored
by or endorsed by Corsair. Do not use Corsair logos or trade dress.

## Claims supported by the current source

- 30 registered first-party widgets.
- 19 registered preset screens.
- 29 themes: 20 free and 9 Pro theme entries.
- 29 accents: 14 standard, 8 Okabe–Ito and 7 theme-completing accents.
- 10 animated backgrounds plus Gradient, and 18 bundled wallpapers.
- Multi-page portrait/landscape layouts and a standalone Manager that pushes
  changes to a running Hub over a local socket.
- Local TOML configuration, no account requirement, no telemetry implementation,
  and a central egress gate for configured network widgets and the opt-in update
  check.
- MIT OR Apache-2.0 source licensing.

These implementation facts do not prove release availability, cross-distro
support, performance, stability or store fulfilment.

## Claims prohibited for beta.1

- “Shipping quality”, “stable”, or a 24/48/72-hour stability claim.
- Any CPU, RSS, startup, leak or battery number. Earlier performance estimates
  were unsupported.
- “Available on AUR/AppImage/Flatpak/Flathub/DEB/RPM” unless the exact referenced
  package is published, downloadable and verified.
- “Auto-updating” or “one-click updates” until the AppImage zsync path has been
  exercised against published artifacts.
- A price, launch discount, refund promise, support SLA, site licence, instant
  delivery or live checkout until those business systems and policies exist and
  are tested.
- GNOME, X11, arbitrary-display or broad distro support beyond recorded
  candidate evidence.
- AppImage, AUR freshness, DEB/RPM repository, Flatpak, or self-update
  availability claims.

## Completed release media

1. Fresh physical-Edge captures for portrait and landscape Hub layouts.
2. Manager screen creation, orientation preview, and Appearance captures from
   the exact candidate.
3. A 59-second product film with a front-facing rounded Edge frame, animated
   landscape-to-portrait turn, camera pullback, and synchronized live Manager
   actions that change the running Hub, with original music.
4. A 45-second Manager showcase covering all 20 Free themes and ten
   representative accent colours, captured inside an isolated virtual display.
5. Theme and accent proof sheets plus selected full-size Manager theme frames.
6. A media evidence appendix with the exact tag, binary hashes, display layout,
   isolated configuration controls, and output checksums.
7. Website, release, press, social, and community copy generated from this
   register and reviewed against the beta.1 claim boundary.

Only the versioned files under
`docs/marketing-site/assets/release/v1.0.0-beta.1/` are approved beta.1 launch
visuals. Older assets remain composition references, not candidate evidence.
