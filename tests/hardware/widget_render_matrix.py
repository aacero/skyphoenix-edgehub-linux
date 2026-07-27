#!/usr/bin/env python3
"""widget_render_matrix.py - every widget type actually RENDERS on the real Edge.

The biggest remaining coverage gap. The offscreen suites prove each widget's
LOGIC and config; e2e_buildup proves that *something* renders. Nothing proved
that each of the 30 widget types individually draws correctly on the panel -
so a widget that silently fell back to "This widget isn't available", or drew
nothing at all, would pass every existing test.

For each widget type this puts it ALONE on the visible page, grabs the Edge, and
asserts two things:

  1. RENDERED - the frame differs from an empty-page baseline. Catches a widget
     that draws nothing.
  2. DISTINCT - no two widget types produce the same frame. This is what catches
     the fallback tile: a broken widget renders the SAME "isn't available" card
     regardless of type, so two broken widgets collide. It also catches a widget
     that renders as an empty card.

Both together are hard to satisfy accidentally: a widget must draw, and draw
something of its own.

Run:
    XENEON_HW_INPUT=1 python3 tests/hardware/widget_render_matrix.py
    # optional: XENEON_WIDGETS=cpu,gpu,clock  to spot-check a subset
"""
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import desktop_target as dt          # noqa: E402
from e2e_harness import (E2E, assert_binaries_current, doc, page)   # noqa: E402

# Every type in ui/qml/WidgetCatalog.qml.
ALL_WIDGETS = [
    "cpu", "gpu", "ram", "net", "disk", "sensors", "packages", "sinceinstall",
    "clock", "analog", "moon", "focus", "tasks", "rightnow", "notes", "habit",
    "hydration", "break", "meds", "braindump", "routine", "media", "httpjson",
    "kpi", "calendar", "nownext", "weather", "countdown", "eod", "quote",
]

# Grid resolution for the frame signature. 32x32, NOT 8x8: a 1x1 widget covers
# only ~a quarter of the tall portrait panel, so a coarse grid averages its
# change away - the first run of this file failed all 30 widgets that were in
# fact rendering perfectly. Measured at 32x32: every widget differs from the
# empty page by >=25, and the two most similar widgets still differ by 8.5.
GRID = 32
# A widget must move at least one grid cell this far vs the empty page. Uses the
# MAX cell delta, not the average - a small widget changes a few cells a lot and
# the rest not at all, which an average hides.
MIN_RENDER_DELTA = 25.0
# Two widgets closer than this are the same picture (the shared "isn't
# available" fallback, or two blank cards). Real closest pair measured at 8.5.
MIN_DISTINCT_DELTA = 4.0


def grid_sig(path, n=GRID):
    from PIL import Image
    im = Image.open(path).convert("RGB").resize((n, n))
    return [im.getpixel((x, y)) for y in range(n) for x in range(n)]


def sig_distance(a, b):
    """MAX per-cell colour distance between two frame signatures."""
    return max(sum((p - q) ** 2 for p, q in zip(pa, pb)) ** 0.5
               for pa, pb in zip(a, b))


def main():
    try:
        print("  binaries under test: %s" % assert_binaries_current())
    except RuntimeError as e:
        print("!!", e)
        return 2

    only = os.environ.get("XENEON_WIDGETS", "").strip()
    widgets = [w.strip() for w in only.split(",") if w.strip()] if only else ALL_WIDGETS

    audit_root = os.environ.get("XENEON_AUDIT_RUN_DIR", "")
    if audit_root:
        work = os.path.join(audit_root, "hardware-widget-render")
        os.mkdir(work, 0o700)
    else:
        work = tempfile.mkdtemp(prefix="widget-render-")
    h = E2E(workdir=work)
    try:
        app = {"themeMode": "nord", "accent": "#58A6FF", "bgStyle": "none",
               "animatedBg": False, "glass": 0.55, "glow": False,
               "gridCols": 1, "orientation": "portrait"}
        h.write_config(doc([page("Home", [])], appearance=app))
        if not h.launch_hub() or not h.verify_target_window():
            print("!! hub not verifiably on the Edge")
            return 2
        h.check("hub-up", h.ping(), "control socket answering")

        def grab(tag):
            p = os.path.join(work, tag + ".png")
            return p if h.grab(p) else None

        # Empty-page baseline, with a STATIC background so the only thing that
        # can change a frame is the widget itself.
        h.set_state(doc([page("Home", [])], appearance=app))
        time.sleep(1.2)
        base = grab("000-empty")
        if not base:
            print("!! could not grab the empty baseline")
            return 2
        base_sig = grid_sig(base)

        sigs = {}
        for i, wtype in enumerate(widgets, start=1):
            h.set_state(doc([page("Home", [{"id": "w-" + wtype, "type": wtype,
                                            "size": "1x1"}])], appearance=app))
            time.sleep(0.9)
            path = grab("%03d-%s" % (i, wtype))
            if not path:
                h.check("render-%s" % wtype, False, "no grab")
                continue
            sig = grid_sig(path)
            delta = sig_distance(sig, base_sig)

            # 1. It drew something.
            drew = delta >= MIN_RENDER_DELTA
            # 2. It drew something of its OWN (not the shared fallback card).
            twin = None
            for other, osig in sigs.items():
                if sig_distance(sig, osig) < MIN_DISTINCT_DELTA:
                    twin = other
                    break
            if not drew:
                why = ("did not render: frame differs from the EMPTY page by only "
                       "%.1f (need >=%.0f)" % (delta, MIN_RENDER_DELTA))
            elif twin:
                why = ("rendered the SAME picture as '%s' - almost certainly the "
                       "\"This widget isn't available\" fallback or an empty card"
                       % twin)
            else:
                why = "rendered, delta=%.1f from empty, distinct from all others" % delta
            h.check("render-%s" % wtype, drew and twin is None, why)
            sigs[wtype] = sig

        h.check("hub-alive-after", h.ping(), "hub still answering")
        print("\n%d frames in %s" % (len(sigs) + 1, work))
        passed, total = h.summary()
        return 0 if passed == total else 1
    finally:
        h.cleanup()


if __name__ == "__main__":
    sys.exit(main())
