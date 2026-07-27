#!/usr/bin/env python3
"""Injection-free contract tests for real desktop bridge evidence receipts."""

from __future__ import annotations

import binascii
import json
import pathlib
import struct
import sys
import tempfile
import types
import unittest
import zlib


REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts" / "lib"))

import audit_artifact_contract as contract  # noqa: E402
import desktop_bridge_evidence as creator  # noqa: E402


SOURCE_COMMIT = "a" * 40


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)
    )


def desktop_png() -> bytes:
    width = 320
    height = 200
    rows = b"".join(
        b"\x00" + bytes((12, 32, 64, 255)) * width
        for _ in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0),
        )
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


def write_events(path: pathlib.Path, prefix: str, events: list[dict]) -> None:
    path.write_text(
        "".join(
            prefix + json.dumps(event, separators=(",", ":")) + "\n"
            for event in events
        ),
        encoding="utf-8",
    )


class DesktopBridgeEvidenceContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="edgehub-desktop-evidence-contract."
        )
        self.root = pathlib.Path(self.temporary.name) / SOURCE_COMMIT
        self.root.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def commands(notification: bool) -> dict[str, list[str]]:
        commands = {
            "configure_command": [
                "/usr/bin/cmake",
                "-B",
                "build",
                f"-DXENEON_EVIDENCE_SOURCE_COMMIT={SOURCE_COMMIT}",
            ],
            "build_command": [
                "/usr/bin/cmake",
                "--build",
                "build",
                "--target",
                "notification_desktop_smoke",
                "mpris_desktop_smoke",
            ],
        }
        if notification:
            commands["transport_monitor_command"] = [
                "/usr/bin/dbus-monitor",
                "--session",
                "org.freedesktop.Notifications Notify",
            ]
            commands["smoke_command"] = [
                "/fixture/notification_desktop_smoke"
            ]
            commands["screenshot_command"] = [
                "/usr/bin/spectacle",
                "-f",
                "-o",
                "/fixture/notification.png",
            ]
        else:
            commands["transport_monitor_command"] = [
                "/usr/bin/dbus-monitor",
                "--session",
                "org.mpris.MediaPlayer2.Player PlayPause",
            ]
            commands["smoke_command"] = [
                "/fixture/mpris_desktop_smoke",
                "vlc",
            ]
        return commands

    def notification_fixture(self) -> types.SimpleNamespace:
        run_id = "desktop-notification-20260727T010203Z-101"
        artifact = self.root / run_id
        evidence = artifact / "evidence"
        evidence.mkdir(parents=True)
        (evidence / "notification.png").write_bytes(desktop_png())
        (evidence / "notification_desktop_smoke").write_bytes(
            b"\x7fELFnotification-" + SOURCE_COMMIT.encode()
        )
        summary = "Break reminder"
        body = "Time to stand up, stretch, and reset."
        (evidence / "dbus-monitor.log").write_text(
            "method call destination=org.freedesktop.Notifications "
            "interface=org.freedesktop.Notifications member=Notify\n"
            f'string "{summary}"\nstring "{body}"\n',
            encoding="utf-8",
        )
        write_events(
            evidence / "process.log",
            "EDGEHUB_NOTIFICATION_EVIDENCE ",
            [
                {
                    "event": "request",
                    "timestamp": "2020-01-01T01:02:03.000Z",
                    "source_commit": SOURCE_COMMIT,
                    "service": "org.freedesktop.Notifications",
                    "method": "Notify",
                    "summary": summary,
                    "body": body,
                    "profile": "priority",
                    "urgency": 2,
                    "resident": True,
                    "transient": False,
                    "timeout_ms": 0,
                },
                {
                    "event": "confirmed",
                    "timestamp": "2020-01-01T01:02:03.100Z",
                    "source_commit": SOURCE_COMMIT,
                    "service": "org.freedesktop.Notifications",
                    "method": "Notify",
                    "notification_id": 42,
                },
            ],
        )
        return types.SimpleNamespace(
            kind="notification",
            artifact_dir=artifact,
            source_commit=SOURCE_COMMIT,
            run_id=run_id,
            attested_by="Contract Auditor",
            attestation=contract.DESKTOP_NOTIFICATION_ATTESTATION,
            summary=summary,
            body=body,
            process_log="evidence/process.log",
            transport_log="evidence/dbus-monitor.log",
            screenshot="evidence/notification.png",
            screenshot_captured_at="2020-01-01T01:02:04.000Z",
            smoke_binary="evidence/notification_desktop_smoke",
            **self.commands(notification=True),
        )

    def mpris_fixture(self) -> types.SimpleNamespace:
        run_id = "mpris-transport-20260727T010203Z-102"
        artifact = self.root / run_id
        evidence = artifact / "evidence"
        evidence.mkdir(parents=True)
        (evidence / "mpris_desktop_smoke").write_bytes(
            b"\x7fELFmpris-" + SOURCE_COMMIT.encode()
        )
        (evidence / "dbus-monitor.log").write_text(
            "method call destination=org.mpris.MediaPlayer2.vlc "
            "interface=org.mpris.MediaPlayer2.Player member=PlayPause\n"
            "method call destination=org.mpris.MediaPlayer2.vlc "
            "interface=org.mpris.MediaPlayer2.Player member=PlayPause\n",
            encoding="utf-8",
        )
        common = {
            "source_commit": SOURCE_COMMIT,
            "player_bus_name": "org.mpris.MediaPlayer2.vlc",
            "action": "PlayPause",
        }
        write_events(
            evidence / "process.log",
            "EDGEHUB_MPRIS_EVIDENCE ",
            [
                {
                    **common,
                    "event": "selected",
                    "timestamp": "2020-01-01T01:03:00.000Z",
                    "player_name": "vlc",
                    "state": "Playing",
                },
                {
                    **common,
                    "event": "action_sent",
                    "timestamp": "2020-01-01T01:03:00.010Z",
                    "state": "Playing",
                },
                {
                    **common,
                    "event": "intermediate_observed",
                    "timestamp": "2020-01-01T01:03:00.200Z",
                    "state": "Paused",
                },
                {
                    **common,
                    "event": "restore_sent",
                    "timestamp": "2020-01-01T01:03:00.210Z",
                    "state": "Paused",
                },
                {
                    **common,
                    "event": "restored_observed",
                    "timestamp": "2020-01-01T01:03:00.400Z",
                    "state": "Playing",
                },
                {
                    **common,
                    "event": "complete",
                    "timestamp": "2020-01-01T01:03:00.410Z",
                    "before_state": "Playing",
                    "intermediate_state": "Paused",
                    "current_state": "Playing",
                    "reason": "state changed and was restored",
                },
            ],
        )
        return types.SimpleNamespace(
            kind="mpris",
            artifact_dir=artifact,
            source_commit=SOURCE_COMMIT,
            run_id=run_id,
            attested_by="Contract Auditor",
            attestation=contract.MPRIS_TRANSPORT_ATTESTATION,
            player="vlc",
            process_log="evidence/process.log",
            transport_log="evidence/dbus-monitor.log",
            smoke_binary="evidence/mpris_desktop_smoke",
            **self.commands(notification=False),
        )

    def test_notification_receipt_requires_real_machine_evidence(self) -> None:
        arguments = self.notification_fixture()
        creator.create_notification(arguments)
        contract.validate_desktop_notification(
            arguments.artifact_dir, SOURCE_COMMIT, arguments.run_id
        )

    def test_notification_never_defaults_the_human_attestation(self) -> None:
        arguments = self.notification_fixture()
        arguments.attestation = "PASS"
        with self.assertRaisesRegex(
            contract.ContractError, "exact human attestation"
        ):
            creator.create_notification(arguments)
        self.assertFalse(
            (arguments.artifact_dir / "DESKTOP_NOTIFICATION.json").exists()
        )

    def test_notification_rejects_signature_only_fake_png(self) -> None:
        arguments = self.notification_fixture()
        (arguments.artifact_dir / arguments.screenshot).write_bytes(
            b"\x89PNG\r\n\x1a\nnot-an-image"
        )
        with self.assertRaisesRegex(contract.ContractError, "PNG"):
            creator.create_notification(arguments)

    def test_notification_rejects_handwritten_transport_claim(self) -> None:
        arguments = self.notification_fixture()
        (arguments.artifact_dir / arguments.transport_log).write_text(
            "service=org.freedesktop.Notifications result=visible\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(contract.ContractError, "exact Notify call"):
            creator.create_notification(arguments)

    def test_mpris_receipt_proves_change_and_restoration(self) -> None:
        arguments = self.mpris_fixture()
        creator.create_mpris(arguments)
        contract.validate_mpris_transport(
            arguments.artifact_dir, SOURCE_COMMIT, arguments.run_id
        )

    def test_mpris_rejects_one_transport_call(self) -> None:
        arguments = self.mpris_fixture()
        transport = arguments.artifact_dir / arguments.transport_log
        transport.write_text(
            transport.read_text(encoding="utf-8").splitlines()[0] + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(contract.ContractError, "restoration calls"):
            creator.create_mpris(arguments)

    def test_mpris_rejects_unrestored_process_state(self) -> None:
        arguments = self.mpris_fixture()
        process = arguments.artifact_dir / arguments.process_log
        lines = process.read_text(encoding="utf-8").splitlines()
        restored = json.loads(lines[4].split(" ", 1)[1])
        restored["state"] = "Paused"
        lines[4] = (
            "EDGEHUB_MPRIS_EVIDENCE "
            + json.dumps(restored, separators=(",", ":"))
        )
        process.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
            contract.ContractError, "restorable state transition"
        ):
            creator.create_mpris(arguments)

    def test_mpris_receipt_tampering_is_rejected(self) -> None:
        arguments = self.mpris_fixture()
        creator.create_mpris(arguments)
        receipt = arguments.artifact_dir / "MPRIS_TRANSPORT.json"
        document = json.loads(receipt.read_text(encoding="utf-8"))
        document["state_restored"] = False
        receipt.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            contract.ContractError, "observed state change"
        ):
            contract.validate_mpris_transport(
                arguments.artifact_dir, SOURCE_COMMIT, arguments.run_id
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
