#!/usr/bin/env python3
"""manager_drag_reorder_test.py - drag a tile onto another to REORDER it, for real.

The last untested interaction. The Manager's own help text says "Drag a tile onto
another to reorder", and tests/ui/tst_edgeclone_drag.qml exercises it OFFSCREEN -
i.e. exactly where pointer physics do not exist. Nothing had ever performed a
real press-move-release on the real Manager and checked the order on the real hub.

Seeds three visually distinct widgets in a known order, drags the FIRST onto the
LAST with a real pointer drag, and asserts the hub's tile order actually changed
- and changed to something sane (same three tiles, none lost or duplicated).

Safety: identical to the other desktop tests (XENEON_HW_INPUT_DESKTOP gate, clamp
to the Manager window rect, idle kill switch). Portrait is pinned so the preview
is the tall left column and the tile centres are predictable.

Run:
    XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 \\
        python3 tests/hardware/manager_drag_reorder_test.py
"""
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import desktop_target as dt          # noqa: E402
import input_guard                   # noqa: E402
import uinput_touch as u             # noqa: E402
import manager_window as mw          # noqa: E402
from e2e_harness import (E2E, MANAGER, assert_binaries_current,  # noqa: E402
                         doc, page)

SIDEBAR_SCREENS = (0.059, 0.126)
# Tile centres inside the portrait preview (left column). Three 1x1 tiles stack
# vertically; measured from the Screens-tab captures.
TILE_X = 0.335
TILE_Y = (0.27, 0.45, 0.63)


def order_of(st):
    pages = (st or {}).get("pages", []) or []
    if not pages:
        return []
    return [t.get("id") for t in (pages[0].get("tiles") or [])]


def main():
    for gate in (u.require_gate, dt.require_desktop_gate):
        try:
            gate()
        except Exception as e:  # noqa: BLE001
            print("!!", e); return 2
    try:
        print("  binaries under test: %s" % assert_binaries_current())
    except RuntimeError as e:
        print("!!", e); return 2

    work = tempfile.mkdtemp(prefix="mgr-drag-")
    h = E2E(workdir=work)
    mgr = None
    try:
        app = {"themeMode": "nord", "accent": "#58A6FF", "bgStyle": "none",
               "animatedBg": False, "glass": 0.55, "glow": False,
               "gridCols": 1, "orientation": "portrait"}
        tiles = [{"id": "t-cpu", "type": "cpu", "size": "1x1"},
                 {"id": "t-gpu", "type": "gpu", "size": "1x1"},
                 {"id": "t-ram", "type": "ram", "size": "1x1"}]
        h.write_config(doc([page("Home", tiles)], appearance=app))
        if not h.launch_hub() or not h.verify_target_window():
            print("!! hub not verifiably on the Edge"); return 2
        h.set_state(doc([page("Home", tiles)], appearance=app))
        time.sleep(1.0)
        h.check("hub-up", h.ping(), "control socket answering")

        before = order_of(h.get_state())
        h.check("seed-order", before == ["t-cpu", "t-gpu", "t-ram"],
                "hub tile order before the drag: %s" % before)

        env = dict(os.environ)
        env["XDG_CONFIG_HOME"] = h.cfg
        env["XDG_RUNTIME_DIR"] = h.run_dir
        log = os.path.join(work, "manager.log")
        mgr = subprocess.Popen([MANAGER], env=env, stdout=open(log, "w"),
                               stderr=subprocess.STDOUT, start_new_session=True)
        rect = dt.manager_rect_from_log(log, timeout=20)
        if not rect:
            print("!! could not read the Manager window rect"); return 2
        dt.assert_rect_on_a_desktop_screen(rect, h.edge_name)
        name, x, y, w, hgt = rect
        print("  Manager window: %s %dx%d+%d+%d" % (name, w, hgt, x, y))
        if not mw.activate_exact_manager(mgr.pid, rect, work):
            print("!! exact Manager window could not be raised and verified")
            return 2

        guard = input_guard.ActivityGuard.connect()
        guard.require_user_idle()
        cw, ch = dt.canvas_size()
        p = u.VPointer(cw, ch, (x, y, w, hgt), guard=guard)
        # Device creation can itself cause compositor activity; require a
        # second idle proof before arming the structurally guarded sink.
        guard.require_user_idle()
        guard.arm()
        # OCCLUSION GUARD: the clamp confines events to the Manager's
        # rect but does not prove the Manager is the window receiving
        # them there. It was not, once: a browser raised itself over the
        # Manager and five clicks went into a docs page. Refuses to emit
        # unless a sidebar row carries the accent. See manager_window.py.
        p = mw.guard_pointer(p, rect, work, mgr.pid)

        def grab(tag):
            path = os.path.join(work, tag + ".png")
            full = dt._full_grab(work, tag)
            if full:
                from PIL import Image
                Image.open(full).crop((x, y, x + w, y + hgt)).save(path)
                os.unlink(full)
            return path

        p.tap(x + int(w * SIDEBAR_SCREENS[0]), y + int(hgt * SIDEBAR_SCREENS[1]))
        time.sleep(0.8)
        grab("00-before-drag")

        # The real drag: press on tile 1, move to tile 3, release. swipe() is
        # press -> stepped move -> release, which is what a reorder needs (a tap
        # would just select). Slow and many-stepped so the drag threshold and the
        # hover-target tracking both see it.
        def drag(fy_from, fy_to):
            p.swipe(x + int(w * TILE_X), y + int(hgt * fy_from),
                    x + int(w * TILE_X), y + int(hgt * fy_to),
                    steps=40, dur=1.4)
            time.sleep(1.2)

        drag(TILE_Y[0], TILE_Y[2])       # first tile onto the last
        grab("01-after-drag")

        after = order_of(h.get_state())
        print("  order: %s  ->  %s" % (before, after))

        # 1. The order actually changed - a drag that does nothing is the bug.
        h.check("drag-reordered-on-hub", after != before and len(after) == 3,
                "hub tile order after dragging tile 1 onto tile 3: %s" % after)
        # 2. And it stayed sane: same three tiles, none lost or duplicated.
        h.check("drag-preserved-all-tiles", sorted(after) == sorted(before),
                "same three tiles after the drag (no loss/duplication): %s" % sorted(after))
        # 3. Specifically, t-cpu is no longer first.
        h.check("dragged-tile-moved", (after[0] != "t-cpu") if after else False,
                "t-cpu is no longer the first tile (now %s)" % (after[0] if after else "?"))

        h.check("hub-alive-after", h.ping(), "hub still answering")
        print("\nframes in %s" % work)
        passed, total = h.summary()
        return 0 if passed == total else 1
    finally:
        if mgr:
            try:
                mgr.kill()
            except Exception:  # noqa: BLE001
                pass
        h.cleanup()


if __name__ == "__main__":
    sys.exit(main())
