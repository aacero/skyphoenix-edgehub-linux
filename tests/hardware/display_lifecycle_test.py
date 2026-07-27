#!/usr/bin/env python3
"""Real KDE/Wayland display-lifecycle validation for the physical Edge.

This suite is intentionally disruptive and therefore separately gated. It
rotates, scales, promotes, disables, and re-enables the detected Edge output,
then restores and verifies the exact KScreen baseline on every exit path. The
Hub runs with an isolated config and runtime directory; the user's Hub
config/socket are never used. No synthetic input is created.

Run on an attended KDE Wayland session with the Edge attached. Evidence must
be written to a new, commit-keyed directory:

    XENEON_HW_DISPLAY_LIFECYCLE=1 \
      python3 tests/hardware/display_lifecycle_test.py \
        --hub "$PWD/build/xeneon-edge-hub" \
        --evidence-dir "$PWD/artifacts/$(git rev-parse HEAD)/display-lifecycle-$(date -u +%Y%m%dT%H%M%SZ)"
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(
    0,
    os.fspath(Path(HERE).resolve().parents[1] / "tests" / "performance"),
)

import desktop_target as dt  # noqa: E402
import e2e_harness as harness  # noqa: E402
from e2e_harness import E2E, assert_binaries_current, doc, page, tile  # noqa: E402
from run_hub_profiles import validate_candidate_build  # noqa: E402


GATE = "XENEON_HW_DISPLAY_LIFECYCLE"
REPO = Path(HERE).resolve().parents[1]
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
ROTATION_NAMES = {
    1: "none", 2: "left", 4: "inverted", 8: "right",
    16: "flipped", 32: "flipped90", 64: "flipped180", 128: "flipped270",
}


def doctor_json():
    result = subprocess.run(["kscreen-doctor", "-j"], capture_output=True,
                            text=True, timeout=15)
    if result.returncode:
        raise RuntimeError("kscreen-doctor -j failed: " + result.stderr.strip())
    return json.loads(result.stdout)


def output_by_name(config, name):
    return next((o for o in config.get("outputs", []) if o.get("name") == name), None)


def apply_doctor(*settings):
    print("  kscreen-doctor", " ".join(settings), flush=True)
    result = subprocess.run(["kscreen-doctor", *settings], capture_output=True,
                            text=True, timeout=20)
    if result.returncode:
        raise RuntimeError("kscreen-doctor failed: " +
                           (result.stderr or result.stdout).strip())
    time.sleep(3.0)


def restore_settings(baseline):
    settings = []
    for out in baseline.get("outputs", []):
        name = out["name"]
        if not out.get("enabled"):
            settings.append("output.%s.disable" % name)
            continue
        rotation = ROTATION_NAMES.get(out.get("rotation"))
        if not rotation:
            raise RuntimeError("unsupported baseline rotation %r for %s" %
                               (out.get("rotation"), name))
        settings.extend([
            "output.%s.enable" % name,
            "output.%s.mode.%s" % (name, out["currentModeId"]),
            "output.%s.position.%d,%d" %
            (name, out["pos"]["x"], out["pos"]["y"]),
            "output.%s.rotation.%s" % (name, rotation),
            "output.%s.scale.%s" % (name, out["scale"]),
            "output.%s.priority.%s" % (name, out["priority"]),
        ])
    return settings


def display_fingerprint(config):
    """Return only the display state that this test may change."""

    result = {}
    for output in config.get("outputs", []):
        name = output.get("name")
        if not isinstance(name, str) or not name:
            raise RuntimeError("KScreen output has no stable name")
        record = {"enabled": bool(output.get("enabled"))}
        if record["enabled"]:
            record.update({
                "currentModeId": output.get("currentModeId"),
                "pos": output.get("pos"),
                "rotation": output.get("rotation"),
                "scale": output.get("scale"),
                "priority": output.get("priority"),
            })
        result[name] = record
    return result


class DisplayRestoreGuard:
    """Restore and verify the complete KScreen baseline on every exit path."""

    def __init__(self, baseline, apply=apply_doctor, read=doctor_json):
        self.baseline = baseline
        self.apply = apply
        self.read = read
        self.final_state = None
        self.verified = False

    def __enter__(self):
        return self

    def __exit__(self, exception_type, exception, exception_traceback):
        try:
            self.apply(*restore_settings(self.baseline))
            self.final_state = self.read()
            expected = display_fingerprint(self.baseline)
            observed = display_fingerprint(self.final_state)
            if observed != expected:
                raise RuntimeError(
                    "display state after restore differs from the exact baseline: "
                    "expected=%r observed=%r" % (expected, observed)
                )
            self.verified = True
        except BaseException as restore_error:
            self.verified = False
            print("!! CRITICAL: baseline display restore failed:",
                  restore_error, flush=True)
            if exception is not None:
                raise RuntimeError(
                    "display restore failed while handling an earlier test error"
                ) from restore_error
            raise
        return False


def repository_commit():
    result = subprocess.run(
        ["git", "-C", str(REPO), "rev-parse", "--verify", "HEAD^{commit}"],
        capture_output=True, text=True, timeout=10,
    )
    commit = result.stdout.strip()
    if result.returncode != 0 or not FULL_SHA.fullmatch(commit):
        raise RuntimeError("display evidence requires a full committed HEAD")
    return commit


def require_clean_repository():
    result = subprocess.run(
        ["git", "-C", str(REPO), "status", "--porcelain=v1",
         "--untracked-files=all", "--ignore-submodules=none"],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        raise RuntimeError("could not verify the repository state")
    if result.stdout:
        raise RuntimeError(
            "display lifecycle evidence requires a clean tree at the recorded SHA"
        )


def prepare_evidence_directory(raw_path, commit, repo=REPO):
    """Create one new, non-symlink artifact leaf for the exact source commit."""

    if not FULL_SHA.fullmatch(commit):
        raise RuntimeError("evidence commit must be a full lowercase SHA")
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        raise RuntimeError("--evidence-dir must be an absolute path")
    candidate = Path(os.path.abspath(os.fspath(candidate)))
    artifacts = Path(os.path.abspath(os.fspath(Path(repo) / "artifacts")))
    try:
        relative = candidate.relative_to(artifacts)
    except ValueError as error:
        raise RuntimeError(
            "--evidence-dir must stay below the repository artifacts directory"
        ) from error
    if len(relative.parts) < 2 or relative.parts[0] != commit:
        raise RuntimeError(
            "--evidence-dir must be keyed as artifacts/<exact-full-commit>/<run>"
        )

    # Every existing component from artifacts through the parent must be a real
    # directory. This refuses both ordinary and dangling symlink redirections.
    try:
        artifacts_metadata = artifacts.lstat()
    except OSError as error:
        raise RuntimeError(
            "the repository artifacts directory must already exist"
        ) from error
    if (stat.S_ISLNK(artifacts_metadata.st_mode)
            or not stat.S_ISDIR(artifacts_metadata.st_mode)):
        raise RuntimeError(
            "the repository artifacts path must be a real directory"
        )
    current = artifacts
    for component in relative.parts[:-1]:
        current = current / component
        try:
            metadata = current.lstat()
        except OSError as error:
            raise RuntimeError(
                "the evidence directory parent must already exist: %s" % current
            ) from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeError(
                "evidence path components must be real directories: %s" % current
            )
    if os.path.lexists(candidate):
        raise RuntimeError(
            "the evidence directory must not already exist: %s" % candidate
        )
    os.mkdir(candidate, mode=0o700)
    os.chmod(candidate, 0o700)
    metadata = candidate.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise RuntimeError("evidence target is not a real directory")
    return candidate


def write_json_exclusive(path, document):
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("short write while retaining display evidence")
            remaining = remaining[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_text_exclusive(path, text):
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        payload = text.encode("utf-8", errors="replace")
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("short write while retaining display error evidence")
            remaining = remaining[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sha256_regular_file(path):
    digest = hashlib.sha256()
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError("Hub candidate changed before it could be hashed")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def current_rect(name):
    for screen in dt.screens():
        if screen[0] == name:
            return screen
    return None


def baseline_rect_restored(observed, baseline):
    return observed is not None and observed == baseline


def grab_full(work, tag):
    path = dt._full_grab(work, tag)
    if not path:
        raise RuntimeError("Spectacle did not produce a full-desktop grab")
    return path


def state_deltas(harness, work, tag):
    from PIL import Image

    dark = {"mode": "dark", "themeMode": "midnight", "accent": "#58A6FF",
            "bgStyle": "none", "animatedBg": False, "glass": 0.0,
            "glow": False, "gridCols": 1}
    light = dict(dark, mode="light", themeMode="light")
    pages = [page("Lifecycle", [tile("clock-life", "clock")])]
    harness.set_state(doc(pages, appearance=dark))
    a_path = grab_full(work, tag + "-dark")
    harness.set_state(doc(pages, appearance=light))
    b_path = grab_full(work, tag + "-light")
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    if a.size != b.size:
        raise RuntimeError("desktop grab size changed between probe states: %r -> %r" %
                           (a.size, b.size))
    screens = dt.screens()
    logical_w = max(x + width for _, x, y, width, height in screens)
    logical_h = max(y + height for _, x, y, width, height in screens)
    # On a mixed-DPI Wayland desktop Spectacle captures a compositor framebuffer,
    # not a 1:1 logical-coordinate image. With the Edge at 125%, this host emits
    # 14336x6912 for a 7168x3456 logical canvas (exactly 2x). Cropping with raw
    # KScreen coordinates silently sampled the wrong output and reported a false
    # render failure. Derive both axes from the actual frame and current canvas.
    scale_x = a.width / logical_w
    scale_y = a.height / logical_h
    deltas = {}
    for name, x, y, w, height in screens:
        box = (round(x * scale_x), round(y * scale_y),
               round((x + w) * scale_x), round((y + height) * scale_y))
        aa = a.crop(box).resize((1, 1)).getpixel((0, 0))
        bb = b.crop(box).resize((1, 1)).getpixel((0, 0))
        deltas[name] = sum((p - q) ** 2 for p, q in zip(aa, bb)) ** 0.5
    return deltas


def log_text(harness):
    try:
        with open(os.path.join(harness.work, "hub.log"), errors="replace") as stream:
            return stream.read()
    except OSError:
        return ""


def seed_config(harness):
    harness.write_config(doc([page("Lifecycle", [tile("clock-life", "clock")])],
                             appearance={"mode": "dark", "themeMode": "midnight",
                                         "accent": "#58A6FF", "bgStyle": "none",
                                         "animatedBg": False, "glass": 0.0,
                                         "glow": False, "gridCols": 1,
                                         "orientation": "auto"}))


def recorded_checks(*instances):
    checks = []
    for instance in instances:
        if instance is None:
            continue
        checks.extend({
            "name": name,
            "status": "PASS" if ok else "FAIL",
            "detail": detail,
        } for name, ok, detail in instance.results)
        checks.extend({
            "name": name,
            "status": "NOT TESTED",
            "detail": reason,
        } for name, reason in instance.skips)
    return checks


def all_checks_passed(*instances):
    return (
        bool(instances)
        and all(instance is not None for instance in instances)
        and all(instance.results for instance in instances)
        and all(ok for instance in instances
                for _, ok, _ in instance.results)
        and all(not instance.skips for instance in instances)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--hub",
        required=True,
        help="absolute path to the exact Hub candidate under test",
    )
    parser.add_argument(
        "--evidence-dir",
        required=True,
        help="new absolute artifacts/<full-sha>/<run> directory",
    )
    arguments = parser.parse_args()

    if os.environ.get(GATE) != "1":
        print("!! real display lifecycle is OFF; set %s=1" % GATE)
        return 77
    if os.environ.get("XDG_SESSION_TYPE") != "wayland":
        print("!! this implementation currently requires a Wayland session")
        return 77
    if not subprocess.run(["which", "kscreen-doctor"], capture_output=True).returncode == 0:
        print("!! kscreen-doctor is unavailable")
        return 77

    commit = repository_commit()
    require_clean_repository()
    work = prepare_evidence_directory(arguments.evidence_dir, commit)
    binary = Path(arguments.hub)
    if not binary.is_absolute():
        raise RuntimeError("--hub must be an absolute path")
    try:
        binary_metadata = binary.lstat()
    except OSError as error:
        raise RuntimeError("the exact Hub candidate is unavailable") from error
    if (stat.S_ISLNK(binary_metadata.st_mode)
            or not stat.S_ISREG(binary_metadata.st_mode)
            or not os.access(binary, os.X_OK)):
        raise RuntimeError(
            "the exact Hub candidate must be an executable regular non-symlink file"
        )
    binary = binary.resolve(strict=True)
    harness.HUB = os.fspath(binary)
    assert_binaries_current((os.fspath(binary),))
    binary_sha256 = sha256_regular_file(binary)
    candidate_build = validate_candidate_build(binary)
    if candidate_build["binary_sha256"] != binary_sha256:
        raise RuntimeError(
            "Hub candidate changed between lifecycle build validation and hashing"
        )
    binary_version = candidate_build["binary_version"]
    print("  binary under test: %s (%s)" %
          (binary_version, binary_sha256))
    baseline = doctor_json()
    write_json_exclusive(work / "kscreen-baseline.json", baseline)
    edge = next((o for o in baseline.get("outputs", [])
                 if o.get("enabled") and
                 ("XENEON" in (o.get("name", "") + " " +
                                (o.get("model") or "")).upper()
                  or (o.get("size", {}).get("width"),
                      o.get("size", {}).get("height")) in
                  ((2560, 720), (720, 2560)))), None)
    if not edge:
        print("!! no enabled 2560x720 Xeneon Edge output found")
        return 77
    edge_name = edge["name"]
    baseline_rect = current_rect(edge_name)
    if baseline_rect is None:
        raise RuntimeError(
            "the enabled Edge output has no matching desktop geometry"
        )
    print("  evidence directory:", work, flush=True)

    h = None
    h2 = None
    guard = DisplayRestoreGuard(baseline)
    error_text = ""
    suite_passed = False
    try:
        with guard:
            h = E2E(workdir=os.fspath(work))
            seed_config(h)
            h.check("hub-launch", h.launch_hub(), "private control socket answering")
            h.check("initial-edge-render", state_deltas(h, work, "initial").get(edge_name, 0) > 25,
                    "dark/light state visibly changed the physical Edge")

            h.stop_hub()
            h.check("hub-restart", h.launch_hub(), "clean restart with the same isolated config")
            h.check("restart-edge-render", state_deltas(h, work, "restart").get(edge_name, 0) > 25,
                    "restarted Hub visibly changed the physical Edge")

            apply_doctor("output.%s.rotation.none" % edge_name,
                         "output.%s.scale.1" % edge_name)
            rect = current_rect(edge_name)
            h.check("native-landscape-geometry", rect is not None and rect[3:] == (2560, 720), rect)
            h.check("native-landscape-render", state_deltas(h, work, "landscape").get(edge_name, 0) > 25,
                    "Hub remained fullscreen and reactive after rotation")

            apply_doctor("output.%s.scale.1.25" % edge_name)
            rect = current_rect(edge_name)
            h.check("fractional-scale-geometry", rect is not None and rect[3:] == (2048, 576), rect)
            h.check("fractional-scale-render", state_deltas(h, work, "scale-125").get(edge_name, 0) > 25,
                    "Hub remained fullscreen and reactive at 125%")

            priorities = []
            for out in baseline["outputs"]:
                priority = 1 if out["name"] == edge_name else out["priority"] + 1
                priorities.append("output.%s.priority.%d" % (out["name"], priority))
            apply_doctor(*priorities)
            promoted = output_by_name(doctor_json(), edge_name)
            h.check("edge-primary-role", promoted is not None and promoted.get("priority") == 1,
                    "priority=%r" % (promoted.get("priority") if promoted else None,))
            h.check("primary-role-render", state_deltas(h, work, "primary").get(edge_name, 0) > 25,
                    "Hub stayed on the Edge when it became primary")

            apply_doctor(*restore_settings(baseline))
            restored_rect = current_rect(edge_name)
            h.check("baseline-geometry-restored-before-hotplug",
                    baseline_rect_restored(restored_rect, baseline_rect),
                    "expected=%r observed=%r" % (baseline_rect, restored_rect))

            apply_doctor("output.%s.disable" % edge_name)
            h.check("target-disable-keeps-hub-alive",
                    h.proc is not None and h.proc.poll() is None and h.ping(),
                    "process and private IPC survived target removal")
            removed_log = log_text(h)
            h.check("target-disable-is-detected",
                    "target display removed; window hidden" in removed_log,
                    "production screenRemoved handler hid before compositor fallback")

            apply_doctor(*restore_settings(baseline))
            returned_log = log_text(h)
            h.check("target-reconnect-is-detected",
                    "target display returned" in returned_log,
                    "production screenAdded handler matched and migrated back")
            h.check("reconnect-edge-render",
                    state_deltas(h, work, "reconnect").get(edge_name, 0) > 25,
                    "reconnected Hub visibly changed the physical Edge")

            h.cleanup()
            h2 = E2E(workdir=os.path.join(work, "missing-target"))
            seed_config(h2)
            config_path = os.path.join(h2.cfg, "xeneon-edge-hub", "config.toml")
            with open(config_path, "r", encoding="utf-8") as stream:
                body = stream.read()
            body = body.replace(
                "[display]\n",
                "[display]\ntarget_connector = \"NO-SUCH-DP\"\n"
                "target_model = \"NO SUCH DISPLAY\"\n",
                1,
            )
            with open(config_path, "w", encoding="utf-8") as stream:
                stream.write(body)
            h2.check("missing-target-launch", h2.launch_hub(),
                     "hidden Hub still exposes its private control socket")
            missing_log = log_text(h2)
            h2.check("missing-target-stays-hidden",
                     "configured target display is not attached; keeping window" in missing_log,
                     "no primary-screen fallback")
            missing_deltas = state_deltas(h2, h2.work, "missing")
            h2.check("missing-target-no-output-hijack",
                     all(delta < 25 for delta in missing_deltas.values()), missing_deltas)

            passed, total = h.summary()
            passed2, total2 = h2.summary()
            suite_passed = (
                passed == total
                and passed2 == total2
                and all_checks_passed(h, h2)
            )
    except BaseException:  # retain the exact failure without skipping restore
        error_text = traceback.format_exc()
        print(error_text, file=sys.stderr, flush=True)
    finally:
        if h is not None:
            h.cleanup()
        if h2 is not None:
            h2.cleanup()

    if guard.final_state is not None:
        write_json_exclusive(work / "kscreen-final.json", guard.final_state)
    if error_text:
        write_text_exclusive(work / "error.log", error_text)
    checks = recorded_checks(h, h2)
    status = "PASS" if suite_passed and guard.verified and not error_text else (
        "FAIL" if any(item["status"] == "FAIL" for item in checks) else "ERROR"
    )
    write_json_exclusive(work / "RESULT.json", {
        "schema": "skyphoenix-edgehub-display-lifecycle/v1",
        "source_commit": commit,
        "status": status,
        "restore_verified": guard.verified,
        "edge_output": edge_name,
        "hub": {
            "path": os.fspath(binary),
            "sha256": binary_sha256,
            "version": binary_version,
            "candidate_build": candidate_build,
        },
        "checks": checks,
        "error": bool(error_text),
    })
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
