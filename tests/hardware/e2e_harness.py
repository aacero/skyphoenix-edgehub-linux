#!/usr/bin/env python3
"""Shared harness for the real-hardware E2E suite (Xeneon Edge + Manager).

Provides: launch/stop the hub on the real Edge with an ISOLATED XDG_CONFIG_HOME
*and* an ISOLATED XDG_RUNTIME_DIR (so the user's live config, single-instance
lock and control socket are never touched), IPC (get/set UI state, ping),
synthetic touch via /dev/uinput (Edge-local coords), Edge screenshots (spectacle
crop), and pass/fail bookkeeping.

## Runtime-dir isolation (the stranding hazard, fixed)

The hub binds its control socket at $XDG_RUNTIME_DIR/xeneon-edge-hub-ctl
(app/src/control_socket_path.h) and its single-instance lock next to it. This
harness used to keep the REAL XDG_RUNTIME_DIR (Wayland's socket lives there),
which meant a spawned hub bound the REAL control socket and the harness's
cleanup os.remove() could strand the user's live hub - the hub keeps its
listening fd, so it looks healthy while the Manager can never reach it again.

The fix, per spawned hub:
  * XDG_RUNTIME_DIR points at a private, 0700, SHORT directory (sockaddr_un
    caps the socket path at ~107 bytes - never a deep workdir);
  * WAYLAND_DISPLAY is rewritten to an ABSOLUTE path into the real runtime
    dir. Wayland resolves an absolute WAYLAND_DISPLAY without consulting
    XDG_RUNTIME_DIR, so the hub still reaches the compositor and renders on
    the Edge while every socket/lock it creates lands in the private dir.
    (Verified on the real session: a hub launched exactly this way renders -
    grab-confirmed - with its control socket in the isolated dir.)
  * cleanup REFUSES to remove any socket it did not create: the guard checks
    the path is inside this instance's private runtime dir. There is no code
    path that removes the user's socket, even on a crashed or half-torn-down
    run.

Geometry is auto-detected via tests/hardware/uinput_touch.detect_edge_ex()
(kscreen-doctor); XENEON_EDGE_GEOM / XENEON_CANVAS overrides are cross-checked
against the live layout and rejected when stale.

## Synthetic-input safety (see README "Synthetic-input safety")

Injection is OPT-IN (XENEON_HW_INPUT=1). h.tap()/h.swipe() only work after
ensure_injection_ready() has, in this order:
  1. connected the user-activity kill switch (input_guard.ActivityGuard;
     no activity signal -> no injection) and waited for the owner to be
     hands-off for XENEON_HW_IDLE_SECONDS (default 3);
  2. render-probe VERIFIED the hub actually occupies the Edge rect (two
     distinct wallpaper states must show up in grabs of that exact rect);
  3. built a confined injector and IPC-verified a landing probe:
     preferred VTouch - an ABS_MT touchscreen physically bound to the Edge
     output via KWin's InputDevice.outputName DBus property (readback-
     verified, axis transform probed); fallback VPointer - arithmetically
     clamped to the Edge rect at the emit layer.
Any REAL input-device event afterwards raises UserActivityAbort and
permanently disables injection for the rest of the run (input_aborted).
"""
import os, sys, time, json, socket, subprocess, shutil, datetime, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import uinput_touch as u  # noqa: E402
import input_guard  # noqa: E402
from input_guard import UserActivityAbort  # noqa: E402  (re-exported for suites)


class InjectionRefused(RuntimeError):
    """A safety precondition failed - suites must skip loudly, not inject."""


# Edge-local centres of the two compact controls used to prove that an injector
# really lands on the verified Hub window. These are intentionally shared with
# e2e_interaction.py: the safety probe and behavior assertions must exercise the
# same real controls, rather than carrying two independently stale copies.
# Re-measured from a real DP-3 grab on 2026-07-20 after the per-size widget
# layouts landed (720x2560 KScreen geometry, current 1x1 tile layout).
PROBE_FOCUS_START = (140, 392)
# Re-measured from the exact b1cb2dd physical-panel grab after the hydration
# layout gained its detail strip. The old x=320 lands outside both pill buttons;
# fail-closed landing verification caught that drift before general injection.
PROBE_HYDRATION_PLUS = (264, 1330)
PROBE_HYDRATION_UNDO = (264, 1206)
# KScreen exposes the physically portrait panel as a rotated 720x2560 output.
# The Hub's horizontal SwipeView axis therefore appears vertical in an output
# grab: bottom-to-top advances, top-to-bottom returns.
PAGE_SWIPE_NEXT = (360, 2100, 360, 500)
PAGE_SWIPE_PREVIOUS = (360, 500, 360, 2100)

HUB = os.path.join(REPO, "build", "xeneon-edge-hub")
MANAGER = os.path.join(REPO, "build", "xeneon-edge-manager")

# The control socket's BASENAME - must match app/src/control_socket_path.h.
# Deliberately NOT a full path at module level any more: the old module-level
# SOCK pointed into the real XDG_RUNTIME_DIR, and everything that touched it
# (launch cleanup, stop_hub, raw IPC in the suites) operated on the LIVE hub's
# socket. The real path now only ever exists per-E2E-instance (self.sock),
# inside a runtime dir that instance owns.
SOCK_NAME = "xeneon-edge-hub-ctl"


def _abs_wayland_display(env):
    """Rewrite WAYLAND_DISPLAY to an absolute path into the REAL runtime dir.

    Wayland clients resolve a relative WAYLAND_DISPLAY against
    $XDG_RUNTIME_DIR; once we isolate that, the compositor socket would stop
    resolving. An ABSOLUTE WAYLAND_DISPLAY is used as-is (no XDG_RUNTIME_DIR
    involved), so the spawned hub keeps its compositor connection while its
    own sockets are private."""
    real_rt = os.environ.get("XDG_RUNTIME_DIR")
    wl = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    if not os.path.isabs(wl):
        if not real_rt:
            return  # no real runtime dir to resolve against; leave untouched
        wl = os.path.join(real_rt, wl)
    env["WAYLAND_DISPLAY"] = wl


def _wait_stable(path, tries=40, quiet=0.25):
    """Wait until `path` exists AND its size stops changing.

    Waiting for size>0 is not enough: spectacle writes a multi-megabyte PNG
    incrementally, so a fast reader gets "image file is truncated". Two
    consecutive equal sizes means the writer is done.
    """
    last = -1
    for _ in range(tries):
        try:
            sz = os.path.getsize(path)
        except OSError:
            sz = -1
        if sz > 0 and sz == last:
            return True
        last = sz
        time.sleep(quiet)
    return False



def assert_binaries_current(binaries=(HUB, MANAGER)):
    """Refuse to test a binary that does not match the working tree.

    A real-hardware run reported results for r190 while r200 was installed,
    because `cmake --build` alone never re-ran git describe (fixed in
    CMakeLists) AND --version was a hardcoded "0.1.0" (fixed in both mains).
    Testing a stale binary and reporting it as current is worse than not
    testing: every conclusion drawn from that run is about code nobody is
    running.

    Raises RuntimeError with what to do about it.
    """
    # A packaged candidate deliberately reports SemVer without the Git tag's
    # leading "v". Capture and release tooling can pin that exact package
    # version explicitly while ordinary developer runs remain tied to the
    # current git-describe identity.
    want = os.environ.get("XENEON_EXPECT_VERSION", "").strip()
    if not want:
        want = subprocess.run(["git", "describe", "--tags", "--always", "--dirty"],
                              cwd=REPO, capture_output=True, text=True).stdout.strip()
        if want.startswith("v"):
            want = want[1:]
    if not want:
        return None                      # no git (packaged tree) - nothing to check
    for b in binaries:
        if not os.path.exists(b):
            raise RuntimeError("missing binary %s - run ./scripts/build.sh" % b)
        try:
            got = subprocess.run([b, "--version"], capture_output=True,
                                 text=True, timeout=10).stdout.strip()
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                "%s did not answer --version within 10s - it probably launched "
                "its GUI instead of printing a version. Fix the binary; a "
                "version check that hangs is worse than none."
                % os.path.basename(b))
        if want not in got:
            raise RuntimeError(
                "STALE BINARY: %s reports %r but the tree is %r.\n"
                "  Rebuild before testing:  cmake -S . -B build && cmake --build build\n"
                "  (configure, not just build - git describe is evaluated at configure time)"
                % (os.path.basename(b), got, want))
    return want


class E2E:
    def __init__(self, workdir):
        self.work = workdir
        os.makedirs(self.work, exist_ok=True)
        self.cfg = os.path.join(self.work, "cfg")
        os.makedirs(os.path.join(self.cfg, "xeneon-edge-hub"), exist_ok=True)
        # Private runtime dir for the spawned hub. mkdtemp under /tmp, NOT
        # under workdir: the socket path must stay short (sockaddr_un ~107
        # bytes) and the dir must be 0700 (mkdtemp guarantees it).
        self.run_dir = tempfile.mkdtemp(prefix="xe-e2e-rt.")
        self.sock = os.path.join(self.run_dir, SOCK_NAME)
        self.proc = None
        self.results = []           # (name, ok, detail)
        g = u.detect_edge_ex()
        self.edge_name = g[0]
        self.ex, self.ey, self.ew, self.eh, self.cw, self.ch = g[1:]
        self.today = datetime.date.today().strftime("%Y-%m-%d")
        # -- synthetic-input safety state --
        self.input_allowed = os.environ.get(u.GATE_ENV) == "1"
        self.input_aborted = False
        self.guard = None
        self._injector = None       # ("touch", VTouch) | ("pointer", VPointer)
        # A pre-created fallback cannot be destroyed while the guard is armed:
        # KWin reports virtual-device removal as activity, which would trip the
        # next real-input check. Keep unused devices inert until final cleanup.
        self._standby_injectors = []
        self.window_verified = False
        self.skips = []             # (name, reason)

    # ── pass/fail ──────────────────────────────────────────────────────────
    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), str(detail)))
        print(("  PASS " if ok else "  FAIL ") + name + (" -> " + str(detail) if detail else ""), flush=True)
        return ok

    def skip(self, name, reason):
        """Loud, first-class skip - visible in output AND in the summary."""
        self.skips.append((name, reason))
        print("  SKIP " + name + " -> " + reason, flush=True)

    def summary(self):
        p = sum(1 for _, ok, _ in self.results if ok)
        print("\n==== %d / %d checks passed, %d skipped ====" % (p, len(self.results), len(self.skips)), flush=True)
        for n, ok, d in self.results:
            if not ok:
                print("   FAILED:", n, "->", d, flush=True)
        for n, r in self.skips:
            print("   SKIPPED:", n, "->", r, flush=True)
        return p, len(self.results)

    # ── config seeding + launch ────────────────────────────────────────────
    def write_config(self, ui_state_obj):
        ui = json.dumps(ui_state_obj)
        assert "'" not in ui, "ui_state must not contain a single quote"
        body = "\n".join([
            "schema_version = 1", "first_run_complete = true", "ui_state = '%s'" % ui, "",
            "[display]", 'fallback_behavior = "hide"', 'starter_layout = "productivity"', "",
            "[theme]", 'mode = "dark"', 'accent_color = "#58A6FF"', "reduced_motion = false", "",
            "[startup]", "autostart = false", "reconnect_on_hotplug = true", "notify_on_disconnect = false", "",
            "[widgets]", "version = 1", "instances = []", "",
        ])
        open(os.path.join(self.cfg, "xeneon-edge-hub", "config.toml"), "w").write(body)

    def _remove_own_socket(self):
        """Remove a stale socket - ONLY ours. The guard is structural: this
        refuses any path outside the private runtime dir this instance
        created, so no bug upstream can turn it into `os.remove(<live sock>)`
        (the exact mistake that used to strand the user's running hub)."""
        sock_dir = os.path.dirname(os.path.realpath(self.sock))
        if sock_dir != os.path.realpath(self.run_dir):
            print("  REFUSING to remove socket outside our runtime dir:", self.sock, flush=True)
            return
        try:
            if os.path.exists(self.sock):
                os.remove(self.sock)
        except OSError:
            pass

    def launch_hub(self, wait=15):
        self._remove_own_socket()   # stale leftover from a crashed prior run
        env = dict(os.environ)
        env["XDG_CONFIG_HOME"] = self.cfg      # isolate config
        env["XDG_RUNTIME_DIR"] = self.run_dir  # isolate socket + lock
        _abs_wayland_display(env)              # …while keeping the compositor
        self.log = open(os.path.join(self.work, "hub.log"), "w")
        self.proc = subprocess.Popen([HUB], cwd=REPO, env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        deadline = time.time() + wait
        while time.time() < deadline:
            if os.path.exists(self.sock):
                try:
                    self.get_state(); return True
                except Exception:
                    pass
            time.sleep(0.3)
        return False

    def stop_hub(self):
        if self.proc:
            try:
                self.proc.terminate()
                try: self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired: self.proc.kill()
            except Exception:
                pass
            self.proc = None
        self._remove_own_socket()

    def cleanup(self):
        """Remove the private runtime dir (call after the final stop_hub)."""
        self.close_injector()
        if self.guard is not None:
            self.guard.close()
            self.guard = None
        self.stop_hub()
        shutil.rmtree(self.run_dir, ignore_errors=True)

    # ── IPC ────────────────────────────────────────────────────────────────
    def _ipc(self, msg, timeout=5):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout); s.connect(self.sock)
        s.sendall((json.dumps(msg) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk: break
            buf += chunk
        s.close()
        return json.loads(buf.decode().split("\n")[0])

    def ping(self):
        try: return self._ipc({"type": "ping"}).get("type") in ("pong", "ok", "ping")
        except Exception: return False

    def get_state(self):
        return json.loads(self._ipc({"type": "getUiState"})["state"])

    def hub_current_page(self):
        """The 0-based screen the panel is currently SHOWING (or -1 if the hub
        does not report it). A sibling field of the getUiState reply, like
        `rotation` - NOT inside `state`. Used to verify the hub mirrors the
        Manager's selected screen (O1)."""
        return self._ipc({"type": "getUiState"}).get("currentPage", -1)

    def set_state(self, obj):
        self._ipc({"type": "setUiState", "state": json.dumps(obj)})
        time.sleep(0.5)   # let the hub apply + render

    def settings(self):
        return self.get_state().get("settings", {})

    # ── synthetic touch (Edge-local pixels 0..ew, 0..eh) ───────────────────
    #
    # SAFETY PIPELINE - no injection happens before every step here passed.
    # See the module docstring; each step is structural, not a convention.

    def verify_target_window(self):
        """Render-probe: prove OUR hub's pixels occupy the Edge rect before
        any event is emitted. Two visually opposite states must both show up
        in grabs cropped to exactly the target rect; a hub that landed on
        another output (KWin placement, stale geometry, wrong screen) fails
        this and injection is refused."""
        if self.window_verified:
            return True
        probes = [("dark", {"mode": "dark", "themeMode": "midnight", "accent": "#58A6FF",
                            "bgStyle": "none", "animatedBg": False, "glass": 0.0,
                            "glow": False, "gridCols": 1},
                   "qrc:/wallpapers/midnight.png"),
                  ("light", {"mode": "light", "themeMode": "light", "accent": "#58A6FF",
                             "bgStyle": "none", "animatedBg": False, "glass": 0.0,
                             "glow": False, "gridCols": 1},
                   "qrc:/wallpapers/sunset.png")]
        shots = []
        for tag, app, wp in probes:
            self.set_state(doc([{"name": "V", "bg": {"wallpaper": wp},
                                 "tiles": [tile("moon-v", "moon")]}], appearance=app))
            time.sleep(0.4)
            p = os.path.join(self.work, "verify_%s.png" % tag)
            if not self.grab(p):
                print("  VERIFY-WINDOW failed: no grab", flush=True)
                return False
            shots.append(p)
        try:
            from PIL import Image
            avg = [Image.open(s).convert("RGB").resize((1, 1)).getpixel((0, 0)) for s in shots]
            dist = sum((a - b) ** 2 for a, b in zip(*avg)) ** 0.5
        except Exception as e:
            print("  VERIFY-WINDOW failed:", e, flush=True)
            return False
        self.window_verified = dist > 25
        print("  VERIFY-WINDOW %s: state-A/B colour distance %.0f (need >25) at rect %d,%d %dx%d"
              % ("OK" if self.window_verified else "FAILED", dist,
                 self.ex, self.ey, self.ew, self.eh), flush=True)
        return self.window_verified

    def _seed_probe_layout(self):
        """The pixel-verified control layout (same as e2e_interaction's) with
        two independent probe controls at the shared PROBE_* coordinates above.
        A real-panel grab is required whenever the widget layouts move; the IPC
        checks below make stale coordinates fail closed before general input."""
        self.set_state(doc([page("Probe", [
            tile("focus-pr", "focus", "1x1"),
            tile("hydration-pr", "hydration", "1x1"),
            tile("tasks-pr", "tasks", "1x2"),
        ])], settings={
            "hydration-pr": {"count": 0, "goal": 8, "day": self.today},
            "focus-pr": {"preset": "classic", "phase": "work", "running": False,
                         "endEpoch": 0, "pausedRemaining": 1500, "doneToday": 0,
                         "day": self.today, "points": 0, "dailyGoal": 4,
                         "rewardPoints": True, "celebrate": True, "autoStartBreak": False},
        }))

    def _probe_landing(self, tap_fn, label):
        """IPC-verified landing probe at TWO independent points: hydration '+'
        must increment AND focus Start must flip `running`. Two hits at
        distinct pixels rule out both a mis-aimed injector and a lucky stray
        tap locking in a wrong axis transform."""
        self._seed_probe_layout()
        tap_fn(*PROBE_HYDRATION_PLUS)
        time.sleep(0.4)
        got = self.settings().get("hydration-pr", {}).get("count")
        print("  LANDING-PROBE %s [1/2]: hydration count=%s (want 1)" % (label, got), flush=True)
        if got != 1:
            return False
        tap_fn(*PROBE_FOCUS_START)
        time.sleep(0.4)
        run = self.settings().get("focus-pr", {}).get("running")
        print("  LANDING-PROBE %s [2/2]: focus running=%s (want True)" % (label, run), flush=True)
        return run is True

    def ensure_injection_ready(self):
        """Build (once) the guarded, verified injector. Raises InjectionRefused
        / InputGateError / UserActivityAbort - callers turn that into a loud
        skip. NEVER emits anything before window verification passed."""
        if self._injector is not None:
            return self._injector[0]
        if not self.input_allowed:
            raise u.InputGateError(
                "synthetic input is opt-in: run with %s=1" % u.GATE_ENV)
        if self.input_aborted:
            raise UserActivityAbort("injection disabled earlier in this run")
        if not self.ping():
            raise InjectionRefused("hub not reachable over IPC")
        # 1. kill switch first - without an activity signal nothing may inject
        if self.guard is None:
            self.guard = input_guard.ActivityGuard.connect()
        self.guard.require_user_idle()          # owner hands-off for >= N s
        # 2. target-window verification (render probe), BEFORE the first event
        if not self.verify_target_window():
            raise InjectionRefused("hub window not verified at the Edge rect -> no injection")
        # 3. Create/map the inert devices BEFORE arming. KWin may report device
        # hot-plug itself as a resumed activity event; every UinputSink write is
        # structurally forbidden while unarmed, so it is safe to let that settle
        # and require owner-idle a second time. Creating a fallback now also means
        # no device enumeration can occur after the guard is live.
        vt = None
        vp = None
        try:
            # 3a. preferred: ABS_MT touchscreen physically bound to the Edge output
            try:
                vt = u.VTouch((0, 0, self.ew, self.eh), guard=self.guard)
                try:
                    vt.map_to_output(self.edge_name)   # KWin readback-verified
                    print("  VTouch bound to output %s (%s)" % (self.edge_name, vt.mapped_path), flush=True)
                except u.OutputMappingError as e:
                    print("  VTouch output mapping unavailable (%s); falling back" % e, flush=True)
                    vt.close(); vt = None
            except OSError as e:
                print("  VTouch device creation failed (%s); falling back" % e, flush=True)

            # 3b. Prepare the whole-canvas pointer fallback before arming too.
            try:
                vp = u.VPointer(self.cw, self.ch, (self.ex, self.ey, self.ew, self.eh),
                                guard=self.guard)
            except OSError as e:
                print("  VPointer device creation failed (%s)" % e, flush=True)
                if vt is None:
                    raise InjectionRefused("no confined injector could be created")

            # Device enumeration and any real owner activity must now be quiet
            # for the full idle interval. Only after that proof can emit() run.
            self.guard.require_user_idle()
            self.guard.arm()

            if vt is not None:
                # rot270 first: measured on this box 2026-07-16 (KWin maps the MT
                # device in the panel's NATIVE landscape axes, then applies the
                # output's 270-degree transform). Fewer stray probe taps this way.
                for tr in ("rot270", "identity", "rot90", "rot180"):
                    vt.transform = tr
                    if self._probe_landing(vt.tap, "touch/" + tr):
                        if vp is not None:
                            self._standby_injectors.append(vp); vp = None
                        self._injector = ("touch", vt)
                        return "touch"
                print("  VTouch landing probe failed for all transforms; falling back", flush=True)
                self._standby_injectors.append(vt); vt = None

            if vp is None:
                raise InjectionRefused("touch landing failed and pointer fallback is unavailable")
            if self._probe_landing(lambda lx, ly: vp.tap(self.ex + lx, self.ey + ly),
                                   "pointer/clamped"):
                self._injector = ("pointer", vp)
                return "pointer"
            vp.close(); vp = None
            raise InjectionRefused("no injector passed the IPC landing probe -> refusing to inject blind")
        except UserActivityAbort:
            self.input_aborted = True           # kill switch mid-probe: stay off
            for dev in (vt, vp):
                if dev is None:
                    continue
                try:
                    dev.close()
                except Exception:
                    pass
            raise
        except Exception:
            # Do not leak a half-created uinput device when mapping, IPC, or a
            # landing probe fails unexpectedly. If the guard was already armed,
            # device teardown itself may be observed as activity, so this run
            # must never attempt another injection after cleanup.
            if self.guard is not None and self.guard.ledger.is_armed():
                self.input_aborted = True
            for dev in (vt, vp):
                if dev is None:
                    continue
                try:
                    dev.close()
                except Exception:
                    pass
            raise

    def _gesture(self, fn):
        try:
            fn()
        except UserActivityAbort:
            self.input_aborted = True           # kill switch: stay off for good
            self.close_injector()
            raise

    def tap(self, lx, ly, settle=0.6):
        kind = self.ensure_injection_ready()
        dev = self._injector[1]
        if kind == "touch":
            self._gesture(lambda: dev.tap(lx, ly))
        else:
            self._gesture(lambda: dev.tap(self.ex + lx, self.ey + ly))
        time.sleep(settle)

    def swipe(self, lx0, ly0, lx1, ly1, settle=0.7):
        kind = self.ensure_injection_ready()
        dev = self._injector[1]
        if kind == "touch":
            self._gesture(lambda: dev.swipe(lx0, ly0, lx1, ly1))
        else:
            self._gesture(lambda: dev.swipe(self.ex + lx0, self.ey + ly0,
                                            self.ex + lx1, self.ey + ly1))
        time.sleep(settle)

    def close_injector(self):
        if self._injector is not None:
            try:
                self._injector[1].close()
            except Exception:
                pass
            self._injector = None
        for dev in self._standby_injectors:
            try:
                dev.close()
            except Exception:
                pass
        self._standby_injectors = []

    # ── screenshots ────────────────────────────────────────────────────────
    def grab(self, path):
        """Grab the full canvas and crop to the Edge rect.

        Spectacle is a SINGLE-INSTANCE KDE app and `-b` returns rc=0 whether or
        not it actually captured. Reusing one `_full.png` across rapid calls
        therefore produced silent staleness: a second grab <1s after the first
        would leave the PREVIOUS file in place, so two different UI states
        compared byte-identical. That is what made verify_target_window report
        "colour distance 0" and refuse injection on a hub that was rendering
        perfectly - measured on the real panel 2026-07-19.

        So: unique filename per grab, delete before capture, and WAIT for the
        file to actually appear rather than trusting the exit code.
        """
        self._grab_seq = getattr(self, "_grab_seq", 0) + 1
        full = os.path.join(self.work, "_full_%03d.png" % self._grab_seq)
        try:
            os.unlink(full)
        except OSError:
            pass
        for attempt in (1, 2):
            subprocess.run(["spectacle", "-b", "-n", "-f", "-o", full],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if _wait_stable(full):
                break
            if attempt == 1:
                time.sleep(1.0)                       # let the previous instance exit
        if not _wait_stable(full, tries=4):
            print("  grab failed: spectacle produced no file at", full)
            return False
        try:
            from PIL import Image
            Image.open(full).crop((self.ex, self.ey, self.ex + self.ew, self.ey + self.eh)).save(path)
        except Exception as e:
            print("  grab failed:", e)
            return False
        finally:
            try:
                os.unlink(full)                       # full-canvas frames are large
            except OSError:
                pass
        return os.path.exists(path)


# ── config helpers (build ui_state docs) ──────────────────────────────────
def page(name, tiles):
    return {"name": name, "tiles": tiles}

def tile(tid, ttype, size="1x1"):
    """Build a tile using the current persisted size contract.

    The dashboard migrated legacy numeric ``w``/``h`` spans to the semantic
    ``size`` strings defined by WidgetSizes.qml.  Keeping this helper strict
    makes stale hardware tests fail at construction time instead of appearing
    to resize a tile whose legacy fields are immediately discarded.
    """
    if not isinstance(size, str):
        raise TypeError("tile size must be a WidgetSizes string, got %r" % (size,))
    return {"id": tid, "type": ttype, "size": size}

def doc(pages, settings=None, appearance=None):
    return {"version": 1,
            "appearance": appearance or {"mode": "dark", "themeMode": "midnight",
                                         "accent": "#58A6FF", "bgStyle": "orbs",
                                         "animatedBg": True, "glass": 0.55, "glow": True, "gridCols": 1},
            "settings": settings or {},
            "pages": pages}
