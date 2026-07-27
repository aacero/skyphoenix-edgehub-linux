#!/usr/bin/env python3
"""Focused positive and negative tests for unsigned release evidence builders."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "scripts"))

from lib.release_evidence_drafts import (  # noqa: E402
    BASELINE_REF_RE,
    CANONICAL_REPOSITORY,
    CANONICAL_WORKFLOW_NAME,
    CANONICAL_WORKFLOW_SIGNER,
    CERTIFICATION_GATES,
    EvidenceDraftError,
    EXPECTED_LIFECYCLE_ENVIRONMENTS,
    LIFECYCLE_ENVIRONMENT_NAME,
    LOWER_SHA_RE,
    NATIVE_PASS_FIELDS,
    build_release_certification_draft,
    import_native_lifecycle,
)


def completed(
    arguments: list[str], stdout: str = ""
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(arguments, 0, stdout=stdout, stderr="")


def run_real(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def write_bytes(path: pathlib.Path, payload: bytes) -> None:
    path.write_bytes(payload)
    path.chmod(0o600)


def write_sidecar(path: pathlib.Path, target: pathlib.Path) -> None:
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    write_bytes(path, f"{digest}  {target.name}\n".encode("ascii"))


class RepositoryFixture:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.root.mkdir(mode=0o700)
        run_real(["git", "-C", str(root), "init", "-q"])
        run_real(
            ["git", "-C", str(root), "config", "user.name", "Evidence Test"]
        )
        run_real(
            [
                "git",
                "-C",
                str(root),
                "config",
                "user.email",
                "evidence-test@example.invalid",
            ]
        )
        (root / ".gitignore").write_text("artifacts/\n", encoding="utf-8")
        (root / "candidate.txt").write_text("baseline\n", encoding="utf-8")
        run_real(
            ["git", "-C", str(root), "add", ".gitignore", "candidate.txt"]
        )
        run_real(
            [
                "git",
                "-C",
                str(root),
                "-c",
                "commit.gpgSign=false",
                "commit",
                "-qm",
                "baseline",
            ]
        )
        self.baseline = run_real(
            ["git", "-C", str(root), "rev-parse", "HEAD"]
        ).stdout.strip()
        (root / "candidate.txt").write_text("candidate\n", encoding="utf-8")
        run_real(["git", "-C", str(root), "add", "candidate.txt"])
        run_real(
            [
                "git",
                "-C",
                str(root),
                "-c",
                "commit.gpgSign=false",
                "commit",
                "-qm",
                "candidate",
            ]
        )
        self.candidate = run_real(
            ["git", "-C", str(root), "rev-parse", "HEAD"]
        ).stdout.strip()


class NativeRunner:
    def __init__(
        self,
        *,
        candidate: str,
        workflow_url: str,
        package_name: str,
        package_digest: str,
        report_name: str,
        report_digest: str,
        environment_name: str,
        environment_digest: str,
        wrong_workflow_sha: bool = False,
        wrong_subject: bool = False,
        wrong_report_subject: bool = False,
        wrong_environment_subject: bool = False,
        wrong_invocation: bool = False,
        reject_attestation: bool = False,
    ) -> None:
        self.candidate = candidate
        self.workflow_url = workflow_url
        self.package_name = package_name
        self.package_digest = package_digest
        self.report_name = report_name
        self.report_digest = report_digest
        self.environment_name = environment_name
        self.environment_digest = environment_digest
        self.wrong_workflow_sha = wrong_workflow_sha
        self.wrong_subject = wrong_subject
        self.wrong_report_subject = wrong_report_subject
        self.wrong_environment_subject = wrong_environment_subject
        self.wrong_invocation = wrong_invocation
        self.reject_attestation = reject_attestation
        self.commands: list[list[str]] = []

    def __call__(
        self, arguments: list[str]
    ) -> subprocess.CompletedProcess[str]:
        command = list(arguments)
        self.commands.append(command)
        if command[0] != "gh":
            return run_real(command)
        if command[1:3] == ["run", "view"]:
            document = {
                "url": self.workflow_url,
                "headSha": (
                    "f" * 40 if self.wrong_workflow_sha else self.candidate
                ),
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "success",
                "workflowName": CANONICAL_WORKFLOW_NAME,
            }
            return completed(command, json.dumps(document))
        if command[1:3] == ["attestation", "verify"]:
            if self.reject_attestation:
                raise EvidenceDraftError("fixture rejected GitHub provenance")
            target_name = pathlib.Path(command[3]).name
            expected_subjects = {
                self.package_name: self.package_digest,
                self.report_name: self.report_digest,
                self.environment_name: self.environment_digest,
            }
            if target_name not in expected_subjects:
                raise AssertionError(
                    f"unexpected attestation target: {target_name}"
                )
            subject_name = target_name
            if self.wrong_subject and target_name == self.package_name:
                subject_name = "wrong-package.deb"
            elif self.wrong_report_subject and target_name == self.report_name:
                subject_name = "fabricated-report.txt"
            elif (
                self.wrong_environment_subject
                and target_name == self.environment_name
            ):
                subject_name = "fabricated-environment.txt"
            document = [
                {
                    "verificationResult": {
                        "statement": {
                            "subject": [
                                {
                                    "name": subject_name,
                                    "digest": {
                                        "sha256": expected_subjects[target_name]
                                    },
                                }
                            ],
                            "predicate": {
                                "runDetails": {
                                    "metadata": {
                                        "invocationId": (
                                            (
                                                self.workflow_url.rsplit("/", 1)[0]
                                                + "/654321"
                                                if self.wrong_invocation
                                                else self.workflow_url
                                            )
                                            + "/attempts/1"
                                        )
                                    }
                                }
                            },
                        }
                    }
                }
            ]
            return completed(command, json.dumps(document))
        raise AssertionError(f"unexpected gh command: {command}")


class NativeLifecycleBuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="edgehub-native-evidence-"
        )
        self.addCleanup(self.temporary.cleanup)
        root = pathlib.Path(self.temporary.name)
        self.fixture = RepositoryFixture(root / "repo")
        self.download = root / "download"
        self.download.mkdir(mode=0o700)
        self.kind = "deb"
        self.baseline_name = "xeneon-edge-hub-0.9.0-Linux.deb"
        self.candidate_name = "xeneon-edge-hub-1.0.0-Linux.deb"
        self.baseline_path = self.download / self.baseline_name
        self.candidate_path = self.download / self.candidate_name
        write_bytes(self.baseline_path, b"baseline-deb-package")
        write_bytes(self.candidate_path, b"candidate-deb-package")
        write_sidecar(
            self.download / f"{self.baseline_name}.sha256",
            self.baseline_path,
        )
        write_sidecar(
            self.download / f"{self.candidate_name}.sha256",
            self.candidate_path,
        )
        self.report_name = "native-upgrade-rollback-deb.txt"
        self.report_path = self.download / self.report_name
        fields = {
            "result": "PASS",
            "package_kind": "deb",
            "baseline_ref": self.fixture.baseline,
            "baseline_sha": self.fixture.baseline,
            "baseline_app_version": "0.9.0",
            "baseline_native_version": "0.9.0",
            "baseline_version_source": "cmake-contract",
            "baseline_package": self.baseline_name,
            "baseline_package_sha256": hashlib.sha256(
                self.baseline_path.read_bytes()
            ).hexdigest(),
            "candidate_ref": self.fixture.candidate,
            "candidate_sha": self.fixture.candidate,
            "candidate_app_version": "1.0.0",
            "candidate_native_version": "1.0.0",
            "candidate_package": self.candidate_name,
            "candidate_package_sha256": hashlib.sha256(
                self.candidate_path.read_bytes()
            ).hexdigest(),
            **{field: "PASS" for field in NATIVE_PASS_FIELDS},
            "config_sha256": "a" * 64,
            "autostart_sha256": "b" * 64,
        }
        write_bytes(
            self.report_path,
            "".join(f"{key}={value}\n" for key, value in fields.items()).encode(),
        )
        write_sidecar(
            self.download / f"{self.report_name}.sha256", self.report_path
        )
        self.environment_path = self.download / LIFECYCLE_ENVIRONMENT_NAME
        environment_lines = [
            *EXPECTED_LIFECYCLE_ENVIRONMENTS["deb"],
            'NAME="Ubuntu"',
            "ID=ubuntu",
            'VERSION_ID="26.04"',
        ]
        write_bytes(
            self.environment_path,
            ("\n".join(environment_lines) + "\n").encode(),
        )
        write_sidecar(
            self.download / f"{LIFECYCLE_ENVIRONMENT_NAME}.sha256",
            self.environment_path,
        )
        self.workflow_url = (
            "https://github.com/skyphoenix-it/"
            "skyphoenix-edgehub-linux/actions/runs/123456"
        )

    def runner(self, **options: bool) -> NativeRunner:
        return NativeRunner(
            candidate=self.fixture.candidate,
            workflow_url=self.workflow_url,
            package_name=self.candidate_name,
            package_digest=hashlib.sha256(
                self.candidate_path.read_bytes()
            ).hexdigest(),
            report_name=self.report_name,
            report_digest=hashlib.sha256(
                self.report_path.read_bytes()
            ).hexdigest(),
            environment_name=LIFECYCLE_ENVIRONMENT_NAME,
            environment_digest=hashlib.sha256(
                self.environment_path.read_bytes()
            ).hexdigest(),
            **options,
        )

    def import_with(
        self, runner: NativeRunner, process_id: int = 71
    ) -> pathlib.Path:
        return import_native_lifecycle(
            repository_root=self.fixture.root,
            downloaded_artifact=self.download,
            kind=self.kind,
            expected_commit=self.fixture.candidate,
            expected_baseline_ref=self.fixture.baseline,
            workflow_url=self.workflow_url,
            contract_path=(
                REPOSITORY / "scripts/lib/audit_artifact_contract.py"
            ),
            runner=runner,
            now=dt.datetime(2026, 7, 27, 4, 5, 6, tzinfo=dt.timezone.utc),
            process_id=process_id,
        )

    def assert_no_import(self) -> None:
        root = (
            self.fixture.root / "artifacts" / self.fixture.candidate
        )
        if root.exists():
            self.assertEqual(list(root.iterdir()), [])

    def contract_result(
        self, destination: pathlib.Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(REPOSITORY / "scripts/lib/audit_artifact_contract.py"),
                "native-lifecycle",
                str(destination),
                self.fixture.candidate,
                destination.name,
            ],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    def assert_contract_rejected(
        self, destination: pathlib.Path, detail: str = ""
    ) -> None:
        result = self.contract_result(destination)
        self.assertNotEqual(
            result.returncode,
            0,
            f"mutated native lifecycle contract unexpectedly passed: {detail}",
        )
        self.assertIn("audit record contract failed:", result.stderr)

    def rewrite_source_and_inventory(
        self,
        destination: pathlib.Path,
        relative_path: str,
        payload: bytes,
    ) -> None:
        source_path = destination / relative_path
        write_bytes(source_path, payload)
        digest = hashlib.sha256(payload).hexdigest()
        record_path = destination / "NATIVE_PACKAGE_LIFECYCLE.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        matches = [
            entry
            for entry in record["source_files"]
            if entry["path"] == relative_path
        ]
        self.assertEqual(len(matches), 1)
        matches[0]["sha256"] = digest
        write_bytes(
            record_path,
            (
                json.dumps(record, indent=2, sort_keys=True) + "\n"
            ).encode("utf-8"),
        )

    def test_import_retains_exact_bytes_and_verified_provenance(self) -> None:
        runner = self.runner()
        destination = self.import_with(runner)
        self.assertEqual(
            destination.name,
            "native-package-lifecycle-deb-20260727T040506Z-71",
        )
        record = json.loads(
            (destination / "NATIVE_PACKAGE_LIFECYCLE.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(record["candidate_sha"], self.fixture.candidate)
        self.assertEqual(
            record["schema"],
            "skyphoenix-edgehub-native-package-lifecycle/v2",
        )
        self.assertTrue(record["github_provenance_verified"])
        self.assertIn("no human observation is asserted", record["attestation"])
        self.assertEqual(
            [entry["path"] for entry in record["source_files"]],
            sorted(entry["path"] for entry in record["source_files"]),
        )
        self.assertEqual(len(record["source_files"]), 11)
        self.assertEqual(
            (destination / "evidence" / self.report_name).read_bytes(),
            self.report_path.read_bytes(),
        )
        self.assertEqual(
            (
                destination / "source" / self.candidate_name
            ).read_bytes(),
            self.candidate_path.read_bytes(),
        )
        self.assertTrue(
            (
                destination
                / "source"
                / "GITHUB_PACKAGE_ATTESTATION_VERIFICATION.json"
            ).is_file()
        )
        self.assertTrue(
            (
                destination
                / "source"
                / "GITHUB_REPORT_ATTESTATION_VERIFICATION.json"
            ).is_file()
        )
        self.assertTrue(
            (
                destination
                / "source"
                / "GITHUB_ENVIRONMENT_ATTESTATION_VERIFICATION.json"
            ).is_file()
        )
        self.assertEqual(
            (
                destination / "source" / LIFECYCLE_ENVIRONMENT_NAME
            ).read_bytes(),
            self.environment_path.read_bytes(),
        )
        self.assertFalse((destination / "MANIFEST.sha256").exists())
        self.assertFalse((destination / "MANIFEST.sha256.asc").exists())
        gh_commands = [
            command for command in runner.commands if command[0] == "gh"
        ]
        self.assertEqual(len(gh_commands), 4)
        for attestation in gh_commands[1:]:
            self.assertEqual(
                attestation[attestation.index("--repo") + 1],
                CANONICAL_REPOSITORY,
            )
            self.assertEqual(
                attestation[attestation.index("--signer-workflow") + 1],
                CANONICAL_WORKFLOW_SIGNER,
            )
            self.assertEqual(
                attestation[attestation.index("--source-digest") + 1],
                self.fixture.candidate,
            )
            self.assertIn("--deny-self-hosted-runners", attestation)

    def test_contract_rejects_deleted_source_tree_and_every_required_file(
        self,
    ) -> None:
        tree_destination = self.import_with(self.runner(), process_id=75)
        shutil.rmtree(tree_destination / "source")
        self.assert_contract_rejected(tree_destination, "deleted source tree")

        inventory_destination = self.import_with(self.runner(), process_id=76)
        inventory = json.loads(
            (
                inventory_destination / "NATIVE_PACKAGE_LIFECYCLE.json"
            ).read_text(encoding="utf-8")
        )["source_files"]
        source_paths = [entry["path"] for entry in inventory]
        shutil.rmtree(inventory_destination)

        for index, relative_path in enumerate(source_paths, start=80):
            with self.subTest(relative_path=relative_path):
                destination = self.import_with(
                    self.runner(), process_id=index
                )
                (destination / relative_path).unlink()
                self.assert_contract_rejected(
                    destination, f"deleted {relative_path}"
                )

    def test_contract_rejects_extra_and_semantically_tampered_source(
        self,
    ) -> None:
        extra = self.import_with(self.runner(), process_id=100)
        write_bytes(extra / "source" / "unexpected.txt", b"unexpected\n")
        self.assert_contract_rejected(extra, "unexpected source file")

        extra_directory = self.import_with(self.runner(), process_id=105)
        (extra_directory / "source" / "unexpected").mkdir()
        self.assert_contract_rejected(
            extra_directory, "unexpected source directory"
        )

        package = self.import_with(self.runner(), process_id=101)
        self.rewrite_source_and_inventory(
            package,
            f"source/{self.candidate_name}",
            b"tampered package bytes",
        )
        self.assert_contract_rejected(
            package, "package hash updated only in source inventory"
        )

        sidecar = self.import_with(self.runner(), process_id=102)
        self.rewrite_source_and_inventory(
            sidecar,
            f"source/{self.candidate_name}.sha256",
            f"{'f' * 64}  {self.candidate_name}\n".encode("ascii"),
        )
        self.assert_contract_rejected(
            sidecar, "sidecar hash updated only in source inventory"
        )

        environment = self.import_with(self.runner(), process_id=103)
        self.rewrite_source_and_inventory(
            environment,
            f"source/{LIFECYCLE_ENVIRONMENT_NAME}",
            (
                "requested_image=ubuntu:rolling\n"
                "resolved_image=ubuntu:rolling@sha256:bad\n"
                "platform=linux/amd64\n"
                "ID=ubuntu\n"
            ).encode("utf-8"),
        )
        self.assert_contract_rejected(
            environment, "environment no longer names the pinned image"
        )

        workflow = self.import_with(self.runner(), process_id=104)
        workflow_path = workflow / "source" / "GITHUB_WORKFLOW_RUN.json"
        workflow_document = json.loads(workflow_path.read_text(encoding="utf-8"))
        workflow_document["headSha"] = "f" * 40
        self.rewrite_source_and_inventory(
            workflow,
            "source/GITHUB_WORKFLOW_RUN.json",
            (
                json.dumps(workflow_document, indent=2, sort_keys=True) + "\n"
            ).encode("utf-8"),
        )
        self.assert_contract_rejected(
            workflow, "workflow head differs from candidate"
        )

    def test_contract_rejects_each_attestation_binding_tamper(self) -> None:
        cases = (
            (
                110,
                "GITHUB_PACKAGE_ATTESTATION_VERIFICATION.json",
                "subject",
            ),
            (
                111,
                "GITHUB_REPORT_ATTESTATION_VERIFICATION.json",
                "digest",
            ),
            (
                112,
                "GITHUB_ENVIRONMENT_ATTESTATION_VERIFICATION.json",
                "invocation",
            ),
        )
        for process_id, name, mutation in cases:
            with self.subTest(name=name, mutation=mutation):
                destination = self.import_with(
                    self.runner(), process_id=process_id
                )
                path = destination / "source" / name
                document = json.loads(path.read_text(encoding="utf-8"))
                statement = document[0]["verificationResult"]["statement"]
                if mutation == "subject":
                    statement["subject"][0]["name"] = "wrong-package.deb"
                elif mutation == "digest":
                    statement["subject"][0]["digest"]["sha256"] = "f" * 64
                else:
                    statement["predicate"]["runDetails"]["metadata"][
                        "invocationId"
                    ] = (
                        "https://github.com/skyphoenix-it/"
                        "skyphoenix-edgehub-linux/actions/runs/999999"
                    )
                self.rewrite_source_and_inventory(
                    destination,
                    f"source/{name}",
                    (
                        json.dumps(document, indent=2, sort_keys=True) + "\n"
                    ).encode("utf-8"),
                )
                self.assert_contract_rejected(
                    destination, f"{name} {mutation}"
                )

    def test_producer_and_importer_share_canonical_ref_grammar(self) -> None:
        accepted = (
            "a" * 40,
            "v1.0.0",
            "refs/tags/v1.0.0",
            "v1.0.0-rc.1",
            "refs/tags/v2.3.4-beta.0",
        )
        rejected = (
            "A" * 40,
            "refs/tags/release/stable",
            "v01.0.0",
            "v1.0.0-rc.01",
            "master",
        )
        for value in accepted:
            with self.subTest(accepted=value):
                self.assertTrue(
                    LOWER_SHA_RE.fullmatch(value)
                    or BASELINE_REF_RE.fullmatch(value)
                )
        for value in rejected:
            with self.subTest(rejected=value):
                self.assertFalse(
                    LOWER_SHA_RE.fullmatch(value)
                    or BASELINE_REF_RE.fullmatch(value)
                )

        workflow = (
            REPOSITORY / ".github/workflows/native-upgrade-rollback.yml"
        ).read_text(encoding="utf-8")
        producer = (
            REPOSITORY / "packaging/ci/native-upgrade-rollback.sh"
        ).read_text(encoding="utf-8")
        for source in (workflow, producer):
            self.assertIn(
                "lowercase full commit or exact SemVer release tag", source
            )
            self.assertNotIn("[0-9A-Fa-f]{40}", source)
            self.assertNotIn("refs/tags/[A-Za-z0-9]", source)

    def test_wrong_package_hash_is_rejected_before_network_verification(
        self,
    ) -> None:
        write_bytes(self.candidate_path, b"mutated-candidate-package")
        runner = self.runner()
        with self.assertRaisesRegex(
            EvidenceDraftError, "candidate package bytes do not match"
        ):
            self.import_with(runner)
        self.assertFalse(any(command[0] == "gh" for command in runner.commands))
        self.assert_no_import()

    def test_wrong_workflow_commit_is_rejected(self) -> None:
        runner = self.runner(wrong_workflow_sha=True)
        with self.assertRaisesRegex(
            EvidenceDraftError, "not the successful canonical lifecycle run"
        ):
            self.import_with(runner)
        self.assert_no_import()

    def test_attestation_from_another_run_is_rejected(self) -> None:
        runner = self.runner(wrong_invocation=True)
        with self.assertRaisesRegex(
            EvidenceDraftError, "requested workflow run"
        ):
            self.import_with(runner)
        self.assert_no_import()

    def test_reported_baseline_must_match_explicit_owner_selection(
        self,
    ) -> None:
        runner = self.runner()
        with self.assertRaisesRegex(
            EvidenceDraftError, "reported baseline ref differs"
        ):
            import_native_lifecycle(
                repository_root=self.fixture.root,
                downloaded_artifact=self.download,
                kind=self.kind,
                expected_commit=self.fixture.candidate,
                expected_baseline_ref=self.fixture.candidate,
                workflow_url=self.workflow_url,
                contract_path=(
                    REPOSITORY / "scripts/lib/audit_artifact_contract.py"
                ),
                runner=runner,
                now=dt.datetime(
                    2026, 7, 27, 4, 5, 6, tzinfo=dt.timezone.utc
                ),
                process_id=74,
            )
        self.assertFalse(any(command[0] == "gh" for command in runner.commands))
        self.assert_no_import()

    def test_wrong_attested_subject_is_rejected_and_draft_is_removed(
        self,
    ) -> None:
        runner = self.runner(wrong_subject=True)
        with self.assertRaisesRegex(
            EvidenceDraftError, "does not bind the exact retained subject"
        ):
            self.import_with(runner)
        self.assert_no_import()

    def test_fabricated_pass_report_with_fresh_sidecar_is_rejected(
        self,
    ) -> None:
        runner = self.runner()
        with self.report_path.open("ab") as handle:
            handle.write(b"fabricated_note=locally-rewritten\n")
        write_sidecar(
            self.download / f"{self.report_name}.sha256", self.report_path
        )
        with self.assertRaisesRegex(
            EvidenceDraftError, "does not bind the exact retained subject"
        ):
            self.import_with(runner)
        attestation_targets = [
            pathlib.Path(command[3]).name
            for command in runner.commands
            if command[0] == "gh"
            and command[1:3] == ["attestation", "verify"]
        ]
        self.assertEqual(
            attestation_targets, [self.candidate_name, self.report_name]
        )
        self.assert_no_import()

    def test_fabricated_environment_with_fresh_sidecar_is_rejected(
        self,
    ) -> None:
        runner = self.runner()
        with self.environment_path.open("ab") as handle:
            handle.write(b"FABRICATED=1\n")
        write_sidecar(
            self.download / f"{LIFECYCLE_ENVIRONMENT_NAME}.sha256",
            self.environment_path,
        )
        with self.assertRaisesRegex(
            EvidenceDraftError, "does not bind the exact retained subject"
        ):
            self.import_with(runner)
        self.assert_no_import()

    def test_symlinked_candidate_package_is_rejected(self) -> None:
        self.candidate_path.unlink()
        os.symlink(self.baseline_path, self.candidate_path)
        runner = self.runner()
        with self.assertRaisesRegex(
            EvidenceDraftError, "candidate package is unavailable"
        ):
            self.import_with(runner)
        self.assert_no_import()


class AggregateRunner:
    def __init__(
        self,
        *,
        reject_gate: str | None = None,
    ) -> None:
        self.reject_gate = reject_gate
        self.commands: list[list[str]] = []

    def __call__(
        self, arguments: list[str]
    ) -> subprocess.CompletedProcess[str]:
        command = list(arguments)
        self.commands.append(command)
        if command[0] == "git":
            return run_real(command)
        if command[0] == "bash":
            target = pathlib.Path(command[-1])
            if self.reject_gate and self.reject_gate in target.as_posix():
                raise EvidenceDraftError("fixture rejected unsigned typed gate")
            for name in (
                "MANIFEST.sha256",
                "MANIFEST.sha256.asc",
                "PROVENANCE.json",
            ):
                if not (target / name).is_file():
                    raise EvidenceDraftError(
                        "fixture rejected unsigned typed gate"
                    )
            return completed(command)
        if command[0] == "python3":
            if command[2] == "release-certification":
                return run_real(command)
            return completed(command)
        raise AssertionError(f"unexpected command: {command}")


class ReleaseCertificationDraftBuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="edgehub-certification-draft-"
        )
        self.addCleanup(self.temporary.cleanup)
        root = pathlib.Path(self.temporary.name)
        self.fixture = RepositoryFixture(root / "repo")
        artifact_root = (
            self.fixture.root / "artifacts" / self.fixture.candidate
        )
        self.paths: dict[str, pathlib.Path] = {}
        names = {
            "physical_touch": (
                artifact_root / "manual-touch" / "20260727T040000Z"
            ),
            "desktop_notification": (
                artifact_root
                / "desktop-notification-20260727T040001Z-11"
            ),
            "mpris_transport": (
                artifact_root / "mpris-transport-20260727T040002Z-12"
            ),
            "native_deb_lifecycle": (
                artifact_root
                / "native-package-lifecycle-deb-20260727T040003Z-13"
            ),
            "native_rpm_lifecycle": (
                artifact_root
                / "native-package-lifecycle-rpm-20260727T040004Z-14"
            ),
        }
        records = {
            gate.gate_id: gate.record_name for gate in CERTIFICATION_GATES
        }
        for gate_id, path in names.items():
            path.mkdir(parents=True, mode=0o700)
            write_bytes(
                path / records[gate_id],
                f"{gate_id} signed record\n".encode(),
            )
            write_bytes(path / "MANIFEST.sha256", b"signed manifest\n")
            write_bytes(path / "MANIFEST.sha256.asc", b"detached signature\n")
            write_bytes(path / "PROVENANCE.json", b"exact provenance\n")
            self.paths[gate_id] = path

    def build_with(
        self, runner: AggregateRunner, attested_by: str = "Release Owner"
    ) -> pathlib.Path:
        return build_release_certification_draft(
            repository_root=self.fixture.root,
            expected_commit=self.fixture.candidate,
            release_version="v1.0.0",
            attested_by=attested_by,
            gate_paths=self.paths,
            finalizer_path=pathlib.Path("/fixture/finalizer.sh"),
            contract_path=(
                REPOSITORY / "scripts/lib/audit_artifact_contract.py"
            ),
            manual_touch_contract_path=pathlib.Path(
                "/fixture/manual_touch_result.py"
            ),
            runner=runner,
            now=dt.datetime(2026, 7, 27, 5, 6, 7, tzinfo=dt.timezone.utc),
            process_id=81,
        )

    def test_builds_contract_valid_unsigned_draft_from_five_verified_gates(
        self,
    ) -> None:
        runner = AggregateRunner()
        destination = self.build_with(runner)
        receipt = json.loads(
            (destination / "RELEASE_CERTIFICATION.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(receipt["attested_by"], "Release Owner")
        self.assertEqual(
            [gate["id"] for gate in receipt["gates"]],
            [gate.gate_id for gate in CERTIFICATION_GATES],
        )
        self.assertFalse((destination / "MANIFEST.sha256").exists())
        self.assertFalse((destination / "MANIFEST.sha256.asc").exists())
        finalizer_commands = [
            command for command in runner.commands if command[0] == "bash"
        ]
        self.assertEqual(len(finalizer_commands), 10)
        self.assertTrue(
            all(
                command[1:5] == [
                    "/fixture/finalizer.sh",
                    "--verify",
                    "--commit",
                    self.fixture.candidate,
                ]
                for command in finalizer_commands
            )
        )
        self.assertTrue(
            all(
                pathlib.Path(command[-1]) != destination
                for command in finalizer_commands
            )
        )

    def test_unsigned_nested_gate_is_rejected_without_a_draft(self) -> None:
        (self.paths["mpris_transport"] / "MANIFEST.sha256.asc").unlink()
        runner = AggregateRunner()
        with self.assertRaisesRegex(
            EvidenceDraftError, "unsigned typed gate"
        ):
            self.build_with(runner)
        root = (
            self.fixture.root / "artifacts" / self.fixture.candidate
        )
        self.assertFalse(
            any(
                path.name.startswith("release-certification-")
                for path in root.iterdir()
            )
        )

    def test_nested_verifier_failure_is_not_converted_to_pass(self) -> None:
        runner = AggregateRunner(reject_gate="native-package-lifecycle-rpm")
        with self.assertRaisesRegex(
            EvidenceDraftError, "unsigned typed gate"
        ):
            self.build_with(runner)
        self.assertFalse(
            any(
                path.name.startswith("release-certification-")
                for path in (
                    self.fixture.root
                    / "artifacts"
                    / self.fixture.candidate
                ).iterdir()
            )
        )

    def test_attester_name_must_be_explicit_and_one_line(self) -> None:
        runner = AggregateRunner()
        for invalid in ("", " Release Owner", "Release\nOwner"):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(
                    EvidenceDraftError, "attested-by"
                ):
                    self.build_with(runner, invalid)
        self.assertFalse(any(command[0] == "bash" for command in runner.commands))


if __name__ == "__main__":
    unittest.main(verbosity=2)
