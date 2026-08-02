---
name: product-decisions
description: "Simon's product decisions for the Xeneon Edge hub (scope, data sources, deps)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7a2d60a1-8c95-41e6-8b0e-230373ba9231
---

Decisions Simon confirmed for the big rebuild (mid-2026):

- **Real system data**: add GPU + Network + Disk metrics in Rust (done — amdgpu
  `gpu_busy_percent`/hwmon for the discrete card by largest VRAM; `/proc/net/dev` deltas
  excluding lo/veth/docker; `statvfs` on `/`). GPU/FPS "fake" widgets removed.
- **Media**: MPRIS/D-Bus "Now Playing" hub (controls Spotify desktop + YouTube Music in
  browser). A native in-app Spotify/YT-Music OAuth login client is explicitly a LATER phase,
  not the initial ask.
- **Internet is allowed** on the display → real Weather via Open-Meteo (no API key); live
  content OK.
- **Full touch edit mode** wanted (add/remove/reorder + persisted layout) AND honor the
  wizard's starter-layout. All interactive widget state must persist across restarts.
- **Focus Timer** must stay, feature-complete, with ADHD considerations. Also wanted: a good
  **Task tracker**, **Calendar** integration (ICS subscription approach), and other useful
  ADHD-oriented widgets (right-now single-focus card, notes, water/break, habit streak, etc.).
- **Dependency added with approval**: `libc` (for disk `statvfs`; no pure-std option). Ask
  before adding further crates (e.g. calendar `ureq`/`ical` still undecided — leaning to a
  no-dep QML ICS parse unless full RRULE fidelity is needed).

Constraint reminder: `core/xeneon_core.h` is hand-maintained — every new `#[no_mangle]` FFI
needs a matching header line. See [[dashboard-architecture]].
