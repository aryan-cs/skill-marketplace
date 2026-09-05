#!/usr/bin/env python3
"""Privacy and packaging checks for the public uiuc-icrn skill."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


SKILL = Path(__file__).resolve().parents[1]
REPO = SKILL.parents[3]


class PublicPackageTests(unittest.TestCase):
    def test_skill_metadata_and_release_are_wired(self) -> None:
        skill_text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        self.assertRegex(skill_text, r"(?m)^name: uiuc-icrn$")
        self.assertIn("configuration.md", skill_text)

        manifest = json.loads(
            (REPO / "plugins/personal/.claude-plugin/plugin.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(manifest["version"], "0.13.0")
        self.assertIn(
            "uiuc-icrn",
            (REPO / "README.md").read_text(encoding="utf-8"),
        )

    def test_example_has_exact_placeholder_schema(self) -> None:
        example = json.loads((SKILL / "config.example.json").read_text(encoding="utf-8"))
        self.assertEqual(
            set(example),
            {
                "schema_version",
                "origin",
                "identity",
                "browser",
                "workspace",
                "target",
                "credentials",
                "allowed_auth_domains",
            },
        )
        self.assertEqual(example["schema_version"], 1)
        self.assertEqual(
            set(example["identity"]),
            {"jupyter_username", "microsoft_account", "identity_provider_label"},
        )
        self.assertEqual(
            set(example["browser"]),
            {"profile_directory", "user_data_directory", "executable"},
        )
        self.assertEqual(set(example["workspace"]), {"remote_root"})
        self.assertEqual(
            set(example["target"]),
            {
                "workbench_service",
                "hub_server_key",
                "profile",
                "image",
                "resource",
                "environment_label",
                "resource_label",
                "remote_python",
            },
        )
        self.assertEqual(set(example["credentials"]), {"jupyter_token_file"})
        self.assertEqual(
            set(example["allowed_auth_domains"]),
            {"identity_provider", "institution", "microsoft", "mfa"},
        )

        def assert_placeholder(value: object) -> None:
            if isinstance(value, dict):
                for nested in value.values():
                    assert_placeholder(nested)
            elif isinstance(value, list):
                for nested in value:
                    assert_placeholder(nested)
            elif isinstance(value, str):
                self.assertTrue(
                    value == "" or re.fullmatch(r"<[^<>]+>", value),
                    f"public example value is not a placeholder: {value!r}",
                )

        assert_placeholder({key: value for key, value in example.items() if key != "schema_version"})

    def test_public_skill_contains_no_deployment_literals_or_secrets(self) -> None:
        text_files = [
            path
            for path in SKILL.rglob("*")
            if path.is_file()
            and path.suffix.lower()
            in {".md", ".json", ".py", ".sh", ".swift", ".yaml", ".yml"}
        ]
        combined = "\n".join(path.read_text(encoding="utf-8") for path in text_files)

        forbidden_patterns = {
            "concrete web origin": r"https?://(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}",
            "literal email address": r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",
            "literal macOS home": r"/(?:Users)/[A-Za-z0-9._-]+/",
            "literal Linux home": r"/(?:home)/[A-Za-z0-9._-]+/",
            "numbered Chrome profile": r"\bProfile\s+\d+\b",
            "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
            "assigned password": r"(?i)\bpassword\s*[:=]\s*['\"][^<][^'\"]+['\"]",
            "assigned bearer token": r"(?i)\bauthorization\s*[:=]\s*['\"]Bearer\s+[A-Za-z0-9._~+/=-]{8,}",
        }
        for label, pattern in forbidden_patterns.items():
            self.assertIsNone(re.search(pattern, combined), label)

        # Assemble the former private deployment values so the regression test
        # does not itself publish the strings it is meant to exclude.
        forbidden_needles = {
            "former account name": "ary" + "ang9",
            "former personal name": "Ary" + "an",
            "former service host": "jupyter" + ".ncsa.illinois.edu",
            "former home path": "/home/" + "ary" + "ang9",
            "former browser profile": "Profile" + " " + "1",
            "former allocation key": "3_" + "h200",
            "former token basename": "h200_" + "jupyter_token",
        }
        lowered = combined.lower()
        for label, needle in forbidden_needles.items():
            self.assertNotIn(needle.lower(), lowered, label)

        forbidden_artifact_names = {
            "config.json",
            "jupyter-token",
            "bridge.log",
        }
        for path in SKILL.rglob("*"):
            if path.is_file() and path.name != "config.example.json":
                self.assertNotIn(path.name, forbidden_artifact_names)

    def test_docs_cover_end_to_end_operating_contract(self) -> None:
        docs = "\n".join(
            path.read_text(encoding="utf-8")
            for path in [SKILL / "SKILL.md", *sorted((SKILL / "references").glob("*.md"))]
        ).lower()
        required_phrases = [
            "24 hours",
            "restart",
            "same-named child",
            "if it does not exist",
            "background terminal",
            "gpu",
            "exit status",
            "exact chrome window",
            "closes only the chrome window it created",
            "resume automatically",
        ]
        for phrase in required_phrases:
            self.assertIn(phrase, docs)


if __name__ == "__main__":
    unittest.main()
