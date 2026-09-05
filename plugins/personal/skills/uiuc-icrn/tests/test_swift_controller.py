#!/usr/bin/env python3
"""Focused privacy and compile checks for the macOS window controllers."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL / "scripts"


class SwiftControllerTests(unittest.TestCase):
    def test_secure_text_values_are_guarded_by_role_and_subrole(self) -> None:
        source = (SCRIPTS / "open_icrn.swift").read_text(encoding="utf-8")
        self.assertIn("kAXSubroleAttribute", source)
        self.assertIn(
            "stringAttribute(element, kAXRoleAttribute as CFString) == secureTextFieldRole",
            source,
        )
        self.assertIn(
            "stringAttribute(element, kAXSubroleAttribute as CFString) == secureTextFieldRole",
            source,
        )
        self.assertIn("value: safeStringValue(element)", source)
        self.assertIn("guard !isProtectedValueElement(element)", source)

    def test_spawn_attestation_has_no_text_presence_fallback(self) -> None:
        source = (SCRIPTS / "open_icrn.swift").read_text(encoding="utf-8")
        start = source.index("private func configuredSpawnAttested")
        end = source.index("private func hostSummary", start)
        attestation = source[start:end]
        self.assertIn("fancyConfigurationIsExpected", attestation)
        self.assertIn("selectedChoice", attestation)
        self.assertNotIn("containsFragment", attestation)
        self.assertNotIn("containsText", attestation)

    def test_window_provenance_and_auth_hosts_fail_closed(self) -> None:
        source = (SCRIPTS / "open_icrn.swift").read_text(encoding="utf-8")
        self.assertIn("private func matchingNewFlows", source)
        self.assertIn("originOnly: false", source)
        self.assertIn("closeSoleNewFlowWindow", source)
        self.assertNotIn("closeNewICRNWindows", source)
        domain_matcher = source[
            source.index("private func domainMatches") : source.index(
                "private func pageEvidenceIsRelevant"
            )
        ]
        self.assertIn("host == domain", domain_matcher)
        self.assertNotIn("hasSuffix", domain_matcher)

    def test_configured_identity_labels_are_not_logged(self) -> None:
        source = (SCRIPTS / "open_icrn.swift").read_text(encoding="utf-8")
        self.assertIn('statusLabel: "configured Microsoft account"', source)
        self.assertIn('safeChoiceLabel: "configured identity provider"', source)
        self.assertNotIn('print("Continuing: \\(config.', source)

    def test_sign_in_requires_exact_configured_account_evidence(self) -> None:
        source = (SCRIPTS / "open_icrn.swift").read_text(encoding="utf-8")
        self.assertIn(
            "let exactAccountVisible = current.containsText(config.microsoftAccount)",
            source,
        )
        self.assertIn("} else if exactAccountVisible {", source)
        self.assertIn(
            "if confirmedMicrosoftAccount || exactAccountVisible",
            source,
        )
        self.assertNotIn("establishesMicrosoftAccount", source)
        self.assertNotIn(
            'current.containsFragment("enter password")\n                        ||',
            source,
        )

    def test_wrappers_bootstrap_validated_config(self) -> None:
        for name in ("open_icrn.sh", "capture_icrn_window.sh"):
            source = (SCRIPTS / name).read_text(encoding="utf-8")
            self.assertIn('icrn_config.py" shell-env', source)
            self.assertIn("if ! CONFIG_EXPORTS=", source)
            self.assertNotIn('eval "$(/usr/bin/python3', source)
        launcher = (SCRIPTS / "open_icrn.sh").read_text(encoding="utf-8")
        self.assertIn("ICRN_LAUNCH_URL", launcher)
        self.assertIn("OPEN_ICRN_USER_DATA_DIR", launcher)

    def test_wrappers_stop_when_config_loading_fails(self) -> None:
        environment = os.environ.copy()
        environment["UIUC_ICRN_CONFIG"] = str(SKILL / "does-not-exist.json")
        for name in ("open_icrn.sh", "capture_icrn_window.sh"):
            result = subprocess.run(
                ["bash", str(SCRIPTS / name)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("icrn-config:", result.stderr)

    @unittest.skipUnless(
        sys.platform == "darwin" and shutil.which("swiftc"),
        "Swift/AppKit type checking requires macOS",
    )
    def test_swift_sources_typecheck_with_warnings_as_errors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="uiuc-icrn-swift-") as cache:
            environment = os.environ.copy()
            environment["SWIFT_MODULECACHE_PATH"] = cache
            environment["CLANG_MODULE_CACHE_PATH"] = cache
            for name in ("open_icrn.swift", "capture_icrn_window.swift"):
                subprocess.run(
                    ["swiftc", "-warnings-as-errors", "-typecheck", str(SCRIPTS / name)],
                    check=True,
                    env=environment,
                    capture_output=True,
                    text=True,
                )


if __name__ == "__main__":
    unittest.main()
