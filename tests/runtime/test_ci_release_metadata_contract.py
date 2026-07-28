#!/usr/bin/env python3
"""Focused lifecycle tests for the stage-aware release metadata contract."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_PATH = PROJECT_ROOT / "scripts" / "check_ci_release_metadata_contract.py"
SPEC = importlib.util.spec_from_file_location(
    "check_ci_release_metadata_contract", CONTRACT_PATH
)
assert SPEC is not None and SPEC.loader is not None
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


class ReleaseMetadataContractTests(unittest.TestCase):
    public_version = "v1.0.0-beta.1"
    target_version = "v1.0.0"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, value: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    def seed(self, stage: str) -> None:
        target = self.target_version
        target_plain = target.removeprefix("v")
        public = self.public_version if stage != "published" else target
        public_plain = public.removeprefix("v")

        target_marker = ""
        if stage != "published":
            target_marker = (
                f"**Release target:** `{target}`. This checkout is unreleased "
                "and is not published or certified.\n"
            )
        self.write(
            "README.md",
            f"[![Release: {public}](badge.svg)]"
            f"(https://github.com/skyphoenix-it/"
            f"skyphoenix-edgehub-linux/releases/tag/{public})\n"
            "The latest published release is\n"
            f"**[{public}](https://github.com/skyphoenix-it/"
            f"skyphoenix-edgehub-linux/releases/tag/{public})**.\n"
            f"{target_marker}",
        )

        roadmap_target = (
            f"**Release target:** `{target}`\n" if stage != "published" else ""
        )
        roadmap_status = (
            "publication is not certified\n" if stage != "published" else ""
        )
        self.write(
            "ROADMAP.md",
            f"**Public baseline:** `{public}`\n"
            f"{roadmap_target}"
            f"{roadmap_status}",
        )

        completed = ""
        if stage != "development":
            completed = f"\n## [{target_plain}] - 2026-07-27\n"
        self.write("CHANGELOG.md", f"## [Unreleased]\n{completed}")

        if stage == "published":
            target_support = "Yes"
            security_rows = f"| {target_plain} | {target_support} |\n"
        else:
            security_rows = (
                f"| {target_plain} | No (unreleased) |\n"
                f"| {public_plain} | Yes |\n"
            )
        self.write(
            "SECURITY.md",
            "| Version | Supported |\n"
            "|---------|-----------|\n"
            f"{security_rows}",
        )

        self.write(
            "RELEASE_NOTES.md",
            f"# EdgeHub {target}\n\n"
            f"Release version: `{target}`\n"
            "Release stage: stable\n",
        )

        if stage == "development":
            releases = (
                f'<release version="{CONTRACT.appstream_version(public)}" '
                'date="2026-07-21" '
                'type="development"/>\n'
            )
        else:
            releases = (
                f'<release version="{target_plain}" date="2026-07-27" '
                'type="stable"/>\n'
            )
            if stage == "candidate":
                releases += (
                    f'<release version="{CONTRACT.appstream_version(public)}" '
                    'date="2026-07-21" '
                    'type="development"/>\n'
                )
        document = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<component type="desktop-application">\n'
            f"<releases>{releases}</releases>\n"
            "</component>\n"
        )
        for path in CONTRACT.APPSTREAM_FILES:
            self.write(path, document)

    def validate(self, stage: str, target: str | None = None) -> tuple[str, str]:
        return CONTRACT.validate_release_metadata(
            root=self.root,
            stage=stage,
            target_version=target,
        )

    def test_every_dtolnay_step_requires_the_exact_toolchain(self) -> None:
        self.write(
            ".github/workflows/ci.yml",
            "jobs:\n"
            "  first:\n"
            "    steps:\n"
            "      - uses: dtolnay/rust-toolchain@0123456789abcdef\n"
            "        with:\n"
            "          toolchain: '1.86.0'\n"
            "      - run: cargo test\n"
            "  second:\n"
            "    steps:\n"
            "      - uses: dtolnay/rust-toolchain@fedcba9876543210\n"
            "        with:\n"
            "          toolchain: '1.86.0'\n"
            "  coverage:\n"
            "    steps:\n"
            "      - uses: dtolnay/rust-toolchain@abcdef0123456789\n"
            "        with:\n"
            "          toolchain: '1.87.0'\n",
        )
        self.write(
            ".github/workflows/supply-chain.yml",
            "jobs:\n"
            "  deny:\n"
            "    steps:\n"
            "      - uses: dtolnay/rust-toolchain@abcdef0123456789\n"
            "        with:\n"
            "          toolchain: '1.88.0'\n",
        )
        self.assertEqual(
            CONTRACT.validate_dtolnay_toolchains(root=self.root), 4
        )
        workflow = self.root / ".github/workflows/ci.yml"
        workflow.write_text(
            workflow.read_text(encoding="utf-8").replace(
                "        with:\n"
                "          toolchain: '1.86.0'\n",
                "",
                1,
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssertionError, "ci.yml:4"):
            CONTRACT.validate_dtolnay_toolchains(root=self.root)

    def test_declaration_allows_only_reviewed_nonpublished_stages(self) -> None:
        self.write(
            CONTRACT.DECLARATION_PATH,
            'schema = 1\nstage = "candidate"\ntarget_version = "v1.0.0"\n',
        )
        self.assertEqual(
            CONTRACT.read_release_declaration(root=self.root),
            ("candidate", "v1.0.0"),
        )
        self.write(
            CONTRACT.DECLARATION_PATH,
            'schema = 1\nstage = "published"\ntarget_version = "v1.0.0"\n',
        )
        with self.assertRaisesRegex(AssertionError, "requires an external"):
            CONTRACT.read_release_declaration(root=self.root)

    def test_development_accepts_unreleased_target_without_advertising_it(self) -> None:
        self.seed("development")
        self.assertEqual(
            self.validate("development"),
            (self.target_version, self.public_version),
        )

    def test_development_rejects_target_in_either_appstream_file(self) -> None:
        self.seed("development")
        manager = self.root / CONTRACT.APPSTREAM_FILES[1]
        manager.write_text(
            manager.read_text(encoding="utf-8").replace(
                "<releases>",
                '<releases><release version="1.0.0" date="2026-07-27" '
                'type="stable"/>',
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssertionError, "must list published"):
            self.validate("development")

    def test_development_target_must_be_newer_than_public(self) -> None:
        self.target_version = "v1.0.0-alpha.1"
        self.seed("development")
        with self.assertRaisesRegex(AssertionError, "must be newer"):
            self.validate("development")

    def test_candidate_requires_external_exact_target(self) -> None:
        self.seed("candidate")
        with self.assertRaisesRegex(AssertionError, "--target-version"):
            self.validate("candidate")
        with self.assertRaisesRegex(AssertionError, "differs"):
            self.validate("candidate", "v1.0.1")

    def test_candidate_accepts_coordinated_prepublication_metadata(self) -> None:
        self.seed("candidate")
        self.assertEqual(
            self.validate("candidate", self.target_version),
            (self.target_version, self.public_version),
        )

    def test_candidate_rejects_a_premature_release_badge(self) -> None:
        self.seed("candidate")
        readme = self.root / "README.md"
        readme.write_text(
            readme.read_text(encoding="utf-8").replace(
                f"Release: {self.public_version}",
                f"Release: {self.target_version}",
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssertionError, "release badge"):
            self.validate("candidate", self.target_version)

    def test_candidate_rejects_target_marked_supported(self) -> None:
        self.seed("candidate")
        security = self.root / "SECURITY.md"
        security.write_text(
            security.read_text(encoding="utf-8").replace(
                "| 1.0.0 | No (unreleased) |", "| 1.0.0 | Yes |"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssertionError, "No \\(unreleased\\)"):
            self.validate("candidate", self.target_version)

    def test_candidate_rejects_hub_manager_appstream_drift(self) -> None:
        self.seed("candidate")
        manager = self.root / CONTRACT.APPSTREAM_FILES[1]
        manager.write_text(
            manager.read_text(encoding="utf-8").replace(
                'date="2026-07-27"', 'date="2026-07-28"', 1
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssertionError, "dates must match"):
            self.validate("candidate", self.target_version)

    def test_published_requires_latest_and_supported_target(self) -> None:
        self.seed("published")
        self.assertEqual(
            self.validate("published", self.target_version),
            (self.target_version, self.target_version),
        )

    def test_published_rejects_an_unreleased_readme_marker(self) -> None:
        self.seed("published")
        readme = self.root / "README.md"
        readme.write_text(
            readme.read_text(encoding="utf-8")
            + f"**Release target:** `{self.target_version}`. "
            "This checkout is unreleased and is not published or certified.\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssertionError, "remove the unreleased"):
            self.validate("published", self.target_version)


if __name__ == "__main__":
    unittest.main()
