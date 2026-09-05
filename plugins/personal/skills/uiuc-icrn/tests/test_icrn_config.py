#!/usr/bin/env python3
"""Focused security and URL-shape tests for the public ICRN configuration."""

from __future__ import annotations

import importlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from urllib.parse import parse_qs, parse_qsl, urlsplit

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
icrn_config = importlib.import_module("icrn_config")


def valid_value(root: Path) -> dict[str, object]:
    return {
        "schema_version": 1,
        "origin": "https" + "://" + "research.example.illinois.edu",
        "identity": {
            "jupyter_username": "example-netid",
            "microsoft_account": "student" + "@" + "illinois.edu",
            "identity_provider_label": "Example institution",
        },
        "browser": {
            "profile_directory": "Default",
            "user_data_directory": str(root / "Browser Data"),
            "executable": str(root / "Browser.app" / "browser"),
        },
        "workspace": {"remote_root": "/srv/research/sandbox"},
        "target": {
            "workbench_service": "code-service",
            "hub_server_key": "",
            "profile": "environment-choice",
            "image": "editor-image",
            "resource": "gpu-resource",
            "environment_label": "Configured editor",
            "resource_label": "Configured accelerator",
            "remote_python": "/opt/runtime/bin/python3.11",
        },
        "credentials": {"jupyter_token_file": str(root / "jupyter-token")},
        "allowed_auth_domains": {
            "identity_provider": ["login.example.org"],
            "institution": ["auth.example.illinois.edu"],
            "microsoft": ["login.example.net"],
            "mfa": ["mfa.example.com"],
        },
    }


class PrivateConfigFixture:
    def __init__(self, case: unittest.TestCase) -> None:
        self.case = case
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.directory = self.root / "uiuc-icrn"
        self.directory.mkdir(mode=0o700)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "config.json"
        self.value = valid_value(self.root)

    def write(self, *, mode: int = 0o600) -> Path:
        self.path.write_text(json.dumps(self.value), encoding="utf-8")
        os.chmod(self.path, mode)
        return self.path

    def close(self) -> None:
        self.temporary.cleanup()


class ICRNConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = PrivateConfigFixture(self)

    def tearDown(self) -> None:
        self.fixture.close()

    def load(self) -> object:
        return icrn_config.load_config(self.fixture.write())

    def assert_rejected(self, pattern: str) -> None:
        with self.assertRaisesRegex(icrn_config.ConfigError, pattern):
            icrn_config.load_config(self.fixture.write())

    def test_loads_exact_schema_and_canonical_fingerprint(self) -> None:
        config = self.load()
        before = config.fingerprint()
        self.fixture.value = dict(reversed(list(self.fixture.value.items())))
        after = self.load().fingerprint()
        self.assertEqual(before, after)
        self.assertRegex(before, r"^[0-9a-f]{64}$")

        self.fixture.value["identity"]["jupyter_username"] = "another-netid"  # type: ignore[index]
        self.assertNotEqual(before, self.load().fingerprint())

    def test_launch_url_preserves_two_ordered_next_parameters(self) -> None:
        config = self.load()
        parsed = urlsplit(config.launch_url())
        self.assertEqual(f"{parsed.scheme}://{parsed.netloc}", config.origin)
        self.assertEqual(parsed.path, "/hub/login")
        self.assertEqual(parsed.fragment, "")
        next_values = parse_qsl(parsed.query, keep_blank_values=True)
        self.assertEqual([key for key, _value in next_values], ["next", "next"])

        workbench = urlsplit(next_values[0][1])
        self.assertEqual(workbench.path, "/hub/user/example-netid/code-service/")
        self.assertEqual(
            parse_qsl(workbench.query),
            [("folder", "/srv/research/sandbox"), ("redirects", "2")],
        )
        spawn = urlsplit(next_values[1][1])
        self.assertEqual(spawn.path, "/hub/spawn")
        fancy = parse_qs(spawn.fragment, strict_parsing=True)["fancy-forms-config"]
        self.assertEqual(
            json.loads(fancy[0]),
            {
                "profile": "environment-choice",
                "image": "editor-image",
                "image:unlisted_choice": "",
                "resource": "gpu-resource",
                "resource:unlisted_choice": "",
            },
        )

    def test_named_server_shapes_paths_without_changing_origin(self) -> None:
        self.fixture.value["target"]["hub_server_key"] = "task-server"  # type: ignore[index]
        config = self.load()
        self.assertEqual(config.server_base, "/user/example-netid/task-server/")
        values = parse_qsl(urlsplit(config.launch_url()).query)
        self.assertEqual(
            urlsplit(values[0][1]).path,
            "/hub/user/example-netid/task-server/code-service/",
        )
        self.assertEqual(urlsplit(values[1][1]).path, "/hub/spawn/example-netid/task-server")

    def test_rejects_untrusted_origin_and_account_domains(self) -> None:
        self.fixture.value["origin"] = "https" + "://" + "untrusted.example.net"
        self.assert_rejected("illinois.edu host")
        self.fixture.value = valid_value(self.fixture.root)
        self.fixture.value["identity"]["microsoft_account"] = (  # type: ignore[index]
            "student" + "@" + "example.net"
        )
        self.assert_rejected("illinois.edu account")

    def test_rejects_root_workspace_and_unsafe_remote_python(self) -> None:
        self.fixture.value["workspace"]["remote_root"] = "/"  # type: ignore[index]
        self.assert_rejected("must not be the filesystem root")
        self.fixture.value = valid_value(self.fixture.root)
        self.fixture.value["target"]["remote_python"] = "/usr/bin/python3;command"  # type: ignore[index]
        self.assert_rejected("unsafe in a remote executable path")

    def test_accepts_general_chrome_profile_names_and_rejects_injection(self) -> None:
        for profile in ("Default", "Profile" + " " + "42"):
            self.fixture.value["browser"]["profile_directory"] = profile  # type: ignore[index]
            self.assertEqual(self.load().browser.profile_directory, profile)
        for profile in (
            "Profile" + " " + "0",
            "../Default",
            "Profile" + " " + "2/../3",
            "Person" + " " + "1",
        ):
            self.fixture.value["browser"]["profile_directory"] = profile  # type: ignore[index]
            self.assert_rejected("profile_directory")

    def test_rejects_extra_keys_and_cross_role_domain_reuse(self) -> None:
        self.fixture.value["unexpected"] = True
        self.assert_rejected("must contain exactly")
        self.fixture.value = valid_value(self.fixture.root)
        shared = "auth.example.org"
        self.fixture.value["allowed_auth_domains"]["institution"] = [shared]  # type: ignore[index]
        self.fixture.value["allowed_auth_domains"]["microsoft"] = [shared]  # type: ignore[index]
        self.assert_rejected("different authentication roles")
        self.fixture.value = valid_value(self.fixture.root)
        self.fixture.value["allowed_auth_domains"]["institution"] = [  # type: ignore[index]
            "child.auth.example.org"
        ]
        self.fixture.value["allowed_auth_domains"]["microsoft"] = [  # type: ignore[index]
            "auth.example.org"
        ]
        self.assert_rejected("Overlapping auth domains")

    def test_rejects_duplicate_json_keys(self) -> None:
        path = self.fixture.path
        path.write_text(
            '{"schema_version":1,"schema_version":1}', encoding="utf-8"
        )
        os.chmod(path, 0o600)
        with self.assertRaisesRegex(icrn_config.ConfigError, "duplicate JSON key"):
            icrn_config.load_config(path)

    def test_rejects_unedited_public_example_placeholders(self) -> None:
        self.fixture.value["identity"]["identity_provider_label"] = (  # type: ignore[index]
            "<identity-provider-label>"
        )
        self.assert_rejected("public-example placeholder")
        self.fixture.value = valid_value(self.fixture.root)
        self.fixture.value["target"]["resource_label"] = (  # type: ignore[index]
            "prefix <resource-label> suffix"
        )
        self.assert_rejected("public-example placeholder")

    def test_rejects_unsafe_parent_and_config_file_metadata(self) -> None:
        path = self.fixture.write()
        os.chmod(path, 0o644)
        with self.assertRaisesRegex(icrn_config.ConfigError, "mode 0600"):
            icrn_config.load_config(path)
        os.chmod(path, 0o600)
        os.chmod(self.fixture.directory, 0o755)
        with self.assertRaisesRegex(icrn_config.ConfigError, "mode 0700"):
            icrn_config.load_config(path)

    def test_rejects_symlinked_parent_and_hardlinked_config(self) -> None:
        path = self.fixture.write()
        hardlink = self.fixture.directory / "second-name.json"
        os.link(path, hardlink)
        with self.assertRaisesRegex(icrn_config.ConfigError, "exactly one hard link"):
            icrn_config.load_config(path)

        hardlink.unlink()
        real_directory = self.fixture.root / "real-private"
        real_directory.mkdir(mode=0o700)
        os.chmod(real_directory, 0o700)
        real_path = real_directory / "config.json"
        real_path.write_text(json.dumps(self.fixture.value), encoding="utf-8")
        os.chmod(real_path, 0o600)
        linked_directory = self.fixture.root / "linked-private"
        linked_directory.symlink_to(real_directory, target_is_directory=True)
        with self.assertRaisesRegex(icrn_config.ConfigError, "non-symlink directory"):
            icrn_config.load_config(linked_directory / "config.json")

    def test_shell_environment_contains_paths_not_secret_contents(self) -> None:
        config = self.load()
        environment = config.shell_environment()
        self.assertEqual(environment["UIUC_ICRN_CONFIG"], str(self.fixture.path))
        self.assertEqual(environment["ICRN_TOKEN_FILE"], str(self.fixture.root / "jupyter-token"))
        roles = json.loads(environment["ICRN_ALLOWED_AUTH_DOMAINS_JSON"])
        self.assertEqual(set(roles), set(icrn_config.AUTH_ROLES))

    def test_cli_does_not_offer_a_permalink_printing_operation(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            icrn_config.build_parser().parse_args(["launch-url"])


if __name__ == "__main__":
    unittest.main()
