#!/usr/bin/env python3
"""Negative controls for semantic release-run evidence enforcement."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest
from collections.abc import Callable
from typing import Any

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "scripts"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from lib import audit_artifact_contract as contract  # noqa: E402
from release_run_fixture import build_release_run_fixture  # noqa: E402


class ReleaseRunContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="edgehub-release-run-contract-"
        )
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.commit = "1" * 40
        self.sequence = 100

    def fixture(self) -> tuple[pathlib.Path, str]:
        self.sequence += 1
        run_id = f"release-gate-20260727T010000Z-{self.sequence}"
        artifact = self.root / self.commit / run_id
        build_release_run_fixture(artifact, self.commit, run_id)
        return artifact, run_id

    def validate(self, artifact: pathlib.Path, run_id: str) -> None:
        contract.validate_release_run(artifact, self.commit, run_id)

    @staticmethod
    def mutate_json(
        path: pathlib.Path, mutation: Callable[[dict[str, Any]], None]
    ) -> None:
        document = json.loads(path.read_text(encoding="utf-8"))
        mutation(document)
        path.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def assert_mutation_rejected(
        self,
        relative_path: str,
        mutation: Callable[[dict[str, Any]], None],
        message: str,
    ) -> None:
        artifact, run_id = self.fixture()
        self.mutate_json(artifact / relative_path, mutation)
        with self.assertRaisesRegex(contract.ContractError, message):
            self.validate(artifact, run_id)

    def test_complete_release_run_is_accepted_with_raw_diagnostics(self) -> None:
        artifact, run_id = self.fixture()
        diagnostic = artifact / "performance" / "rotation-frame" / "raw"
        diagnostic.mkdir()
        (diagnostic / "observer.log").write_text(
            "retained raw diagnostic\n", encoding="utf-8"
        )
        self.validate(artifact, run_id)

    def test_every_semantic_report_is_mandatory(self) -> None:
        required = (
            "display-lifecycle/RESULT.json",
            "performance/rotation-frame/report.json",
            "performance/short/summary.json",
            "performance/short/startup-first-render.json",
            "performance/short/idle-5m.json",
            "performance/short/active-10x5m.json",
            "performance/14-widget-30m/report.json",
            "performance/14-widget-30m/startup-first-render.json",
            "performance/14-widget-30m/samples.jsonl",
        )
        for relative_path in required:
            with self.subTest(relative_path=relative_path):
                artifact, run_id = self.fixture()
                (artifact / relative_path).unlink()
                with self.assertRaisesRegex(
                    contract.ContractError,
                    "required retained release evidence is unavailable",
                ):
                    self.validate(artifact, run_id)

    def test_display_must_pass_restore_and_test_every_check(self) -> None:
        cases = (
            (
                lambda doc: doc.__setitem__("source_commit", "2" * 40),
                "source_commit",
            ),
            (lambda doc: doc.__setitem__("status", "FAIL"), "status must be PASS"),
            (
                lambda doc: doc.__setitem__("restore_verified", False),
                "verified display restoration",
            ),
            (lambda doc: doc.__setitem__("error", True), "runtime error"),
            (
                lambda doc: doc["checks"][0].__setitem__("status", "FAIL"),
                "FAIL and NOT TESTED cannot seal",
            ),
            (
                lambda doc: doc["checks"][0].__setitem__(
                    "status", "NOT TESTED"
                ),
                "FAIL and NOT TESTED cannot seal",
            ),
        )
        for mutation, message in cases:
            with self.subTest(message=message):
                self.assert_mutation_rejected(
                    "display-lifecycle/RESULT.json", mutation, message
                )

    def test_candidate_identity_is_cross_bound_everywhere(self) -> None:
        cases = (
            (
                "display-lifecycle/RESULT.json",
                lambda doc: doc["hub"]["candidate_build"].__setitem__(
                    "source_commit", "2" * 40
                ),
            ),
            (
                "performance/rotation-frame/report.json",
                lambda doc: doc["candidate"].__setitem__(
                    "binary_sha256", "b" * 64
                ),
            ),
            (
                "performance/short/idle-5m.json",
                lambda doc: doc["metadata"]["candidate_build"].__setitem__(
                    "binary_version", "different candidate"
                ),
            ),
            (
                "performance/14-widget-30m/report.json",
                lambda doc: doc["candidate"].__setitem__(
                    "binary_sha256", "c" * 64
                ),
            ),
        )
        for relative_path, mutation in cases:
            with self.subTest(relative_path=relative_path):
                self.assert_mutation_rejected(
                    relative_path, mutation, "candidate|source_commit"
                )

    def test_short_summary_and_each_profile_must_be_qualified_passes(self) -> None:
        cases = (
            (
                "performance/short/summary.json",
                lambda doc: doc.__setitem__("qualified", False),
            ),
            (
                "performance/short/startup-first-render.json",
                lambda doc: doc.__setitem__("status", "FAIL"),
            ),
            (
                "performance/short/idle-5m.json",
                lambda doc: doc.__setitem__("qualified", False),
            ),
            (
                "performance/short/active-10x5m.json",
                lambda doc: doc.__setitem__("status", "FAIL"),
            ),
        )
        for relative_path, mutation in cases:
            with self.subTest(relative_path=relative_path):
                self.assert_mutation_rejected(
                    relative_path, mutation, "PASS contract"
                )

    def test_short_profiles_cannot_fake_literal_duration_or_load(self) -> None:
        self.assert_mutation_rejected(
            "performance/short/idle-5m.json",
            lambda doc: doc["samples"].pop(),
            "sample_count differs",
        )
        self.assert_mutation_rejected(
            "performance/short/active-10x5m.json",
            lambda doc: doc["metadata"]["observed_load"].__setitem__(
                "observed_widget_count", 9
            ),
            "fixed live profile",
        )
        self.assert_mutation_rejected(
            "performance/short/idle-5m.json",
            lambda doc: doc["metrics"].__setitem__(
                "average_cpu_percent", 1.0
            ),
            "CPU budget",
        )

    def test_rotation_requires_schema_v2_and_every_transition_slo(self) -> None:
        cases = (
            (lambda doc: doc.__setitem__("schema_version", 1), "PASS contract"),
            (lambda doc: doc.__setitem__("status", "FAIL"), "PASS contract"),
            (lambda doc: doc.__setitem__("qualified", False), "PASS contract"),
            (
                lambda doc: doc["transitions"][0]["smoothness_slo"].__setitem__(
                    "passed", False
                ),
                "did not pass",
            ),
            (
                lambda doc: doc["transitions"][0]["smoothness_slo"]["checks"][
                    0
                ].__setitem__("passed", False),
                "does not meet",
            ),
            (
                lambda doc: doc["transitions"].pop(),
                "exactly three cycles",
            ),
            (
                lambda doc: doc["smoothness_slo"].__setitem__(
                    "first_frame_max_ms", 1000.0
                ),
                "exactly 100",
            ),
        )
        for mutation, message in cases:
            with self.subTest(message=message):
                self.assert_mutation_rejected(
                    "performance/rotation-frame/report.json",
                    mutation,
                    message,
                )

    def test_rotation_recomputes_slo_instead_of_trusting_pass_booleans(self) -> None:
        def falsify_first_frame(document: dict[str, Any]) -> None:
            transition = document["transitions"][0]
            transition["frames"]["frame_callback_timestamps_ms"] = [
                value + 150.0
                for value in transition["frames"][
                    "frame_callback_timestamps_ms"
                ]
            ]

        self.assert_mutation_rejected(
            "performance/rotation-frame/report.json",
            falsify_first_frame,
            "observation window|does not match",
        )

    def test_14_widget_report_requires_literal_load_duration_and_gpu_trace(
        self,
    ) -> None:
        cases = (
            (lambda doc: doc.__setitem__("status", "FAIL"), "PASS contract"),
            (lambda doc: doc.__setitem__("qualified", False), "PASS contract"),
            (
                lambda doc: doc["load"]["widget_types"].pop(),
                "fixed 14-widget live load",
            ),
            (
                lambda doc: doc["metrics"].__setitem__(
                    "observed_duration_seconds", 1799.0
                ),
                "retained observations",
            ),
            (
                lambda doc: doc["metrics"]["gpu_memory"].__setitem__(
                    "available", False
                ),
                "not fully available",
            ),
        )
        for mutation, message in cases:
            with self.subTest(message=message):
                self.assert_mutation_rejected(
                    "performance/14-widget-30m/report.json",
                    mutation,
                    message,
                )

        artifact, run_id = self.fixture()
        trace_path = (
            artifact / "performance" / "14-widget-30m" / "samples.jsonl"
        )
        rows = trace_path.read_text(encoding="utf-8").splitlines()
        trace_path.write_text("\n".join(rows[:-1]) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
            contract.ContractError, "sample_count differs"
        ):
            self.validate(artifact, run_id)

    def test_14_widget_embedded_startup_must_match_retained_report(self) -> None:
        self.assert_mutation_rejected(
            "performance/14-widget-30m/report.json",
            lambda doc: doc["startup"]["metrics"].__setitem__(
                "first_render_upper_bound_seconds", 0.5
            ),
            "differs from its retained report",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
