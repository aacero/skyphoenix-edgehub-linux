# EdgeHub

**Leaving Windows behind? Your Edge can come with you.**

EdgeHub by [SKYPhoenix IT](https://skyphoenix-it.com) is a native Linux widget
dashboard designed for the Corsair Xeneon Edge and selected secondary/portrait
touchscreens. No browser, Electron, web server, account or telemetry implementation
is required. Broad display and desktop support remains evidence-gated.

[![CI](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)
[![Release: v1.0.0](https://img.shields.io/badge/release-v1.0.0-blue.svg)](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0)

![EdgeHub running in portrait and landscape beside EdgeHub Manager](docs/marketing-site/assets/release/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-website-hero.png)

> **Current public status: stable.** `v1.0.0` is the first stable EdgeHub
> release. The release owner waived both the planned 30-minute instrumented
> observation and the earlier 48-hour soak, so this release makes no formal
> performance or long-duration stability claim. The scripted physical-touch
> certificate was not completed; physical panel input was owner-confirmed but
> is not reported as a certified manual audit. See the
> [1.0 release notes](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0).

**Release target:** `v1.0.1`. This checkout is unreleased and is not published
or certified.

**[Watch the 71-second live product film](docs/marketing-site/trailer.html)** or
**[open the MP4 directly](docs/marketing-site/assets/release/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-live-product-film.mp4)**.

It shows the running Hub change screens, turn between landscape and portrait
while Manager follows, add a screen and widget from Manager, and apply a theme
and accent live.

![EdgeHub Manager and the running Hub showing the same three-widget dashboard](docs/marketing-site/assets/release/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-manager-hub-live-sync.png)

**[Watch all 20 Free themes and ten accent colours](docs/marketing-site/assets/release/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-manager-theme-showcase.mp4)**.

---

## What it is

The Corsair Xeneon Edge is a 2560×720 secondary touchscreen that works in either orientation. EdgeHub gives it - and other secondary or portrait displays - a purpose-built home screen: swipeable pages of live widgets you arrange by touch, right on the device.

**Who it's for:** anyone with a second screen they don't want to waste. Developers watching a build. Homelab owners watching a rack. People who want a calm timer and the weather instead of another browser window.

- **Native, without Chromium.** A Rust core handles metrics and configuration;
  Qt 6/QML draws the UI. Resource limits are evidence-gated; no passing stable
  CPU, memory or long-duration number is claimed before the exact candidate run.
- **Designed for touch.** Large targets, page swipes, in-widget controls, and
  on-device settings cover normal dashboard use. Text entry uses a physical
  keyboard or a desktop-provided input method.
- **It finds the right screen.** Display detection puts EdgeHub on your Edge (or a display you choose), and a real HID orientation sensor follows the panel when you flip it.
- **Design it from your desk.** The companion **EdgeHub Manager** is a live clone of your Edge - drag, reorder, resize, and restyle from your main monitor.

---

## 19 ready-made screens

You don't start from a blank grid. Each preset is a designed layout - a small, purposeful set of widgets, with a fitting background and motion character.

| Screen | For |
|---|---|
| **Calm Focus** | A large focus timer beside the single thing you are doing now. |
| **Notes & Streak** | A scratchpad and habit streak for keeping momentum visible. |
| **Home** | A large clock and weather view for an everyday desk screen. |
| **Ambient** | Now playing beside tonight's moon phase. |
| **Remote Work** | Today's tasks and a live view of how much of the workday remains. |
| **Developer** | Labelled, unconnected slots for CI status and an open pull-request KPI. |
| **Homelab Ops** | Labelled, unconnected feeds for service uptime and container health. |
| **Gaming Cockpit** | A large GPU view beside compact CPU and memory telemetry. |
| **Trading Desk** | Local and New York clocks beside one unconnected P&L KPI. |
| **Health & Routine** | Gentle nudges toward a good day - water, breaks, and a daily streak. |
| **Creator / Media** | Now playing beside a focus timer for a compact studio screen. |
| **System Core** | CPU, GPU and memory at a glance. |
| **System I/O** | Network, disk and sensor detail. |
| **Day Plan** | A clock beside an agenda that you connect with an ICS URL. |
| **Minimalist** | Almost nothing. A clock, the weather, and the moon. |
| **Analyst / Data** | Two unconnected headline numbers, including one local-file KPI, plus a monitoring feed. |
| **Student / Study** | A focus timer, today's tasks, and an exam countdown. |
| **Productivity** | A large focus timer beside today's tasks. |
| **Team / Enterprise** | The workday beside one unconnected, approved team KPI. |

Applying a preset keeps *your* theme and accent - it changes the screen, not your taste.

Selecting a screen now opens a passive preview before anything is added. It
shows the exact widget arrangement and sizes, the screen's intended job, its
included widgets, and any setup or connection work it needs.

The data-connected presets (Developer, Homelab Ops, Trading Desk, Analyst, Enterprise) ship their data tiles **labelled but deliberately unconnected** - "CI status → Add a URL in settings". A preset never guesses an endpoint, so a fresh install never polls a stranger's host.

*Defined in [`ui/qml/PresetCatalog.qml`](ui/qml/PresetCatalog.qml).*

---

## 30 widgets

| Category | Widgets |
|----------|---------|
| **System** (8) | CPU load & temp, multi-GPU telemetry for AMD, Intel and NVIDIA where exposed by Linux DRM, Memory, Network throughput, Disk usage, combined Sensors, installed Packages, System Age |
| **Data** (2) | **HTTP / JSON** - poll any endpoint, pull a value out by path, show it as a number, gauge or list · **KPI** - one number that matters, from a URL *or a local file*, with colour-coded thresholds |
| **Time** (3) | Clock (**real IANA time zones - daylight saving included**), Analog Clock, Moon Phase |
| **Focus** (10) | Focus Timer (Pomodoro), Tasks, Right Now, Quick Note, Habit Streak, Hydration, Break Reminder, Meds, Braindump, Routine |
| **Media** (1) | Now Playing (MPRIS - Spotify, browsers, any player on the machine) |
| **Info** (6) | Calendar (subscribe via ICS URL), Now / Next, Weather (Open-Meteo), Countdown, End of Day, Daily Quote |

System metrics come from the Rust core and the kernel. Focus, task, note, habit and hydration widgets persist your data locally.

**Real time zones, properly.** The clock is backed by a `QTimeZone` bridge, so it follows actual IANA rules - every zone your OS `tzdata` knows (~600), daylight saving included, and correct through a `tzdata` update with no code change. QML has no `Intl`, and `Date.toLocaleString(…, { timeZone })` silently returns host-local time - which is exactly the kind of quiet wrongness a clock cannot afford.

*Defined in [`ui/qml/WidgetCatalog.qml`](ui/qml/WidgetCatalog.qml).*

---

## Connect your own data

The **HTTP/JSON** and **KPI** widgets point at *your* endpoint: a CI status, a queue depth, a P&L number, a Prometheus query, a file on disk. No integration, no account, no vendor. KPI's local-file source works with no network at all.

**Credentials are references, not secrets.** Write `${env:MY_TOKEN}` or `file:/run/secrets/token`, and the value is read at request time and **never written to your config**. A token typed in directly still works - the app tells you it's in plain text so you can migrate.

| Form | Meaning |
|---|---|
| `${env:VAR}` | Read environment variable `VAR` at request time |
| `file:/path/to/token` | Read the file's contents at request time |
| anything else | A plaintext literal - still honoured, and flagged in the UI |

*Implemented in [`core/src/secrets.rs`](core/src/secrets.rs).*

---

## Privacy, enforced rather than asserted

Most apps promise they don't phone home. EdgeHub's design makes the promise checkable.

- **One audited egress gate.** Every outbound request goes through [`NetHub.request()`](ui/qml/widgets/NetHub.qml) - the only place in the QML tree that may construct a network call. It owns a **global offline kill switch**, a **per-host allowlist**, and **per-host counters** for what was actually sent.
- **A lint enforces it.** [`scripts/check_no_raw_xhr.sh`](scripts/check_no_raw_xhr.sh) fails if any file outside the gate constructs its own request, and also fails if the gate stops being the one construction site. It runs as a suite in [`scripts/run_all_tests.sh`](scripts/run_all_tests.sh). There is no exemption list - an exception there would be a hole in the claim, not a lint detail.
- **Unknown schemes are refused, not guessed.** The gate recognises a fixed set of local forms (`file:`, `qrc:`, bare paths). Anything else is egress. An earlier shape treated every unknown scheme as local, so a `webcal://` calendar URL skipped both the kill switch and the allowlist - that class of bug is now structurally impossible.
- **The Rust core has no network stack at all.** "No outbound" is true there by construction, not by policy.
- **Your config stays yours.** Plain TOML at `~/.config/xeneon-edge-hub/config.toml`, written atomically and **owner-only (`0600`) at creation** - not chmod'd afterwards, so a credential is never briefly world-readable.
- **No telemetry, no account, no cloud.** EdgeHub touches the network only for widgets you explicitly configure - Weather, a Calendar feed, or a data widget you pointed somewhere. All of it through the same gate.

### Performance

No passing CPU or memory number is claimed for the stable release. A
historical 2026-07-21 run measured a then-current dirty development binary:
startup and average CPU met that run's targets, while peak RSS failed. Those
numbers describe only that obsolete dirty binary. The release owner waived the
planned 30-minute, 14-widget instrumented observation and the historical
48-hour soak. They are reported as not run, not as passes, and this release
makes no formal performance or long-duration stability claim.

---

## Make it yours

- **29 themes** - 20 free themes and 9 optional Pro themes, including dark,
  light, OLED, high-contrast, Nord, Dracula, Gruvbox, Catppuccin, Synthwave and more.
- **29 accent colors** - 14 standard tones, the 8 published **Okabe–Ito**
  colors, and 7 theme-completing accents.
- **10 animated backgrounds plus Gradient** - orbs, waves, starfield, mesh,
  aurora, bokeh, grid, Arch Peaks, Fedora Loops and Aubergine Ribbons - plus
  static wallpapers, settable globally or per page.
- **Glass, glow, and a reduced-motion mode.** One shared design system keeps every widget consistent.
- **Comfortable text by default.** Every widget shares a legibility floor, with
  Compact, Comfortable, Large, and Extra large choices plus bundled Atkinson
  Hyperlegible and Lexend typefaces.
- **Standard or Immersive Hub controls.** Immersive mode removes the Hub navigation bar and gives that space back to widgets while keeping each widget's own configuration available. Manager can restore Standard mode at any time.
- **Edit mode** to add, remove, move and resize tiles across multiple pages, with schema-driven per-widget configuration.
- **First-run wizard**, on-device **Settings**, and a **Diagnostics** screen.

![EdgeHub Manager changing the live Hub theme](docs/marketing-site/assets/release/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-live-theme-control.png)

![Twenty Free EdgeHub themes shown through EdgeHub Manager](docs/marketing-site/assets/release/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-manager-theme-sheet.png)

*The live-sync and theme-control frames come from the final beta.1 Product Film,
rendered from the exact signed Hub and Manager binaries.*

### EdgeHub Manager

A companion desktop app (`xeneon-edge-manager`) that mirrors your Edge in real time over a control socket, with Dark / Light / Default chrome:

| Tab | What it does |
|---|---|
| **Screens** | Preview real widgets before adding a screen, then arrange and resize them on the same packed geometry as the Hub |
| **Look** | Themes, accents, backgrounds, text size, typeface, Manager chrome, glass and glow with a live Hub preview |
| **Images** | Wallpapers and per-widget imagery |
| **Device** | Pick and orient the target screen, control startup and update checks |
| **About** | Version and project info |

---

## Install

The latest published release is
**[v1.0.0](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0)**.
The release page provides a bundled AppImage plus native DEB and RPM packages.
Only files attached to that release are availability claims.

### Current checkout on CachyOS or Arch

For a developer installation of exactly the checked-out source, use the guarded
local updater:

```sh
./scripts/update-local.sh
```

It builds a fresh pacman package, creates a checksum-recorded owner-only
configuration backup, stops Manager and Hub before replacement, installs with
`pacman -U`, verifies both installed binary identities, starts the Hub, and
restores the Manager only if it was open before the update. A dirty-tree install
is labelled `-dirty` and remains development evidence.

### Stable AppImage, DEB and RPM

Download the package for your system plus `SHA256SUMS` and `SHA256SUMS.asc`
from the [v1.0.0 release](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0).
Verify the signed checksums before installation.

```sh
# Portable AppImage
chmod +x xeneon-edge-hub-1.0.0-x86_64.AppImage
./xeneon-edge-hub-1.0.0-x86_64.AppImage

# Ubuntu 26.04
sudo apt install ./xeneon-edge-hub_1.0.0_amd64.deb

# Fedora 43
sudo dnf install ./xeneon-edge-hub-1.0.0-1.x86_64.rpm
```

The native packages install both Hub and Manager. Package installation never
starts Manager. The AppImage starts Hub by default and accepts `--manager` when
you deliberately want the companion application.

### CachyOS / Arch Linux, current source

Until a stable AUR package is published, build and install the current checkout
with the guarded local updater:

```sh
./scripts/update-local.sh
```

The committed AUR recipe remains pinned to the historical signed
`v1.0.0-beta.1` source asset. It is not the stable 1.0 package.

### Historical beta.1 Arch recipe

The committed Arch recipe is pinned to the signed `v1.0.0-beta.1` source asset.
Build the package from that signed source, close both product applications, and
install it as a normal pacman upgrade. Do not remove the old package first:

```sh
cd /path/to/skyphoenix-edgehub-linux
gpg --import packaging/edgehub-signing.pub
(cd packaging/aur && makepkg -Csf)

sudo pacman -U packaging/aur/xeneon-edge-hub-1.0.0beta1-2-x86_64.pkg.tar.zst
/usr/bin/xeneon-edge-hub --version
```

The final command must print `Xeneon Edge Linux Hub 1.0.0-beta.1`. The Manager
is installed by the same package but is not started by this procedure.

### Historical beta.1 portable tarball

Download `xeneon-edge-hub_1.0.0-beta.1_x86_64.tar.gz`, `SHA256SUMS` and `SHA256SUMS.asc` from the [release page](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0-beta.1), then:

```sh
gpg --verify SHA256SUMS.asc SHA256SUMS   # key import: see "Verifying your download"
sha256sum -c SHA256SUMS
tar -xf xeneon-edge-hub_1.0.0-beta.1_x86_64.tar.gz
```

The tarball is a relocatable `/usr` payload, not a self-contained bundle: its
binaries use the build host's glibc floor and the target system's Qt 6.9+
libraries. The current maintainer build requires glibc 2.39 or newer. After
extracting, run the Hub or Manager from the archive's `usr/bin/` directory, or
use a native package only when that exact release lists the distribution as
supported. An AppImage, when attached to a release, bundles Qt for systems that
do not provide a compatible version.

The historical signed beta.1 recipe lives in
[`packaging/aur/PKGBUILD`](packaging/aur/PKGBUILD). Its presence does not imply
that a current package has been published to the AUR. The command above builds
the pinned recipe locally from the signed release source. (`v1.0.0-alpha.1`
remains unsigned because it predates the release key.)

### Verifying your download

The `v1.0.0` release provides `SHA256SUMS` alongside a detached
`SHA256SUMS.asc`, made with the EdgeHub release key. (`v1.0.0-alpha.1` predates
the key and is checksum-only - it has no `.asc`.)

**1. Import the key.** Retrieve it from a public keyserver, GitHub, or the
repository:

```sh
gpg --keyserver hkps://keys.openpgp.org \
  --recv-keys 2F0CAD36DC1D46F3347B7EF293CDC77EACF98990
curl -sL https://github.com/SimonKreitmayer.gpg | gpg --import   # from GitHub
gpg --import packaging/edgehub-signing.pub                        # from a clone
```

**2. Verify the signature, then the files:**

```sh
gpg --verify SHA256SUMS.asc SHA256SUMS   # is the checksum list authentic?
sha256sum -c SHA256SUMS                  # do the files match the list?
```

`gpg --verify` must say **Good signature** for this fingerprint:

```
SKYPhoenix IT <simon.kreitmayer@skyphoenix-it.com>
2F0C AD36 DC1D 46F3 347B  7EF2 93CD C77E ACF9 8990
```

**Check the fingerprint, not just the words "Good signature."** Any key can produce a good signature over anything - including one an attacker made and shipped next to a tampered download. The signature is only worth what the fingerprint is, so compare it against the line above (published here, in [`packaging/edgehub-signing.pub`](packaging/edgehub-signing.pub), and on [GitHub](https://github.com/SimonKreitmayer.gpg)).

gpg will also warn `This key is not certified with a trusted signature`. That is expected and not a failure: it means you haven't personally certified the key. Trust here rests on the fingerprint matching, not on the web of trust.

Policy, scope and key rotation: [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md#release-signing).

### Everything else

Build from source below. AUR, AppImage, Flatpak, DEB and RPM routes are authored
in this repository, but no format is a verified stable artifact until its exact
release SHA and exact bytes pass the gates in
[`packaging/README.md`](packaging/README.md). Do not infer current-candidate
status from the presence of a recipe or an older green workflow.
The exact 1.0 desktop, display, architecture, input, and package support boundary
is documented in the
[EdgeHub 1.0 support contract](docs/DISTRIBUTION.md#edgehub-10-support-contract).

---

## Build from source

### Prerequisites

- **Rust** 1.86+ (the minimum declared by the locked Rust graph)
- **C++17 compiler** (GCC 12+ or Clang 16+)
- **CMake** 3.22+
- **Qt 6.9+** with Qt Quick, Quick Controls, DBus, Network, SVG and Wayland
  support

**Arch / CachyOS**

```sh
sudo pacman -S --needed base-devel git rust cmake qt6-base qt6-declarative \
  qt6-svg qt6-wayland
```

**Ubuntu 26.04 LTS**, the exact native Ubuntu target:

```sh
sudo apt install git cargo cmake make g++ qt6-base-dev qt6-declarative-dev \
  qt6-svg-dev libgl1-mesa-dev
```

Ubuntu 24.04's apt Qt 6.4.2 is below the project floor. Use a release
AppImage when one is offered, or install an upstream Qt 6.9 or newer toolchain;
the repository does not claim native Ubuntu 24.04 package support.

### Build & run

```sh
git clone https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
cd skyphoenix-edgehub-linux
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

./build/xeneon-edge-hub          # the on-device hub
./build/xeneon-edge-manager      # the companion Manager
```

`--reset` loads fresh defaults; `--reset-wizard` re-triggers the first-run wizard.

### Test

```sh
cd core && cargo test --locked  # Rust core
./scripts/run_ui_tests.sh    # QML GUI suite (offscreen, compiled product assets)
./scripts/run_all_tests.sh   # everything: Rust + QML + ctest + requirements matrix + lints
```

---

## Architecture

```
Rust core (config · EDID · metrics · FFI)  ──C ABI──▶  Qt 6 / QML (hub + Manager)
                                                         │
                    local TOML config ◀── control-socket IPC · single-instance
```

- **Rust core** owns configuration, EDID display identity, and system metrics, and exposes a stable, hand-written C ABI. It has no network stack.
- **Qt 6/QML** renders both the hub and the Manager on top of that core. Widgets are declared once in a registry and reused by the grid, the expanded overlay, and the add-widget picker.
- The hub and Manager talk over a **control socket** (`QLocalServer`), which is how the Manager pushes a live layout to a running hub. The app is **single-instance**.

Further reading: [architecture overview](docs/architecture/overview.md) · [ADR 0001 - application stack](docs/adr/0001-application-stack.md) · [ADR 0002 - widget runtime](docs/adr/0002-widget-runtime.md).

---

## Quality

The repository includes all of these verification layers:

| Layer | Result |
|---|---|
| **Real hardware** ([`tests/hardware/`](tests/hardware/README.md)) | Widget/catalog drift, portrait/landscape rendering, Manager-to-Hub integration, guarded synthetic touch and soak scenarios on a physical Edge |
| **Rust** | Unit tests, formatting, Clippy and coverage gate |
| **C++** | QtTest suites against the real core plus a coverage gate |
| **QML** | Offscreen and compositor-backed GUI suites plus a finite enumerated-requirements matrix that requires every listed requirement to be assertion-backed |
| **Lints** | Egress lint (no raw request outside the gate) and a widget-icon lint |
| **Runtime E2E** | Drives the real hub binary headless and asserts what it persists to `config.toml` |

The intended CI gate runs Rust format, Clippy, tests and dependency checks; the
build; docs/link checks; QML and C++ suites; independent Rust and C++ line
coverage at ≥95%; and the all-assertion-backed QML requirements checklist - see
[`.github/workflows/ci.yml`](.github/workflows/ci.yml). The hardware suite needs a
physical Edge and therefore runs locally. A working-tree run is development
evidence, not a release certificate. The stable release notes distinguish every
passed, waived, cancelled, and not-run gate. Full plan:
[`docs/DEV_AND_TEST_PLAN.md`](docs/DEV_AND_TEST_PLAN.md).

The hardware suite asserts its widget list against `WidgetCatalog.qml`, so a new widget cannot go silently unexercised - a drift check added after the list had quietly omitted two widgets while still reporting green.

---

## Release status

Version 1.0.0 is the latest published build. The release deliberately does not
claim the following:

- **No Flatpak or stable AUR package.** The published channels are AppImage,
  Ubuntu 26.04 DEB, and Fedora 43 RPM. The committed AUR recipe remains pinned
  to beta.1, and the Flatpak recipe is development material only.
- **No formal performance or long-soak claim.** The release owner accepted the
  stable release without the planned 30-minute observation or 48-hour soak, and
  earlier development RSS results do not support a release performance claim.
- **No formal physical-touch certificate.** The owner confirmed that physical
  panel input works, but the scripted nine-action manual audit was not completed
  and is reported as not tested rather than passed.
- **The current defaults are selected, not pending:** Nord, Atkinson Hyperlegible,
  animated background and widget glow off, with normal transitions on and a
  separate reduce-motion preference. Legal review of the Inspired themes and any
  payment/store delivery route remain open before a paid offering.
- **Weather and Calendar reach the network** for the feeds you configure - as designed, through the same audited gate as everything else.
- **The Manager follows a single-writer rule.** While the Hub is connected,
  display/autostart changes go over the control socket and the Hub persists them;
  the Manager writes directly only while it is the offline owner.
- **Physical rotation** is wired and debounced from the HID sensor. Automated
  orientation and Manager-reflection behavior is covered; a completed signed
  physical-turn audit is not claimed for this release.
- **GPU detail depends on the Linux driver.** AMD, Intel and NVIDIA devices are
  discovered through DRM sysfs, but a driver may not expose every utilization,
  temperature, power, clock, fan or VRAM value.

---

## Roadmap

Version 1.0 contains 30 widgets, 19 presets, the Manager, and expanded test and
release tooling. The next milestone is evidence-led: address stable-release
feedback, add a stable AUR package, finish Flatpak validation, and collect the
performance and physical-touch evidence that 1.0 deliberately does not claim.

Beyond 1.0: segment integration packs (OBS, MangoHud, Prometheus, smart home, market data), a WASM widget SDK, and internationalization.

Full plan: **[ROADMAP.md](ROADMAP.md)** · changes: **[CHANGELOG.md](CHANGELOG.md)** · overview: [`docs/marketing-site/index.html`](docs/marketing-site/index.html).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Bug reports are especially welcome - please say what broke and on what hardware.

## Security

See [SECURITY.md](SECURITY.md) for the security policy and how to report a vulnerability.

## License

Dual-licensed under either of:

- **MIT License** ([LICENSE-MIT](LICENSE-MIT) · <http://opensource.org/licenses/MIT>)
- **Apache License 2.0** ([LICENSE-APACHE](LICENSE-APACHE) · <http://www.apache.org/licenses/LICENSE-2.0>)

at your option.

**Qt licensing note:** Qt modules do not all use the same open-source licence.
EdgeHub does not import, link, package, or require Qt Virtual Keyboard. Text
entry uses a physical keyboard or an input method supplied independently by the
desktop environment. Review the exact dynamically linked and bundled Qt
inventory for each release artifact against the official
[Qt licensing table](https://doc.qt.io/qt-6/licensing.html).

**Bundled fonts:** the selectable typeface options include [Atkinson Hyperlegible](https://github.com/googlefonts/atkinson-hyperlegible) (© Braille Institute of America) and [Lexend](https://github.com/googlefonts/lexend) (© The Lexend Project Authors); the brand wordmark uses [Chakra Petch](https://fonts.google.com/specimen/Chakra+Petch) (© The Chakra Petch Project Authors); the default UI face is [Inter](https://github.com/rsms/inter) (© The Inter Project Authors); and tabular readouts (timers, metric values) use [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (© The JetBrains Mono Project Authors). Inter and JetBrains Mono are bundled so the interface and its fixed-pitch digits render identically on every machine, rather than depending on what the local fontconfig happens to resolve. All five are bundled unmodified under the SIL Open Font License 1.1. Their OFL texts ship in both [`assets/fonts/`](assets/fonts/) and installed packages (`LICENSE-OFL-AtkinsonHyperlegible.txt`, `LICENSE-OFL-ChakraPetch.txt`, `LICENSE-OFL-Inter.txt`, `LICENSE-OFL-JetBrainsMono.txt`, `LICENSE-OFL-Lexend.txt`).

**Bundled icons:** the interface includes SVGs derived from [Phosphor Icons core](https://github.com/phosphor-icons/core), Copyright (c) 2023 Phosphor Icons, under the MIT License. The exact upstream notice is stored at [`assets/icons/LICENSE-MIT-PhosphorIcons.txt`](assets/icons/LICENSE-MIT-PhosphorIcons.txt) and accompanies every installed package.

**Rust dependencies:** the native binaries include lockfile-pinned crates under
MIT, Apache-2.0, BSD-3-Clause, Unicode-3.0 and MPL-2.0 terms. Some crates also
offer the Unlicense as an alternative. The generated
[`THIRD_PARTY_NOTICES-RUST.txt`](packaging/THIRD_PARTY_NOTICES-RUST.txt)
records every reachable package, SPDX expression, source URL and exact notice
text, and accompanies every native package.

App-id: `com.skyphoenix_it.XeneonEdgeHub` · Companion: `com.skyphoenix_it.XeneonEdgeManager`

---

## Not affiliated with Corsair

EdgeHub is an independent product of SKYPhoenix IT. It is **not affiliated with, sponsored by, or endorsed by Corsair.** "Corsair" and "Xeneon Edge" are used only to describe hardware compatibility.
