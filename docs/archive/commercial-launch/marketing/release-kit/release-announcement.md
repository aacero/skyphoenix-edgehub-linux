# EdgeHub v1.0.0-beta.1 release announcement

> **Prepared copy.** Publish only after the signed artifacts and checksums are
> live at the release URL.

## EdgeHub v1.0.0-beta.1: a native Linux dashboard for the Xeneon Edge

EdgeHub v1.0.0-beta.1 is now available for the Corsair Xeneon Edge on
**CachyOS/Arch Linux with KDE Plasma on Wayland**. Portable x86-64 builds
require Qt 6.5 or newer.

**Leaving Windows behind? Your Edge can come with you.**

Watch the 71-second live product film:
https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-live-product-film.mp4

The camera pushes into the running Hub, turns the display smoothly from
landscape to portrait, then pulls back to show the separate Manager reflect the
same orientation. It follows Manager selecting screens, adding a screen and
widget, changing the page layout, applying a theme and accent, restyling
Manager, and updating a Device preference.

Your favorite features. Your chosen OS. Commissioned development and custom
widgets are available for workflows that need something more specific.

**Explore all 20 Free themes and ten accent looks:**
https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-manager-theme-showcase.mp4

Both videos include original sample-free ambient music created for EdgeHub.

This release turns the 2560×720 touch panel into swipeable dashboard pages with
live system, time, focus, media, data, and information widgets. You can arrange
the dashboard by touch on the panel or edit it from the companion EdgeHub
Manager on your main display. Manager changes are pushed to the running Hub over
a local socket, so the panel follows the screen, layout, orientation, and look
you are editing.

### What is included

- 30 first-party widgets and 19 ready-made preset screens;
- portrait and landscape layouts with widget-specific size treatments;
- desktop editing through EdgeHub Manager, including add, resize, reorder,
  appearance, image, and screen controls;
- 29 themes, 29 accents, 10 animated backgrounds plus Gradient, and 18 bundled
  wallpapers;
- local TOML configuration, no account requirement, and no telemetry
  implementation;
- a central egress gate for configured network widgets and the opt-in update
  check;
- source under MIT OR Apache-2.0.

### Free and Pro

Free contains the complete functional product: all 30 widgets, all 19 presets,
all layouts, backgrounds, wallpapers, accents, accessibility features, and the
full Manager.

Pro adds nine optional colour themes. It does not unlock widgets, data sources,
layout tools, or update access. Pro keys are not offered for sale in beta.1.

### Built around real panel workflows

The release work focused on the relationship between the physical Edge, the
Hub, and the Manager: display targeting and reconnect behavior, orientation,
screen selection, live reflection, capacity-aware resizing, drag reorder,
touch navigation, and recovery across restarts.

The release evidence includes 269 physical-Edge checks, 53 Manager/Hub
scenarios, 18 display-lifecycle scenarios, and 1,311 local compositor checks.
The release owner waived the planned 48-hour soak, and this beta makes no formal
performance or long-duration stability claim. Evidence is available at
https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/v1.0.0-beta.1/docs/testing/hardware-validation-2026-07-21.md.

### Download and documentation

- Download: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0-beta.1
- Live product film: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-live-product-film.mp4
- Theme and accent showcase: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/v1.0.0-beta.1/edgehub-v1.0.0-beta.1-manager-theme-showcase.mp4
- Release notes: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0-beta.1
- Installation: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/v1.0.0-beta.1/README.md#install
- Evidence and checksums: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/v1.0.0-beta.1/docs/testing/hardware-validation-2026-07-21.md
- Media evidence: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/blob/master/docs/testing/release-media-validation-2026-07-21.md
- Source and issues: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux
- Support: https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/issues

Supported release artifacts: signed source tarball and portable x86-64 tarball, with checksums and signatures.

### Independent project notice

EdgeHub is an independent product by SKYPhoenix IT. It is not affiliated with,
sponsored by or endorsed by Corsair. “Corsair” and “Xeneon Edge” are used only
to describe hardware compatibility.

---

Released on 2026-07-21. Media/contact: simon.kreitmayer@skyphoenix-it.com.
