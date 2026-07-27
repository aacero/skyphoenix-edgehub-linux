#!/usr/bin/env python3
"""manager_window.py - proof that the Manager is the window we are clicking.

WHY THIS EXISTS (2026-07-20)
────────────────────────────────────────────────────────────────────────────
Every Manager test clamps its synthetic events to the Manager's window RECT.
That confines the cursor, and it is necessary - but it does NOT establish that
the Manager is the window RECEIVING events in that rect. Nothing did.

The first ever run of manager_gui_test.py proved the gap the expensive way: the
owner's browser raised itself over the Manager on DP-2 mid-run, so five sidebar
clicks went into a documentation page. The run reported four Manager defects
("the click did not change tabs", "SELECTED row is None") that did not exist,
and six real clicks landed in an unrelated application.

`assert_rect_on_a_desktop_screen()` cannot catch this. It only asserts the rect
lies on a real non-Edge screen - a correct window, an occluded one and a stale
rect all satisfy it identically.

THE SIGNAL
────────────────────────────────────────────────────────────────────────────
The Manager always has exactly ONE sidebar row filled with the accent. So:

    exactly one accent row  -> we are looking at the Manager (and we know which
                               tab is selected)
    no accent row at all    -> we are NOT looking at the Manager

That distinction is the whole thing. It was already computable before this
module existed, and was misread as "the wrong tab is selected" - which turned an
environment problem into four fabricated bug reports. Occlusion is not a product
failure and must never be reported as one.

USE
────────────────────────────────────────────────────────────────────────────
    import manager_window as mw
    p = mw.guard_pointer(u.VPointer(cw, ch, rect_xywh, guard=g), rect, work)
    p.tap(x, y)        # refuses (returns False) if the Manager is not in front

`guard_pointer` is a drop-in wrapper: it forwards every attribute to the real
pointer and only interposes on the emitting calls.
"""
import os
import subprocess
import time

import desktop_target as dt

# Sidebar row centres in logical pixels. The sidebar is anchored at the top and
# its rows have fixed QML heights, so these coordinates do not move when only
# the window height changes. The old height fractions turned Screens at y=164
# into y=126 in a 1000px-tall Manager and falsely reported the selected Look row.
ROW_Y = {"Screens": 164, "Look": 220, "Images": 276,
         "Device": 332, "About": 388}
ROW_X = 120


def active_row(path, win_w=None, win_h=None):
    """Which sidebar row is selected, read from the accent fill - or None.

    None means NO row is accented, i.e. this is not the Manager. Callers must
    treat that as "lost the window", never as "wrong tab".

    The selected row is the ONE colour outlier. The Manager's Default chrome
    uses corporate orange, but Dark and Light deliberately follow the Hub's
    selected accent. Hard-coding orange therefore rejected the real Manager as
    soon as a user chose blue (or any other accent), disabling every guarded
    real-input test. The four unselected rows share the sidebar background, so
    a single row separated from every peer by a conservative RGB distance is
    the stable identity signal across themes.
    """
    import math

    from PIL import Image
    im = Image.open(path).convert("RGB")
    samples = []
    for name, y in ROW_Y.items():
        x = ROW_X
        if 0 <= x < im.size[0] and 0 <= y < im.size[1]:
            samples.append((name, im.getpixel((x, y))))
    if len(samples) != len(ROW_Y):
        return None

    def distance(a, b):
        return math.sqrt(sum((left - right) ** 2
                             for left, right in zip(a, b)))

    # An outlier must be far from even its closest peer. The background rows
    # are normally identical, while all shipped accents are comfortably beyond
    # 40 RGB units from both light and dark sidebar backgrounds.
    separated = []
    for index, (name, colour) in enumerate(samples):
        nearest = min(
            distance(colour, other)
            for other_index, (_, other) in enumerate(samples)
            if other_index != index
        )
        if nearest >= 40:
            separated.append(name)
    return separated[0] if len(separated) == 1 else None


def grab_rect(rect, work, tag="frontcheck"):
    """Grab the screen and crop to the Manager's rect. Returns a path or None."""
    name, x, y, w, h = rect
    full = dt._full_grab(work, tag)
    if not full:
        return None
    try:
        from PIL import Image
        out = os.path.join(work, "_%s.png" % tag)
        Image.open(full).crop((x, y, x + w, y + h)).save(out)
        os.unlink(full)
        return out
    except Exception:
        return None


def is_in_front(rect, work):
    """True if the Manager is the window rendering in its own rect."""
    p = grab_rect(rect, work)
    if not p:
        return False
    ok = active_row(p) is not None
    try:
        os.unlink(p)
    except OSError:
        pass
    return ok


def _manager_accessible(manager_pid=None):
    """Return the live Manager application from AT-SPI, or None.

    Semantic accessibility actions are safer than screen coordinates: the action
    is delivered to the named Manager control itself, even after layout changes,
    and can never land in an unrelated window covering the same pixels.
    """
    try:
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        Atspi.init()
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if not app or app.get_name() != "Xeneon Edge Manager":
                continue
            if manager_pid is not None:
                try:
                    if app.get_process_id() != manager_pid:
                        continue
                except Exception:
                    continue
            if app:
                return app, Atspi
    except Exception:
        return None, None
    return None, None


def _find_accessible(node, name, atspi):
    try:
        if node.get_name() == name:
            states = node.get_state_set()
            if (states.contains(atspi.StateType.SHOWING)
                    and states.contains(atspi.StateType.ENABLED)):
                return node
        for i in range(node.get_child_count()):
            found = _find_accessible(node.get_child_at_index(i), name, atspi)
            if found:
                return found
    except Exception:
        return None
    return None


def invoke_accessible(name, timeout=3.0, manager_pid=None):
    """Invoke one exact, visible, enabled Manager control by accessible name."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        app, atspi = _manager_accessible(manager_pid)
        target = _find_accessible(app, name, atspi) if app else None
        if target:
            try:
                action = target.get_action_iface()
                if action and action.get_n_actions() > 0:
                    # Custom QML controls expose SetFocus first and Press second,
                    # while native Qt buttons may expose Press as their first action.
                    # Invoking index 0 blindly therefore focused tabs and screen
                    # chips without activating them. Resolve the semantic Press
                    # action by name so both control types behave identically.
                    for index in range(action.get_n_actions()):
                        if action.get_action_name(index).lower() == "press":
                            return bool(action.do_action(index))
                    return False
            except Exception:
                return False
        time.sleep(0.1)
    return False


def _wmctrl_manager_window(manager_pid):
    """Return the one X11 Manager window ID owned by manager_pid, or None.

    The Manager deliberately uses XWayland in a KDE Wayland session so its
    non-Edge placement can be deterministic. wmctrl can therefore activate the
    exact top-level window by X11 ID. Both PID and title must match, and an
    ambiguous result is rejected.
    """
    try:
        result = subprocess.run(
            ["wmctrl", "-lpGx"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None

    matches = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 9)
        if len(fields) < 10:
            continue
        window_id, _, raw_pid, _, _, _, _, _, _, title = fields
        try:
            pid = int(raw_pid)
        except ValueError:
            continue
        if pid == manager_pid and title == "EdgeHub Manager":
            matches.append(window_id)
    return matches[0] if len(matches) == 1 else None


def activate_exact_manager(manager_pid, rect, work, timeout=5.0):
    """Raise only the launched Manager and prove its sidebar is visible.

    This is window activation, not pointer or keyboard injection. It is safe to
    retry because the target comes from an exact PID plus exact window-title
    match. The function still fails closed unless the post-activation screen
    proof sees one selected Manager sidebar row in the logged rectangle.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        window_id = _wmctrl_manager_window(manager_pid)
        if window_id:
            try:
                result = subprocess.run(
                    ["wmctrl", "-i", "-a", window_id],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError):
                result = None
            if result and result.returncode == 0:
                time.sleep(0.25)
                if is_in_front(rect, work):
                    return True
        time.sleep(0.1)
    return False


class GuardedPointer:
    """Wraps a VPointer and refuses to emit unless the Manager is in front.

    Checked BEFORE each emitting call, not after: a post-hoc check catches the
    occlusion one click too late, and that one click is exactly the one that
    lands in someone else's window.
    """

    _EMITTERS = ("tap", "press", "move", "release", "click", "drag", "swipe")

    def __init__(self, pointer, rect, work, manager_pid=None):
        self._p, self._rect, self._work = pointer, rect, work
        self._manager_pid = manager_pid
        self.refused = 0

    def __getattr__(self, name):
        attr = getattr(self._p, name)
        if name not in self._EMITTERS or not callable(attr):
            return attr

        def guarded(*a, **kw):
            front = is_in_front(self._rect, self._work)
            if (not front and self._manager_pid is not None):
                front = activate_exact_manager(
                    self._manager_pid, self._rect, self._work
                )
            if not front:
                self.refused += 1
                print("  REFUSED %s%r: the Manager is not the window in its own "
                      "rect (occluded?). Emitting nothing." % (name, a), flush=True)
                return False
            return attr(*a, **kw)
        return guarded


def guard_pointer(pointer, rect, work, manager_pid=None):
    return GuardedPointer(pointer, rect, work, manager_pid)
