#!/usr/bin/env python3
"""Injection-free contracts for the real-hardware E2E harness.

These checks keep the expensive panel suite aligned with the QML registry and
persisted tile schema.  They intentionally need neither a compositor nor the
Xeneon display, so CI can catch drift before a hardware run.
"""

import ast
import os
import re
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock


HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from e2e_harness import assert_binaries_current, tile  # noqa: E402
import e2e_widgets  # noqa: E402
import edge_e2e  # noqa: E402
import input_guard  # noqa: E402
import manager_window  # noqa: E402


class TestTileContract(unittest.TestCase):
    def test_tile_uses_only_the_named_size_schema(self):
        self.assertEqual(
            tile("clock-1", "clock", "1x1.5"),
            {"id": "clock-1", "type": "clock", "size": "1x1.5"},
        )

    def test_legacy_numeric_spans_fail_loudly(self):
        with self.assertRaises(TypeError):
            tile("clock-1", "clock", 1)


class TestPackagedCandidateIdentity(unittest.TestCase):
    def test_explicit_package_version_accepts_semver_without_tag_prefix(self):
        result = SimpleNamespace(stdout="Xeneon Edge Linux Hub 1.0.0-beta.1\n")
        with mock.patch.dict(os.environ,
                             {"XENEON_EXPECT_VERSION": "1.0.0-beta.1"}), \
             mock.patch("e2e_harness.os.path.exists", return_value=True), \
             mock.patch("e2e_harness.subprocess.run", return_value=result):
            self.assertEqual(
                assert_binaries_current(("/candidate/xeneon-edge-hub",)),
                "1.0.0-beta.1",
            )

    def test_explicit_package_version_still_rejects_a_stale_binary(self):
        result = SimpleNamespace(stdout="Xeneon Edge Linux Hub 1.0.0-alpha.2\n")
        with mock.patch.dict(os.environ,
                             {"XENEON_EXPECT_VERSION": "1.0.0-beta.1"}), \
             mock.patch("e2e_harness.os.path.exists", return_value=True), \
             mock.patch("e2e_harness.subprocess.run", return_value=result):
            with self.assertRaises(RuntimeError):
                assert_binaries_current(("/candidate/xeneon-edge-hub",))


class TestCatalogContract(unittest.TestCase):
    def test_lifecycle_matrix_covers_every_catalog_type(self):
        self.assertEqual(set(e2e_widgets.WIDGETS), e2e_widgets._catalog_types())

    def test_every_widget_has_a_real_resize_target(self):
        for wtype, spec in e2e_widgets.WIDGET_SPECS.items():
            with self.subTest(widget=wtype):
                self.assertIn(spec["default"], spec["sizes"])
                self.assertTrue(any(size != spec["default"] for size in spec["sizes"]))

    def test_catalog_sizes_are_legal_widget_sizes(self):
        sizes_path = os.path.join(REPO, "ui", "qml", "WidgetSizes.qml")
        with open(sizes_path, "r", errors="replace") as source:
            legal = set(re.findall(r'^\s*"([0-9.]+x[0-9.]+)"\s*:', source.read(), re.M))
        self.assertTrue(legal)
        used = {size for spec in e2e_widgets.WIDGET_SPECS.values()
                for size in spec["sizes"]}
        self.assertEqual(set(), used - legal)


class TestManagerInputLifecycle(unittest.TestCase):
    """Every input-emitting Manager driver must arm after its pointer exists.

    Creating a uinput device may itself wake the compositor.  The required
    sequence is therefore: first idle proof, create inert pointer, second idle
    proof, arm, emit.  UinputSink enforces the last boundary at runtime; this
    injection-free contract keeps every Manager entry point from forgetting
    the setup step again.
    """

    INPUT_FILES = (
        "manager_gui_test.py",
        "manager_hub_boundary.py",
        "manager_page_mirror_test.py",
        "manager_drag_reorder_test.py",
    )
    INPUT_FREE_FILES = ("manager_reflection_test.py",)
    EMITTERS = {"tap", "swipe", "move", "press", "release", "click", "drag"}

    @staticmethod
    def _call_lines(tree, names):
        return sorted(
            node.lineno
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr in names
        )

    def test_manager_drivers_settle_arm_then_emit(self):
        for filename in self.INPUT_FILES:
            with self.subTest(driver=filename):
                path = os.path.join(HERE, filename)
                with open(path, "r", encoding="utf-8") as source:
                    tree = ast.parse(source.read(), filename=path)
                pointer_lines = self._call_lines(tree, {"VPointer"})
                idle_lines = self._call_lines(tree, {"require_user_idle"})
                arm_lines = self._call_lines(tree, {"arm"})
                emit_lines = self._call_lines(tree, self.EMITTERS)
                self.assertEqual(1, len(pointer_lines))
                pointer = pointer_lines[0]
                idle_after_device = next((line for line in idle_lines if line > pointer), None)
                arm = next((line for line in arm_lines
                            if idle_after_device is not None and line > idle_after_device), None)
                first_emit = next((line for line in emit_lines if line > pointer), None)
                self.assertIsNotNone(idle_after_device)
                self.assertIsNotNone(arm)
                self.assertIsNotNone(first_emit)
                self.assertLess(arm, first_emit)

    def test_input_free_manager_drivers_stay_input_free(self):
        """A screenshot/IPC suite must not quietly grow an unguarded emitter.

        Reflection starts on the tab it inspects, so its former synthetic click
        was pure risk. Keep the replacement proof (frontmost real-window grab)
        free of uinput construction, idle gates, arming, and emitting calls.
        """
        for filename in self.INPUT_FREE_FILES:
            with self.subTest(driver=filename):
                path = os.path.join(HERE, filename)
                with open(path, "r", encoding="utf-8") as source:
                    text = source.read()
                tree = ast.parse(text, filename=path)
                self.assertEqual([], self._call_lines(tree, {"VPointer"}))
                self.assertEqual([], self._call_lines(tree, {"require_user_idle"}))
                self.assertEqual([], self._call_lines(tree, {"arm"}))
                self.assertEqual([], self._call_lines(tree, self.EMITTERS))
                self.assertNotIn("XENEON_HW_INPUT", text)


class TestManagerWindowProof(unittest.TestCase):
    def test_selected_sidebar_row_is_detected_for_every_manager_accent_mode(self):
        from PIL import Image

        with tempfile.TemporaryDirectory() as work:
            for height in (1000, 1300):
                for accent in ((237, 109, 31), (88, 166, 255)):
                    with self.subTest(height=height, accent=accent):
                        path = os.path.join(
                            work, "manager-%d-%s.png"
                            % (height, "-".join(str(value) for value in accent)))
                        image = Image.new("RGB", (1440, height), (22, 27, 34))
                        image.putpixel((manager_window.ROW_X,
                                        manager_window.ROW_Y["Screens"]),
                                       accent)
                        image.save(path)
                        self.assertEqual("Screens", manager_window.active_row(path))

    def test_sidebar_without_one_selected_row_is_not_the_manager(self):
        from PIL import Image

        with tempfile.TemporaryDirectory() as work:
            for variant in ("none", "two"):
                with self.subTest(variant=variant):
                    path = os.path.join(work, "manager-%s.png" % variant)
                    image = Image.new("RGB", (1440, 1000), (22, 27, 34))
                    if variant == "two":
                        for row in ("Screens", "Look"):
                            image.putpixel(
                                (manager_window.ROW_X,
                                 manager_window.ROW_Y[row]),
                                (88, 166, 255))
                    image.save(path)
                    self.assertIsNone(manager_window.active_row(path))


class TestSoakCompleteness(unittest.TestCase):
    class FakeHarness:
        def __init__(self, abort=False):
            self.input_allowed = True
            self.input_aborted = False
            self.abort = abort
            self.skips = []
            self.results = []
            self.swipes = 0

        def set_state(self, _state):
            pass

        def get_state(self):
            return {}

        def ping(self):
            return True

        def swipe(self, *_args, **_kwargs):
            self.swipes += 1
            if self.abort:
                self.input_aborted = True
                raise input_guard.UserActivityAbort("synthetic owner activity")

        def skip(self, name, reason):
            self.skips.append((name, reason))

        def check(self, name, ok, detail=""):
            self.results.append((name, bool(ok), detail))
            return bool(ok)

    def _run_fast_soak(self, harness):
        clock = iter(i / 1000 for i in range(10000))
        with mock.patch.object(edge_e2e.time, "time",
                               side_effect=lambda: next(clock)), \
             mock.patch.object(edge_e2e.time, "sleep"):
            edge_e2e.soak(harness, seconds=0.09)

    def test_touch_abort_is_a_first_class_incomplete_result(self):
        harness = self.FakeHarness(abort=True)
        self._run_fast_soak(harness)
        self.assertEqual([name for name, _ in harness.skips],
                         ["soak_touch_remainder"])
        checks = {name: ok for name, ok, _ in harness.results}
        self.assertTrue(checks["soak_no_crash"])
        self.assertFalse(checks["soak_touch_continuity"])

    def test_touch_continuity_requires_a_real_under_load_swipe(self):
        harness = self.FakeHarness()
        self._run_fast_soak(harness)
        self.assertGreater(harness.swipes, 0)
        self.assertEqual(harness.skips, [])
        checks = {name: ok for name, ok, _ in harness.results}
        self.assertTrue(checks["soak_touch_continuity"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
