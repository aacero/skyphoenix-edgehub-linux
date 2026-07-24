#!/usr/bin/env python3
"""Static contracts preventing hollow or duration-scaled performance gates."""

from __future__ import annotations

import ast
import unittest
from pathlib import Path

from resource_probe import GATE_SPECS, SAMPLING_INTERVAL_SECONDS, STARTUP_LIMIT_SECONDS


HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run_hub_profiles.py"
README = HERE / "README.md"
PREPARE = HERE / "prepare_release_candidate.sh"
AUDIT_14_WIDGET = HERE / "run_audit_14_widget_30m.py"


def _literal_assignment(source: str, name: str):
    tree = ast.parse(source)
    for node in tree.body:
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        if any(isinstance(target, ast.Name) and target.id == name for target in targets):
            return ast.literal_eval(node.value)
    raise AssertionError(f"assignment not found: {name}")


class ThresholdContractTests(unittest.TestCase):
    def test_five_minute_idle_contract(self) -> None:
        spec = GATE_SPECS["idle-5m"]
        self.assertEqual(spec.minimum_duration_seconds, 300.0)
        self.assertEqual(spec.maximum_average_cpu_percent, 1.0)
        self.assertEqual(spec.maximum_rss_mib, 150.0)
        self.assertEqual(spec.required_widget_count, 0)

    def test_ten_widget_active_contract(self) -> None:
        spec = GATE_SPECS["active-10x5m"]
        self.assertEqual(spec.minimum_duration_seconds, 300.0)
        self.assertEqual(spec.maximum_average_cpu_percent, 5.0)
        self.assertEqual(spec.maximum_rss_mib, 250.0)
        self.assertEqual(spec.required_widget_count, 10)

    def test_startup_contract_is_first_render_below_two_seconds(self) -> None:
        self.assertEqual(STARTUP_LIMIT_SECONDS, 2.0)
        source = (HERE / "resource_probe.py").read_text(encoding="utf-8")
        self.assertIn('"evidence_type": "wayland-non-null-buffer-commit"', source)
        self.assertIn("control-socket readiness is intentionally not accepted", source)

    def test_long_intervals_and_growth_are_literal(self) -> None:
        day = GATE_SPECS["idle-24h"]
        two_days = GATE_SPECS["idle-48h"]
        self.assertEqual(day.minimum_duration_seconds, 86_400.0)
        self.assertEqual(two_days.minimum_duration_seconds, 172_800.0)
        self.assertEqual(day.maximum_rss_growth_percent, 10.0)
        self.assertEqual(two_days.maximum_rss_growth_percent, 10.0)
        self.assertEqual(SAMPLING_INTERVAL_SECONDS, 1.0)


class RunnerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = RUNNER.read_text(encoding="utf-8")

    def test_active_profile_has_ten_unique_updating_widgets(self) -> None:
        widgets = _literal_assignment(self.source, "ACTIVE_WIDGET_TYPES")
        self.assertEqual(len(widgets), 10)
        self.assertEqual(len(set(widgets)), 10)
        self.assertEqual(
            widgets,
            (
                "cpu",
                "gpu",
                "ram",
                "net",
                "disk",
                "sensors",
                "clock",
                "analog",
                "focus",
                "break",
            ),
        )

    def test_no_duration_override_can_shorten_a_release_profile(self) -> None:
        self.assertNotIn('"--duration"', self.source)
        self.assertNotIn("XENEON_PERF_DURATION", self.source)
        self.assertIn('choices=("short", "idle-24h", "idle-48h")', self.source)

    def test_five_minute_profiles_are_both_executed_in_short_mode(self) -> None:
        self.assertIn('run_resource_profile(binary, "idle-5m"', self.source)
        self.assertIn('run_resource_profile(binary, "active-10x5m"', self.source)
        self.assertIn("run_startup_profile(binary, output_dir, candidate)", self.source)

    def test_long_duration_modes_run_the_matching_literal_gate(self) -> None:
        self.assertIn('run_resource_profile(binary, "idle-24h"', self.source)
        self.assertIn('run_resource_profile(binary, "idle-48h"', self.source)

    def test_evidence_directory_rejects_stale_files(self) -> None:
        self.assertIn("evidence directory must be empty", self.source)

    def test_candidate_must_be_release_and_non_instrumented(self) -> None:
        self.assertIn('"CMAKE_BUILD_TYPE": "Release"', self.source)
        self.assertIn('"CMAKE_INSTALL_PREFIX": "/usr"', self.source)
        self.assertIn('"XENEON_BUILD_TESTS": "OFF"', self.source)
        self.assertIn('"XENEON_COVERAGE": "OFF"', self.source)
        self.assertIn('"XENEON_QA_HOOKS": "OFF"', self.source)
        preparation = PREPARE.read_text(encoding="utf-8")
        self.assertIn('PERFORMANCE_BUILD_DIR="$PROJECT_DIR/cmake-build-release-performance"', preparation)
        self.assertIn("-DXENEON_COVERAGE=OFF", preparation)
        self.assertIn("-DXENEON_QA_HOOKS=OFF", preparation)
        self.assertIn("-DXENEON_BUILD_TESTS=OFF", preparation)
        self.assertIn("-DCMAKE_BUILD_TYPE=Release", preparation)
        self.assertIn("-DCMAKE_INSTALL_PREFIX=/usr", preparation)
        self.assertIn('--target clean', preparation)

    def test_live_hub_load_is_verified_before_sampling(self) -> None:
        self.assertIn("_verify_loaded_profile(instance, expected_types)", self.source)
        self.assertIn('"live_state_verified": True', self.source)

    def test_documentation_never_calls_short_trends_long_soak_evidence(self) -> None:
        documentation = README.read_text(encoding="utf-8")
        normalised = " ".join(documentation.split())
        self.assertIn("does not satisfy the 24-hour or 48-hour requirement", normalised)
        self.assertIn("--mode idle-24h", documentation)
        self.assertIn("--mode idle-48h", documentation)


class AuditSubstituteContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = AUDIT_14_WIDGET.read_text(encoding="utf-8")

    def test_literal_duration_interval_and_widget_manifest(self) -> None:
        self.assertEqual(
            _literal_assignment(self.source, "AUDIT_DURATION_SECONDS"),
            1800.0,
        )
        self.assertEqual(
            _literal_assignment(self.source, "AUDIT_INTERVAL_SECONDS"),
            30.0,
        )
        widgets = _literal_assignment(self.source, "AUDIT_WIDGET_TYPES")
        self.assertEqual(len(widgets), 14)
        self.assertEqual(len(set(widgets)), 14)

    def test_audit_cannot_be_presented_as_a_release_gate(self) -> None:
        self.assertIn('"status": "MEASURED"', self.source)
        self.assertIn('"qualified": None', self.source)
        self.assertNotIn('"--duration"', self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
