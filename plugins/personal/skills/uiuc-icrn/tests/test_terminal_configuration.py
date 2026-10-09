#!/usr/bin/env python3
"""Focused tests that bind terminal and broker behavior to private configuration."""

from __future__ import annotations

import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
icrn_config = importlib.import_module("icrn_config")
terminal = importlib.import_module("icrn_jupyter_terminal")
broker = importlib.import_module("icrn_terminal_broker")


class ConfigFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.directory = self.root / "config-home"
        self.directory.mkdir(mode=0o700)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "config.json"
        self.value: dict[str, object] = {
            "schema_version": 1,
            "origin": "https" + "://" + "notebook.example.illinois.edu",
            "identity": {
                "jupyter_username": "sample-user",
                "microsoft_account": "sample" + "@" + "illinois.edu",
                "identity_provider_label": "Example provider",
            },
            "browser": {
                "profile_directory": "Default",
                "user_data_directory": str(self.root / "Chrome Data"),
                "executable": str(self.root / "Browser.app" / "browser"),
            },
            "workspace": {"remote_root": "/srv/sandbox"},
            "target": {
                "workbench_service": "editor",
                "hub_server_key": "named-session",
                "profile": "profile-key",
                "image": "image-key",
                "resource": "resource-key",
                "environment_label": "Editor environment",
                "resource_label": "Accelerator resource",
                "remote_python": "/opt/custom/bin/python3.12",
            },
            "credentials": {"jupyter_token_file": str(self.root / "token")},
            "allowed_auth_domains": {
                "identity_provider": ["idp.example.org"],
                "institution": ["auth.example.illinois.edu"],
                "microsoft": ["login.example.net"],
                "mfa": [],
            },
        }
        self.write()

    def write(self) -> None:
        self.path.write_text(json.dumps(self.value), encoding="utf-8")
        os.chmod(self.path, 0o600)

    def close(self) -> None:
        self.temporary.cleanup()


class TerminalConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ConfigFixture()
        self.environment = mock.patch.dict(
            os.environ, {"UIUC_ICRN_CONFIG": str(self.fixture.path)}, clear=False
        )
        self.environment.start()
        broker._configuration.cache_clear()
        broker._source_id.cache_clear()

    def tearDown(self) -> None:
        broker._source_id.cache_clear()
        broker._configuration.cache_clear()
        self.environment.stop()
        self.fixture.close()

    def test_client_uses_configured_server_root_options_and_python(self) -> None:
        config = icrn_config.load_config()
        client = terminal.JupyterTerminalClient("test-token", config=config)
        self.assertEqual(client.root, "/srv/sandbox")
        self.assertEqual(client.server_key, "named-session")
        self.assertEqual(client.server_base, "/user/sample-user/named-session/")
        self.assertEqual(
            client.expected_options,
            {"profile": "profile-key", "image": "image-key", "resource": "resource-key"},
        )
        self.assertEqual(client.remote_python, "/opt/custom/bin/python3.12")
        self.assertEqual(terminal.validate_cwd("child", root=client.root), "/srv/sandbox/child")
        with self.assertRaisesRegex(terminal.TerminalClientError, "configured remote root"):
            terminal.validate_cwd("/srv/outside", root=client.root)

    def test_remote_launcher_uses_configured_root_and_python(self) -> None:
        source = terminal._remote_launcher_source("READY", root="/srv/sandbox")
        self.assertIn(b"ROOT=pathlib.Path('/srv/sandbox')", source)
        command = terminal._remote_shell_command(
            source,
            remote_python="/opt/custom/bin/python3.12",
            idle="IDLE",
        )
        self.assertIn("command /opt/custom/bin/python3.12 -I -S", command)
        self.assertNotIn("command /usr/bin/python3 -I -S", command)

    def test_attestation_uses_exact_named_server_and_configured_options(self) -> None:
        config = icrn_config.load_config()
        client = terminal.JupyterTerminalClient("test-token", config=config)

        class FakeREST:
            origin = config.origin

            def request_json(self, _method: str, path: str, **_kwargs: object) -> tuple[int, object]:
                if path == "/hub/api/user":
                    return 200, {
                        "name": "sample-user",
                        "servers": {
                            "named-session": {
                                "url": "/user/sample-user/named-session/",
                                "ready": True,
                                "pending": None,
                                "user_options": {
                                    "profile": "profile-key",
                                    "image": "image-key",
                                    "resource": "resource-key",
                                },
                            }
                        },
                    }
                if path.endswith("api/status"):
                    return 200, {"connections": 0}
                if path.endswith("api/terminals"):
                    return 200, []
                raise AssertionError(path)

        client.rest = FakeREST()  # type: ignore[assignment]
        self.assertEqual(client.attest(), set())

    def test_api_failures_do_not_echo_dynamic_endpoint_paths(self) -> None:
        rest = terminal._NoRedirectJSONClient(
            "http://localhost:8999", "test-token", allow_insecure_for_tests=True
        )

        class FakeResponse:
            status = 403

            @staticmethod
            def getheader(_name: str, default: object = None) -> object:
                return default

            @staticmethod
            def read(_limit: int) -> bytes:
                return b""

        class FakeConnection:
            @staticmethod
            def request(*_args: object, **_kwargs: object) -> None:
                return None

            @staticmethod
            def getresponse() -> FakeResponse:
                return FakeResponse()

            @staticmethod
            def close() -> None:
                return None

        rest._connection = lambda _timeout=None: FakeConnection()  # type: ignore[method-assign]
        private_path = "/user/private-identity/named-session/api/status"
        with self.assertRaises(terminal.TerminalClientError) as caught:
            rest.request_json("GET", private_path)
        self.assertNotIn(private_path, str(caught.exception))
        self.assertNotIn("private-identity", str(caught.exception))
        self.assertIn("HTTP 403", str(caught.exception))

    def test_claude_session_id_scopes_broker(self) -> None:
        project = self.fixture.root / "project"
        project.mkdir()
        with mock.patch.dict(
            os.environ,
            {
                "CLAUDE_CODE_SESSION_ID": "claude-session-example",
                "CODEX_THREAD_ID": "",
                "CODEX_SESSION_ID": "",
            },
            clear=False,
        ):
            implicit = broker.scope_id(project)
        explicit = broker.scope_id(project, task_identity="claude-session-example")
        self.assertEqual(implicit, explicit)

    def test_config_change_changes_scope_and_source_compatibility_ids(self) -> None:
        project = self.fixture.root / "project"
        project.mkdir()
        before_scope = broker.scope_id(project, task_identity="task")
        before_source = broker._source_id()
        self.fixture.value["target"]["resource"] = "different-resource"  # type: ignore[index]
        self.fixture.write()
        broker._source_id.cache_clear()
        broker._configuration.cache_clear()
        self.assertNotEqual(before_scope, broker.scope_id(project, task_identity="task"))
        self.assertNotEqual(before_source, broker._source_id())


if __name__ == "__main__":
    unittest.main()
