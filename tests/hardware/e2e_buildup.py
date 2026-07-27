#!/usr/bin/env python3
"""e2e_buildup.py - incremental build-up scenario on the REAL Edge panel.

Owner-requested (2026-07-19): strip the dashboard to nothing, then add things
back ONE AT A TIME, checking the real hub on the real panel after every single
step. Screens, then widgets, then themes, then accents, then animated
backgrounds, then wallpapers, then orientation.

Why this exists, in test terms: it is the first coverage of the REAL hub binary
being driven incrementally over the REAL control socket, with the rendered panel
checked after each mutation. Everything else either drives a stub (the GUI
suite's ManagerHarness), or asserts store facts with nothing rendered
(tests/runtime), or changes many things at once. A build-up is what catches
"step 7 is fine alone but breaks after step 6" - coherence, not units.

Every step does three things:
  1. push ONE change over IPC,
  2. read the state back and assert the hub actually took it,
  3. grab the Edge rect to a PNG so a human can flip through the sequence.

Grabs are cropped to the Edge rect by the harness, so no other monitor is
captured.

The hub runs with an isolated XDG_CONFIG_HOME and XDG_RUNTIME_DIR, so the live
hub's config, single-instance lock and control socket are never touched.

Run:
    python3 tests/hardware/e2e_buildup.py                  # IPC + grabs
    XENEON_HW_INPUT=1 python3 tests/hardware/e2e_buildup.py  # + real touch

Output: /tmp/edge-buildup-<n>/NNN-<step>.png, one frame per step, in order.
"""
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from e2e_harness import E2E, assert_binaries_current, doc, page, tile  # noqa: E402

# One widget per family we care about, in the order a user would plausibly add
# them. Deliberately spans metric widgets (need the Rust core), time widgets
# (need timers), and focus widgets (need persisted settings).
WIDGET_WALK = [
    ("clock",     "time"),
    ("cpu",       "metric"),
    ("ram",       "metric"),
    ("weather",   "network-ish"),
    ("tasks",     "productivity"),
    ("hydration", "focus"),
    ("media",     "entertainment"),
]

# Themes across every group, including the renamed inspired palettes (D3) and
# the new shipped default (D1).
THEME_WALK = ["nord", "dark", "light", "high_contrast",
              "trilby_key_check", "catppuccin", "matrix"]
# `trilby_key_check` is not a key - replaced below. Keys stayed as the distro
# spellings on purpose (see ui/qml/Theme.qml naming policy); the DISPLAY name is
# what changed. Asserting the key still works is the point of including it.
THEME_WALK[4] = "fedora"

ACCENT_WALK = ["#58A6FF", "#3FB950", "#F778BA", "#E3B341", "#000000"]
BG_WALK = ["orbs", "mesh", "aurora", "waves", "stars", "bokeh", "grid", "none"]


# Fraction of a step's settle time. The hub applies + renders fast; 0.45s was
# conservative. 0.25 keeps grabs clean while cutting ~40% off the run.
SETTLE = float(os.environ.get("XENEON_BUILDUP_SETTLE", "0.25"))


def grid_sig(path, n=8):
    """An n x n grid of average colours - a cheap render fingerprint that is
    sensitive to WHERE things are, not just the overall tint. Two frames with
    the same average but different layout (a widget present vs an empty page)
    have very different grid signatures."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    w, h = im.size
    small = im.resize((n, n))
    return [small.getpixel((x, y)) for y in range(n) for x in range(n)]


def sig_distance(a, b):
    return sum(sum((p - q) ** 2 for p, q in zip(pa, pb)) ** 0.5
               for pa, pb in zip(a, b)) / max(len(a), 1)


class BuildUp:
    def __init__(self, h):
        self.h = h
        self.n = 0
        self.frames = []
        self.empty_sig = None      # grid signature of the empty content page

    def step(self, label, mutate, verify, min_render_delta=None):
        """One atomic change: push it, read it back, grab the panel.

        min_render_delta (optional): the grabbed frame must differ from the
        empty-page baseline by at least this much. This is what makes a WIDGET
        test a real GUI test - it asserts the widget actually RENDERED, not just
        that the hub's state reports it. The 65/65 run before this existed showed
        an empty page for every 'widget added' step because the content was on a
        page the hub was not displaying."""
        self.n += 1
        tag = "%03d-%s" % (self.n, label.replace(" ", "_").replace("/", "-"))
        try:
            mutate()
        except Exception as e:  # noqa: BLE001
            self.h.check(label, False, "mutate raised: %r" % (e,))
            return False
        time.sleep(SETTLE)
        st = self.h.get_state()
        ok, detail = verify(st)
        path = os.path.join(self.h.work, tag + ".png")
        grabbed = False
        try:
            grabbed = self.h.grab(path)
            self.frames.append(path)
        except Exception as e:  # noqa: BLE001
            print("    (grab failed: %r)" % (e,))
        if ok and min_render_delta is not None:
            if not grabbed:
                ok, detail = False, "no grab to check rendering against"
            elif self.empty_sig is None:
                detail += " [no empty baseline captured]"
            else:
                d = sig_distance(grid_sig(path), self.empty_sig)
                if d < min_render_delta:
                    ok = False
                    detail = ("STATE ok but NOT RENDERED: frame differs from the "
                              "empty page by only %.0f (need >=%.0f) - the content "
                              "is not on screen" % (d, min_render_delta))
                else:
                    detail += " [rendered, delta=%.0f]" % d
        self.h.check(label, ok, detail)
        return ok

    def capture_empty_baseline(self):
        """Grab the current (empty) content page as the render baseline."""
        p = os.path.join(self.h.work, "000-empty-baseline.png")
        if self.h.grab(p):
            self.empty_sig = grid_sig(p)


def pages_of(st):
    return (st or {}).get("pages", []) or []


def appearance_of(st):
    return (st or {}).get("appearance", {}) or {}


def main():
    try:
        print("  binaries under test: %s" % assert_binaries_current())
    except RuntimeError as e:
        print("!!", e)
        return 2
    audit_root = os.environ.get("XENEON_AUDIT_RUN_DIR", "")
    if audit_root:
        workdir = os.path.join(audit_root, "hardware-edge-buildup")
        os.mkdir(workdir, 0o700)
    else:
        workdir = tempfile.mkdtemp(prefix="edge-buildup-")
    h = E2E(workdir=workdir)
    b = BuildUp(h)
    try:
        # Seed the config BEFORE launching: without first_run_complete the hub
        # boots into the First-Run Wizard, the Dashboard never loads, and every
        # probe/grab shows the same wizard - which reads as "distance 0, the hub
        # is not on the Edge" when in fact it is, just showing another screen.
        h.write_config(doc([page("Blank", [])]))
        h.launch_hub()
        if not h.verify_target_window():
            print("!! could not verify the hub is the window on the Edge - aborting")
            return 2

        # THROUGHOUT: the page under test is page 0 ("Home"), because the hub
        # resets swipeView.currentIndex to 0 on every setUiState
        # (ui/qml/Dashboard.qml:410) and the state has no field to select a
        # page. Earlier versions put content on page 1 and the hub kept
        # displaying page 0, so every "widget added" frame showed an EMPTY page
        # and the visual verification was hollow. Content stays on page 0 here so
        # it actually renders and can be checked.

        # ── 0. STRIP: one empty screen, and capture it as the render baseline ─
        b.step("strip-to-one-empty-screen",
               lambda: h.set_state(doc([page("Home", [])])),
               lambda st: (len(pages_of(st)) == 1 and not pages_of(st)[0].get("tiles"),
                           "pages=%d tiles=%s" % (len(pages_of(st)),
                                                  pages_of(st)[0].get("tiles") if pages_of(st) else "?")))
        b.capture_empty_baseline()

        # ── 1. SCREENS: add extra ones AFTER the visible content page ────────
        # "Home" stays page 0 (shown); System/Focus/Media are appended after it.
        extra = ["System", "Focus", "Media"]
        for i, nm in enumerate(extra, start=1):
            want = i + 1  # Home + i added

            def mut(upto=i):
                h.set_state(doc([page("Home", [])] +
                                [page(extra[k], []) for k in range(upto)]))

            def ver(st, want=want):
                got = len(pages_of(st))
                return got == want, "expected %d screens, hub reports %d" % (want, got)
            b.step("screen-add-%d-%s" % (i, nm), mut, ver)

        names = ["Home"] + extra   # full set, Home first

        # ── 2. WIDGETS onto the VISIBLE page - asserts they RENDER ───────────
        placed = []
        for i, (wtype, family) in enumerate(WIDGET_WALK, start=1):
            placed.append(tile("bu-%s" % wtype, wtype, "1x1"))

            def mut(tiles=list(placed)):
                h.set_state(doc([page("Home", tiles)] + [page(n, []) for n in extra]))

            def ver(st, want=i, wtype=wtype):
                pg = [p for p in pages_of(st) if p.get("name") == "Home"]
                if not pg:
                    return False, "no Home screen in hub state"
                tiles = pg[0].get("tiles", [])
                types = [t.get("type") for t in tiles]
                return (len(tiles) == want and wtype in types,
                        "want %d tiles incl %s, hub has %d: %s" % (want, wtype, len(tiles), types))
            # min_render_delta: the frame MUST differ from the empty page now.
            b.step("widget-add-%d-%s" % (i, wtype), mut, ver, min_render_delta=12)

        # ── 2a-i. RENAME each screen ─────────────────────────────────────────
        for i, nm in enumerate(names):
            newname = nm + " R"

            def mut(idx=i, nn=newname):
                pgs = [page(names[k] if k != idx else nn,
                            list(placed) if names[k] == "Home" else [])
                       for k in range(len(names))]
                h.set_state(doc(pgs))

            def ver(st, nn=newname):
                got = [p.get("name") for p in pages_of(st)]
                return nn in got, "expected %r among hub screens %s" % (nn, got)
            b.step("screen-rename-%d-%s" % (i + 1, nm), mut, ver)

        # ── 2a-ii. RESIZE a widget through its DECLARED legal sizes ──────────
        # The canonical tile format is a `size` STRING ("1x1", "1x1.5"), not
        # integer w/h. Every widget declares its own legal set in
        # ui/qml/WidgetCatalog.qml and the hub coerces DOWN to the nearest legal
        # size (DashboardStore.qml:144) - so a resize test MUST use sizes that
        # are actually legal for the widget, or it only ever tests coercion.
        # The clock's set is ["0.5x0.5","0.5x1","1x0.5","1x1","1x1.5"].
        for sz in ("0.5x0.5", "0.5x1", "1x0.5", "1x1.5", "1x1"):
            def mut(size=sz):
                tiles = [{"id": "bu-clock", "type": "clock", "size": size}] + \
                        [{"id": "bu-%s" % t, "type": t, "size": "1x1"}
                         for (t, _) in WIDGET_WALK[1:]]
                h.set_state(doc([page("Home", tiles)] + [page(n, []) for n in extra]))

            def ver(st, size=sz):
                pg = [p for p in pages_of(st) if p.get("name") == "Home"]
                if not pg:
                    return False, "no Home screen"
                t0 = [t for t in pg[0].get("tiles", []) if t.get("id") == "bu-clock"]
                if not t0:
                    return False, "clock tile missing after resize"
                got = t0[0].get("size")
                return got == size, "asked size=%s, hub reports size=%s" % (size, got)
            b.step("widget-resize-%s" % sz.replace(".", "_"), mut, ver)

        # ── 2a-iii. REMOVE widgets one at a time ─────────────────────────────
        remaining = list(placed)
        for i in range(len(placed) - 1, -1, -1):
            remaining = remaining[:i]

            def mut(tiles=list(remaining)):
                h.set_state(doc([page("Home", tiles)] + [page(n, []) for n in extra]))

            def ver(st, want=i):
                pg = [p for p in pages_of(st) if p.get("name") == "Home"]
                got = len(pg[0].get("tiles", [])) if pg else -1
                return got == want, "expected %d widgets left, hub reports %d" % (want, got)
            b.step("widget-remove-down-to-%d" % i, mut, ver)

        # Put the widgets back for the removal walk below.
        h.set_state(doc([page("Home", list(placed))] + [page(n, []) for n in extra]))
        time.sleep(0.4)

        # ── 2b. SCREENS: remove them again, one at a time ────────────────────
        # Adding was covered above; REMOVAL is the direction that strands state
        # (a page's tiles, the current-page index, the dying-row sweep in
        # Dashboard.qml). Walk back down to a single screen and check the hub
        # agrees at every step.
        for i in range(len(names), 0, -1):
            want = i  # Blank + (i-1) remaining

            def mut(keep=i - 1):
                h.set_state(doc([page("Home", list(placed))] +
                                [page(extra[k], []) for k in range(keep)]))

            def ver(st, want=want):
                got = len(pages_of(st))
                return got == want, "expected %d screens after removal, hub reports %d" % (want, got)
            b.step("screen-remove-down-to-%d" % want, mut, ver)

        b.step("screens-fully-stripped",
               lambda: h.set_state(doc([page("Home", list(placed))])),
               lambda st: (len(pages_of(st)) == 1,
                           "back to one screen (Home, with its widgets): pages=%d" % len(pages_of(st))))

        # Keep Home + its widgets on page 0 for the appearance walk, so themes,
        # accents, backgrounds and wallpapers are all judged against a page that
        # actually has content on it.
        time.sleep(SETTLE)

        # A stable layout to mutate appearance against, from here on.
        base = [page("Home", list(placed))] + [page(n, []) for n in extra]

        def push_appearance(**kw):
            app = {"mode": "dark", "themeMode": "nord", "accent": "#58A6FF",
                   "bgStyle": "orbs", "animatedBg": True, "glass": 0.55,
                   "glow": True, "gridCols": 1}
            app.update(kw)
            h.set_state(doc(base, appearance=app))

        # ── 3. THEMES ────────────────────────────────────────────────────────
        for i, key in enumerate(THEME_WALK, start=1):
            b.step("theme-%d-%s" % (i, key),
                   lambda key=key: push_appearance(themeMode=key),
                   lambda st, key=key: (appearance_of(st).get("themeMode") == key,
                                        "hub themeMode=%r" % appearance_of(st).get("themeMode")))

        # ── 4. ACCENTS / palette ─────────────────────────────────────────────
        for i, acc in enumerate(ACCENT_WALK, start=1):
            b.step("accent-%d-%s" % (i, acc.lstrip("#")),
                   lambda acc=acc: push_appearance(themeMode="nord", accent=acc),
                   lambda st, acc=acc: (str(appearance_of(st).get("accent", "")).lower() == acc.lower(),
                                        "hub accent=%r" % appearance_of(st).get("accent")))

        # ── 5. ANIMATED BACKGROUNDS ──────────────────────────────────────────
        for i, style in enumerate(BG_WALK, start=1):
            b.step("bg-%d-%s" % (i, style),
                   lambda style=style: push_appearance(themeMode="nord", bgStyle=style, animatedBg=True),
                   lambda st, style=style: (appearance_of(st).get("bgStyle") == style,
                                            "hub bgStyle=%r" % appearance_of(st).get("bgStyle")))

        # animatedBg off - the calm default. Proves the switch actually gates.
        b.step("bg-animated-off",
               lambda: push_appearance(themeMode="nord", bgStyle="orbs", animatedBg=False),
               lambda st: (appearance_of(st).get("animatedBg") is False,
                           "hub animatedBg=%r" % appearance_of(st).get("animatedBg")))

        # ── 6. IMAGES / wallpaper ────────────────────────────────────────────
        for i, wp in enumerate(["midnight", "nebula", "aurora", ""], start=1):
            b.step("wallpaper-%d-%s" % (i, wp or "none"),
                   lambda wp=wp: push_appearance(themeMode="nord", wallpaper=wp),
                   lambda st, wp=wp: (appearance_of(st).get("wallpaper", "") == wp,
                                      "hub wallpaper=%r" % appearance_of(st).get("wallpaper")))

        # ── 7. ORIENTATION: forced flip, both ways, twice ────────────────────
        # Physical rotation needs a human (the sensor is on /dev/hidraw5), so
        # this forces the mode the way the Manager's orientation chip does.
        for i, mode in enumerate(["portrait", "landscape", "portrait", "landscape"], start=1):
            b.step("orientation-%d-%s" % (i, mode),
                   lambda mode=mode: push_appearance(themeMode="nord", orientation=mode),
                   lambda st, mode=mode: (appearance_of(st).get("orientation") == mode,
                                          "hub orientation=%r" % appearance_of(st).get("orientation")))

        # ── 8. COHERENCE: everything at once, then back to the shipped default
        b.step("coherence-all-changed-at-once",
               lambda: push_appearance(themeMode="matrix", accent="#3FB950",
                                       bgStyle="stars", wallpaper="", glass=0.9,
                                       glow=False, orientation="portrait"),
               lambda st: (appearance_of(st).get("themeMode") == "matrix"
                           and appearance_of(st).get("bgStyle") == "stars",
                           "hub=%r" % {k: appearance_of(st).get(k)
                                       for k in ("themeMode", "bgStyle", "accent", "orientation")}))
        b.step("back-to-shipped-defaults",
               lambda: push_appearance(),
               lambda st: (appearance_of(st).get("themeMode") == "nord",
                           "hub themeMode=%r" % appearance_of(st).get("themeMode")))

        # ── 9. survival: the hub is still alive and answering ────────────────
        h.check("hub-alive-after-buildup", h.ping(), "control socket still answering")

        print("\n%d frames written to %s" % (len(b.frames), h.work))
        passed, total = h.summary()
        return 0 if passed == total else 1
    finally:
        h.cleanup()


if __name__ == "__main__":
    sys.exit(main())
