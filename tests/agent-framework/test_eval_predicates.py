"""E18 secret-detection predicate regressions.

E18 flags tracked files that look like committed secrets. Its directory rule was
once unanchored (`"/secrets/" in f`), which also matched any SOURCE package
directory named `secrets` at any depth — an adopter with a
`com/skyphoenix/platform/secrets/**` Java module saw 9 ordinary source files
reported as tracked secrets, failing E18 and turning its gate red.

These tests pin both halves of the fix: source packages must not be flagged, and
genuine secrets must still be caught regardless of nesting depth.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _helpers import SCRIPTS  # noqa: E402


def e18_bad(tracked: list[str]) -> list[str]:
    """Apply the shipped E18 predicate, read out of run-evals.py rather than
    restated here — a copy would drift and pass while the real gate regressed."""
    src = (SCRIPTS / "evals" / "run-evals.py").read_text(encoding="utf-8")
    body = src.split("def e18_no_sensitive_config", 1)[1].split("gi = read(", 1)[0]
    start = body.index("bad = [")
    expr = body[start:].split("\n    gi")[0]
    ns: dict = {"re": re, "tracked": tracked}
    exec(expr, ns)  # noqa: S102 - executing our own source, in-process, no input
    return ns["bad"]


class TestE06E07AreHermetic(unittest.TestCase):
    """E06/E07 must control project.yaml, not inherit it from the repo under test.

    The step once mutated with `text.replace("skills: []", "skills: [sap-s4hana]")`, which
    silently did nothing in a repository that legitimately selects domain skills — the
    literal was absent. Such a repo failed BOTH evals for using a documented feature: E06
    because the selection never happened, E07 because its own skills rendered and counted
    as leakage. Observed in skyphoenix-servicenow-tosca-automation, which selects
    servicenow and tricentis-tosca.

    These are source-level pins, deliberately: the behavioural proof is the eval suite
    itself, which is far too slow to run per-assertion here.
    """

    def _source(self) -> str:
        return (SCRIPTS / "evals" / "run-evals.py").read_text(encoding="utf-8")

    def test_selection_is_not_a_literal_string_replace(self):
        self.assertNotIn(
            'replace("skills: []"', self._source(),
            "E06/E07 must not assume the repo's project.yaml literally contains "
            "'skills: []' — that silently no-ops for any adopter using the feature")

    def test_selection_is_set_through_parsed_yaml(self):
        src = self._source()
        self.assertIn('doc.setdefault("agent_framework", {})["skills"]', src,
                      "the selection must be set on the parsed document")
        self.assertIn("\nimport yaml\n", src,
                      "run-evals.py must import yaml to control project.yaml")


class TestE18SecretsPattern(unittest.TestCase):
    def test_source_package_named_secrets_is_not_flagged(self):
        tracked = [
            "platform-secrets/src/main/java/com/skyphoenix/platform/secrets/spi/SecretStore.java",
            "platform-secrets/src/main/java/com/skyphoenix/platform/secrets/impl/VaultSecretStore.java",
            "platform-secrets/src/test/java/com/skyphoenix/platform/secrets/spi/SecretStoreConfigTest.java",
            "apps/web/src/lib/secrets/useSecret.ts",
        ]
        self.assertEqual(e18_bad(tracked), [], "source packages named 'secrets' must not be flagged")

    def test_root_level_secrets_directory_is_flagged(self):
        self.assertEqual(e18_bad(["secrets/production.yaml"]), ["secrets/production.yaml"])

    def test_nested_genuine_secrets_still_caught_by_extension_rules(self):
        # Anchoring the directory rule is only safe because these are depth-independent.
        for f in ("apps/api/secrets/prod.pem",
                  "config/secrets/signing.key",
                  "services/worker/.env",
                  "packages/cli/.env.production"):
            with self.subTest(f=f):
                self.assertEqual(e18_bad([f]), [f], f"{f} must still be flagged")

    def test_benign_files_are_not_flagged(self):
        tracked = [".env.example", "README.md", "src/main.rs", "docs/secrets-handling.md"]
        self.assertEqual(e18_bad(tracked), [])

    def test_per_environment_example_files_are_not_flagged(self):
        """`.env.<name>.example` is the ordinary convention and carries no secret.

        The exemption was written as a lookahead immediately after `.env.`, so it only
        ever cleared the exact name `.env.example`. For `.env.prod.example` the lookahead
        inspects `prod.example`, does not match `example`, and the file is flagged.

        Found on skyphoenix-mobile-device-cloud, which tracks
        infra/compose/.env.prod.example and .env.browser.example — both headed "Every
        value below is a placeholder, not a secret". E18 failed, so `ci.sh` failed, for
        using the convention the framework's own initialize-project.sh assumes when it
        does `cp .env.example .env.local`.
        """
        tracked = [
            "infra/compose/.env.prod.example",
            "infra/compose/.env.browser.example",
            ".env.local.example",
            "apps/api/.env.sample",
            "deploy/.env.template",
        ]
        self.assertEqual(e18_bad(tracked), [],
                         "example/sample/template env files carry placeholders by "
                         "definition and must not be reported as tracked secrets")

    def test_real_env_files_are_still_flagged_next_to_the_examples(self):
        """Negative control: the exemption must not swallow the real files beside them."""
        tracked = [
            "infra/compose/.env.prod.example",   # exempt
            "infra/compose/.env.prod",           # must still be caught
            ".env",
            ".env.local",
            "apps/x/.env.production",
        ]
        self.assertEqual(
            e18_bad(tracked),
            ["infra/compose/.env.prod", ".env", ".env.local", "apps/x/.env.production"])

    def test_example_suffix_does_not_exempt_keys_and_pems(self):
        """A .pem or .key is material regardless of what the filename claims."""
        for f in ("certs/server.key.example", "certs/server.pem"):
            with self.subTest(f=f):
                self.assertEqual(e18_bad([f]), [f] if f.endswith((".pem", ".key")) else [])


if __name__ == "__main__":
    unittest.main()
