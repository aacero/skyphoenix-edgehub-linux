# Manager display safety correction, 2026-07-22

## Finding

The Manager startup policy attempted to choose a non-Edge output before showing
the QML window. Its final fallback returned without choosing a target when every
detected output matched the Edge, after which startup still made the window
visible. Qt could therefore map the Manager on the Edge.

The locally installed package was also older than the current repository build:

- installed package: `1.0.0.alpha.2.r246.g684cddb-1`;
- installed Manager: `v1.0.0-alpha.2-246-g684cddb-dirty`.

## Correction

- Extracted the screen classification and safe-target selection into
  `manager/src/manager_display_policy.h`.
- Changed Edge-only startup from a permissive fallback to exit code 2 without
  mapping the Manager window.
- Added a runtime guard that hides and exits if the compositor assigns the
  mapped Manager window to an Edge output.
- Kept the existing preference for the primary desktop output, followed by the
  first available non-Edge output.
- Moved all Manager theme and accent capture to a private Xvfb display. That
  capture path starts no Hub and touches no physical output or input device.

## KDE Wayland follow-up, 2026-07-26

Real-hardware validation found a second placement failure. KWin mapped the
Manager's first native Wayland surface on the active DP-3 output even though Qt
had selected and logged DP-1 before showing the window. The runtime guard hid
and closed the Manager, so it did not remain visible on the Edge, but the
Manager was unusable and its backend had already started.

Wayland intentionally does not provide ordinary top-level clients with a
portable first-output placement API. For KDE Wayland sessions with XWayland
available, the Manager now selects Qt's `xcb` platform before constructing
`QGuiApplication`. X11 geometry is enforceable, so the existing non-Edge target
selection can place the first frame on the desktop monitor. This applies only
when `QT_QPA_PLATFORM` is unset; explicit platform choices, offscreen tests,
non-KDE desktops, and non-Wayland sessions are unchanged. The Hub remains
native Wayland.

## Focused verification

- `xeneon-edge-manager` Release build: PASS.
- `manager_display_policy`: 3 focused QtTest cases, PASS.
- Fixed-height Manager sidebar proof at 1000 and 1300 pixels: PASS.
- No physical Manager launch was used for this correction.

The corrected local package still requires an interactive privileged package
installation before it replaces `/usr/bin/xeneon-edge-manager` on this PC.
