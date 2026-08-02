#!/usr/bin/env python3
"""Fast source-of-truth checks for CI, toolchain, packaging, and release docs.

The reviewed repository declaration lets ordinary branch and pull-request
checks distinguish development from candidate preparation without accepting a
published state. A release driver must still supply one exact target version
before the signed candidate suite can accept prepared changelog and AppStream
metadata.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tomllib
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION_PATTERN = (
    r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-(?:alpha|beta|rc)\.(?:0|[1-9][0-9]*))?"
)
VERSION_RE = re.compile(rf"^{VERSION_PATTERN}$")
APPSTREAM_FILES = (
    "assets/metainfo/com.skyphoenix_it.XeneonEdgeHub.metainfo.xml",
    "assets/metainfo/com.skyphoenix_it.XeneonEdgeManager.metainfo.xml",
)
DECLARATION_PATH = "release-metadata.toml"


def text(path: str, *, root: pathlib.Path = ROOT) -> str:
    return (root / path).read_text(encoding="utf-8")


def require(
    path: str,
    needle: str,
    *,
    count: int | None = None,
    root: pathlib.Path = ROOT,
) -> None:
    value = text(path, root=root).count(needle)
    if value == 0 or (count is not None and value != count):
        suffix = f" exactly {count} times" if count is not None else ""
        raise AssertionError(f"{path} must contain {needle!r}{suffix}")


def release_stage(version: str) -> str:
    return "prerelease" if "-" in version else "stable"


def appstream_version(version: str) -> str:
    """Translate release SemVer into AppStream's sortable version syntax."""
    validate_version(version, "release version")
    match = re.fullmatch(
        r"v([0-9]+)\.([0-9]+)\.([0-9]+)"
        r"(?:-(alpha|beta|rc)\.([0-9]+))?",
        version,
    )
    assert match is not None
    base = ".".join(match.group(index) for index in (1, 2, 3))
    channel = match.group(4)
    return base if channel is None else f"{base}~{channel}.{match.group(5)}"


def validate_version(version: str, label: str) -> None:
    if not VERSION_RE.fullmatch(version):
        raise AssertionError(
            f"{label} must be vMAJOR.MINOR.PATCH or a numbered alpha, beta, "
            f"or rc version; got {version!r}"
        )


def version_key(version: str) -> tuple[int, int, int, int, int]:
    validate_version(version, "version")
    match = re.fullmatch(
        r"v([0-9]+)\.([0-9]+)\.([0-9]+)"
        r"(?:-(alpha|beta|rc)\.([0-9]+))?",
        version,
    )
    assert match is not None
    prerelease_rank = {"alpha": 0, "beta": 1, "rc": 2, None: 3}
    return (
        int(match.group(1)),
        int(match.group(2)),
        int(match.group(3)),
        prerelease_rank[match.group(4)],
        int(match.group(5) or 0),
    )


def read_release_declaration(
    *, root: pathlib.Path
) -> tuple[str, str]:
    declaration = tomllib.loads(text(DECLARATION_PATH, root=root))
    if set(declaration) != {"schema", "stage", "target_version"}:
        raise AssertionError(
            f"{DECLARATION_PATH} keys differ from the exact contract"
        )
    if declaration["schema"] != 1:
        raise AssertionError(f"{DECLARATION_PATH} schema must be 1")
    stage = declaration["stage"]
    if stage not in {"development", "candidate"}:
        raise AssertionError(
            f"{DECLARATION_PATH} stage must be development or candidate; "
            "published status requires an external post-publication check"
        )
    target = declaration["target_version"]
    if not isinstance(target, str):
        raise AssertionError(
            f"{DECLARATION_PATH} target_version must be a string"
        )
    validate_version(target, f"{DECLARATION_PATH} target_version")
    return stage, target


def read_public_version(readme: str) -> str:
    match = re.search(
        rf"The latest published release is\s+"
        rf"\*\*\[({VERSION_PATTERN})\]"
        rf"\(https://github\.com/skyphoenix-it/skyphoenix-edgehub-linux/"
        rf"releases/tag/({VERSION_PATTERN})\)\*\*\.",
        readme,
    )
    if not match or match.group(1) != match.group(2):
        raise AssertionError(
            "README.md must name and link one exact latest published release"
        )
    return match.group(1)


def read_badge_version(readme: str) -> str:
    matches = re.findall(
        rf"\[!\[Release: ({VERSION_PATTERN})\]\([^)]*\)\]"
        rf"\(https://github\.com/skyphoenix-it/skyphoenix-edgehub-linux/"
        rf"releases/tag/({VERSION_PATTERN})\)",
        readme,
    )
    if len(matches) != 1 or matches[0][0] != matches[0][1]:
        raise AssertionError(
            "README.md must contain one exact release badge linked to its tag"
        )
    return matches[0][0]


def read_target_version(readme: str) -> str | None:
    matches = re.findall(
        rf"(?m)^\*\*Release target:\*\* `({VERSION_PATTERN})`\. "
        rf"This checkout is unreleased and is not published\s+or certified\.$",
        readme,
    )
    if not matches:
        return None
    if len(matches) != 1:
        raise AssertionError("README.md must contain at most one release target")
    return matches[0]


def read_security_support(security: str) -> dict[str, str]:
    support: dict[str, str] = {}
    for version, status in re.findall(
        r"(?m)^\|\s*([^|\n]+?)\s*\|\s*([^|\n]+?)\s*\|$", security
    ):
        if version in {"Version", "---------"}:
            continue
        if version in support:
            raise AssertionError(
                f"SECURITY.md repeats supported-version row {version!r}"
            )
        support[version] = status
    return support


def appstream_releases(
    path: str, *, root: pathlib.Path
) -> list[ET.Element]:
    releases = ET.fromstring(text(path, root=root)).find("releases")
    if releases is None:
        raise AssertionError(f"{path} must contain a releases element")
    result = list(releases)
    if not result:
        raise AssertionError(f"{path} must contain at least one release")
    for item in result:
        version = item.attrib.get("version", "")
        semantic_version = f"v{version.replace('~', '-', 1)}"
        validate_version(
            semantic_version, f"{path} AppStream release version")
        if version != appstream_version(semantic_version):
            raise AssertionError(
                f"{path} AppStream release version must use sortable "
                f"prerelease syntax; got {version!r}"
            )
    return result


def validate_dtolnay_toolchains(*, root: pathlib.Path) -> int:
    action = re.compile(
        r"^(?P<indent>[ ]*)-[ ]+uses:[ ]+dtolnay/rust-toolchain@"
        r"[^ #]+(?:[ ]+#.*)?$"
    )
    count = 0
    exceptions = {
        ("ci.yml", "coverage"): "1.87.0",
        ("supply-chain.yml", "deny"): "1.88.0",
    }
    for path in sorted((root / ".github" / "workflows").glob("*.yml")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            match = action.fullmatch(line)
            if not match:
                continue
            count += 1
            indent = len(match.group("indent"))
            end = len(lines)
            for following in range(index + 1, len(lines)):
                if re.match(rf"^[ ]{{{indent}}}-[ ]+", lines[following]):
                    end = following
                    break
            step = lines[index + 1 : end]
            job = ""
            for preceding in range(index - 1, -1, -1):
                job_match = re.fullmatch(
                    r"  ([A-Za-z0-9_-]+):", lines[preceding]
                )
                if job_match:
                    job = job_match.group(1)
                    break
            if not job:
                relative = path.relative_to(root)
                raise AssertionError(
                    f"{relative}:{index + 1} dtolnay step is not inside a job"
                )
            required_toolchain = exceptions.get(
                (path.name, job), "1.86.0"
            )
            numeric_pins = [
                value
                for value in step
                if re.fullmatch(
                    r"[ ]+toolchain: '[0-9]+\.[0-9]+\.[0-9]+'", value
                )
            ]
            expected = (
                " " * (indent + 4)
                + f"toolchain: '{required_toolchain}'"
            )
            if step.count(expected) != 1:
                relative = path.relative_to(root)
                raise AssertionError(
                    f"{relative}:{index + 1} must set exactly one "
                    f"toolchain: '{required_toolchain}' in its dtolnay step"
                )
            if len(numeric_pins) != 1:
                relative = path.relative_to(root)
                raise AssertionError(
                    f"{relative}:{index + 1} dtolnay step must contain "
                    "exactly one numeric toolchain pin"
                )
    if count == 0:
        raise AssertionError("no dtolnay/rust-toolchain workflow steps were found")
    return count


def validate_release_metadata(
    *,
    root: pathlib.Path,
    stage: str,
    target_version: str | None,
) -> tuple[str, str]:
    readme = text("README.md", root=root)
    roadmap = text("ROADMAP.md", root=root)
    changelog = text("CHANGELOG.md", root=root)
    security = text("SECURITY.md", root=root)
    notes = text("RELEASE_NOTES.md", root=root)

    public_version = read_public_version(readme)
    validate_version(public_version, "latest published release")
    badge_version = read_badge_version(readme)
    if badge_version != public_version:
        raise AssertionError(
            "README.md release badge differs from latest published release"
        )
    documented_target = read_target_version(readme)

    if stage == "candidate" and target_version is None:
        raise AssertionError(
            "--target-version is required for candidate metadata validation"
        )
    if stage == "published":
        if target_version is None:
            raise AssertionError(
                "--target-version is required for published metadata validation"
            )
        validate_version(target_version, "target version")
        if documented_target is not None:
            raise AssertionError(
                "README.md must remove the unreleased target marker after publication"
            )
        if public_version != target_version:
            raise AssertionError(
                "README.md latest published release differs from --target-version"
            )
    else:
        if documented_target is None:
            raise AssertionError(
                "README.md must state the unreleased release target exactly"
            )
        if target_version is not None:
            validate_version(target_version, "target version")
            if target_version != documented_target:
                raise AssertionError(
                    "README.md release target differs from --target-version"
                )
        target_version = documented_target
        if public_version == target_version:
            raise AssertionError(
                "an unreleased target cannot also be the latest published release"
            )
        if version_key(target_version) <= version_key(public_version):
            raise AssertionError(
                "the unreleased target must be newer than the latest "
                "published release"
            )

    assert target_version is not None
    target_plain = target_version.removeprefix("v")
    public_plain = public_version.removeprefix("v")
    target_appstream = appstream_version(target_version)
    public_appstream = appstream_version(public_version)

    if stage == "published":
        require(
            "ROADMAP.md",
            f"**Public baseline:** `{target_version}`",
            count=1,
            root=root,
        )
    else:
        require(
            "ROADMAP.md",
            f"**Public baseline:** `{public_version}`",
            count=1,
            root=root,
        )
        require(
            "ROADMAP.md",
            f"**Release target:** `{target_version}`",
            count=1,
            root=root,
        )
        require(
            "ROADMAP.md",
            "publication is not certified",
            root=root,
        )

    expected_heading = f"# EdgeHub {target_version}"
    if notes.splitlines()[:1] != [expected_heading]:
        raise AssertionError(
            f"RELEASE_NOTES.md first heading must be exactly {expected_heading!r}"
        )
    require(
        "RELEASE_NOTES.md",
        f"Release version: `{target_version}`",
        count=1,
        root=root,
    )
    require(
        "RELEASE_NOTES.md",
        f"Release stage: {release_stage(target_version)}",
        count=1,
        root=root,
    )

    require("CHANGELOG.md", "## [Unreleased]", count=1, root=root)
    target_heading = re.compile(
        rf"(?m)^## \[{re.escape(target_plain)}\] - "
        r"(?:[0-9]{4}-[0-9]{2}-[0-9]{2})$"
    )
    completed_target_headings = target_heading.findall(changelog)
    if stage == "development":
        if completed_target_headings:
            raise AssertionError(
                f"development metadata must keep {target_version} under Unreleased"
            )
    elif len(completed_target_headings) != 1:
        raise AssertionError(
            f"{stage} metadata requires one dated CHANGELOG.md heading for "
            f"{target_version}"
        )

    support = read_security_support(security)
    if stage == "published":
        if support.get(target_plain) != "Yes":
            raise AssertionError(
                f"SECURITY.md must support published version {target_plain}"
            )
    else:
        if support.get(public_plain) != "Yes":
            raise AssertionError(
                f"SECURITY.md must support latest published version {public_plain}"
            )
        if support.get(target_plain) != "No (unreleased)":
            raise AssertionError(
                f"SECURITY.md must mark target {target_plain} as No (unreleased)"
            )

    target_dates: set[str] = set()
    for path in APPSTREAM_FILES:
        releases = appstream_releases(path, root=root)
        versions = [item.attrib["version"] for item in releases]
        if stage == "development":
            if versions[0] != public_appstream:
                raise AssertionError(
                    f"{path} must list published {public_appstream} first in "
                    "development"
                )
            if target_appstream in versions:
                raise AssertionError(
                    f"{path} must not advertise unreleased {target_appstream} in "
                    "development"
                )
            continue

        if versions[0] != target_appstream:
            raise AssertionError(
                f"{path} must list exact {stage} target {target_appstream} first"
            )
        if stage == "candidate" and public_appstream not in versions[1:]:
            raise AssertionError(
                f"{path} must retain published predecessor {public_appstream}"
            )
        target = releases[0]
        expected_type = (
            "development" if release_stage(target_version) == "prerelease"
            else "stable"
        )
        if target.attrib.get("type") != expected_type:
            raise AssertionError(
                f"{path} target release type must be {expected_type!r}"
            )
        date = target.attrib.get("date", "")
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
            raise AssertionError(
                f"{path} target release must have an ISO publication date"
            )
        target_dates.add(date)
    if len(target_dates) > 1:
        raise AssertionError(
            "Hub and Manager AppStream target release dates must match"
        )

    return target_version, public_version


def validate_static_contract(*, root: pathlib.Path) -> None:
    distro = ".github/workflows/distro.yml"
    for trigger in (
        "'cmake/**'",
        "'CMakeLists.txt'",
        "'LICENSE*'",
        "'.git_archival.txt'",
        "'.gitattributes'",
    ):
        require(distro, trigger, count=2, root=root)
    for trigger in (
        "'release-metadata.toml'",
        "'.github/workflows/docs.yml'",
        "'scripts/check_doc_links.sh'",
        "'scripts/check_ci_release_metadata_contract.py'",
    ):
        require(".github/workflows/docs.yml", trigger, count=2, root=root)

    supply = text(".github/workflows/supply-chain.yml", root=root)
    if re.search(r"(?m)^[ \t]+paths:", supply):
        raise AssertionError("supply-chain workflow must have no path-filter gap")
    for needle in (
        "'release/1.0.0'",
        "fetch-depth: 0",
        "gitleaks_8.30.1_linux_x64.tar.gz",
        "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb",
        "--config .gitleaks.toml .",
        "cargo install cargo-deny --version 0.20.2 --locked",
        "cargo-deny 0.20.2",
    ):
        require(".github/workflows/supply-chain.yml", needle, root=root)

    for manifest in (
        "core/Cargo.toml",
        "tools/license-tool/Cargo.toml",
        "tools/license-webhook/Cargo.toml",
    ):
        package = tomllib.loads(text(manifest, root=root))["package"]
        if package.get("rust-version") != "1.86":
            raise AssertionError(f"{manifest} must declare rust-version 1.86")
    validate_dtolnay_toolchains(root=root)
    for needle in (
        "pipx install gcovr==8.6",
        "gcovr 8.6",
        "cargo install cargo-llvm-cov --version 0.8.7 --locked",
        "cargo-llvm-cov 0.8.7",
    ):
        require(".github/workflows/ci.yml", needle, root=root)

    ordinary_cargo_files = (
        ".github/workflows/ci.yml",
        ".github/workflows/distro.yml",
        ".github/workflows/supply-chain.yml",
        "packaging/aur/PKGBUILD",
        "packaging/ci/native-upgrade-rollback.sh",
        "scripts/build.sh",
        "scripts/coverage.sh",
        "scripts/mint-license.sh",
        "scripts/run_all_tests.sh",
        "scripts/run_release_tests.sh",
    )
    ordinary = re.compile(r"\bcargo (?:build|test|clippy|run)\b")
    for path in ordinary_cargo_files:
        for number, line in enumerate(
            text(path, root=root).splitlines(), start=1
        ):
            stripped = line.strip()
            if (
                stripped.startswith("#")
                or stripped.startswith('run_suite "')
                or not ordinary.search(line)
            ):
                continue
            if "--locked" not in line:
                raise AssertionError(f"{path}:{number} runs Cargo without --locked")

    require(
        "CMakeLists.txt",
        "find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui Quick Qml DBus "
        "Network Svg QuickControls2)",
        root=root,
    )
    for needle in (
        "libqt6svg6",
        "qt6-qtsvg",
        "qt6-qtwayland",
    ):
        require("CMakeLists.txt", needle, root=root)
    virtual_keyboard_tokens = (
        "QtQuick.VirtualKeyboard",
        "Qt6::VirtualKeyboard",
        "qtvirtualkeyboard",
        "qt6-virtualkeyboard",
        "qt6-qtvirtualkeyboard",
        "virtualkeyboard",
    )
    virtual_keyboard_surfaces = (
        "CMakeLists.txt",
        "ui/qml/main.qml",
        "packaging/aur/PKGBUILD",
        "packaging/local/PKGBUILD",
        "packaging/appimage/build-appimage.sh",
        ".github/workflows/ci.yml",
        ".github/workflows/distro.yml",
        ".github/workflows/native-upgrade-rollback.yml",
        ".github/workflows/supply-chain.yml",
    )
    for path in virtual_keyboard_surfaces:
        contents = text(path, root=root)
        for token in virtual_keyboard_tokens:
            if token.lower() in contents.lower():
                raise AssertionError(
                    f"{path} still contains removed Qt Virtual Keyboard token: {token}"
                )
    require(
        ".github/workflows/distro.yml",
        "container: ubuntu:26.04@sha256:",
        root=root,
    )
    require(
        "docs/installation/ubuntu.md",
        "Ubuntu 26.04 LTS exactly",
        root=root,
    )

    readme = text("README.md", root=root)
    if "pacman -R" in readme:
        raise AssertionError("README must not advise remove-before-upgrade")
    require("README.md", "./scripts/update-local.sh", root=root)
    require(
        "docs/architecture/overview.md",
        "hand-written C ABI",
        root=root,
    )


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate CI/toolchain truth and stage-aware release metadata"
        )
    )
    parser.add_argument(
        "--stage",
        choices=("development", "candidate", "published"),
        help=(
            "metadata lifecycle stage; default reads the reviewed development "
            "or candidate declaration"
        ),
    )
    parser.add_argument(
        "--target-version",
        help=(
            "exact v-prefixed target; mandatory for candidate and published, "
            "optional cross-check in development"
        ),
    )
    return parser.parse_args(arguments)


def main(arguments: list[str]) -> int:
    options = parse_arguments(arguments)
    declared_stage, declared_target = read_release_declaration(root=ROOT)
    stage = options.stage or declared_stage
    target_version = options.target_version or declared_target
    if options.stage in {"development", "candidate"}:
        if options.stage != declared_stage:
            raise AssertionError(
                f"--stage {options.stage} differs from {DECLARATION_PATH} "
                f"stage {declared_stage}"
            )
    if options.target_version and options.target_version != declared_target:
        raise AssertionError(
            f"--target-version differs from {DECLARATION_PATH} target_version"
        )
    if stage in {"candidate", "published"} and not target_version:
        raise AssertionError(
            f"--target-version is required for --stage {stage}"
        )
    validate_static_contract(root=ROOT)
    target, public = validate_release_metadata(
        root=ROOT,
        stage=stage,
        target_version=target_version,
    )
    print(
        "CI/toolchain/release metadata contract: PASS "
        f"(stage={stage}, target={target}, published={public})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (AssertionError, OSError, ET.ParseError, tomllib.TOMLDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
