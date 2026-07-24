#!/usr/bin/env python3
"""Unit tests for the synthetic-input safety layer - NO injection, no
/dev/uinput, no compositor traffic. Run:

    python3 -m unittest tests.hardware.test_input_safety -v      # from repo root
    python3 tests/hardware/test_input_safety.py                  # or directly

Covers the four structural guarantees:
  * the clamp: no emitted event stream can leave the Edge rect (CaptureSink);
  * the opt-in gate: real sinks refuse to exist without XENEON_HW_INPUT=1;
  * the kill switch: user-vs-ours attribution + abort, through the same
    byte-level path compositor traffic uses;
  * geometry: live kscreen-doctor parses to the known 3-monitor layout, and
    a stale XENEON_EDGE_GEOM override is rejected.
"""
import os
import shutil
import struct
import sys
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import input_guard  # noqa: E402
import uinput_touch as u  # noqa: E402

EDGE_RECT = (5120, 2880, 720, 2560)
CANVAS = (5840, 5440)

# Wild inputs: far outside, negative, corners of the whole canvas, huge.
WILD = [(-500, -500), (0, 0), (2560, 720), (5119, 2879), (5121, 2881),
        (5839, 5439), (10**6, 10**6), (5120 + 719, 2880 + 2559),
        (4000, 4000), (5500, 100), (100, 3000)]


class TestPointerClamp(unittest.TestCase):
    def _decode_abs(self, events):
        xs = [v for t, c, v in events if t == u.EV_ABS and c == u.ABS_X]
        ys = [v for t, c, v in events if t == u.EV_ABS and c == u.ABS_Y]
        return xs, ys

    def test_stream_never_leaves_rect(self):
        cs = u.CaptureSink()
        vp = u.VPointer(*CANVAS, EDGE_RECT, sink=cs)
        for cx, cy in WILD:
            vp.move(cx, cy)
            vp.tap(cx, cy, hold=0)
        vp.swipe(-1000, -1000, 10**5, 10**5, steps=10, dur=0)
        vp.swipe(0, 3000, 5839, 3000, steps=10, dur=0)
        xs, ys = self._decode_abs(cs.events)
        self.assertTrue(xs and ys)
        rx, ry, rw, rh = EDGE_RECT
        cw, ch = CANVAS
        # exact device-unit bounds of the rect (same arithmetic as the injector)
        ax_lo, ax_hi = int(rx / cw * u.ABS_MAX), int((rx + rw - 1) / cw * u.ABS_MAX)
        ay_lo, ay_hi = int(ry / ch * u.ABS_MAX), int((ry + rh - 1) / ch * u.ABS_MAX)
        self.assertTrue(all(ax_lo <= v <= ax_hi for v in xs),
                        "ABS_X escaped rect: %s not in [%d,%d]" %
                        (sorted(set(v for v in xs if not ax_lo <= v <= ax_hi)), ax_lo, ax_hi))
        self.assertTrue(all(ay_lo <= v <= ay_hi for v in ys),
                        "ABS_Y escaped rect: %s not in [%d,%d]" %
                        (sorted(set(v for v in ys if not ay_lo <= v <= ay_hi)), ay_lo, ay_hi))

    def test_rect_must_fit_canvas(self):
        with self.assertRaises(ValueError):
            u.VPointer(1000, 1000, EDGE_RECT, sink=u.CaptureSink())


class TestTouchClamp(unittest.TestCase):
    def test_touch_units_confined(self):
        cs = u.CaptureSink()
        vt = u.VTouch(EDGE_RECT, sink=cs)
        for lx, ly in [(-100, -100), (0, 0), (719, 2559), (720, 2560),
                       (10**6, -10**6), (360, 1280)]:
            vt.tap(lx, ly, hold=0)
        vt.swipe(-500, 99999, 99999, -500, steps=8, dur=0)
        pos = [(c, v) for t, c, v in cs.events
               if t == u.EV_ABS and c in (u.ABS_MT_POSITION_X, u.ABS_MT_POSITION_Y,
                                          u.ABS_X, u.ABS_Y)]
        self.assertTrue(pos)
        # Device range 0..ABS_MAX maps 1:1 onto the BOUND OUTPUT; clamped
        # local coords may only produce values in [0, ABS_MAX].
        self.assertTrue(all(0 <= v <= u.ABS_MAX for _, v in pos))

    def test_transforms_stay_in_range(self):
        for tr in ("identity", "rot90", "rot180", "rot270"):
            cs = u.CaptureSink()
            vt = u.VTouch(EDGE_RECT, sink=cs, transform=tr)
            vt.tap(-50, 99999, hold=0)
            vals = [v for t, c, v in cs.events if t == u.EV_ABS
                    and c in (u.ABS_MT_POSITION_X, u.ABS_MT_POSITION_Y)]
            self.assertTrue(all(0 <= v <= u.ABS_MAX for v in vals), tr)


class TestOptInGate(unittest.TestCase):
    def setUp(self):
        self._saved = os.environ.pop(u.GATE_ENV, None)

    def tearDown(self):
        if self._saved is not None:
            os.environ[u.GATE_ENV] = self._saved

    def test_real_sink_refused_without_gate(self):
        with self.assertRaises(u.InputGateError):
            u.UinputSink(guard=object())

    def test_real_sink_refused_without_guard(self):
        os.environ[u.GATE_ENV] = "1"
        with self.assertRaises(u.InputGateError):
            u.UinputSink(guard=None)   # kill switch is mandatory, not optional

    def test_default_injector_paths_are_gated(self):
        # sink=None means "real device": both injectors must refuse pre-open.
        with self.assertRaises(u.InputGateError):
            u.VPointer(*CANVAS, EDGE_RECT)
        with self.assertRaises(u.InputGateError):
            u.VTouch(EDGE_RECT)

    def test_capture_sink_is_exempt(self):
        u.VPointer(*CANVAS, EDGE_RECT, sink=u.CaptureSink())  # no raise


class TestKillSwitch(unittest.TestCase):
    def test_our_events_do_not_abort(self):
        led = input_guard.IdleLedger(attrib_window=input_guard.ATTRIB_WINDOW)
        led.arm()
        t = 1000.0
        led.note_emit(ts=t)
        # Exercise a delayed compositor echo beyond the old 150ms window.
        led.on_resumed(ts=t + 0.25)     # compositor reacting to OUR write
        self.assertFalse(led.aborted)

    def test_user_event_aborts(self):
        led = input_guard.IdleLedger(attrib_window=input_guard.ATTRIB_WINDOW)
        led.arm()
        led.note_emit(ts=1000.0)
        led.on_resumed(ts=1002.0)       # 2s after our last write -> a human
        self.assertTrue(led.aborted)
        self.assertIn("real input-device activity", led.abort_reason)

    def test_event_just_after_attribution_window_aborts(self):
        led = input_guard.IdleLedger(attrib_window=input_guard.ATTRIB_WINDOW)
        led.arm()
        t = 1000.0
        led.note_emit(ts=t)
        led.on_resumed(ts=t + input_guard.ATTRIB_WINDOW + 0.001)
        self.assertTrue(led.aborted)

    def test_unarmed_ledger_records_but_does_not_abort(self):
        led = input_guard.IdleLedger()
        led.on_resumed(ts=time.monotonic())
        self.assertFalse(led.aborted)
        self.assertEqual(led.user_idle_for(), 0.0)

    def test_guard_check_raises(self):
        led = input_guard.IdleLedger()
        led.arm()
        led.note_emit(ts=1.0)
        led.on_resumed(ts=5.0)
        g = input_guard.ActivityGuard(ledger=led)
        with self.assertRaises(input_guard.UserActivityAbort):
            g.check()

    def test_real_sink_cannot_emit_before_guard_is_armed(self):
        saved = os.environ.get(u.GATE_ENV)
        try:
            os.environ[u.GATE_ENV] = "1"
            g = input_guard.ActivityGuard(ledger=input_guard.IdleLedger())
            sink = u.UinputSink(g)
            # emit() rejects before it reaches os.write, so no /dev/uinput fd is
            # needed and this remains an injection-free unit test.
            with self.assertRaises(input_guard.UserActivityAbort):
                sink.emit(u.EV_KEY, u.BTN_LEFT, 1)
        finally:
            if saved is None:
                os.environ.pop(u.GATE_ENV, None)
            else:
                os.environ[u.GATE_ENV] = saved

    def test_detection_path_bytes(self):
        """Feed a crafted `resumed` through the SAME byte-level ingest path
        compositor traffic uses -> armed ledger aborts."""
        led = input_guard.IdleLedger()
        led.arm()
        mon = input_guard.WaylandIdleMonitor.for_test(led)
        resumed = struct.pack("<II", mon.NOTIF, (8 << 16) | 1)
        mon._ingest(resumed)
        self.assertTrue(led.aborted)

    def test_detection_path_handles_split_messages(self):
        led = input_guard.IdleLedger()
        led.arm()
        mon = input_guard.WaylandIdleMonitor.for_test(led)
        idled = struct.pack("<II", mon.NOTIF, (8 << 16) | 0)
        resumed = struct.pack("<II", mon.NOTIF, (8 << 16) | 1)
        blob = idled + resumed
        mon._ingest(blob[:5])            # partial header
        self.assertFalse(led.aborted)
        mon._ingest(blob[5:])
        self.assertTrue(led.aborted)

    def test_require_user_idle_times_out(self):
        led = input_guard.IdleLedger()   # starts "assume active"
        g = input_guard.ActivityGuard(ledger=led)
        with self.assertRaises(input_guard.UserActivityAbort):
            g.require_user_idle(seconds=3, timeout=0.3)

    def test_sink_write_path_aborts_mid_gesture(self):
        """A real-sink-shaped write path must stop the INSTANT the guard
        aborts - modelled with a stub sink calling the same guard hooks."""
        led = input_guard.IdleLedger()
        led.arm()
        g = input_guard.ActivityGuard(ledger=led)

        class StubRealSink(u.CaptureSink):
            def emit(self, t, c, v):
                g.check()
                super().emit(t, c, v)
                if t != u.EV_SYN:
                    g.note_emit()

        sink = StubRealSink()
        vt = u.VTouch(EDGE_RECT, sink=sink)
        vt.tap(100, 100, hold=0)                 # fine
        n = len(sink.events)
        led.on_resumed(ts=time.monotonic() + 10)  # owner touches the mouse
        with self.assertRaises(input_guard.UserActivityAbort):
            vt.swipe(0, 0, 500, 500, steps=5, dur=0)
        self.assertEqual(len(sink.events), n)    # not one event after abort


class TestGeometry(unittest.TestCase):
    KS_SAMPLE = (
        "Output: 1 DP-2 uuid\n\tenabled\n\tGeometry: 0,0 5120x1440\n"
        "Output: 2 DP-1 uuid\n\tenabled\n\tGeometry: 0,1440 5120x1440\n"
        "Output: 3 DP-3 uuid\n\tenabled\n\tGeometry: 5120,2880 720x2560\n")

    def test_parse_kscreen_sample(self):
        outs = u.parse_kscreen(self.KS_SAMPLE)
        self.assertEqual(outs, [("DP-2", 0, 0, 5120, 1440),
                                ("DP-1", 0, 1440, 5120, 1440),
                                ("DP-3", 5120, 2880, 720, 2560)])

    def test_live_outputs_retries_transient_failure_without_guessing(self):
        failed = mock.Mock(returncode=134, stdout="")
        recovered = mock.Mock(returncode=0, stdout=self.KS_SAMPLE)
        with mock.patch.object(u.subprocess, "run",
                               side_effect=[failed, recovered]) as run, \
             mock.patch.object(u.time, "sleep") as sleep:
            self.assertEqual(u._live_outputs(attempts=2),
                             [("DP-2", 0, 0, 5120, 1440),
                              ("DP-1", 0, 1440, 5120, 1440),
                              ("DP-3", 5120, 2880, 720, 2560)])
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(0.25)

    def test_live_outputs_fails_closed_after_retries(self):
        failed = mock.Mock(returncode=0, stdout="not a display layout")
        with mock.patch.object(u.subprocess, "run", return_value=failed) as run, \
             mock.patch.object(u.time, "sleep"):
            self.assertEqual(u._live_outputs(attempts=3), [])
        self.assertEqual(run.call_count, 3)

    @unittest.skipUnless(shutil.which("kscreen-doctor"), "kscreen-doctor not present")
    def test_live_layout_matches_this_box(self):
        for var in ("XENEON_EDGE_GEOM", "XENEON_CANVAS"):
            os.environ.pop(var, None)
        live = u._live_outputs()
        self.assertTrue(live, "live KScreen layout could not be read")
        name, ex, ey, ew, eh, cw, ch = u.detect_edge_ex()
        self.assertIn((name, ex, ey, ew, eh), live)
        self.assertEqual(name, "DP-3")
        self.assertEqual((ew, eh), (720, 2560))
        self.assertEqual(cw, max(x + width for _, x, _, width, _ in live))
        self.assertEqual(ch, max(y + height for _, _, y, _, height in live))

    @unittest.skipUnless(shutil.which("kscreen-doctor"), "kscreen-doctor not present")
    def test_stale_override_rejected(self):
        saved = {v: os.environ.get(v) for v in
                 ("XENEON_EDGE_GEOM", "XENEON_CANVAS", "XENEON_GEOM_TRUST")}
        try:
            os.environ.pop("XENEON_GEOM_TRUST", None)
            os.environ["XENEON_EDGE_GEOM"] = "100,100,720,2560"   # stale rect
            os.environ["XENEON_CANVAS"] = "5840,5440"
            with self.assertRaises(RuntimeError):
                u.detect_edge_ex()
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


if __name__ == "__main__":
    unittest.main(verbosity=2)
