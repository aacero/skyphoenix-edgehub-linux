# Phase 0A Real Deployment Report

Date: 2026-07-22
Host: Simon's workstation
Session: KDE Wayland
Target: DP-3, XENEON EDGE, 2560x720 native mode, portrait geometry 720x2560,
scale 1

## Recovery points

- Before deployment:
  `/home/simon/.config/xeneon-edge-hub/config.toml.before-widget-upgrade.20260722-092017`
- Before deployment SHA-256:
  `e8b53409eb2ee55522921e998af5810e4bbbe48a940d7dbe07db456b627d398d`
- After the live Manager demonstration:
  `/home/simon/.config/xeneon-edge-hub/config.toml.after-live-demo.20260722-0934`
- Post-demo SHA-256:
  `07b51843557fd9c952976b88d39f727fab90dd45aefa9c43c39e51d079f85f55`

The package installation and first Hub restart preserved the original semantic
UI state. During the later live Manager session, the control socket received
real layout edits: one screen was added, tile sizes and settings changed, and a
wallpaper changed. Those edits were preserved as current user state and captured
in the post-demo backup.

## Installed candidate

- Package: `xeneon-edge-hub 1.0.0.beta.1.r11.g2526cf5-1`
- Package SHA-256 after the real-device correction:
  `6e52cf47c189719fe9676b3fd175d695798c3e6ccd7702e19d06e7b4a95e30fc`
- Embedded version: `v1.0.0-beta.1-11-g2526cf5-dirty`
- Installed Hub binary SHA-256:
  `c0395f98a2383428f2cc08a2950be99c1bf87f4b7f7a509e72676203e6a51003`
- The installed binary matches the packaged binary.
- `pacman -Qkk` reported 57 package files and 0 altered files.
- The package contains no Manager autostart entry.

## Real-device results

- Hub matched DP-3 by the configured XENEON EDGE model.
- Hub placed itself at `5120,2880`, using portrait geometry `720x2560`.
- Hub entered fullscreen on DP-3 and did not open on either primary monitor.
- The orientation sensor opened `/dev/hidraw4`.
- The control server opened
  `/run/user/1000/xeneon-edge-hub-ctl`.
- The Manager live preview matched the portrait Hub layout during the captured
  session.
- The Manager was closed after capture. Only `/usr/bin/xeneon-edge-hub` remained
  running at handoff.

## Finding fixed during deployment

The first real-device start reported eight instances of:

`HydrationWidget.qml: Unable to assign double to int`

The repeated droplet font size was backed by a real-valued layout token even
though `Text.font.pixelSize` requires an integer. `ovlDropPx` is now explicitly
integer-typed. The focused Hydration suite passed 54 tests with 0 failures and 0
fatal QML diagnostics. The package was rebuilt, reinstalled, and restarted. The
final real Hub log contains 0 instances of that warning.

## Deployment workflow finding

The first KDE administrator prompt followed the active fullscreen output and
appeared on DP-3. The transaction was not approved there. It was cancelled,
DP-2 was verified as the active output, and authorization was relaunched on the
main monitor. This concerns the local privileged deployment workflow, not Hub
window targeting.

A Manager process observed during the demonstration was owned by KDE's transient
desktop application service. No Manager autostart file, persistent user service,
or package-hook launch was found. It was closed normally after the screenshot.

## Visual evidence

- [Physical Edge, portrait](screenshots/phase0a-deployed/hub-real-edge-portrait-final.png)
- [Manager on the main monitor](screenshots/phase0a-deployed/manager-real-main-monitor-final.png)

Only the two isolated product captures are kept in the repository. Full-desktop
working captures were moved to the private temporary directory
`/tmp/edgehub-private-captures-20260722-0931` because they contained unrelated
desktop content.

## Remaining scope

Verified here: KDE Wayland, scale 1, portrait, installed-package restart,
display selection, fullscreen placement, orientation-device access, Manager live
connection, and normal Manager shutdown.

Not exercised in this deployment: landscape physical turn, fractional scaling,
KDE X11, GNOME Wayland, GNOME X11, hot-plug, reconnect, port change, primary
monitor change, display power cycle, suspend/resume, or missing configured
display. No claims are made for those scenarios from this run.

The final log retains two pre-existing Qt 6.11 member-name warnings for
`PopupList.contentWidth` and `DashboardStore.data`, plus the documented sensor
startup fallback when the panel rejects `GET_REPORT`. They did not affect display
placement or interaction in this run and remain recorded for later cleanup.
