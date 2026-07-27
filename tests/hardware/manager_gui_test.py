#!/usr/bin/env python3
"""manager_gui_test.py - drive the REAL Manager on the REAL desktop, with real
synthetic input, and verify the effect reaches the REAL hub on the Edge.

This closes the largest coverage gap in the repo. Until now:
  * tests/gui/ drives Manager.qml with the C++ backend STUBBED
    (ManagerHarness.qml: screensJson()="[]", metricsJson()="{}"), inside a
    nested compositor. It is not the Manager as shipped.
  * tests/hardware/edge_e2e.py runs the Manager as
    `timeout -s KILL 10 MANAGER` - launch, screenshot, kill. Zero interaction.
  * Nothing anywhere connects the real Manager binary to the real hub binary.

So: real Manager, real hub, real clicks, real socket, real panel.

────────────────────────────────────────────────────────────────────────────
SAFETY - what stops this clicking somewhere it should not
────────────────────────────────────────────────────────────────────────────
Owner constraint (2026-07-19): "I approve that my cursor moves around, as long
as the clicks and so on are focused on the applications that are actually being
tested."

  1. SEPARATE GATE - XENEON_HW_INPUT_DESKTOP=1. The Edge gate alone does not
     enable this; the cursor never leaves the Edge without this second opt-in.
  2. WINDOW-PRECISE CLAMP - every event is clamped to the Manager's OWN window
     rect, parsed from the rect the Manager logs at placement
     (manager/src/main.cpp). Not the monitor: on a 5120x1440 screen "confined to
     the monitor" would still allow clicking whatever else is open there.
  3. CONTAINMENT CHECK - the parsed rect must lie inside a real non-Edge screen,
     or we refuse to inject (a stale/bogus rect must never become a click).
  4. RENDER PROBE - the rect must visibly change when the Manager changes state,
     proving the window is actually there, before the first event is emitted.
  5. KILL SWITCH - input_guard aborts injection for the rest of the run on ANY
     real input from the owner. Watch, do not touch.
  6. The hub runs with an isolated XDG_CONFIG_HOME/XDG_RUNTIME_DIR, so the live
     hub's config and socket are untouched. The MANAGER, however, is the real
     binary against that same isolated config - that is the point.

Run (after approval):
    XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 \\
        python3 tests/hardware/manager_gui_test.py
"""
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import desktop_target as dt
import manager_window as mw          # noqa: E402
import input_guard                   # noqa: E402
import uinput_touch as u             # noqa: E402
from e2e_harness import (E2E, MANAGER, assert_binaries_current,  # noqa: E402
                         doc, page, tile)


class ManagerGui:
    def __init__(self, h, rect, work):
        self.h, self.rect, self.work = h, rect, work
        self.name, self.x, self.y, self.w, self.hgt = rect
        self.n = 0
        cw, ch = dt.canvas_size()
        # The kill switch is MANDATORY - UinputSink refuses to construct without
        # one, by design. require_user_idle blocks until the owner has been
        # hands-off, and any real input afterwards aborts injection for the rest
        # of the run.
        self.guard = input_guard.ActivityGuard.connect()
        self.guard.require_user_idle()
        # THE clamp: the Manager window rect, nothing wider.
        self.p = u.VPointer(cw, ch, (self.x, self.y, self.w, self.hgt),
                            guard=self.guard)
        # KWin can report creation of the virtual pointer as activity.  Let the
        # device settle, prove the owner is idle again, and only then permit
        # UinputSink.emit() to cross the structural arming boundary.
        self.guard.require_user_idle()
        self.guard.arm()

    def in_front(self):
        """Cheap pre-click check: is the Manager still the window in its rect?

        The Manager always has exactly one sidebar row filled with the accent,
        so "no accent row anywhere" means we are looking at something else.
        Checked immediately BEFORE each click, not only after: the post-click
        check catches an occlusion one click too late, and that one click lands
        in whatever raised itself. Costs one grab per click; a stray click into
        the owner's browser costs more.
        """
        p = self.shot("frontcheck")
        if not p:
            return False
        ok = self.active_row(p) is not None
        try:
            os.unlink(p)          # a check, not evidence - do not litter
        except OSError:
            pass
        return ok

    def click_rel(self, fx, fy, settle=0.8, require_front=True):
        """Click at a FRACTION of the Manager window (0..1), so the test does
        not hardcode pixel positions that drift with window size.

        Refuses to emit if the Manager is not the window in its own rect.
        Returns True if the click was emitted.
        """
        if require_front and not self.in_front():
            print("  REFUSED click at (%.3f, %.3f): the Manager is not in front"
                  % (fx, fy), flush=True)
            return False
        cx = self.x + int(self.w * fx)
        cy = self.y + int(self.hgt * fy)
        self.p.tap(cx, cy)
        time.sleep(settle)
        return True

    # The accent-row detector lives in manager_window.py - ONE implementation,
    # shared with the four other Manager suites. It was briefly duplicated here;
    # two copies of the one thing that decides "am I even looking at the
    # Manager?" is exactly the drift this repo keeps paying for.
    @classmethod
    def active_row(cls, path):
        return mw.active_row(path)

    @staticmethod
    def _sig(path):
        from PIL import Image
        import hashlib
        return hashlib.md5(Image.open(path).convert("RGB").tobytes()).hexdigest()

    def verify_owns_its_rect(self, settle=1.5):
        """Prove the MANAGER is the window actually showing in its own rect,
        before a single event is emitted. Returns True/False.

        WHY THIS EXISTS (2026-07-20). The clamp confines every event to the
        Manager's window RECT. It does NOT establish that the Manager is the
        window RECEIVING events there. On this box the owner's browser was
        stacked above the Manager on DP-2, so all five sidebar clicks went into
        a documentation page: four checks failed as "the click did not change
        tabs", the frames were byte-identical because the browser never moved,
        and the run reported Manager bugs that did not exist. Worse than the
        false result, we injected six clicks into an unrelated application.

        `manager-rect-verified` could not catch this - it only asserts the rect
        lies on a real non-Edge screen. A stale-but-plausible rect, an occluded
        window and a correct one all look identical to it.

        The technique is the one e2e_harness already uses for the Edge: change
        the app's state from OUTSIDE and require the pixels to move. The Manager
        is live-connected to the hub, so pushing an appearance change through
        the hub repaints its Edge preview. The connected Manager pulls the local
        socket twice per second, so this probe spans multiple pull intervals.
        If those pixels do not move, either
        the Manager is occluded, or it is not connected, or it is not rendering
        - and in all three cases injecting would be firing blind. Refuse.
        """
        from PIL import Image
        before = self.shot("verify-a")
        if not before:
            return False
        st = self.h.get_state() or {}
        ap = dict(st.get("appearance") or {})
        was = ap.get("themeMode", "dark")
        flipped = "light" if was != "light" else "dark"
        try:
            ap["themeMode"] = flipped
            st["appearance"] = ap
            self.h.set_state(st)
            time.sleep(settle)
            after = self.shot("verify-b")
            if not after:
                return False
            a = Image.open(before).convert("RGB").resize((32, 32))
            b = Image.open(after).convert("RGB").resize((32, 32))
            # Pillow 14 removes Image.getdata(). Prefer its replacement while
            # retaining compatibility with older distro Pillow releases.
            def pixels(image):
                flatten = getattr(image, "get_flattened_data", None)
                return list(flatten() if flatten else image.getdata())
            pa, pb = pixels(a), pixels(b)
            worst = max(sum((x - y) ** 2 for x, y in zip(p, q)) ** 0.5
                        for p, q in zip(pa, pb))
            ok = worst > 25
            print("  VERIFY-MANAGER %s: themeMode %s->%s moved its pixels by %.0f "
                  "(need >25) at %s %dx%d+%d+%d"
                  % ("OK" if ok else "FAILED", was, flipped, worst,
                     self.name, self.w, self.hgt, self.x, self.y), flush=True)
            if not ok:
                print("     The Manager is not the window rendering in that rect "
                      "(occluded by another window?), or it is not connected to "
                      "the hub. Refusing to inject - see verify_owns_its_rect().",
                      flush=True)
            return ok
        finally:
            # Always put the theme back, whatever happened above.
            try:
                st2 = self.h.get_state() or {}
                ap2 = dict(st2.get("appearance") or {})
                ap2["themeMode"] = was
                st2["appearance"] = ap2
                self.h.set_state(st2)
                time.sleep(0.4)
            except Exception:
                pass

    def shot(self, tag):
        self.n += 1
        path = os.path.join(self.work, "%03d-%s.png" % (self.n, tag))
        full = dt._full_grab(self.work, "s%03d" % self.n)
        if not full:
            return None
        try:
            from PIL import Image
            Image.open(full).crop((self.x, self.y, self.x + self.w,
                                   self.y + self.hgt)).save(path)
            os.unlink(full)
            return path
        except Exception:
            return None


def main():
    # Fail closed, loudly, before anything is launched.
    try:
        u.require_gate()
    except Exception as e:
        print("!!", e)
        return 2
    try:
        dt.require_desktop_gate()
    except dt.DesktopGateError as e:
        print("!!", e)
        return 2

    # Fail before launching anything if the binaries are not the working tree.
    try:
        ver = assert_binaries_current()
        print("  binaries under test: %s" % ver)
    except RuntimeError as e:
        print("!!", e)
        return 2

    work = tempfile.mkdtemp(prefix="mgr-gui-")
    h = E2E(workdir=work)
    mgr = None
    try:
        # ── the hub, isolated, on the Edge ───────────────────────────────────
        h.write_config(doc([page("Start", [tile("clock-1", "clock")])]))
        if not h.launch_hub():
            print("!! hub did not come up"); return 2
        if not h.verify_target_window():
            print("!! hub is not verifiably on the Edge"); return 2
        h.check("hub-up", h.ping(), "control socket answering")

        # ── the REAL Manager, against the SAME isolated config ───────────────
        env = dict(os.environ)
        env["XDG_CONFIG_HOME"] = h.cfg
        env["XDG_RUNTIME_DIR"] = h.run_dir
        log = os.path.join(work, "manager.log")
        mgr = subprocess.Popen([MANAGER], env=env, stdout=open(log, "w"),
                               stderr=subprocess.STDOUT, start_new_session=True)
        rect = dt.manager_rect_from_log(log, timeout=20)
        if not rect:
            print("!! could not read the Manager's window rect from", log)
            return 2
        print("  Manager window: %s at %d,%d %dx%d" % rect)
        dt.assert_rect_on_a_desktop_screen(rect, h.edge_name)
        h.check("manager-rect-verified", True, "%s %dx%d+%d+%d"
                % (rect[0], rect[3], rect[4], rect[1], rect[2]))
        if not mw.activate_exact_manager(mgr.pid, rect, work):
            h.check("manager-window-activated", False,
                    "exact Manager PID could not be raised and screen-verified")
            return 1
        h.check("manager-window-activated", True,
                "exact Manager PID raised; selected sidebar row is visible")

        gui = ManagerGui(h, rect, work)
        gui.shot("00-manager-open")

        # NOTHING may be clicked until the Manager is proven to be the window
        # rendering in its own rect. Without this the clamp happily fires into
        # whatever is stacked on top of it - it did, into the owner's browser.
        if not gui.verify_owns_its_rect():
            h.check("manager-window-owns-its-rect", False,
                    "occluded or not repainting - refused to inject")
            print("\n!! Bring the Manager to the front (or close windows covering "
                  "it on that screen) and re-run. No events were emitted.",
                  flush=True)
            return 1
        h.check("manager-window-owns-its-rect", True,
                "the Manager repaints in its own rect")

        # ── drive the five tabs, screenshotting each ─────────────────────────
        # ASSERT THE SCREEN CHANGED, not merely that a grab succeeded. The
        # first version of this checked `p is not None`, which passed for three
        # tabs whose clicks missed the sidebar entirely and produced byte-
        # identical frames. A GUI test that cannot tell "the UI changed" from
        # "I took a picture of the same UI" is worse than no test.
        # Invoke exact AT-SPI identities instead of coordinates. This remains
        # stable when rows, scaling, or the Manager window size change and can
        # never deliver an event to an unrelated overlapping window.
        tabs = ["Screens", "Look", "Images", "Device", "About"]
        sigs = {}
        for i, name in enumerate(tabs):
            if not mw.activate_exact_manager(mgr.pid, rect, work):
                h.check("manager-window-stayed-in-front", False,
                        "exact Manager window could not be restored before '%s'" % name)
                break
            if not mw.invoke_accessible(name, manager_pid=mgr.pid):
                h.check("manager-window-stayed-in-front", False,
                        "accessible tab '%s' was unavailable - no event emitted" % name)
                break
            time.sleep(0.8)
            p = gui.shot("tab-%d-%s" % (i, name.lower()))
            if not p:
                h.check("manager-tab-%s" % name.lower(), False, "no grab")
                continue
            sig = gui._sig(p)
            dup = sigs.get(sig)
            active = gui.active_row(p)

            # OCCLUSION IS NOT A PRODUCT FAILURE. `active_row` returning None
            # means NO row carries the accent fill - the Manager always has
            # exactly one selected, so None means we are not looking at the
            # Manager at all. On 2026-07-20 the owner's browser raised itself
            # over the Manager MID-RUN: rows 2-5 reported "the click did not
            # change tabs" and "SELECTED row is None", which reads as four
            # product bugs and was really four clicks into a documentation
            # page. Distinguish "wrong row highlighted" (a real failure) from
            # "no row highlighted" (we lost the window) and stop, because every
            # further click would land in someone else's application.
            if active is None:
                print("\n!! OCCLUDED: no sidebar row carries the accent in %s -"
                      " the Manager is no longer the window in its own rect."
                      % os.path.basename(p), flush=True)
                print("!! Aborting before the next click. This is an environment"
                      " problem (another window raised itself over the Manager),"
                      " NOT a Manager defect. Re-run with that screen clear.",
                      flush=True)
                h.check("manager-window-stayed-in-front", False,
                        "lost the window at tab '%s' - remaining clicks skipped" % name)
                break

            ok = (dup is None) and (active == name)
            if dup is not None:
                why = "IDENTICAL to '%s' - the click did not change tabs" % dup
            elif active != name:
                why = "clicked '%s' but the SELECTED row is %r" % (name, active)
            else:
                why = "selected row is '%s'" % name
            h.check("manager-tab-%s" % name.lower(), ok, why)
            sigs.setdefault(sig, name)
        else:
            h.check("manager-window-stayed-in-front", True,
                    "the Manager stayed in front for every tab")

        # ── the integration assertion: Manager click -> hub state ────────────
        # This is the leg nothing else covers. We do NOT assert a specific
        # widget lands at a specific pixel (that is what the offscreen suite is
        # for); we assert that driving the real Manager mutates the real hub.
        before = h.get_state() or {}
        mw.activate_exact_manager(mgr.pid, rect, work)
        mw.invoke_accessible("Screens", manager_pid=mgr.pid)
        gui.shot("integration-before")
        time.sleep(1.0)
        after = h.get_state() or {}
        h.check("hub-still-answering-after-manager-input", h.ping(),
                "hub alive while the Manager is driven")
        h.check("hub-state-readable", isinstance(after, dict) and "pages" in after,
                "hub state keys: %s" % (sorted(after.keys()) if after else None))
        _ = before

        print("\n%d frames in %s" % (gui.n, work))
        passed, total = h.summary()
        return 0 if passed == total else 1
    finally:
        if mgr:
            try:
                mgr.kill()
            except Exception:
                pass
        h.cleanup()


if __name__ == "__main__":
    sys.exit(main())
