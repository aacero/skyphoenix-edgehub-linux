#!/usr/bin/env bash
# Focused negative controls for typed, signed stable-publication receipts.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/edgehub-release-certification.XXXXXX")"
fixture_repo="$fixture/repo"
fixture_gnupg="$fixture/gnupg"

cleanup() {
    case "$fixture" in
        "${TMPDIR:-/tmp}"/edgehub-release-certification.*)
            find "$fixture" -depth -delete
            ;;
        *) printf 'REFUSING unsafe cleanup path: %s\n' "$fixture" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_rejected() {
    local label="$1"
    shift
    if "$@" >"$fixture/rejected.log" 2>&1; then
        fail "$label"
    fi
    printf '  ok  %s\n' "$label"
}

mkdir -m 0700 -p "$fixture_gnupg" "$fixture_repo/scripts/lib"
cp -- \
    "$repo/scripts/finalize_audit_artifacts.sh" \
    "$repo/scripts/verify_release_certification.sh" \
    "$fixture_repo/scripts/"
cp -- \
    "$repo/scripts/lib/audit_artifact_contract.py" \
    "$repo/scripts/lib/audit_artifact_manifest.py" \
    "$repo/scripts/lib/manual_touch_result.py" \
    "$repo/scripts/lib/release_origin.sh" \
    "$fixture_repo/scripts/lib/"
chmod 0755 \
    "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
    "$fixture_repo/scripts/verify_release_certification.sh"

GNUPGHOME="$fixture_gnupg" gpg --batch --quiet --passphrase '' \
    --quick-generate-key \
    "Release Certification Contract <certification@example.invalid>" \
    ed25519 sign 1d
fixture_key="$(
    GNUPGHOME="$fixture_gnupg" gpg --with-colons --list-keys \
        | awk -F: '$1 == "fpr" { print $10; exit }'
)"
[ -n "$fixture_key" ] || fail "temporary signing key was not created"
python3 - "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
    "$fixture_repo/scripts/verify_release_certification.sh" \
    "$fixture_key" <<'PY'
import pathlib
import sys

old = "2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
for name in sys.argv[1:3]:
    path = pathlib.Path(name)
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"could not replace the pinned key in {path}")
    path.write_text(text.replace(old, sys.argv[3]), encoding="utf-8")
PY

printf 'artifacts/\n' >"$fixture_repo/.gitignore"
printf 'release certification fixture\n' >"$fixture_repo/candidate.txt"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name "Release Certification Contract"
git -C "$fixture_repo" config user.email "certification@example.invalid"
git -C "$fixture_repo" remote add origin \
    https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
git -C "$fixture_repo" add .
git -C "$fixture_repo" -c commit.gpgSign=false commit -qm fixture
candidate_sha="$(git -C "$fixture_repo" rev-parse HEAD)"
artifact_root="$fixture_repo/artifacts/$candidate_sha"

python3 - "$artifact_root" "$candidate_sha" <<'PY'
import datetime
import binascii
import hashlib
import json
import pathlib
import struct
import sys
import zlib

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
stamp = "20260726T110000Z"
completed = "2026-07-26T11:05:00Z"
def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)
    )

width = 320
height = 200
scanlines = b"".join(
    b"\x00" + (bytes((20, 40, 80, 255)) * width)
    for _ in range(height)
)
png = (
    b"\x89PNG\r\n\x1a\n"
    + png_chunk(
        b"IHDR",
        struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0),
    )
    + png_chunk(b"IDAT", zlib.compress(scanlines))
    + png_chunk(b"IEND", b"")
)

touch = root / "manual-touch" / stamp
touch.mkdir(parents=True)
ids = [
    "01-focus",
    "02-hydration",
    "03-task-toggle",
    "04-page-swipe",
    "05-widget-settings",
    "06-edit-gestures",
]
with (touch / "ACTION_RESULTS.tsv").open("w", encoding="utf-8", newline="\n") as handle:
    handle.write(
        "id\taction\tresult\tstarted\tended\tscreenshot\t"
        "physical_evidence\tnotes\n"
    )
    for index, action_id in enumerate(ids, start=1):
        physical_name = f"{action_id}-physical.png"
        handle.write(
            f"{action_id}\tAction {index}\tPASS\t"
            f"2026-07-26T11:0{index}:00+00:00\t"
            f"2026-07-26T11:0{index}:30+00:00\t"
            f"{action_id}.png\t{physical_name}\t"
            "Observed on physical panel.\n"
        )
        (touch / f"{action_id}.png").write_bytes(png + bytes([index]))
        (touch / physical_name).write_bytes(png + bytes([index, 255]))
(touch / "ENVIRONMENT.txt").write_text(
    f"source_sha={commit}\n"
    "branch=master\n"
    "host=contract-host\n"
    "panel=DP-3\n"
    "geometry=2560x720+0+0\n"
    "rotation=1\n"
    "scale=1\n"
    "started=2026-07-26T11:00:00+00:00\n"
    "running_hub_pid=1234\n"
    "running_hub_executable=/usr/bin/xeneon-edge-hub\n"
    f"running_hub_sha256={'a' * 64}\n"
    "running_hub_identity=Xeneon Edge Linux Hub 1.0.0\n"
    "expected_hub_identity=Xeneon Edge Linux Hub 1.0.0\n"
    "installed_package=xeneon-edge-hub 1.0.0-1\n",
    encoding="utf-8",
)
(touch / "REPORT.md").write_text(
    "# Manual physical-touch audit\n\n"
    "- Overall result: **PASS**\n"
    f"- Source SHA: `{commit}`\n"
    "- Running Hub identity: `Xeneon Edge Linux Hub 1.0.0`\n"
    f"- Running Hub SHA-256: `{'a' * 64}`\n"
    "- Installed package: `xeneon-edge-hub 1.0.0-1`\n"
    "- Auditor: Contract Auditor\n\n"
    "Electronic signature: **Contract Auditor**\n",
    encoding="utf-8",
)

def write_json(path, document):
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

notification_id = f"desktop-notification-{stamp}-11"
notification = root / notification_id
(notification / "evidence").mkdir(parents=True)
notification_png = notification / "evidence" / "notification.png"
notification_log = notification / "evidence" / "dbus.log"
notification_process = notification / "evidence" / "process.log"
notification_binary = notification / "evidence" / "notification_desktop_smoke"
notification_png.write_bytes(png)
notification_log.write_text(
    "method call destination=org.freedesktop.Notifications "
    "interface=org.freedesktop.Notifications member=Notify\n"
    'string "Break reminder"\n'
    'string "Time to stand up, stretch, and reset."\n',
    encoding="utf-8",
)
notification_events = [
    {
        "event": "request",
        "timestamp": "2026-07-26T11:00:00.000Z",
        "source_commit": commit,
        "service": "org.freedesktop.Notifications",
        "method": "Notify",
        "summary": "Break reminder",
        "body": "Time to stand up, stretch, and reset.",
        "profile": "priority",
        "urgency": 2,
        "resident": True,
        "transient": False,
        "timeout_ms": 0,
    },
    {
        "event": "confirmed",
        "timestamp": "2026-07-26T11:00:00.100Z",
        "source_commit": commit,
        "service": "org.freedesktop.Notifications",
        "method": "Notify",
        "notification_id": 42,
    },
]
notification_process.write_text(
    "".join(
        "EDGEHUB_NOTIFICATION_EVIDENCE "
        + json.dumps(event, separators=(",", ":"))
        + "\n"
        for event in notification_events
    ),
    encoding="utf-8",
)
notification_binary.write_bytes(
    b"\x7fELFnotification-fixture-" + commit.encode()
)
commands = {
    "configure": [
        "/usr/bin/cmake",
        "-B",
        "build",
        f"-DXENEON_EVIDENCE_SOURCE_COMMIT={commit}",
    ],
    "build": [
        "/usr/bin/cmake",
        "--build",
        "build",
        "--target",
        "notification_desktop_smoke",
        "mpris_desktop_smoke",
    ],
    "transport_monitor": [
        "/usr/bin/dbus-monitor",
        "--session",
        "org.freedesktop.Notifications Notify",
    ],
    "smoke": ["/fixture/notification_desktop_smoke"],
    "screenshot": [
        "/usr/bin/spectacle",
        "-f",
        "-o",
        "/fixture/notification.png",
    ],
}
write_json(
    notification / "DESKTOP_NOTIFICATION.json",
    {
        "schema": "skyphoenix-edgehub-desktop-notification/v2",
        "source_commit": commit,
        "run_id": notification_id,
        "result": "PASS",
        "request_sent_at": "2026-07-26T11:00:00.000Z",
        "delivery_confirmed_at": "2026-07-26T11:00:00.100Z",
        "screenshot_captured_at": "2026-07-26T11:00:01.000Z",
        "completed_at": completed,
        "desktop_service": "org.freedesktop.Notifications",
        "method": "Notify",
        "summary": "Break reminder",
        "body": "Time to stand up, stretch, and reset.",
        "priority_profile": {
            "category": "x-edgehub.reminder",
            "resident": True,
            "timeout_ms": 0,
            "transient": False,
            "urgency": 2,
        },
        "commands": commands,
        "observed_on_real_desktop": True,
        "visually_distinct": True,
        "screenshot_path": "evidence/notification.png",
        "screenshot_sha256": hashlib.sha256(notification_png.read_bytes()).hexdigest(),
        "transport_log_path": "evidence/dbus.log",
        "transport_log_sha256": hashlib.sha256(notification_log.read_bytes()).hexdigest(),
        "process_log_path": "evidence/process.log",
        "process_log_sha256": hashlib.sha256(notification_process.read_bytes()).hexdigest(),
        "smoke_binary_path": "evidence/notification_desktop_smoke",
        "smoke_binary_sha256": hashlib.sha256(notification_binary.read_bytes()).hexdigest(),
        "attested_by": "Contract Auditor",
        "attestation": (
            "I observed this priority break notification on the real desktop and "
            "confirm it was visually distinct."
        ),
    },
)

mpris_id = f"mpris-transport-{stamp}-12"
mpris = root / mpris_id
(mpris / "evidence").mkdir(parents=True)
mpris_log = mpris / "evidence" / "transport.log"
mpris_process = mpris / "evidence" / "process.log"
mpris_binary = mpris / "evidence" / "mpris_desktop_smoke"
mpris_log.write_text(
    "method call destination=org.mpris.MediaPlayer2.vlc "
    "interface=org.mpris.MediaPlayer2.Player member=PlayPause\n"
    "method call destination=org.mpris.MediaPlayer2.vlc "
    "interface=org.mpris.MediaPlayer2.Player member=PlayPause\n",
    encoding="utf-8",
)
mpris_events = [
    {
        "event": "selected",
        "timestamp": "2026-07-26T11:01:00.000Z",
        "source_commit": commit,
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "player_name": "vlc",
        "action": "PlayPause",
        "state": "Playing",
    },
    {
        "event": "action_sent",
        "timestamp": "2026-07-26T11:01:00.010Z",
        "source_commit": commit,
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "action": "PlayPause",
        "state": "Playing",
    },
    {
        "event": "intermediate_observed",
        "timestamp": "2026-07-26T11:01:00.200Z",
        "source_commit": commit,
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "action": "PlayPause",
        "state": "Paused",
    },
    {
        "event": "restore_sent",
        "timestamp": "2026-07-26T11:01:00.210Z",
        "source_commit": commit,
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "action": "PlayPause",
        "state": "Paused",
    },
    {
        "event": "restored_observed",
        "timestamp": "2026-07-26T11:01:00.400Z",
        "source_commit": commit,
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "action": "PlayPause",
        "state": "Playing",
    },
    {
        "event": "complete",
        "timestamp": "2026-07-26T11:01:00.410Z",
        "source_commit": commit,
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "action": "PlayPause",
        "before_state": "Playing",
        "intermediate_state": "Paused",
        "current_state": "Playing",
        "reason": "state changed and was restored",
    },
]
mpris_process.write_text(
    "".join(
        "EDGEHUB_MPRIS_EVIDENCE "
        + json.dumps(event, separators=(",", ":"))
        + "\n"
        for event in mpris_events
    ),
    encoding="utf-8",
)
mpris_binary.write_bytes(b"\x7fELFmpris-fixture-" + commit.encode())
write_json(
    mpris / "MPRIS_TRANSPORT.json",
    {
        "schema": "skyphoenix-edgehub-mpris-transport/v2",
        "source_commit": commit,
        "run_id": mpris_id,
        "result": "PASS",
        "completed_at": completed,
        "player_requested": "vlc",
        "player_bus_name": "org.mpris.MediaPlayer2.vlc",
        "action": "PlayPause",
        "before_state": "Playing",
        "intermediate_state": "Paused",
        "restored_state": "Playing",
        "state_changed": True,
        "state_restored": True,
        "action_sent_at": "2026-07-26T11:01:00.010Z",
        "intermediate_observed_at": "2026-07-26T11:01:00.200Z",
        "restore_sent_at": "2026-07-26T11:01:00.210Z",
        "restored_at": "2026-07-26T11:01:00.400Z",
        "commands": {
            "configure": commands["configure"],
            "build": commands["build"],
            "transport_monitor": [
                "/usr/bin/dbus-monitor",
                "--session",
                "org.mpris.MediaPlayer2.Player PlayPause",
            ],
            "smoke": ["/fixture/mpris_desktop_smoke", "vlc"],
        },
        "transport_log_path": "evidence/transport.log",
        "transport_log_sha256": hashlib.sha256(mpris_log.read_bytes()).hexdigest(),
        "process_log_path": "evidence/process.log",
        "process_log_sha256": hashlib.sha256(mpris_process.read_bytes()).hexdigest(),
        "smoke_binary_path": "evidence/mpris_desktop_smoke",
        "smoke_binary_sha256": hashlib.sha256(mpris_binary.read_bytes()).hexdigest(),
        "attested_by": "Contract Auditor",
        "attestation": (
            "I observed the named real player change state after PlayPause and "
            "return to its original state."
        ),
    },
)

pass_fields = [
    "clean_install",
    "exact_artifact_reinstall",
    "upgrade",
    "upgrade_retired_paths_removed",
    "candidate_notices_and_autostart",
    "rollback",
    "rollback_retired_paths_removed",
    "rollback_baseline_payload_restored",
    "removal",
    "candidate_and_baseline_payload_removal",
]
for number, kind in enumerate(("deb", "rpm"), start=13):
    run_id = f"native-package-lifecycle-{kind}-{stamp}-{number}"
    run = root / run_id
    (run / "evidence").mkdir(parents=True)
    package_hash = (("d" if kind == "deb" else "e") * 64)
    report = run / "evidence" / f"native-upgrade-rollback-{kind}.txt"
    fields = {
        "result": "PASS",
        "package_kind": kind,
        "baseline_sha": "b" * 40,
        "candidate_sha": commit,
        "candidate_package_sha256": package_hash,
    }
    fields.update({field: "PASS" for field in pass_fields})
    report.write_text(
        "".join(f"{key}={value}\n" for key, value in fields.items()),
        encoding="utf-8",
    )
    write_json(
        run / "NATIVE_PACKAGE_LIFECYCLE.json",
        {
            "schema": "skyphoenix-edgehub-native-package-lifecycle/v1",
            "source_commit": commit,
            "run_id": run_id,
            "result": "PASS",
            "completed_at": completed,
            "package_kind": kind,
            "baseline_sha": "b" * 40,
            "candidate_sha": commit,
            "candidate_package_sha256": package_hash,
            "workflow_url": (
                "https://github.com/skyphoenix-it/"
                "skyphoenix-edgehub-linux/actions/runs/123456"
            ),
            "github_provenance_verified": True,
            "report_path": f"evidence/native-upgrade-rollback-{kind}.txt",
            "report_sha256": hashlib.sha256(report.read_bytes()).hexdigest(),
            "attested_by": "Contract Auditor",
            "attestation": "I verified the exact GitHub lifecycle artifact and provenance.",
        },
    )

# A structurally valid notification record that is deliberately left unsigned.
unsigned_id = f"desktop-notification-{stamp}-21"
unsigned = root / unsigned_id
(unsigned / "evidence").mkdir(parents=True)
for name in (
    "notification.png",
    "dbus.log",
    "process.log",
    "notification_desktop_smoke",
):
    (unsigned / "evidence" / name).write_bytes(
        (notification / "evidence" / name).read_bytes()
    )
unsigned_document = json.loads(
    (notification / "DESKTOP_NOTIFICATION.json").read_text(encoding="utf-8")
)
unsigned_document["run_id"] = unsigned_id
write_json(unsigned / "DESKTOP_NOTIFICATION.json", unsigned_document)

# A typed record with FAIL must be rejected by the semantic finalizer.
failed_id = f"mpris-transport-{stamp}-22"
failed = root / failed_id
(failed / "evidence").mkdir(parents=True)
failed_log = failed / "evidence" / "transport.log"
failed_log.write_text(
    "bus=org.mpris.MediaPlayer2.vlc action=PlayPause before=Playing after=Paused\n",
    encoding="utf-8",
)
failed_document = json.loads(
    (mpris / "MPRIS_TRANSPORT.json").read_text(encoding="utf-8")
)
failed_document["run_id"] = failed_id
failed_document["result"] = "FAIL"
failed_document["transport_log_sha256"] = hashlib.sha256(
    failed_log.read_bytes()
).hexdigest()
write_json(failed / "MPRIS_TRANSPORT.json", failed_document)

# An old generic text-file receipt must not satisfy the typed v2 contract.
generic_id = "release-certification-20260726T110000Z-31"
generic = root / generic_id
(generic / "evidence").mkdir(parents=True)
(generic / "evidence" / "claim.txt").write_text("PASS\n", encoding="utf-8")
write_json(
    generic / "RELEASE_CERTIFICATION.json",
    {
        "schema": "skyphoenix-edgehub-release-certification/v1",
        "source_commit": commit,
        "release_version": "v1.0.0",
        "run_id": generic_id,
        "result": "PASS",
        "completed_at": completed,
        "attested_by": "Contract Auditor",
        "attestation": (
            "I attest that every named gate was reviewed against the retained "
            "evidence and passed for this exact source commit and release version."
        ),
        "gates": [],
    },
)
PY

touch_dir="$artifact_root/manual-touch/20260726T110000Z"
notification_dir="$artifact_root/desktop-notification-20260726T110000Z-11"
mpris_dir="$artifact_root/mpris-transport-20260726T110000Z-12"
deb_dir="$artifact_root/native-package-lifecycle-deb-20260726T110000Z-13"
rpm_dir="$artifact_root/native-package-lifecycle-rpm-20260726T110000Z-14"
unsigned_dir="$artifact_root/desktop-notification-20260726T110000Z-21"
failed_dir="$artifact_root/mpris-transport-20260726T110000Z-22"
generic_dir="$artifact_root/release-certification-20260726T110000Z-31"

echo "==> Typed stable-publication receipt contract"
if bash "$repo/scripts/release.sh" --version v9.8.7 --publish \
        >"$fixture/direct-stable.log" 2>&1; then
    fail "direct stable publication bypassed candidate staging"
elif grep -Fq "direct stable publication is forbidden" \
        "$fixture/direct-stable.log"; then
    printf '  ok  direct stable publication cannot bypass candidate staging\n'
else
    fail "direct stable publication did not report the staging requirement"
fi
if bash "$repo/scripts/release.sh" \
        --version v9.8.7 --stage-candidate \
        >"$fixture/missing-release-certification.log" 2>&1; then
    fail "stable candidate staging accepted no --certification receipt"
elif grep -Fq "stable release requires --certification" \
        "$fixture/missing-release-certification.log"; then
    printf '  ok  stable candidate staging fails before work without certification\n'
else
    fail "candidate staging did not report the missing certification receipt"
fi

expect_rejected "generic non-empty text claims cannot be sealed" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$generic_dir"
expect_rejected "a failed typed MPRIS receipt cannot be sealed" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$failed_dir"

for typed_dir in \
    "$touch_dir" "$notification_dir" "$mpris_dir" "$deb_dir" "$rpm_dir"; do
    env GNUPGHOME="$fixture_gnupg" \
        bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$typed_dir" \
        >/dev/null
done

create_aggregate() {
    local run_id="$1" mode="$2"
    local aggregate_dir="$artifact_root/$run_id"
    python3 - "$fixture_repo" "$aggregate_dir" "$candidate_sha" \
        "$run_id" "$mode" <<'PY'
import datetime
import hashlib
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
commit = sys.argv[3]
run_id = sys.argv[4]
mode = sys.argv[5]
root.mkdir(parents=True)
typed = [
    ("physical_touch", f"artifacts/{commit}/manual-touch/20260726T110000Z",
     "ACTION_RESULTS.tsv"),
    ("desktop_notification",
     f"artifacts/{commit}/desktop-notification-20260726T110000Z-11",
     "DESKTOP_NOTIFICATION.json"),
    ("mpris_transport", f"artifacts/{commit}/mpris-transport-20260726T110000Z-12",
     "MPRIS_TRANSPORT.json"),
    ("native_deb_lifecycle",
     f"artifacts/{commit}/native-package-lifecycle-deb-20260726T110000Z-13",
     "NATIVE_PACKAGE_LIFECYCLE.json"),
    ("native_rpm_lifecycle",
     f"artifacts/{commit}/native-package-lifecycle-rpm-20260726T110000Z-14",
     "NATIVE_PACKAGE_LIFECYCLE.json"),
]
if mode == "unsigned":
    typed[1] = (
        "desktop_notification",
        f"artifacts/{commit}/desktop-notification-20260726T110000Z-21",
        "DESKTOP_NOTIFICATION.json",
    )
gates = []
for gate_id, artifact_path, record_name in typed:
    run = repo / artifact_path
    names = [
        record_name,
        "MANIFEST.sha256",
        "MANIFEST.sha256.asc",
        "PROVENANCE.json",
    ]
    hashes = {}
    for name in names:
        path = run / name
        if path.exists():
            hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        else:
            hashes[name] = "0" * 64
    if mode == "wrong-hash" and gate_id == "mpris_transport":
        hashes[record_name] = "f" * 64
    gates.append(
        {
            "id": gate_id,
            "result": "PASS",
            "receipt": {
                "artifact_path": artifact_path,
                "record_name": record_name,
                "record_sha256": hashes[record_name],
                "manifest_sha256": hashes["MANIFEST.sha256"],
                "signature_sha256": hashes["MANIFEST.sha256.asc"],
                "provenance_sha256": hashes["PROVENANCE.json"],
            },
        }
    )
document = {
    "schema": "skyphoenix-edgehub-release-certification/v2",
    "source_commit": commit,
    "release_version": "v1.0.0",
    "run_id": run_id,
    "result": "PASS",
    "completed_at": "2026-07-26T12:00:00Z",
    "attested_by": "Contract Auditor",
    "attestation": (
        "I attest that every named gate was reviewed against the retained evidence "
        "and passed for this exact source commit and release version."
    ),
    "gates": gates,
}
(root / "RELEASE_CERTIFICATION.json").write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
    printf '%s\n' "$aggregate_dir"
}

unsigned_aggregate="$(create_aggregate \
    release-certification-20260726T120000Z-41 unsigned)"
env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
        "$unsigned_aggregate" >/dev/null
expect_rejected "a signed aggregate cannot bless an unsigned typed receipt" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$candidate_sha" --version v1.0.0 "$unsigned_aggregate"

wrong_hash_aggregate="$(create_aggregate \
    release-certification-20260726T120000Z-42 wrong-hash)"
env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" \
        "$wrong_hash_aggregate" >/dev/null
expect_rejected "a signed aggregate with a wrong nested record hash is rejected" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$candidate_sha" --version v1.0.0 "$wrong_hash_aggregate"

valid_dir="$(create_aggregate \
    release-certification-20260726T120000Z-43 valid)"
env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/finalize_audit_artifacts.sh" "$valid_dir" \
    >/dev/null
env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$candidate_sha" --version v1.0.0 "$valid_dir" \
    >/dev/null
printf '  ok  five exact-commit signed typed PASS receipts are accepted\n'

native_hashes="$(env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$candidate_sha" --version v1.0.0 \
        --print-native-package-hashes "$valid_dir")"
expected_native_hashes="$(printf 'deb\t%s\nrpm\t%s' \
    "$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..64})")"
[ "$native_hashes" = "$expected_native_hashes" ] \
    || fail "verified certification did not expose the exact native package hashes"
printf '  ok  verified certification exposes exact DEB and RPM package hashes\n'

expect_rejected "a typed aggregate for another stable version is rejected" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$candidate_sha" --version v1.0.1 "$valid_dir"

printf 'next committed state\n' >"$fixture_repo/next.txt"
git -C "$fixture_repo" add next.txt
git -C "$fixture_repo" -c commit.gpgSign=false commit -qm next
wrong_sha="$(git -C "$fixture_repo" rev-parse HEAD)"
expect_rejected "typed receipts keyed to another source SHA are rejected" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$wrong_sha" --version v1.0.0 "$valid_dir"

chmod u+w "$valid_dir/MANIFEST.sha256.asc"
printf 'invalid signature\n' >"$valid_dir/MANIFEST.sha256.asc"
expect_rejected "an invalid aggregate detached signature is rejected" \
    env GNUPGHOME="$fixture_gnupg" \
    bash "$fixture_repo/scripts/verify_release_certification.sh" \
        --commit "$candidate_sha" --version v1.0.0 "$valid_dir"

printf 'RESULT: SUCCESS\n'
