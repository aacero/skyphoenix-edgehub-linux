# Email templates

## Release email

**Subject:** EdgeHub v1.0.0-beta.1 is available for the Xeneon Edge on Linux

**Preview text:** A native touch dashboard, 30 widgets, and live editing from
EdgeHub Manager.

Hello,

EdgeHub v1.0.0-beta.1 is now available for CachyOS/Arch Linux with KDE Plasma on Wayland; portable x86-64 builds require Qt 6.5 or newer.

EdgeHub turns the Corsair Xeneon Edge into swipeable, touch-first dashboard
pages. Choose from 30 first-party widgets and 19 preset screens, then arrange the
panel directly or edit it live from the companion desktop Manager.

Highlights:

- portrait and landscape layouts;
- live Manager-to-Hub editing, screen selection, resizing, and reorder;
- local configuration, no account, and no telemetry implementation;
- all widgets, presets, layout features, backgrounds, wallpapers, and the full
  Manager in Free;
- nine optional Pro colour themes.

Download v1.0.0-beta.1: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0-beta.1

Read the release evidence and checksums: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/v1.0.0-beta.1/docs/testing/hardware-validation-2026-07-21.md

Thank you to everyone who tested the real hardware, reported edge cases, and
helped make the release gates fail visibly.

- SKYPhoenix IT

EdgeHub is independent and is not affiliated with, sponsored by or endorsed by
Corsair.

## Contributor/tester thank-you

**Subject:** Thank you for helping test EdgeHub v1.0.0-beta.1

Hello,

EdgeHub v1.0.0-beta.1 has been published, and your testing helped close the gap
between “the UI opens” and “the real Hub, Manager, touch panel, reconnect path,
and release artifacts work together.”

The final evidence is here: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/v1.0.0-beta.1/docs/testing/hardware-validation-2026-07-21.md

If you have the release installed, the most useful follow-up feedback is:

- reconnect behavior, portrait layouts, and installation on other Qt 6.5+ distributions
- exact distro, desktop, session type, and display orientation;
- logs and reproduction steps with personal data removed.

Thank you,

SKYPhoenix IT

## Hold/update email (safe before release)

**Subject:** EdgeHub release update: integration green, publication gate still open

Hello,

The current EdgeHub development branch has completed its real Xeneon Edge and
Manager/Hub integration pass. It is not published as a new release yet.

The remaining release work is tracked at https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/master/docs/BETA_PLAN.md, including the
strict immutable-candidate gate, native package lifecycle, performance limits,
long hardware soak, published update round trip, and legal/business review.

We will send release links only after those checks are complete.
