#!/usr/bin/env python3
"""manager_reflection_test.py - HUB -> Manager reflection (the other direction).

manager_hub_boundary tests Manager -> hub (clicks in the Manager land on the
hub). This tests the reverse: a change made on the HUB must appear in the
Manager, because the Manager polls the hub every 4s (manager_backend.h, the
`pull` timer) and mirrors it.

Covers three reflections, each: change it on the hub over the control socket,
wait for the Manager to pull, grab the Manager, assert it changed.

  1. SCREENS    - add screens on the hub -> the Manager's screen chips grow.
  2. THEME      - change the theme on the hub -> the Manager preview recolours.
  3. ORIENTATION - set the hub to landscape -> the Manager PREVIEW becomes WIDE.

(3) is a KNOWN BUG the owner reported: hub horizontal shown vertical in the
Manager. The hub reports the raw SENSOR rotation (-1 with no sensor) rather than
its effective CONTENT rotation, and with no sensor the hub DEFAULTS to landscape
(main.qml contentRotation) - so the panel is landscape while the Manager, in
auto, is told "unknown" and falls back to portrait. This test is written to FAIL
until the hub reports effective rotation.

This direction is deliberately input-free: the Manager starts on the Screens
tab, so clicking that already-selected tab adds risk without adding coverage.
Before inspecting it, the suite grabs the real desktop and proves the real
Manager is frontmost in its own logged window rect and that Screens is selected.

Run:
    python3 tests/hardware/manager_reflection_test.py
"""
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import desktop_target as dt          # noqa: E402
import manager_window as mw          # noqa: E402
from e2e_harness import (E2E, MANAGER, assert_binaries_current,  # noqa: E402
                         doc, page, tile)

PULL = 5.0   # > the Manager's 4s pull interval, so a hub change is picked up


def preview_rect(path, win_w, win_h):
    """Bounding box (w, h) of the dark phone-mockup preview on the light Manager.

    The preview is a near-black rounded frame in the left ~45% of the window; the
    rest of that region is the cream page background. Returns (w, h) of the dark
    region's bounding box, or None if not found. Landscape -> wide, portrait ->
    tall.
    """
    from PIL import Image
    im = Image.open(path).convert("RGB")
    W, H = im.size
    x0, x1 = int(W * 0.15), int(W * 0.47)   # left band, past the sidebar
    y0, y1 = int(H * 0.12), int(H * 0.98)
    step = 4
    minx = miny = 10 ** 9
    maxx = maxy = -1
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            r, g, b = im.getpixel((x, y))
            if r < 70 and g < 70 and b < 80:      # near-black frame/screen
                minx = min(minx, x); maxx = max(maxx, x)
                miny = min(miny, y); maxy = max(maxy, y)
    if maxx < 0:
        return None
    return (maxx - minx, maxy - miny)


def preview_is_landscape(path):
    """True if the Manager preview is in its LANDSCAPE (full-width, top) layout.

    Robust binary discriminator for the O2 layout: three points on the RIGHT
    side, upper area, are the light CONFIG panel in portrait (preview is a narrow
    left column) but are COVERED by the dark full-width preview in landscape.
    Dark at all three => landscape. Measured on real captures: portrait
    (250,244,236) light vs landscape (~60,70,85) dark."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    W, H = im.size
    pts = [(0.55, 0.28), (0.65, 0.28), (0.72, 0.30)]
    dark = 0
    for fx, fy in pts:
        r, g, b = im.getpixel((int(W * fx), int(H * fy)))
        if r + g + b < 260:
            dark += 1
    return dark >= 2


def preview_center(path, win_w, win_h):
    """Centre pixel of the preview's dark bounding box, or None."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    W, H = im.size
    x0, x1 = int(W * 0.15), int(W * 0.47)
    y0, y1 = int(H * 0.12), int(H * 0.98)
    minx = miny = 10 ** 9; maxx = maxy = -1
    for y in range(y0, y1, 4):
        for x in range(x0, x1, 4):
            r, g, b = im.getpixel((x, y))
            if r < 70 and g < 70 and b < 80:
                minx = min(minx, x); maxx = max(maxx, x)
                miny = min(miny, y); maxy = max(maxy, y)
    if maxx < 0:
        return None
    return ((minx + maxx) // 2, (miny + maxy) // 2)


def main():
    try:
        print("  binaries under test: %s" % assert_binaries_current())
    except RuntimeError as e:
        print("!!", e); return 2

    work = tempfile.mkdtemp(prefix="mgr-refl-")
    h = E2E(workdir=work)
    mgr = None
    try:
        # Hub: a couple of visible widgets so the preview has content, auto orient.
        base_pages = [page("Home", [tile("clock-1", "clock"), tile("cpu-1", "cpu")])]
        h.write_config(doc(base_pages, appearance={"themeMode": "nord", "orientation": "portrait"}))
        if not h.launch_hub() or not h.verify_target_window():
            print("!! hub not verifiably on the Edge"); return 2
        h.set_state(doc(base_pages))     # clear the probe tile
        h.check("hub-up", h.ping(), "control socket answering")

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

        front = mw.grab_rect(rect, work, "initial-front")
        if not front:
            print("!! could not capture the Manager window"); return 2
        row = mw.active_row(front, w, hgt)
        try:
            os.unlink(front)
        except OSError:
            pass
        h.check("manager-frontmost-on-screens-tab", row == "Screens",
                "real desktop grab selected row = %r" % (row,))
        if row != "Screens":
            print("!! Manager is occluded or not on Screens; refusing to inspect")
            return 2

        def grab(tag):
            path = os.path.join(work, tag + ".png")
            full = dt._full_grab(work, tag)
            if full:
                from PIL import Image
                Image.open(full).crop((x, y, x + w, y + hgt)).save(path)
                os.unlink(full)
            return path

        def appearance(**kw):
            a = {"themeMode": "nord", "accent": "#58A6FF", "bgStyle": "orbs",
                 "animatedBg": True, "glass": 0.55, "glow": True,
                 "gridCols": 1, "orientation": "portrait"}
            a.update(kw)
            return a

        # ── 1. SCREENS reflect ───────────────────────────────────────────────
        base0 = grab("00-baseline")
        h.set_state(doc([page("Home", base_pages[0]["tiles"])] +
                        [page(n, []) for n in ("Two", "Three", "Four")]))
        time.sleep(PULL)
        after = grab("01-screens-added")
        # The sidebar screen chips live in a strip near the top; more screens =>
        # more coloured chips => that strip changes. Compare the chip strip band.
        from PIL import Image
        b_im = Image.open(base0).convert("RGB")
        a_im = Image.open(after).convert("RGB")
        # Region right of the first chip: cream when there is one screen, filled
        # by the Two/Three/Four chips after. Sensitive to chips appearing.
        band = (int(w * 0.24), int(hgt * 0.072), int(w * 0.44), int(hgt * 0.11))
        def band_sig(im):
            c = im.crop(band).resize((10, 3))
            return [c.getpixel((i, j)) for j in range(3) for i in range(10)]
        d = sum(sum((p1 - q1) ** 2 for p1, q1 in zip(a, b)) ** 0.5
                for a, b in zip(band_sig(a_im), band_sig(b_im))) / 30
        h.check("hub-screens-reflect-in-manager", d > 8,
                "chip region changed by %.0f after adding 3 screens" % d)

        # ── 2. THEME reflects ────────────────────────────────────────────────
        h.set_state(doc(base_pages, appearance=appearance(themeMode="light")))
        time.sleep(PULL)
        light = grab("02-theme-light")
        h.set_state(doc(base_pages, appearance=appearance(themeMode="matrix")))
        time.sleep(PULL)
        matrix = grab("03-theme-matrix")
        # The PREVIEW recolours between light and matrix themes.
        # Sample the CENTRE of the detected preview rect, so it works whether the
        # preview is tall or wide.
        c = preview_center(light, w, hgt)
        if c:
            lp = Image.open(light).convert("RGB").getpixel(c)
            mp = Image.open(matrix).convert("RGB").getpixel(c)
            dd = sum((a - b) ** 2 for a, b in zip(lp, mp)) ** 0.5
            h.check("hub-theme-reflects-in-manager-preview", dd > 40,
                    "preview centre %s recoloured by %.0f (light %s -> matrix %s)"
                    % (c, dd, lp, mp))
        else:
            h.check("hub-theme-reflects-in-manager-preview", False,
                    "could not locate the preview")

        # ── 3. ORIENTATION reflects (the reported bug) ───────────────────────
        h.set_state(doc(base_pages, appearance=appearance(orientation="portrait")))
        time.sleep(PULL)
        pth = grab("04-orient-portrait")
        h.set_state(doc(base_pages, appearance=appearance(orientation="landscape")))
        time.sleep(PULL)
        lsc = grab("05-orient-landscape")

        lp = preview_is_landscape(pth)
        ll = preview_is_landscape(lsc)
        print("  preview-is-landscape: portrait=%s landscape=%s" % (lp, ll))
        # Hub portrait -> Manager preview in the beside-config (portrait) layout.
        h.check("manager-preview-portrait-layout", lp is False,
                "hub portrait -> Manager preview beside config (not full-width)")
        # Hub landscape -> Manager preview in the full-width (landscape) layout.
        h.check("manager-preview-landscape-layout", ll is True,
                "hub landscape -> Manager preview full-width on top; if not, the "
                "hub orientation is NOT reflected in the Manager")

        # AUTO with no sensor: the hub defaults to LANDSCAPE, so the Manager
        # preview in auto must ALSO be wide. This is the exact reported case.
        h.set_state(doc(base_pages, appearance=appearance(orientation="auto")))
        time.sleep(PULL)
        auto = grab("06-orient-auto")
        la = preview_is_landscape(auto)
        print("  preview-is-landscape (auto)=%s (hub default is landscape)" % la)
        h.check("manager-preview-auto-matches-hub-landscape", la is True,
                "hub auto defaults to landscape, so the Manager preview must be "
                "full-width; beside-config = the reported bug")

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
