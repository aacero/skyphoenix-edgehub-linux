"""User-activity kill switch for synthetic input on a LIVE session.

Safety contract (see tests/hardware/README.md, "Synthetic-input safety"):
any REAL input-device event (the owner touching mouse/keyboard/touchscreen)
during an injection run must abort injection immediately, and injection must
never START while the owner has been active within the last N seconds
(default N = 3, `XENEON_HW_IDLE_SECONDS`).

Why N = 3 s: human interaction bursts (typing, mouse repositioning) have
intra-burst gaps well under 2 s, so 3 s of silence reliably separates "the
owner is using the machine" from "the owner paused"; anything much longer
only stalls the suite on a busy desktop without adding safety (the kill
switch - not the idle gate - is what protects against the owner *resuming*).

## How activity is detected on this box

/dev/input/event* is NOT readable by the test user (root:input, mode 660, no
ACL), so raw evdev monitoring is impossible without system changes. Instead
we speak the Wayland `ext-idle-notify-v1` protocol directly to the
compositor (pure python, no libraries): an idle notification with a short
timeout flips between `idled` (quiet for >= timeout) and `resumed` (first
input after an idle period). Every `resumed` is an input event observed by
the COMPOSITOR - the same pipeline real devices feed.

Our own synthetic events also produce `resumed`, so events are attributed:
a `resumed` arriving within ATTRIB_WINDOW of our last synthetic write is
ours; anything else is the owner -> abort. Honest limitation: a real event
landing inside that small window right after one of our writes is masked
until the next idle cycle (~probe timeout, 100 ms). The pre-gesture idle
gate plus per-event abort checks keep the exposure to fractions of a second.

`WaylandIdleMonitor._ingest()` is the single byte-level entry point for
compositor traffic; tests and the live kill-switch demo feed a crafted
`resumed` event through it, exercising the identical detection path.
"""
import os
import socket
import struct
import threading
import time

# KWin can deliver the compositor-side `resumed` notification noticeably after
# the final uinput write under rendering load (0.173s observed on the Edge E2E).
# Keep enough scheduling margin that our own input is not mislabeled as the
# owner while still bounding the blind attribution interval well below a second.
ATTRIB_WINDOW = 0.35     # s: `resumed` within this of our own write -> ours
IDLE_PROBE_MS = 100      # ext-idle-notify timeout for the activity probe
DEFAULT_IDLE_SECONDS = float(os.environ.get("XENEON_HW_IDLE_SECONDS", "3"))
DEFAULT_IDLE_TIMEOUT = float(os.environ.get("XENEON_HW_IDLE_TIMEOUT", "90"))


class UserActivityAbort(RuntimeError):
    """Raised the moment real user input is detected during injection."""


class GuardUnavailable(RuntimeError):
    """The compositor offers no usable activity signal -> injection refused."""


class IdleLedger:
    """Pure attribution/abort logic (unit-testable without a compositor).

    State machine fed by three notifications:
      note_emit()   -- we just wrote a synthetic event to the kernel
      on_idled(ts)  -- compositor: no input for IDLE_PROBE_MS
      on_resumed(ts)-- compositor: first input after an idle period
    """

    def __init__(self, attrib_window=ATTRIB_WINDOW):
        now = time.monotonic()
        self._lock = threading.Lock()
        self.attrib_window = attrib_window
        self.last_emit_ts = None
        # Conservative start: assume the owner is active RIGHT NOW until the
        # compositor proves otherwise with an `idled`.
        self.last_user_activity_ts = now
        self.session_active = True       # between resumed..idled
        self.active_is_user = True       # who caused the current active phase
        self.armed = False               # only an armed ledger aborts
        self.aborted = False
        self.abort_reason = ""

    def note_emit(self, ts=None):
        with self._lock:
            self.last_emit_ts = time.monotonic() if ts is None else ts

    def on_idled(self, ts=None):
        with self._lock:
            self.session_active = False
            self.active_is_user = False

    def on_resumed(self, ts=None):
        ts = time.monotonic() if ts is None else ts
        with self._lock:
            ours = (
                self.last_emit_ts is not None
                and (ts - self.last_emit_ts) <= self.attrib_window
            )
            self.session_active = True
            self.active_is_user = not ours
            if not ours:
                self.last_user_activity_ts = ts
                if self.armed and not self.aborted:
                    self.aborted = True
                    if self.last_emit_ts is None:
                        self.abort_reason = (
                            "real input-device activity before the first "
                            "synthetic event")
                    else:
                        self.abort_reason = (
                            "real input-device activity %.3fs after the last "
                            "synthetic event" % (ts - self.last_emit_ts))

    def arm(self):
        with self._lock:
            self.armed = True

    def is_armed(self):
        with self._lock:
            return self.armed

    def user_idle_for(self):
        """Seconds since the last known REAL user activity (0 while active)."""
        with self._lock:
            if self.session_active and self.active_is_user:
                return 0.0
            return time.monotonic() - self.last_user_activity_ts


# ── minimal Wayland wire helpers ─────────────────────────────────────────

def _wl_msg(obj, opcode, body=b""):
    return struct.pack("<II", obj, ((8 + len(body)) << 16) | opcode) + body


def _wl_string(s):
    b = s.encode() + b"\0"
    return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)


def _parse_string(body, off):
    (n,) = struct.unpack_from("<I", body, off)
    s = body[off + 4: off + 4 + n - 1].decode()
    return s, off + 4 + n + (-n % 4)


def wayland_socket_path():
    wl = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    if os.path.isabs(wl):
        return wl
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if not rt:
        raise GuardUnavailable("no XDG_RUNTIME_DIR to resolve WAYLAND_DISPLAY")
    return os.path.join(rt, wl)


class WaylandIdleMonitor:
    """ext-idle-notify-v1 client feeding an IdleLedger.

    Object ids (client-allocated): 2=wl_registry, 3=sync callback,
    4=wl_seat, 5=ext_idle_notifier_v1, 6=ext_idle_notification_v1.
    """

    REGISTRY, SYNC_CB, SEAT, NOTIFIER, NOTIF = 2, 3, 4, 5, 6

    def __init__(self, ledger):
        self.ledger = ledger
        self.sock = None
        self._buf = b""
        self._globals = {}          # interface -> (name, version)
        self._stop = threading.Event()
        self._thread = None
        self.notifier_version = 0

    # -- construction paths -------------------------------------------------
    @classmethod
    def connect(cls, ledger):
        m = cls(ledger)
        path = wayland_socket_path()
        try:
            m.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            m.sock.settimeout(5)
            m.sock.connect(path)
        except OSError as e:
            raise GuardUnavailable("cannot connect to compositor at %s: %s" % (path, e))
        m._setup()
        m._thread = threading.Thread(target=m._loop, daemon=True,
                                     name="xeneon-idle-monitor")
        m._thread.start()
        return m

    @classmethod
    def for_test(cls, ledger):
        """Offline instance: no socket; feed bytes via _ingest()."""
        return cls(ledger)

    # -- protocol setup -------------------------------------------------------
    def _send(self, data):
        self.sock.sendall(data)

    def _roundtrip(self, cb_id):
        """wl_display.sync and pump until the callback fires."""
        done = {"hit": False}
        self._send(_wl_msg(1, 0, struct.pack("<I", cb_id)))
        deadline = time.time() + 5
        while not done["hit"]:
            if time.time() > deadline:
                raise GuardUnavailable("compositor roundtrip timed out")
            self._pump(lambda o, op, b: done.update(hit=True)
                       if o == cb_id and op == 0 else self._handle(o, op, b))

    def _setup(self):
        self._send(_wl_msg(1, 1, struct.pack("<I", self.REGISTRY)))  # get_registry
        self._roundtrip(self.SYNC_CB)
        if "wl_seat" not in self._globals:
            raise GuardUnavailable("compositor exposes no wl_seat")
        if "ext_idle_notifier_v1" not in self._globals:
            raise GuardUnavailable(
                "compositor lacks ext-idle-notify-v1 -> no user-activity "
                "signal -> synthetic input is refused")
        name, ver = self._globals["wl_seat"]
        self._bind(name, "wl_seat", 1, self.SEAT)
        name, ver = self._globals["ext_idle_notifier_v1"]
        self.notifier_version = min(ver, 2)
        self._bind(name, "ext_idle_notifier_v1", self.notifier_version, self.NOTIFIER)
        # v2 `get_input_idle_notification` ignores idle inhibitors (a video
        # keeping the session "active" must not mask real input); fall back
        # to v1 semantics when the compositor is older.
        opcode = 2 if self.notifier_version >= 2 else 1
        self._send(_wl_msg(self.NOTIFIER, opcode,
                           struct.pack("<III", self.NOTIF, IDLE_PROBE_MS, self.SEAT)))
        self._roundtrip(self.SYNC_CB)   # surface immediate protocol errors

    def _bind(self, gname, iface, version, new_id):
        body = struct.pack("<I", gname) + _wl_string(iface) + struct.pack("<II", version, new_id)
        self._send(_wl_msg(self.REGISTRY, 0, body))

    # -- event plumbing -------------------------------------------------------
    def _pump(self, handler=None):
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout:
            return
        if not chunk:
            raise GuardUnavailable("compositor closed the connection")
        self._ingest(chunk, handler)

    def _ingest(self, data, handler=None):
        """Single byte-level entry point for compositor traffic. Tests and
        the live kill-switch demo feed crafted events through THIS path."""
        self._buf += data
        handler = handler or self._handle
        while len(self._buf) >= 8:
            obj, szop = struct.unpack_from("<II", self._buf)
            size, opcode = szop >> 16, szop & 0xFFFF
            if size < 8 or len(self._buf) < size:
                break
            body = self._buf[8:size]
            self._buf = self._buf[size:]
            handler(obj, opcode, body)

    def _handle(self, obj, opcode, body):
        if obj == 1 and opcode == 0:                 # wl_display.error
            oid, code = struct.unpack_from("<II", body)
            msg, _ = _parse_string(body, 8)
            raise GuardUnavailable("wayland error on object %d code %d: %s" % (oid, code, msg))
        if obj == self.REGISTRY and opcode == 0:     # registry.global
            (gname,) = struct.unpack_from("<I", body)
            iface, off = _parse_string(body, 4)
            (ver,) = struct.unpack_from("<I", body, off)
            self._globals[iface] = (gname, ver)
        elif obj == self.NOTIF and opcode == 0:      # idled
            self.ledger.on_idled()
        elif obj == self.NOTIF and opcode == 1:      # resumed
            self.ledger.on_resumed()
        # everything else (seat caps/name, delete_id, ...) is irrelevant

    def _loop(self):
        self.sock.settimeout(0.25)
        while not self._stop.is_set():
            try:
                self._pump()
            except GuardUnavailable:
                # Connection died mid-run: fail SAFE - report as user activity
                # so any in-flight injection aborts rather than flying blind.
                self.ledger.on_resumed(time.monotonic() + 10 * ATTRIB_WINDOW)
                return

    def close(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass


class ActivityGuard:
    """Facade the injectors consult around EVERY kernel write.

    check()             raise UserActivityAbort if the owner touched anything
    note_emit()         timestamp our own synthetic write (attribution)
    require_user_idle() block until the owner has been idle >= N seconds
    """

    def __init__(self, ledger=None, monitor=None):
        self.ledger = ledger or IdleLedger()
        self.monitor = monitor   # None in unit tests (fed ledgers)

    @classmethod
    def connect(cls):
        ledger = IdleLedger()
        monitor = WaylandIdleMonitor.connect(ledger)
        return cls(ledger, monitor)

    def check(self):
        if self.ledger.aborted:
            raise UserActivityAbort("KILL SWITCH: " + self.ledger.abort_reason)

    def require_armed(self):
        """Refuse a kernel write until the live kill switch is armed.

        Device creation itself is deliberately allowed before arming so KWin's
        device-hotplug activity can settle and pass a second idle gate. No input
        event may cross that boundary.
        """
        if not self.ledger.is_armed():
            raise UserActivityAbort(
                "KILL SWITCH: synthetic event attempted before guard was armed")

    def note_emit(self):
        self.ledger.note_emit()

    def arm(self):
        self.ledger.arm()

    def require_user_idle(self, seconds=DEFAULT_IDLE_SECONDS,
                          timeout=DEFAULT_IDLE_TIMEOUT):
        """Block until the owner has been hands-off for `seconds`. Raises
        UserActivityAbort if that never happens within `timeout` (the suite
        must skip loudly, not inject into an in-use session)."""
        deadline = time.monotonic() + timeout
        while True:
            self.check()
            if self.ledger.user_idle_for() >= seconds:
                return
            if time.monotonic() > deadline:
                raise UserActivityAbort(
                    "owner never idle for %.1fs within %.0fs - refusing to inject"
                    % (seconds, timeout))
            time.sleep(0.1)

    def close(self):
        if self.monitor:
            self.monitor.close()
