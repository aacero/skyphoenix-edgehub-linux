---
name: v1-alpha-verification-state
description: "What's tested-green vs. what still needs Simon's on-device confirm on v1.0-alpha"
metadata: 
  node_type: memory
  type: project
  originSessionId: cc3f5c02-a801-4f39-936e-d4d0ed258239
---

On branch `v1.0-alpha` (local, unpushed), the FULL suite (`./scripts/run_all_tests.sh`)
is GREEN: Rust, QML GUI (run_ui_tests.sh), C++ ctest, QML behavior matrix 97.5% (gate ≥95%),
all lints, AppImage contract, all 9 Runtime E2E. Verified 2026-07-19.

Running the full suite surfaced two real regressions that renders/smoke had missed
(lesson: the offscreen QML suite catches parser/layout bugs screenshots can't):
- The "plain dashes" sweep (e4fd7d2) rewrote QuoteWidget's em-dash *parser* separator
  to ASCII — restored (keep sweeps off parser logic, only display text).
- The "joined segmented" ConfigField rework made segment chips <44px (0px when the
  parent has no resolved height) — chips now carry an explicit ≥44px height like the
  accent swatches. See [[dashboard-architecture]].

STILL OWED — on-device confirm by Simon via `./scripts/update-local.sh`:
- Add-page snap-back: fix is committed (goToPage → positionViewAtIndex(SnapPosition)
  + long sustained hold) and covered by tst_hub_navigation (7/7, real shell). But
  offscreen has no Wayland compositor, so it cannot reproduce the exact deferred-relayout
  snap — device confirmation required before calling it fixed.

KNOWN MINOR, not yet done (deliberately excluded to keep the green run valid):
- EdgeClone resize-handle overlaps a widget's bottom-right controls (Agent A bug 1) —
  cosmetic, no user report.
