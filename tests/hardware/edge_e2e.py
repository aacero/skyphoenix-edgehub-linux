#!/usr/bin/env python3
"""Comprehensive real-hardware E2E suite for EdgeHub (hub on the Xeneon Edge + Manager).

Covers: widget lifecycle (add/render/resize/remove for every WidgetCatalog
type), theming (all themes + backgrounds + accents + per-widget style,
lists derived-and-drift-checked against Theme.qml / BackgroundCatalog.qml),
synthetic-touch
interaction (compact controls start/stop, page swipe), IPC robustness &
performance, and Manager chrome rendering.

Uses an ISOLATED XDG_CONFIG_HOME, so the user's live config is never touched.
Requires: the Edge connected, a release build, /dev/uinput writable, spectacle +
PIL for grabs, no other hub running.

Run:  python3 tests/hardware/edge_e2e.py        # exits 0 on pass, 1 on any FAIL
"""
import os, sys, time, json, socket, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e2e_harness import (E2E, MANAGER, REPO, assert_binaries_current, doc,
                         page, tile, UserActivityAbort,
                         PAGE_SWIPE_NEXT)  # noqa: E402
import e2e_interaction  # noqa: E402
import e2e_widgets  # noqa: E402
import e2e_theming  # noqa: E402


def _kill_stale():
    # Only hubs launched from THIS repo's build tree (a stale spawn from a
    # crashed previous run). Never a bare "xeneon-edge-hub" pattern - that
    # would match the user's live packaged hub. And never touch the real
    # XDG_RUNTIME_DIR: since the harness isolates each spawned hub's runtime
    # dir, the live hub's lock and control socket are not ours to remove.
    subprocess.run("pkill -9 -f %s/build/xeneon-edge-hub" % REPO, shell=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)


def section(title):
    print("\n" + "=" * 64 + "\n== " + title + "\n" + "=" * 64, flush=True)


def ipc_robustness_and_perf(h):
    section("IPC robustness + performance")
    # malformed / partial / oversized must not crash the hub
    def raw(b, wait_reply=True):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(4); s.connect(h.sock)
        s.sendall(b)
        try:
            if wait_reply: s.recv(4096)
        except socket.timeout:
            pass
        s.close()
    try: raw(b'{"type":"nonsense"}\n'); raw(b'not json at all\n'); raw(b'{"partial"', wait_reply=False)
    except Exception: pass
    try: raw(b'{"type":"setUiState","state":"' + b'x' * (9 * 1024 * 1024) + b'"}\n', wait_reply=False)
    except Exception: pass
    time.sleep(0.5)
    h.check("hub_survives_bad_ipc", h.ping(), "still responds after malformed/oversized input")

    # latency over 200 round-trips
    lat = []
    for _ in range(200):
        t0 = time.perf_counter(); h.get_state(); lat.append((time.perf_counter() - t0) * 1000)
    lat.sort()
    p50, p99 = lat[len(lat) // 2], lat[int(len(lat) * 0.99)]
    h.check("ipc_latency", p99 < 50, "p50=%.2fms p99=%.2fms over 200 calls" % (p50, p99))

    # 20 concurrent connections all answered
    socks, ok = [], 0
    for _ in range(20):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5); s.connect(h.sock)
        s.sendall(b'{"type":"getUiState"}\n'); socks.append(s)
    for s in socks:
        try:
            if s.recv(65536): ok += 1
        except socket.timeout: pass
        s.close()
    h.check("ipc_concurrent", ok == 20, "%d/20 concurrent getUiState answered" % ok)


def soak(h, seconds=120):
    """Sustained MIXED-operation endurance test: rotate themes/backgrounds, add &
    remove widgets, resize, rebuild multi-page layouts, and periodically swipe -
    a realistic churn that stresses every path for the full duration. Catches
    leaks, races, and crashes that only surface over time."""
    section("Soak (%ds sustained mixed operations)" % seconds)
    # Rotate through the FULL catalogs, derived from the same drift-checked
    # lists the theming suite asserts against Theme.qml / BackgroundCatalog.qml
    # - a new theme or background style is soak-tested automatically.
    themes, bgs = list(e2e_theming.THEMES), list(e2e_theming.BG_STYLES)
    types = ["cpu", "gpu", "ram", "clock", "focus", "weather", "moon", "quote", "habit", "media"]
    end = time.time() + seconds
    n, crashed, err = 0, False, ""
    touch_swipes = 0
    while time.time() < end:
        try:
            k = n % len(types)
            sizes = e2e_widgets.WIDGET_SPECS[types[k]]["sizes"]
            resize_choices = [s for s in sizes
                              if s != e2e_widgets.WIDGET_SPECS[types[k]]["default"]]
            chosen_size = (resize_choices[n % len(resize_choices)]
                           if resize_choices else "1x1")
            pages = [page("A", [tile("cpu-1", "cpu"),
                                 tile(types[k] + "-x", types[k], chosen_size)]),
                     page("B", [tile("clock-1", "clock"), tile("focus-1", "focus")])]
            st = doc(pages, settings={"weather-x": {"lat": 52.52, "lon": 13.405, "place": "Berlin"}},
                     appearance={"mode": "dark", "themeMode": themes[n % len(themes)],
                                 "accent": "#58A6FF", "bgStyle": bgs[n % len(bgs)],
                                 "animatedBg": (n % 2 == 0), "glass": 0.4 + 0.4 * (n % 2),
                                 "glow": (n % 2 == 0), "gridCols": 1 + (n % 2)})
            h.set_state(st); h.get_state(); n += 1
            # Occasional real touch input under load - ONLY when synthetic
            # input is opted in (XENEON_HW_INPUT=1) and not killed. The soak
            # itself is IPC-driven and stays fully useful without it.
            if n % 40 == 0 and h.input_allowed and not h.input_aborted:
                try:
                    h.swipe(*PAGE_SWIPE_NEXT, settle=0.2)
                    touch_swipes += 1
                except UserActivityAbort as e:
                    h.skip("soak_touch_remainder",
                           "KILL SWITCH aborted touch under load: %s; IPC soak continued" % e)
                except Exception as e:
                    # A broken gesture must not disappear behind a healthy IPC
                    # endurance result. Disable further input and make the
                    # incomplete hardware path first-class in the summary.
                    h.input_aborted = True
                    h.skip("soak_touch_remainder",
                           "touch under load failed: %s; IPC soak continued" % e)
        except Exception as e:
            crashed = True; err = str(e); break
        time.sleep(0.03)
    h.check("soak_no_crash", (not crashed) and h.ping(),
            "%d mixed cycles in %ds, hub alive=%s %s" % (n, seconds, h.ping(), err))
    if h.input_allowed:
        h.check("soak_touch_continuity", touch_swipes > 0 and not h.input_aborted,
                "%d successful touch swipes under load, aborted=%s" %
                (touch_swipes, h.input_aborted))


def manager_chrome(h):
    section("Manager chrome (Dark / Light / Default) + About")
    for theme in ("dark", "light", "default"):
        w = tempfile.mkdtemp(prefix="e2e-mgr-")
        os.makedirs(w + "/config/xeneon-edge-hub", exist_ok=True)
        open(w + "/config/xeneon-edge-hub/Xeneon Edge Manager.conf", "w").write(
            "[ManagerChrome]\nchromeTheme=%s\n" % theme)
        out = w + "/m.png"
        env = dict(os.environ)
        env.update({"XDG_CONFIG_HOME": w + "/config", "XDG_RUNTIME_DIR": w + "/run",
                    "QT_QPA_PLATFORM": "offscreen", "XENEON_GRAB": out, "XENEON_TAB": "0"})
        os.makedirs(w + "/run", mode=0o700, exist_ok=True)
        log = w + "/log"
        subprocess.run(["timeout", "-s", "KILL", "10", MANAGER], env=env,
                       stdout=open(log, "w"), stderr=subprocess.STDOUT)
        errs = 0
        try:
            t = open(log).read().lower()
            errs = t.count("is not a") + t.count("unavailable")
        except Exception:
            pass
        h.check("manager_%s_render" % theme, os.path.exists(out) and errs == 0,
                "grab=%s errors=%d" % (os.path.exists(out), errs))


def main():
    try:
        print("  binaries under test: %s" % assert_binaries_current())
    except RuntimeError as e:
        print("!!", e)
        return 2
    _kill_stale()
    audit_root = os.environ.get("XENEON_AUDIT_RUN_DIR", "")
    if audit_root:
        work = os.path.join(audit_root, "hardware-edge-e2e")
        os.mkdir(work, 0o700)
    else:
        work = tempfile.mkdtemp(prefix="edge-e2e-")
    print("EdgeHub E2E - workdir:", work, flush=True)
    h = E2E(work)
    print("Edge geom:", h.ex, h.ey, h.ew, h.eh, "canvas:", h.cw, h.ch, flush=True)
    h.write_config(doc([page("Start", [tile("clock-1", "clock")])]))
    if not h.check("hub_launch", h.launch_hub(), "control socket up"):
        h.summary(); return 1

    t0 = time.time()
    try:
        section("Widget lifecycle (add / render / resize / remove - all %d types)"
                % len(e2e_widgets.WIDGETS))
        e2e_widgets.run(h)
        section("Theming (all themes / backgrounds / accents / per-widget style)")
        e2e_theming.run(h)
        section("Interaction (synthetic touch: compact controls + page swipe)")
        e2e_interaction.run(h)
        ipc_robustness_and_perf(h)
        # The ordinary developer run retains the historical endurance section.
        # A release may set the duration to zero because its owner-approved
        # stability substitute is the separate, instrumented 30-minute
        # 14-widget observation. Zero omits only this duplicate endurance loop;
        # every functional section above still runs and must pass.
        soak_seconds = int(os.environ.get("E2E_SOAK_SECONDS", "1200"))
        if soak_seconds > 0:
            soak(h, seconds=soak_seconds)
    finally:
        h.cleanup()   # stop the spawned hub + remove its private runtime dir

    manager_chrome(h)

    p, total = h.summary()
    print("\nElapsed: %.1f min" % ((time.time() - t0) / 60.0), flush=True)
    complete = p == total and not h.skips
    print("RESULT:", "SUCCESS" if complete else "FAILURE", flush=True)
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main())
