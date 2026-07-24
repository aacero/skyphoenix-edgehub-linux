#!/usr/bin/env python3
"""Create or compare the committed composed-UI visual baselines.

The compositor suite writes full-frame PNG evidence to gui-evidence/. This tool
selects the finite review set declared in tests/visual/cases.json. Update mode
normalizes those images into tests/visual/baselines/ and records the source
commit plus file hashes. Compare mode fails on missing images, dimensions,
baseline hash drift, or a perceptually material pixel difference.

Baselines are intentionally reviewed artifacts. Never update them as an
automatic consequence of a failed comparison.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageFilter
except ImportError as exc:
    raise SystemExit("Pillow is required: install python-pillow or python3-pil") from exc


REPO = Path(__file__).resolve().parent.parent
DEFAULT_CASES = REPO / "tests" / "visual" / "cases.json"
DEFAULT_BASELINES = REPO / "tests" / "visual" / "baselines"
DEFAULT_CURRENT = REPO / "gui-evidence"


def git_output(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], cwd=REPO, text=True, stderr=subprocess.STDOUT
    ).strip()


def require_clean() -> str:
    dirty = git_output("status", "--porcelain=v1", "--untracked-files=normal")
    if dirty:
        raise RuntimeError(
            "visual evidence requires a clean committed tree; outstanding paths:\n"
            + dirty
        )
    return git_output("rev-parse", "HEAD")


def require_current_evidence(current: Path, commit: str) -> None:
    marker = current / "source-commit.txt"
    dirty_marker = current / "source-dirty.txt"
    if not marker.is_file() or marker.read_text(encoding="utf-8").strip() != commit:
        raise RuntimeError(
            f"{current}: screenshot provenance is missing or does not match {commit[:12]}; "
            "rerun tests/gui/run_gui_tests.sh"
        )
    if not dirty_marker.is_file():
        raise RuntimeError(f"{current}: missing source-dirty.txt provenance marker")
    dirty = dirty_marker.read_text(encoding="utf-8").strip()
    if dirty:
        raise RuntimeError(
            f"{current}: screenshots came from a dirty tree and cannot become audit baselines:\n"
            + dirty
        )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_spec(path: Path) -> dict:
    raw = json.loads(path.read_text(encoding="utf-8"))
    cases = raw.get("cases", [])
    if raw.get("version") != 1 or not cases:
        raise ValueError(f"{path}: expected version 1 with at least one case")
    ids: set[str] = set()
    sources: set[str] = set()
    for case in cases:
        case_id = case.get("id", "")
        source = case.get("source", "")
        kind = case.get("kind", "")
        if not case_id or not source or kind not in {"widget", "preset"}:
            raise ValueError(f"{path}: malformed case {case!r}")
        if case_id in ids:
            raise ValueError(f"{path}: duplicate case id {case_id!r}")
        if source in sources:
            raise ValueError(f"{path}: duplicate source {source!r}")
        crop = case.get("crop")
        if crop is not None and (
            not isinstance(crop, list)
            or len(crop) != 4
            or not all(isinstance(value, int) and value >= 0 for value in crop)
            or crop[2] < 1
            or crop[3] < 1
        ):
            raise ValueError(f"{path}: invalid crop for {case_id!r}: {crop!r}")
        overrides = case.get("thresholds", {})
        if not isinstance(overrides, dict) or any(
            key not in {"channel_tolerance", "max_changed_fraction", "max_rms"}
            for key in overrides
        ):
            raise ValueError(
                f"{path}: invalid threshold override for {case_id!r}: {overrides!r}"
            )
        if overrides and not str(case.get("variance_reason", "")).strip():
            raise ValueError(
                f"{path}: {case_id!r} overrides thresholds without variance_reason"
            )
        ids.add(case_id)
        sources.add(source)
    expected = raw.get("expected", {})
    widget_count = sum(c["kind"] == "widget" for c in cases)
    preset_count = sum(c["kind"] == "preset" for c in cases)
    if widget_count != expected.get("widgets") or preset_count != expected.get("presets"):
        raise ValueError(
            f"{path}: anti-vacuity counts are widgets={widget_count}, "
            f"presets={preset_count}, expected={expected}"
        )
    return raw


def normalized_image(path: Path, crop: list[int] | None = None) -> Image.Image:
    with Image.open(path) as opened:
        image = opened.convert("RGB")
        if crop is not None:
            if len(crop) != 4 or min(crop) < 0:
                raise ValueError(f"{path}: invalid crop rectangle {crop!r}")
            left, top, width, height = crop
            if width < 1 or height < 1 or left + width > image.width or top + height > image.height:
                raise ValueError(
                    f"{path}: crop {crop!r} exceeds image dimensions {image.size}"
                )
            image = image.crop((left, top, left + width, top + height))
        return image


def write_normalized(
    source: Path, target: Path, crop: list[int] | None
) -> tuple[int, int]:
    image = normalized_image(source, crop)
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target, format="PNG", optimize=False, compress_level=9)
    return image.size


def compare_images(
    expected: Image.Image,
    actual: Image.Image,
    channel_tolerance: int,
) -> tuple[float, float, Image.Image]:
    if expected.size != actual.size:
        raise ValueError(f"dimension mismatch {expected.size} != {actual.size}")

    # A small blur removes renderer-specific subpixel antialiasing while keeping
    # geometry, hierarchy, fill, contrast, and spacing differences visible.
    a = expected.filter(ImageFilter.GaussianBlur(radius=1.0))
    b = actual.filter(ImageFilter.GaussianBlur(radius=1.0))
    changed = 0
    squared = 0.0
    pixel_count = a.width * a.height
    left_bytes = a.tobytes()
    right_bytes = b.tobytes()
    for offset in range(0, len(left_bytes), 3):
        delta = tuple(
            abs(left_bytes[offset + channel] - right_bytes[offset + channel])
            for channel in range(3)
        )
        if max(delta) > channel_tolerance:
            changed += 1
        squared += sum(value * value for value in delta) / 3.0
    changed_fraction = changed / pixel_count if pixel_count else 1.0
    rms = math.sqrt(squared / pixel_count) if pixel_count else 255.0
    return changed_fraction, rms, ImageChops.difference(a, b)


def update(spec: dict, current: Path, baselines: Path) -> int:
    commit = require_clean()
    require_current_evidence(current, commit)
    entries = []
    missing = []
    for case in spec["cases"]:
        source = current / case["source"]
        target = baselines / f"{case['id']}.png"
        if not source.is_file():
            missing.append(str(source))
            continue
        crop = case.get("crop")
        width, height = write_normalized(source, target, crop)
        entries.append(
            {
                "id": case["id"],
                "kind": case["kind"],
                "source": case["source"],
                "file": target.name,
                "width": width,
                "height": height,
                "crop": crop,
                "sha256": sha256(target),
            }
        )
    if missing:
        for path in missing:
            print(f"FAIL missing current image: {path}")
        return 1

    manifest = {
        "version": 1,
        "source_commit": commit,
        "case_count": len(entries),
        "entries": entries,
    }
    baselines.mkdir(parents=True, exist_ok=True)
    (baselines / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"UPDATED {len(entries)} reviewed visual baselines from clean commit "
        f"{commit[:12]}"
    )
    return 0


def compare(spec: dict, current: Path, baselines: Path, diffs: Path) -> int:
    commit = require_clean()
    require_current_evidence(current, commit)
    manifest_path = baselines / "manifest.json"
    if not manifest_path.is_file():
        print(f"FAIL missing baseline manifest: {manifest_path}")
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = {entry["id"]: entry for entry in manifest.get("entries", [])}
    if manifest.get("case_count") != len(spec["cases"]) or len(entries) != len(spec["cases"]):
        print("FAIL baseline manifest case count does not match cases.json")
        return 1

    thresholds = spec["thresholds"]
    failures = 0
    for case in spec["cases"]:
        case_thresholds = dict(thresholds)
        case_thresholds.update(case.get("thresholds", {}))
        channel_tolerance = int(case_thresholds["channel_tolerance"])
        max_changed = float(case_thresholds["max_changed_fraction"])
        max_rms = float(case_thresholds["max_rms"])
        entry = entries.get(case["id"])
        baseline = baselines / f"{case['id']}.png"
        current_image = current / case["source"]
        if not entry or not baseline.is_file() or not current_image.is_file():
            print(f"FAIL {case['id']}: missing manifest, baseline, or current image")
            failures += 1
            continue
        if sha256(baseline) != entry.get("sha256"):
            print(f"FAIL {case['id']}: baseline hash differs from manifest")
            failures += 1
            continue
        expected = normalized_image(baseline)
        if entry.get("crop") != case.get("crop"):
            print(f"FAIL {case['id']}: crop rectangle differs from manifest")
            failures += 1
            continue
        actual = normalized_image(current_image, case.get("crop"))
        if expected.size != (entry.get("width"), entry.get("height")):
            print(f"FAIL {case['id']}: baseline dimensions differ from manifest")
            failures += 1
            continue
        try:
            changed, rms, diff = compare_images(expected, actual, channel_tolerance)
        except ValueError as exc:
            print(f"FAIL {case['id']}: {exc}")
            failures += 1
            continue
        if changed > max_changed or rms > max_rms:
            diffs.mkdir(parents=True, exist_ok=True)
            diff.save(diffs / f"{case['id']}.png", format="PNG")
            print(
                f"FAIL {case['id']}: changed={changed:.4%} (max {max_changed:.2%}), "
                f"rms={rms:.3f} (max {max_rms:.3f})"
            )
            failures += 1
        else:
            print(f"PASS {case['id']}: changed={changed:.4%}, rms={rms:.3f}")

    print(
        f"VISUAL BASELINES: commit={commit[:12]} cases={len(spec['cases'])} "
        f"failed={failures}"
    )
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("compare", "update"))
    parser.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    parser.add_argument("--current", type=Path, default=DEFAULT_CURRENT)
    parser.add_argument("--baselines", type=Path, default=DEFAULT_BASELINES)
    parser.add_argument(
        "--diffs",
        type=Path,
        default=REPO / "artifacts" / "visual-baseline-diffs",
    )
    args = parser.parse_args()
    try:
        spec = load_spec(args.cases)
        if args.mode == "update":
            return update(spec, args.current, args.baselines)
        return compare(spec, args.current, args.baselines, args.diffs)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL {exc}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
