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
import display_lifecycle_test as display_lifecycle  # noqa: E402
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
    def test_git_tag_identity_accepts_binary_without_tag_prefix(self):
        result = SimpleNamespace(
            stdout="Xeneon Edge Linux Hub 1.0.0-beta.1-107-gb19853b\n"
        )
        describe = SimpleNamespace(stdout="v1.0.0-beta.1-107-gb19853b\n")
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch("e2e_harness.os.path.exists", return_value=True), \
             mock.patch(
                 "e2e_harness.subprocess.run",
                 side_effect=[describe, result],
             ):
            self.assertEqual(
                assert_binaries_current(("/candidate/xeneon-edge-hub",)),
                "1.0.0-beta.1-107-gb19853b",
            )

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


class TestDisplayLifecycleEvidence(unittest.TestCase):
    SHA = "a" * 40

    def make_repo(self, temporary):
        repository = os.path.join(temporary, "repo")
        os.makedirs(os.path.join(repository, "artifacts", self.SHA))
        return repository

    def test_new_commit_keyed_evidence_leaf_is_private_and_empty(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = self.make_repo(temporary)
            target = os.path.join(
                repository, "artifacts", self.SHA, "display-lifecycle-run"
            )
            created = display_lifecycle.prepare_evidence_directory(
                target, self.SHA, repo=repository
            )
            self.assertEqual(os.path.abspath(target), os.fspath(created))
            self.assertEqual(0o700, os.stat(created).st_mode & 0o777)
            self.assertEqual([], os.listdir(created))

    def test_unsafe_or_ambiguous_evidence_targets_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = self.make_repo(temporary)
            artifacts = os.path.join(repository, "artifacts")

            with self.subTest(case="relative"):
                with self.assertRaisesRegex(RuntimeError, "absolute"):
                    display_lifecycle.prepare_evidence_directory(
                        "artifacts/run", self.SHA, repo=repository
                    )
            with self.subTest(case="outside-artifacts"):
                with self.assertRaisesRegex(RuntimeError, "below"):
                    display_lifecycle.prepare_evidence_directory(
                        os.path.join(repository, "outside", "run"),
                        self.SHA,
                        repo=repository,
                    )
            with self.subTest(case="wrong-commit-key"):
                wrong_parent = os.path.join(artifacts, "b" * 40)
                os.mkdir(wrong_parent)
                with self.assertRaisesRegex(RuntimeError, "exact-full-commit"):
                    display_lifecycle.prepare_evidence_directory(
                        os.path.join(wrong_parent, "run"),
                        self.SHA,
                        repo=repository,
                    )
            with self.subTest(case="existing-empty-target"):
                existing = os.path.join(artifacts, self.SHA, "existing")
                os.mkdir(existing)
                with self.assertRaisesRegex(RuntimeError, "must not already exist"):
                    display_lifecycle.prepare_evidence_directory(
                        existing, self.SHA, repo=repository
                    )
            with self.subTest(case="existing-nonempty-target"):
                nonempty = os.path.join(artifacts, self.SHA, "nonempty")
                os.mkdir(nonempty)
                with open(os.path.join(nonempty, "old.log"), "w", encoding="utf-8"):
                    pass
                with self.assertRaisesRegex(RuntimeError, "must not already exist"):
                    display_lifecycle.prepare_evidence_directory(
                        nonempty, self.SHA, repo=repository
                    )

    def test_symlink_target_and_parent_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = self.make_repo(temporary)
            commit_root = os.path.join(repository, "artifacts", self.SHA)
            outside = os.path.join(temporary, "outside")
            os.mkdir(outside)

            target_link = os.path.join(commit_root, "target-link")
            os.symlink(outside, target_link)
            with self.assertRaisesRegex(RuntimeError, "must not already exist"):
                display_lifecycle.prepare_evidence_directory(
                    target_link, self.SHA, repo=repository
                )

            parent_link = os.path.join(commit_root, "parent-link")
            os.symlink(outside, parent_link)
            with self.assertRaisesRegex(RuntimeError, "real directories"):
                display_lifecycle.prepare_evidence_directory(
                    os.path.join(parent_link, "run"),
                    self.SHA,
                    repo=repository,
                )

    def test_symlink_artifacts_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = os.path.join(temporary, "repo")
            outside = os.path.join(temporary, "outside")
            os.mkdir(repository)
            os.makedirs(os.path.join(outside, self.SHA))
            os.symlink(outside, os.path.join(repository, "artifacts"))
            with self.assertRaisesRegex(RuntimeError, "real directory"):
                display_lifecycle.prepare_evidence_directory(
                    os.path.join(
                        repository,
                        "artifacts",
                        self.SHA,
                        "display-lifecycle-run",
                    ),
                    self.SHA,
                    repo=repository,
                )

    def test_restore_guard_runs_and_verifies_after_test_failure(self):
        baseline = {
            "outputs": [{
                "name": "DP-3",
                "enabled": True,
                "currentModeId": "1",
                "pos": {"x": 10, "y": 20},
                "rotation": 8,
                "scale": 1.25,
                "priority": 2,
            }]
        }
        applied = []
        guard = display_lifecycle.DisplayRestoreGuard(
            baseline,
            apply=lambda *settings: applied.extend(settings),
            read=lambda: baseline,
        )
        with self.assertRaisesRegex(ValueError, "injected body failure"):
            with guard:
                raise ValueError("injected body failure")
        self.assertEqual(
            display_lifecycle.restore_settings(baseline),
            applied,
        )
        self.assertTrue(guard.verified)

    def test_any_not_tested_check_blocks_a_lifecycle_pass(self):
        complete = SimpleNamespace(
            results=[("render", True, "visible")],
            skips=[],
        )
        incomplete = SimpleNamespace(
            results=[("missing-target", True, "hidden")],
            skips=[("reconnect", "not exercised")],
        )
        self.assertTrue(display_lifecycle.all_checks_passed(complete))
        self.assertFalse(
            display_lifecycle.all_checks_passed(complete, incomplete)
        )

    def test_baseline_geometry_accepts_landscape_without_hardcoded_portrait(self):
        landscape = ("DP-3", 5120, 0, 2560, 720)
        self.assertTrue(
            display_lifecycle.baseline_rect_restored(landscape, landscape)
        )
        self.assertFalse(
            display_lifecycle.baseline_rect_restored(
                ("DP-3", 5120, 0, 720, 2560),
                landscape,
            )
        )


class TestDisplayLifecycleReleaseWiring(unittest.TestCase):
    def test_strict_runner_uses_the_exact_candidate_and_audit_root(self):
        runner_path = os.path.join(REPO, "scripts", "run_release_tests.sh")
        with open(runner_path, "r", encoding="utf-8") as source:
            runner = source.read()
        lifecycle_path = os.path.join(
            REPO, "tests", "hardware", "display_lifecycle_test.py"
        )
        with open(lifecycle_path, "r", encoding="utf-8") as source:
            display_lifecycle_source = source.read()
        self.assertIn(
            'preflight_ok "XENEON_HW_DISPLAY_LIFECYCLE=1 '
            '(temporary output changes explicitly authorised)"',
            runner,
        )
        self.assertIn(
            'preflight_ok "no Hub or Manager process is running"',
            runner,
        )
        self.assertIn(
            'for process_executable in /proc/[0-9]*/exe',
            runner,
        )
        self.assertIn(
            'run_release_suite "Real Edge disruptive display lifecycle" 1200',
            runner,
        )
        self.assertIn('XENEON_HUB="$PERFORMANCE_HUB"', runner)
        self.assertIn(
            '--evidence-dir "$AUDIT_ROOT/display-lifecycle"',
            runner,
        )
        self.assertIn(
            'run_release_suite "Real Edge rotation smoothness SLO" 300',
            runner,
        )
        self.assertIn(
            '--output-dir "$performance_evidence_root/rotation-frame"',
            runner,
        )
        prepared = runner.index(
            'run_release_suite "Fresh non-instrumented performance candidate"'
        )
        process_guard = runner.index(
            'preflight_ok "no Hub or Manager process is running"'
        )
        first_suite = runner.index(
            'run_release_suite "Repository full-history secret scan"'
        )
        lifecycle = runner.index(
            'run_release_suite "Real Edge disruptive display lifecycle"'
        )
        rotation = runner.index(
            'run_release_suite "Real Edge rotation smoothness SLO"'
        )
        lifecycle_block = runner[lifecycle:rotation]
        self.assertIn('--hub "$PERFORMANCE_HUB"', lifecycle_block)
        self.assertIn(
            "candidate_build = validate_candidate_build(binary)",
            display_lifecycle_source,
        )
        self.assertIn(
            '"candidate_build": candidate_build',
            display_lifecycle_source,
        )
        rotation_block = runner[rotation:]
        self.assertIn('--hub "$PERFORMANCE_HUB"', rotation_block)
        self.assertLess(process_guard, first_suite)
        self.assertLess(prepared, lifecycle)
        self.assertLess(lifecycle, rotation)


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
    def test_wmctrl_window_requires_one_exact_pid_and_title_match(self):
        listing = (
            "0x012  0 222 1840 1510 1440 1300 manager.host host EdgeHub Manager\n"
            "0x013  0 333 0 0 800 600 browser.host host EdgeHub Manager\n"
        )
        result = SimpleNamespace(returncode=0, stdout=listing)
        with mock.patch.object(
                manager_window.subprocess, "run", return_value=result):
            self.assertEqual(
                "0x012", manager_window._wmctrl_manager_window(222)
            )

    def test_wmctrl_window_rejects_ambiguous_pid_matches(self):
        listing = (
            "0x012  0 222 1840 1510 1440 1300 manager.host host EdgeHub Manager\n"
            "0x014  0 222 1900 1550 400 300 manager.host host EdgeHub Manager\n"
        )
        result = SimpleNamespace(returncode=0, stdout=listing)
        with mock.patch.object(
                manager_window.subprocess, "run", return_value=result):
            self.assertIsNone(manager_window._wmctrl_manager_window(222))

    def test_wmctrl_window_rejects_title_only_match(self):
        listing = (
            "0x012  0 999 1840 1510 1440 1300 manager.host host EdgeHub Manager\n"
        )
        result = SimpleNamespace(returncode=0, stdout=listing)
        with mock.patch.object(
                manager_window.subprocess, "run", return_value=result):
            self.assertIsNone(manager_window._wmctrl_manager_window(222))

    def test_guarded_swipe_raises_exact_manager_before_emitting(self):
        pointer = SimpleNamespace(swipe=mock.Mock(return_value=True))
        guarded = manager_window.guard_pointer(
            pointer, ("DP-1", 10, 20, 300, 400), "/tmp", 222
        )
        with mock.patch.object(
                manager_window, "is_in_front", return_value=False), \
             mock.patch.object(
                 manager_window, "activate_exact_manager", return_value=True
             ) as activate:
            self.assertTrue(guarded.swipe(1, 2, 3, 4))
        activate.assert_called_once()
        pointer.swipe.assert_called_once_with(1, 2, 3, 4)

    def test_guarded_swipe_refuses_when_exact_manager_cannot_be_verified(self):
        pointer = SimpleNamespace(swipe=mock.Mock(return_value=True))
        guarded = manager_window.guard_pointer(
            pointer, ("DP-1", 10, 20, 300, 400), "/tmp", 222
        )
        with mock.patch.object(
                manager_window, "is_in_front", return_value=False), \
             mock.patch.object(
                 manager_window, "activate_exact_manager", return_value=False
             ):
            self.assertFalse(guarded.swipe(1, 2, 3, 4))
        pointer.swipe.assert_not_called()
        self.assertEqual(1, guarded.refused)

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
