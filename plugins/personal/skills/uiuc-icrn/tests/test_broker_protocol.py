#!/usr/bin/env python3
"""Behavioral and process-lifecycle tests for the local terminal broker."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import types
import unittest
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from unittest import mock

SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL / "scripts"
BROKER_PATH = SCRIPTS / "icrn_terminal_broker.py"
REMOTE_ROOT = "/srv/remote-sandbox"


class SyntheticConfig:
    workspace = types.SimpleNamespace(remote_root=REMOTE_ROOT)
    credentials = types.SimpleNamespace(jupyter_token_file=Path("/unused/token"))

    @staticmethod
    def fingerprint() -> str:
        return "f" * 64


def load_isolated_broker(root: Path) -> Any:
    """Import the real broker against a minimal behaviorally compatible terminal."""

    terminal_source = root / "icrn_jupyter_terminal.py"
    terminal_source.write_text("# synthetic broker-test dependency\n", encoding="utf-8")
    terminal_module = types.ModuleType("icrn_jupyter_terminal")
    terminal_module.__file__ = str(terminal_source)
    terminal_module.re = re
    terminal_module.TERMINAL_NAME_PATTERN = re.compile(r"icrn_[0-9a-f]{32}")
    terminal_module.DEFAULT_TIMEOUT_SECONDS = 30.0
    terminal_module.DELETE_TIMEOUT_SECONDS = 0.1
    terminal_module.MAX_TIMEOUT_SECONDS = 3_600.0

    class TerminalClientError(Exception):
        pass

    @dataclass(frozen=True)
    class ExecutionResult:
        returncode: int
        timed_out: bool
        interrupted: bool
        truncated: bool
        output_bytes: int

    def validate_argv(argv: list[str]) -> list[str]:
        if not isinstance(argv, list) or not argv:
            raise TerminalClientError("invalid argv")
        return list(argv)

    def validate_cwd(cwd: str, *, root: str | None = None) -> str:
        expected = root or REMOTE_ROOT
        if cwd != expected and not cwd.startswith(expected + "/"):
            raise TerminalClientError("invalid cwd")
        return cwd

    terminal_module.TerminalClientError = TerminalClientError
    terminal_module.ExecutionResult = ExecutionResult
    terminal_module.JupyterTerminalClient = object
    terminal_module.JupyterTerminalSession = object
    terminal_module.read_private_token = lambda _path: "synthetic-token"
    terminal_module.validate_argv = validate_argv
    terminal_module.validate_cwd = validate_cwd
    terminal_module._timeout_argument = float

    module_name = f"icrn_terminal_broker_test_{uuid.uuid4().hex}"
    specification = importlib.util.spec_from_file_location(module_name, BROKER_PATH)
    if specification is None or specification.loader is None:
        raise AssertionError("could not load broker module")
    module = importlib.util.module_from_spec(specification)
    with mock.patch.dict(
        sys.modules,
        {"icrn_jupyter_terminal": terminal_module, module_name: module},
    ):
        if str(SCRIPTS) not in sys.path:
            sys.path.insert(0, str(SCRIPTS))
        specification.loader.exec_module(module)
    module._configuration = lambda: SyntheticConfig()
    module._source_id.cache_clear()
    return module


class FakeSession:
    def __init__(
        self,
        terminal_module: Any,
        outcomes: list[int | BaseException] | None = None,
    ) -> None:
        self.terminal_module = terminal_module
        self.outcomes = list(outcomes or [0])
        self.calls: list[dict[str, Any]] = []
        self.close_calls = 0
        self.closed = False

    def run(
        self,
        argv: list[str],
        *,
        cwd: str,
        ensure_cwd: bool,
        timeout_seconds: float,
        output: Any,
    ) -> Any:
        self.calls.append(
            {
                "argv": list(argv),
                "cwd": cwd,
                "ensure_cwd": ensure_cwd,
                "timeout_seconds": timeout_seconds,
            }
        )
        outcome = self.outcomes.pop(0) if self.outcomes else 0
        if isinstance(outcome, BaseException):
            raise outcome
        data = ("output:" + " ".join(argv) + "\n").encode()
        output.write(data)
        output.flush()
        return self.terminal_module.ExecutionResult(
            returncode=outcome,
            timed_out=False,
            interrupted=False,
            truncated=False,
            output_bytes=len(data),
        )

    def close(self) -> None:
        self.close_calls += 1
        self.closed = True


class FakeClient:
    def __init__(self, session: FakeSession) -> None:
        self.root = REMOTE_ROOT
        self.session = session
        self.opened_names: list[str] = []
        self.cleaned_names: list[str] = []

    def open_session(self, terminal_name: str) -> FakeSession:
        self.opened_names.append(terminal_name)
        return self.session

    def cleanup_terminal(self, terminal_name: str) -> bool:
        self.cleaned_names.append(terminal_name)
        return True


def scope(character: str = "a") -> str:
    return character * 64


def open_broker(
    module: Any,
    state_root: Path,
    fake_client: FakeClient,
    **kwargs: Any,
) -> tuple[Any, Any]:
    scope_id = scope()
    paths = module._paths(scope_id, root=state_root)
    module._prepare_paths(paths)
    broker = module.TerminalBroker(
        scope_id,
        paths,
        client_factory=lambda: fake_client,
        **kwargs,
    )
    broker._open_remote()
    return broker, paths


def handle_frames(
    module: Any,
    broker: Any,
    request: dict[str, Any],
) -> tuple[list[dict[str, Any]], BaseException | None]:
    frames: list[dict[str, Any]] = []
    server, client = socket.socketpair()
    caught: BaseException | None = None
    try:
        module._send_frame(client, request, limit=module.MAX_REQUEST_BYTES)
        try:
            broker._handle(server)
        except BaseException as error:
            caught = error
        reader = module._FrameReader(client, limit=module.MAX_FRAME_BYTES)
        while True:
            frame = reader.receive()
            frames.append(frame)
            if frame.get("type") in {"result", "error", "closed", "status"}:
                return frames, caught
    finally:
        server.close()
        client.close()


def exec_request(
    module: Any,
    scope_id: str,
    argv: list[str],
    request_id: str,
) -> dict[str, Any]:
    return {
        **module._base_request(scope_id, "exec"),
        "request_id": request_id,
        "argv": argv,
        "cwd": f"{REMOTE_ROOT}/project",
        "ensure_cwd": True,
        "timeout_seconds": 30.0,
    }


def decoded_output(frames: list[dict[str, Any]]) -> bytes:
    return b"".join(
        base64.b64decode(frame["data_b64"], validate=True)
        for frame in frames
        if frame.get("type") == "stdout"
    )


class BrokerProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="ib-", dir="/private/tmp"
        )
        self.root = Path(self.temporary.name)
        self.module = load_isolated_broker(self.root)
        self.state_root = self.root / "state"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_reuses_one_terminal_and_closes_exactly(self) -> None:
        session = FakeSession(self.module.terminal, outcomes=[7, 0])
        client = FakeClient(session)
        broker, paths = open_broker(self.module, self.state_root, client)

        first, first_error = handle_frames(
            self.module,
            broker,
            exec_request(self.module, broker.scope_id, ["first"], "1" * 32),
        )
        second, second_error = handle_frames(
            self.module,
            broker,
            exec_request(self.module, broker.scope_id, ["second"], "2" * 32),
        )
        closed, close_error = handle_frames(
            self.module,
            broker,
            self.module._base_request(broker.scope_id, "close"),
        )

        self.assertEqual([value["type"] for value in first], ["accepted", "stdout", "result"])
        self.assertEqual([value["type"] for value in second], ["accepted", "stdout", "result"])
        self.assertEqual(first[-1]["returncode"], 7)
        self.assertFalse(first[-1]["reused"])
        self.assertEqual(second[-1]["returncode"], 0)
        self.assertTrue(second[-1]["reused"])
        self.assertEqual(decoded_output(first), b"output:first\n")
        self.assertEqual(decoded_output(second), b"output:second\n")
        self.assertEqual(len(client.opened_names), 1)
        self.assertRegex(client.opened_names[0], r"^icrn_[0-9a-f]{32}$")
        self.assertEqual([value["argv"] for value in session.calls], [["first"], ["second"]])
        self.assertEqual(session.close_calls, 1)
        self.assertEqual(client.cleaned_names, client.opened_names)
        self.assertEqual(closed[-1]["type"], "closed")
        self.assertFalse(paths.lease.exists())
        self.assertIsNone(first_error)
        self.assertIsNone(second_error)
        self.assertIsNone(close_error)

    def test_private_state_and_stale_running_lease_reconciliation(self) -> None:
        stale_scope = scope()
        paths = self.module._paths(stale_scope, root=self.state_root)
        self.module._prepare_paths(paths)
        stale_name = "icrn_" + "7" * 32
        stale = self.module._lease_value(
            stale_scope,
            stale_name,
            state="running",
            request_id="8" * 32,
        )
        self.module._atomic_private_json(paths.lease, stale)
        session = FakeSession(self.module.terminal)
        client = FakeClient(session)
        broker = self.module.TerminalBroker(
            stale_scope,
            paths,
            client_factory=lambda: client,
        )

        with self.assertRaisesRegex(self.module.BrokerError, "uncertain outcome"):
            broker.serve()

        self.assertEqual(stat.S_IMODE(paths.root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(paths.scope.stat().st_mode), 0o700)
        self.assertEqual(client.cleaned_names, [stale_name])
        self.assertEqual(client.opened_names, [])
        self.assertFalse(paths.lease.exists())
        uncertainty = self.module._read_private_json(paths.uncertain, required=True)
        self.assertEqual(uncertainty["request_id"], "8" * 32)
        self.assertEqual(uncertainty["prior_state"], "running")

    def test_acceptance_follows_durable_running_journal(self) -> None:
        session = FakeSession(self.module.terminal)
        client = FakeClient(session)
        broker, _paths = open_broker(self.module, self.state_root, client)
        observed_states: list[str] = []
        original_send = self.module._send_frame

        def observe_send(connection: socket.socket, value: dict[str, Any], **kwargs: Any) -> None:
            if value.get("type") == "accepted":
                observed_states.append(broker.lease["state"])
            original_send(connection, value, **kwargs)

        with mock.patch.object(self.module, "_send_frame", observe_send):
            _frames, error = handle_frames(
                self.module,
                broker,
                exec_request(self.module, broker.scope_id, ["work"], "3" * 32),
            )
        self.assertIsNone(error)
        self.assertEqual(observed_states, ["running"])
        broker._close_remote()

    def test_command_timeout_is_capped_by_absolute_lifetime(self) -> None:
        session = FakeSession(self.module.terminal)
        client = FakeClient(session)
        broker, _paths = open_broker(
            self.module,
            self.state_root,
            client,
            idle_seconds=10.0,
            max_age_seconds=10.0,
        )
        broker.started_monotonic = time.monotonic() - 9.0
        request = exec_request(self.module, broker.scope_id, ["long"], "9" * 32)
        request["timeout_seconds"] = 100.0
        _frames, error = handle_frames(self.module, broker, request)
        self.assertIsNone(error)
        self.assertGreater(session.calls[0]["timeout_seconds"], 0.0)
        self.assertLessEqual(session.calls[0]["timeout_seconds"], 1.1)
        broker._close_remote()

    def test_idle_expiry_closes_owned_terminal(self) -> None:
        session = FakeSession(self.module.terminal)
        client = FakeClient(session)
        paths = self.module._paths(scope(), root=self.state_root)
        broker = self.module.TerminalBroker(
            scope(),
            paths,
            client_factory=lambda: client,
            idle_seconds=0.05,
            max_age_seconds=1.0,
        )

        class TimeoutServer:
            def accept(self) -> Any:
                raise socket.timeout()

            def close(self) -> None:
                return

        def bind_without_network() -> None:
            broker.server = TimeoutServer()

        broker._bind = bind_without_network
        self.assertEqual(broker.serve(), 0)
        self.assertEqual(session.close_calls, 1)
        self.assertEqual(client.cleaned_names, client.opened_names)
        self.assertFalse(paths.lease.exists())

    def test_invalid_request_is_rejected_without_running_command(self) -> None:
        session = FakeSession(self.module.terminal)
        client = FakeClient(session)
        broker, _paths = open_broker(self.module, self.state_root, client)
        request = exec_request(self.module, broker.scope_id, ["work"], "b" * 32)
        request["unexpected"] = True
        server, client_socket = socket.socketpair()
        try:
            self.module._send_frame(client_socket, request)
            with self.assertRaisesRegex(self.module.BrokerError, "unexpected or missing"):
                broker._handle(server)
        finally:
            server.close()
            client_socket.close()
        self.assertEqual(session.calls, [])
        broker._close_remote()

    def test_disconnect_after_acceptance_records_uncertainty_and_cleans(self) -> None:
        started = threading.Event()
        release = threading.Event()

        class HeldSession(FakeSession):
            def run(self, argv: list[str], **kwargs: Any) -> Any:
                self.calls.append({"argv": list(argv), **kwargs})
                started.set()
                if not release.wait(timeout=2.0):
                    raise AssertionError("test did not release held command")
                return self.terminal_module.ExecutionResult(
                    returncode=0,
                    timed_out=False,
                    interrupted=False,
                    truncated=False,
                    output_bytes=0,
                )

        session = HeldSession(self.module.terminal)
        client = FakeClient(session)
        broker, paths = open_broker(self.module, self.state_root, client)
        request_id = "d" * 32
        request = exec_request(self.module, broker.scope_id, ["held"], request_id)
        server, client_socket = socket.socketpair()
        errors: list[BaseException] = []

        def handle() -> None:
            try:
                broker._handle(server)
            except BaseException as error:
                errors.append(error)

        self.module._send_frame(client_socket, request)
        thread = threading.Thread(target=handle, daemon=True)
        thread.start()
        reader = self.module._FrameReader(client_socket, limit=self.module.MAX_FRAME_BYTES)
        accepted = reader.receive()
        self.assertEqual(accepted["type"], "accepted")
        self.assertEqual(accepted["request_id"], request_id)
        self.assertTrue(started.wait(timeout=2.0))
        client_socket.close()
        release.set()
        thread.join(timeout=2.0)
        server.close()

        self.assertFalse(thread.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], BrokenPipeError)
        uncertainty = self.module._read_private_json(paths.uncertain, required=True)
        self.assertEqual(uncertainty["request_id"], request_id)
        self.assertEqual(uncertainty["prior_state"], "completed")
        broker._close_remote()
        self.assertTrue(session.closed)
        self.assertEqual(client.cleaned_names, client.opened_names)
        self.assertFalse(paths.lease.exists())
        self.assertTrue(paths.uncertain.exists())

    def test_frame_reader_retains_coalesced_messages(self) -> None:
        sender, receiver = socket.socketpair()
        first = {"v": 1, "type": "accepted", "request_id": "c" * 32}
        second = {"v": 1, "type": "result", "request_id": "c" * 32, "returncode": 0}
        payload = (
            json.dumps(first, separators=(",", ":"))
            + "\n"
            + json.dumps(second, separators=(",", ":"))
            + "\n"
        ).encode()
        try:
            sender.sendall(payload)
            reader = self.module._FrameReader(receiver, limit=self.module.MAX_FRAME_BYTES)
            self.assertEqual(reader.receive(), first)
            self.assertEqual(reader.receive(), second)
            self.assertEqual(reader.buffer, b"")
        finally:
            sender.close()
            receiver.close()

    def test_cli_process_reuses_broker_then_closes(self) -> None:
        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o700)
        broker_copy = runtime / "icrn_terminal_broker.py"
        terminal_copy = runtime / "icrn_jupyter_terminal.py"
        config_copy = runtime / "icrn_config.py"
        project = self.root / "project"
        project.mkdir()
        state = self.root / "cli-state"
        audit = self.root / "audit.jsonl"
        shutil.copyfile(BROKER_PATH, broker_copy)
        config_copy.write_text(
            textwrap.dedent(
                f"""\
                from pathlib import Path

                class Value:
                    workspace = type("Workspace", (), {{"remote_root": {REMOTE_ROOT!r}}})()
                    credentials = type(
                        "Credentials", (), {{"jupyter_token_file": Path("/unused/token")}}
                    )()

                    @staticmethod
                    def fingerprint():
                        return "f" * 64

                def load_config():
                    return Value()
                """
            ),
            encoding="utf-8",
        )
        terminal_copy.write_text(
            textwrap.dedent(
                f"""\
                from __future__ import annotations

                import argparse
                import json
                import os
                import re
                from dataclasses import dataclass

                DEFAULT_TIMEOUT_SECONDS = 30.0
                MAX_TIMEOUT_SECONDS = 3600.0
                DELETE_TIMEOUT_SECONDS = 0.1
                TERMINAL_NAME_PATTERN = re.compile(r"icrn_[0-9a-f]{{32}}")
                REMOTE_ROOT = {REMOTE_ROOT!r}

                class TerminalClientError(Exception):
                    pass

                @dataclass(frozen=True)
                class ExecutionResult:
                    returncode: int
                    timed_out: bool
                    interrupted: bool
                    truncated: bool
                    output_bytes: int

                def _record(event, **values):
                    with open(os.environ["ICRN_SYNTHETIC_AUDIT"], "a", encoding="utf-8") as stream:
                        stream.write(json.dumps({{"event": event, **values}}, sort_keys=True) + "\\n")

                def read_private_token(_path):
                    return "synthetic-token"

                def validate_argv(argv):
                    if not isinstance(argv, list) or not argv:
                        raise TerminalClientError("invalid argv")
                    return list(argv)

                def validate_cwd(cwd, *, root=None):
                    expected = root or REMOTE_ROOT
                    if cwd != expected and not cwd.startswith(expected + "/"):
                        raise TerminalClientError("invalid cwd")
                    return cwd

                def _timeout_argument(value):
                    result = float(value)
                    if not 0 < result <= MAX_TIMEOUT_SECONDS:
                        raise argparse.ArgumentTypeError("timeout outside range")
                    return result

                class FakeSession:
                    def __init__(self, name):
                        self.terminal_name = name
                        self.closed = False
                        self.poisoned = False

                    def run(self, argv, *, cwd, ensure_cwd, timeout_seconds, output):
                        _record(
                            "run",
                            terminal_name=self.terminal_name,
                            argv=argv,
                            cwd=cwd,
                            ensure_cwd=ensure_cwd,
                            timeout_seconds=timeout_seconds,
                        )
                        data = ("ran:" + " ".join(argv) + "\\n").encode()
                        output.write(data)
                        output.flush()
                        return ExecutionResult(0, False, False, False, len(data))

                    def close(self):
                        if not self.closed:
                            _record("session_close", terminal_name=self.terminal_name)
                            self.closed = True

                class JupyterTerminalClient:
                    def __init__(self, _token, config=None):
                        self.root = config.workspace.remote_root

                    def open_session(self, terminal_name=None):
                        if terminal_name is None or TERMINAL_NAME_PATTERN.fullmatch(terminal_name) is None:
                            raise TerminalClientError("invalid terminal name")
                        _record("open", terminal_name=terminal_name)
                        return FakeSession(terminal_name)

                    def cleanup_terminal(self, terminal_name):
                        if TERMINAL_NAME_PATTERN.fullmatch(terminal_name) is None:
                            raise TerminalClientError("invalid cleanup name")
                        _record("cleanup", terminal_name=terminal_name)
                        return True
                """
            ),
            encoding="utf-8",
        )

        environment = os.environ.copy()
        environment.update(
            {
                "CODEX_THREAD_ID": "synthetic-public-cli-integration",
                "ICRN_SYNTHETIC_AUDIT": str(audit),
                "PYTHONPYCACHEPREFIX": str(self.root / "pycache"),
                "XDG_STATE_HOME": str(state),
            }
        )
        base = ["/usr/bin/python3", str(broker_copy)]
        common = ["--scope-root", str(project)]

        def run(operation: str, *arguments: str) -> subprocess.CompletedProcess[bytes]:
            return subprocess.run(
                [*base, operation, *common, *arguments],
                check=False,
                capture_output=True,
                env=environment,
                timeout=10.0,
            )

        first = run(
            "exec",
            "--cwd",
            f"{REMOTE_ROOT}/project",
            "--ensure-cwd",
            "--",
            "first",
        )
        try:
            second = run(
                "exec",
                "--cwd",
                f"{REMOTE_ROOT}/project",
                "--ensure-cwd",
                "--",
                "second",
            )
            status_result = run("status")
            self.assertEqual(first.returncode, 0, first.stderr.decode())
            self.assertEqual(second.returncode, 0, second.stderr.decode())
            self.assertEqual(first.stdout, b"ran:first\n")
            self.assertEqual(second.stdout, b"ran:second\n")
            self.assertEqual(status_result.returncode, 0, status_result.stderr.decode())
            status_value = json.loads(status_result.stdout)
            self.assertEqual(status_value["state"], "idle")
            self.assertEqual(status_value["commands"], 2)
        finally:
            closed = run("close")

        self.assertEqual(closed.returncode, 0, closed.stderr.decode())
        after_close = run("status")
        self.assertEqual(after_close.returncode, 0, after_close.stderr.decode())
        self.assertEqual(json.loads(after_close.stdout)["state"], "closed")
        self.assertEqual(list(state.rglob("broker.sock")), [])
        self.assertEqual(list(state.rglob("lease.json")), [])
        self.assertEqual(list(state.rglob("broker.pid.json")), [])

        records = [
            json.loads(line) for line in audit.read_text(encoding="utf-8").splitlines()
        ]
        opens = [value for value in records if value["event"] == "open"]
        runs = [value for value in records if value["event"] == "run"]
        cleanups = [value for value in records if value["event"] == "cleanup"]
        self.assertEqual(len(opens), 1)
        self.assertEqual([value["argv"] for value in runs], [["first"], ["second"]])
        self.assertEqual(
            {value["terminal_name"] for value in [*opens, *runs, *cleanups]},
            {opens[0]["terminal_name"]},
        )


if __name__ == "__main__":
    unittest.main()
