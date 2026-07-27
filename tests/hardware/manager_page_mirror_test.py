#!/usr/bin/env python3
"""manager_page_mirror_test.py - the hub mirrors the Manager's selected screen (O1).

Owner-reported bug: "adding screens via the Manager always jumps to screen #1;
the hub never mirrors what is selected on the Manager - always screen #1."

Root cause was that nothing told the hub which screen the Manager had selected:
the protocol had no active-page concept, and the hub's SwipeView reset to page 0
on any structure change. Fixed by a setActivePage message (Manager -> hub) plus a
currentPage field in the getUiState reply (so it is observable).

This drives the REAL Manager and asserts on the REAL hub:
  * click each screen chip in the Manager -> the hub reports currentPage == that
    chip's index (the panel shows the selected screen), and
  * add a screen via the Manager -> the hub follows to the NEW screen, not 0.

Safety identical to the other desktop tests (XENEON_HW_INPUT_DESKTOP gate, clamp
to the Manager window rect, idle kill switch).

Run:
    XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 \\
        python3 tests/hardware/manager_page_mirror_test.py
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
                         doc, page, tile)

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

    work = tempfile.mkdtemp(prefix="mgr-mirror-")
    h = E2E(workdir=work)
    mgr = None
    try:
        # Four named screens, each with one distinguishable widget.
        pages = [page("Home", [tile("clock-1", "clock")]),
                 page("Two", [tile("cpu-1", "cpu")]),
                 page("Three", [tile("ram-1", "ram")]),
                 page("Four", [tile("net-1", "net")])]
        h.write_config(doc(pages))
        if not h.launch_hub() or not h.verify_target_window():
            print("!! hub not verifiably on the Edge"); return 2
        h.set_state(doc(pages))   # clear the probe tile
        h.check("hub-up", h.ping(), "control socket answering")

        # The hub must report a current page at all (proves the field is wired).
        cp0 = h.hub_current_page()
        h.check("hub-reports-current-page", cp0 >= 0,
                "getUiState currentPage = %s (>= 0 means the field is wired)" % cp0)

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

        def click(fx, fy, settle=0.6):
            p.tap(x + int(w * fx), y + int(hgt * fy)); time.sleep(settle)

        def grab(tag):
            path = os.path.join(work, tag + ".png")
            full = dt._full_grab(work, tag)
            if full:
                from PIL import Image
                Image.open(full).crop((x, y, x + w, y + hgt)).save(path)
                os.unlink(full)
            return path

        def wait_page(expect, timeout=4.0):
            """Poll the hub's reported page until it matches, or time out."""
            deadline = time.time() + timeout
            last = None
            while time.time() < deadline:
                last = h.hub_current_page()
                if last == expect:
                    return True, last
                time.sleep(0.2)
            return False, last

        grab("screens-tab")

        # ── select each screen chip; the hub must follow ────────────────────
        # Visit out of order so a pass cannot be "it was already there".
        for label, idx in [("Three", 2), ("Home", 0), ("Four", 3), ("Two", 1)]:
            mw.activate_exact_manager(mgr.pid, rect, work)
            invoked = mw.invoke_accessible(
                "Screen: " + label, manager_pid=mgr.pid
            )
            ok, got = wait_page(idx) if invoked else (False, h.hub_current_page())
            grab("select-%d-%s" % (idx, label))
            h.check("mirror-select-%s" % label, ok,
                    "invoked screen #%d (%s); hub currentPage = %s" % (idx, label, got))

        # ── add a screen via the Manager; the hub must follow to the NEW one ─
        # Select the last screen first so the add is unambiguous, then click the
        # "+" chip (just right of the last screen chip).
        mw.activate_exact_manager(mgr.pid, rect, work)
        mw.invoke_accessible("Screen: Four", manager_pid=mgr.pid)
        wait_page(3)
        n_before = len(h.get_state().get("pages", []))
        invoked = mw.invoke_accessible("Add screen", manager_pid=mgr.pid)
        time.sleep(1.0)
        n_after = len(h.get_state().get("pages", []))
        added = invoked and n_after > n_before
        ok, got = wait_page(n_after - 1) if added else (False, h.hub_current_page())
        grab("after-add-screen")
        h.check("mirror-add-lands-on-new-screen", added and ok,
                "screens %d -> %d, hub currentPage = %s (expected the new last "
                "screen %d, NOT 0)" % (n_before, n_after, got, n_after - 1))

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
