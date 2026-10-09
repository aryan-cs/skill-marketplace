#!/usr/bin/env python3
"""Behavioral tests for the public Jupyter REST/WebSocket terminal client."""

from __future__ import annotations

import base64
import contextlib
import hashlib
import http.server
import importlib
import io
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import zlib
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
terminal = importlib.import_module("icrn_jupyter_terminal")

TOKEN = "t" * 32
USERNAME = "sample-user"
SERVER_KEY = "named-session"
SERVER_BASE = f"/user/{USERNAME}/{SERVER_KEY}/"
REMOTE_ROOT = "/srv/remote-sandbox"
PROFILE = "environment-key"
IMAGE = "editor-key"
RESOURCE = "accelerator-key"
REMOTE_PYTHON = "/opt/runtime/bin/python3"


def _config() -> Any:
    """Return the narrow validated-config interface consumed by the client."""

    return types.SimpleNamespace(
        origin="https" + "://" + "research.example.illinois.edu",
        identity=types.SimpleNamespace(jupyter_username=USERNAME),
        workspace=types.SimpleNamespace(remote_root=REMOTE_ROOT),
        target=types.SimpleNamespace(
            hub_server_key=SERVER_KEY,
            profile=PROFILE,
            image=IMAGE,
            resource=RESOURCE,
            remote_python=REMOTE_PYTHON,
        ),
    )


@dataclass
class FakeState:
    token: str = TOKEN
    server_url: str = SERVER_BASE
    output: bytes = b"remote output\n"
    returncode: int = 0
    timed_out: bool = False
    no_completion: bool = False
    fragment_messages: bool = False
    post_status: int = 200
    resource_after_post: str | None = None
    terminals: set[str] = field(default_factory=set)
    requests: list[tuple[str, str, bool]] = field(default_factory=list)
    posts: list[dict[str, Any]] = field(default_factory=list)
    deletes: list[str] = field(default_factory=list)
    websocket_paths: list[str] = field(default_factory=list)
    launcher_commands: list[str] = field(default_factory=list)
    payloads: list[dict[str, Any]] = field(default_factory=list)
    interrupts: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)


def _server_frame(opcode: int, payload: bytes, *, final: bool = True) -> bytes:
    first = (0x80 if final else 0) | opcode
    if len(payload) < 126:
        return bytes([first, len(payload)]) + payload
    if len(payload) <= 0xFFFF:
        return bytes([first, 126]) + struct.pack("!H", len(payload)) + payload
    return bytes([first, 127]) + struct.pack("!Q", len(payload)) + payload


def _read_exact(stream: Any, size: int) -> bytes:
    value = stream.read(size)
    if value is None or len(value) != size:
        raise EOFError
    return value


def _read_client_frame(stream: Any) -> tuple[int, bytes]:
    first, second = _read_exact(stream, 2)
    opcode = first & 0x0F
    if first & 0x80 == 0 or second & 0x80 == 0:
        raise AssertionError("client WebSocket frames must be final and masked")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _read_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _read_exact(stream, 8))[0]
    mask = _read_exact(stream, 4)
    payload = _read_exact(stream, length)
    return opcode, bytes(
        value ^ mask[index % 4] for index, value in enumerate(payload)
    )


class FakeHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def state(self) -> FakeState:
        return self.server.fake_state  # type: ignore[attr-defined,no-any-return]

    def log_message(self, *_args: Any) -> None:
        return

    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == f"token {self.state.token}"

    def _record(self) -> None:
        with self.state.lock:
            self.state.requests.append((self.command, self.path, self._authorized()))

    def _json_response(self, status: int, value: Any) -> None:
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        self._record()
        if not self._authorized():
            self._json_response(403, {"error": "forbidden"})
            return
        if self.path == "/hub/api/user":
            resource = (
                self.state.resource_after_post
                if self.state.posts and self.state.resource_after_post is not None
                else RESOURCE
            )
            self._json_response(
                200,
                {
                    "name": USERNAME,
                    "servers": {
                        SERVER_KEY: {
                            "url": self.state.server_url,
                            "ready": True,
                            "pending": None,
                            "user_options": {
                                "profile": PROFILE,
                                "image": IMAGE,
                                "image:unlisted_choice": "",
                                "resource": resource,
                                "resource:unlisted_choice": "",
                            },
                        }
                    },
                },
            )
            return
        if self.path == f"{SERVER_BASE}api/status":
            self._json_response(200, {"connections": 0, "kernels": 0})
            return
        if self.path == f"{SERVER_BASE}api/terminals":
            with self.state.lock:
                models = [{"name": name} for name in sorted(self.state.terminals)]
            self._json_response(200, models)
            return
        if self.path.startswith(f"{SERVER_BASE}terminals/websocket/"):
            self._websocket()
            return
        self._json_response(404, {"error": "not-found"})

    def do_POST(self) -> None:
        self._record()
        if not self._authorized():
            self._json_response(403, {"error": "forbidden"})
            return
        if self.path != f"{SERVER_BASE}api/terminals":
            self._json_response(404, {"error": "not-found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        value = json.loads(_read_exact(self.rfile, length))
        if not isinstance(value, dict):
            raise AssertionError("terminal POST body must be an object")
        with self.state.lock:
            self.state.posts.append(value)
            self.state.terminals.add(value["name"])
        if self.state.post_status != 200:
            self._json_response(self.state.post_status, {"error": "simulated"})
            return
        self._json_response(200, {"name": value["name"]})

    def do_DELETE(self) -> None:
        self._record()
        if not self._authorized():
            self._json_response(403, {"error": "forbidden"})
            return
        prefix = f"{SERVER_BASE}api/terminals/"
        if not self.path.startswith(prefix):
            self._json_response(404, {"error": "not-found"})
            return
        name = self.path.removeprefix(prefix)
        with self.state.lock:
            existed = name in self.state.terminals
            self.state.terminals.discard(name)
            self.state.deletes.append(name)
        self.send_response(204 if existed else 404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _websocket(self) -> None:
        if self.headers.get("Upgrade", "").lower() != "websocket":
            raise AssertionError("missing WebSocket upgrade")
        if self.headers.get("Origin") != self.server.origin:  # type: ignore[attr-defined]
            raise AssertionError("wrong WebSocket origin")
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii"),
                usedforsecurity=False,
            ).digest()
        ).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        with self.state.lock:
            self.state.websocket_paths.append(self.path)
        self.connection.sendall(_server_frame(0x1, json.dumps(["setup", {}]).encode()))

        ready = end = idle = None
        payload_chunks: list[str] = []
        while True:
            try:
                opcode, frame = _read_client_frame(self.rfile)
            except (EOFError, ConnectionError, OSError):
                return
            if opcode == 0x8:
                with contextlib.suppress(OSError):
                    self.connection.sendall(_server_frame(0x8, frame))
                return
            if opcode == 0xA:
                continue
            if opcode != 0x1:
                raise AssertionError(f"unexpected client opcode: {opcode}")
            packet = json.loads(frame)
            if packet[0] == "set_size":
                if packet != ["set_size", 24, 80, 0, 0]:
                    raise AssertionError("unexpected terminal size")
                continue
            if packet[0] != "stdin" or not isinstance(packet[1], str):
                raise AssertionError("unexpected terminal packet")
            value = packet[1]
            if ready is None:
                with self.state.lock:
                    self.state.launcher_commands.append(value)
                match = re.search(r'base64\.b64decode\("([A-Za-z0-9+/=]+)"', value)
                if match is None:
                    raise AssertionError("launcher source was not embedded")
                source = zlib.decompress(base64.b64decode(match.group(1))).decode("utf-8")
                ready_match = re.search(r"READY='([^']+)'", source)
                if ready_match is None:
                    raise AssertionError("ready marker was not embedded")
                ready = ready_match.group(1)
                idle_match = re.search(r"ICRN_DIRECT_IDLE_[0-9a-f]{48}", value)
                if idle_match is None:
                    raise AssertionError("idle marker was not embedded")
                idle = idle_match.group(0)
                self._send_stdout(f"old prompt\r\n\r\n{ready}\r\n")
                continue
            if value == "\x03":
                with self.state.lock:
                    self.state.interrupts += 1
                if self.state.no_completion:
                    if end is None or idle is None:
                        raise AssertionError("interrupt arrived before payload")
                    self._send_stdout(
                        f"\r\n{end}{self._result_marker(130, interrupted=True)}\r\n"
                    )
                    self._send_stdout(f"\r\n{idle}\r\n")
                    ready = end = idle = None
                    payload_chunks.clear()
                continue
            if not value.endswith("\r"):
                raise AssertionError("payload line was not terminated")
            line = value[:-1]
            if line != ".":
                payload_chunks.append(line)
                continue
            payload = json.loads(base64.b64decode("".join(payload_chunks)))
            with self.state.lock:
                self.state.payloads.append(payload)
            nonce = payload["nonce"]
            begin = f"ICRN_DIRECT_BEGIN_{nonce}"
            chunk = f"ICRN_DIRECT_CHUNK_{nonce}:"
            end = f"ICRN_DIRECT_END_{nonce}:"
            self._send_stdout(f"\r\n{begin}\r\n")
            accepted = self.state.output[: payload["max_output_bytes"]]
            output_truncated = accepted != self.state.output
            if accepted:
                encoded = base64.b64encode(accepted).decode("ascii")
                self._send_stdout(f"\r\n{chunk}{encoded}\r\n")
            if self.state.no_completion:
                continue
            returncode = 125 if output_truncated else self.state.returncode
            marker = self._result_marker(
                returncode,
                timed_out=self.state.timed_out,
                output_truncated=output_truncated,
            )
            self._send_stdout(f"\r\n{end}{marker}\r\n")
            if idle is None:
                raise AssertionError("idle marker was unavailable")
            self._send_stdout(f"\r\n{idle}\r\n")
            ready = end = idle = None
            payload_chunks.clear()

    @staticmethod
    def _result_marker(
        returncode: int,
        *,
        timed_out: bool = False,
        interrupted: bool = False,
        output_truncated: bool = False,
    ) -> str:
        raw = json.dumps(
            {
                "interrupted": interrupted,
                "output_truncated": output_truncated,
                "returncode": returncode,
                "timed_out": timed_out,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    def _send_stdout(self, value: str) -> None:
        packet = json.dumps(["stdout", value], separators=(",", ":")).encode()
        if self.state.fragment_messages and len(packet) > 4:
            split = len(packet) // 2
            self.connection.sendall(_server_frame(0x9, b"synthetic-ping"))
            self.connection.sendall(_server_frame(0x1, packet[:split], final=False))
            self.connection.sendall(_server_frame(0x0, packet[split:]))
            return
        self.connection.sendall(_server_frame(0x1, packet))


class FakeServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, _request: Any, _client_address: Any) -> None:
        """Suppress the expected connection reset after the timeout cleanup case."""

        return


@contextlib.contextmanager
def fake_server(state: FakeState) -> Iterator[str]:
    server = FakeServer(("127.0.0.1", 0), FakeHandler)
    server.fake_state = state  # type: ignore[attr-defined]
    server.origin = f"http://127.0.0.1:{server.server_port}"  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.origin  # type: ignore[attr-defined]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def make_client(state: FakeState, origin: str, *, output_limit: int = 4096) -> Any:
    return terminal.JupyterTerminalClient(
        state.token,
        config=_config(),
        origin=origin,
        max_output_bytes=output_limit,
        allow_insecure_for_tests=True,
    )


def run_real_launcher(
    root: Path,
    argv: list[str],
    *,
    cwd: Path | None = None,
    ensure_cwd: bool = False,
    timeout: float = 2.0,
    output_limit: int = 4096,
) -> tuple[bytes, dict[str, Any], float]:
    ready = "ICRN_DIRECT_READY_" + "a" * 48
    nonce = "b" * 48
    source = terminal._remote_launcher_source(ready, root=str(root))
    payload = base64.b64encode(
        json.dumps(
            {
                "nonce": nonce,
                "argv": argv,
                "cwd": str(root if cwd is None else cwd),
                "ensure_cwd": ensure_cwd,
                "timeout": timeout,
                "max_output_bytes": output_limit,
            },
            separators=(",", ":"),
        ).encode()
    )
    started = time.monotonic()
    completed = subprocess.run(
        [sys.executable, "-I", "-S", "-c", source.decode("utf-8")],
        input=payload + b"\n.\n",
        capture_output=True,
        cwd=root,
        env={**os.environ, "PYTHONPATH": str(root)},
        timeout=8,
        check=False,
    )
    elapsed = time.monotonic() - started
    if completed.returncode != 0 or completed.stderr:
        raise AssertionError(
            f"launcher failed: rc={completed.returncode}, stderr={completed.stderr!r}"
        )
    chunks: list[bytes] = []
    result = None
    chunk_prefix = f"ICRN_DIRECT_CHUNK_{nonce}:".encode()
    end_prefix = f"ICRN_DIRECT_END_{nonce}:".encode()
    for line in completed.stdout.splitlines():
        if line.startswith(chunk_prefix):
            chunks.append(base64.b64decode(line.removeprefix(chunk_prefix), validate=True))
        elif line.startswith(end_prefix):
            encoded = line.removeprefix(end_prefix)
            result = json.loads(
                base64.urlsafe_b64decode(encoded + b"=" * (-len(encoded) % 4))
            )
    if result is None:
        raise AssertionError("launcher produced no completion marker")
    return b"".join(chunks), result, elapsed


class TerminalProtocolTests(unittest.TestCase):
    def test_loopback_attestation_argv_output_and_exact_cleanup(self) -> None:
        state = FakeState(output=b"hello \xff\n", returncode=7, fragment_messages=True)
        argv = ["python3", "-c", "print('safe')", "a b", "$(not-executed)"]
        with fake_server(state) as origin:
            sink = io.BytesIO()
            result = make_client(state, origin).run(
                argv,
                cwd="nested",
                timeout_seconds=3,
                output=sink,
            )

        self.assertEqual(result.returncode, 7)
        self.assertFalse(result.timed_out)
        self.assertFalse(result.truncated)
        self.assertEqual(sink.getvalue(), b"hello \xff\n")
        self.assertEqual(state.posts[0]["cwd"], REMOTE_ROOT)
        name = state.posts[0]["name"]
        self.assertRegex(name, r"^icrn_[0-9a-f]{32}$")
        self.assertEqual(state.deletes, [name])
        self.assertEqual(state.terminals, set())
        self.assertEqual(
            state.websocket_paths,
            [f"{SERVER_BASE}terminals/websocket/{name}"],
        )
        self.assertEqual(state.payloads[0]["argv"], argv)
        self.assertEqual(state.payloads[0]["cwd"], f"{REMOTE_ROOT}/nested")
        self.assertEqual(state.payloads[0]["timeout"], 3.0)
        self.assertFalse(state.payloads[0]["ensure_cwd"])
        self.assertTrue(all(authorized for _method, _path, authorized in state.requests))
        self.assertNotIn(TOKEN, state.launcher_commands[0])
        for value in argv[2:]:
            self.assertNotIn(value, state.launcher_commands[0])

    def test_output_limit_drains_and_cleans_terminal(self) -> None:
        state = FakeState(output=("pi" * 100).encode())
        with fake_server(state) as origin:
            sink = io.BytesIO()
            result = make_client(state, origin, output_limit=17).run(
                ["true"], output=sink
            )
        self.assertEqual(result.returncode, 125)
        self.assertTrue(result.truncated)
        self.assertEqual(result.output_bytes, 17)
        self.assertEqual(sink.getvalue(), state.output[:17])
        self.assertEqual(len(state.deletes), 1)

    def test_local_timeout_interrupts_and_still_cleans_terminal(self) -> None:
        state = FakeState(no_completion=True, output=b"partial")
        with (
            mock.patch.object(terminal, "INTERRUPT_GRACE_SECONDS", 0.1),
            fake_server(state) as origin,
            self.assertRaises(terminal.TerminalTimeout),
        ):
            make_client(state, origin).run(["sleep", "60"], timeout_seconds=0.05)
        self.assertEqual(state.interrupts, 1)
        self.assertEqual(len(state.deletes), 1)
        self.assertEqual(state.terminals, set())

    def test_post_create_attestation_failure_cleans_without_websocket(self) -> None:
        state = FakeState(resource_after_post="different-resource")
        with fake_server(state) as origin:
            with self.assertRaisesRegex(
                terminal.TerminalClientError, "exact configured ICRN environment"
            ):
                make_client(state, origin).run(["true"])
        self.assertEqual(len(state.posts), 1)
        self.assertEqual(state.websocket_paths, [])
        self.assertEqual(state.deletes, [state.posts[0]["name"]])

    def test_reusable_session_runs_two_commands_in_one_terminal(self) -> None:
        state = FakeState(output=b"first\n", returncode=9)
        requested = "icrn_" + "1" * 32
        with fake_server(state) as origin:
            client = make_client(state, origin)
            first_sink = io.BytesIO()
            second_sink = io.BytesIO()
            with client.open_session(requested) as session:
                first = session.run(["first"], cwd="one", output=first_sink)
                self.assertEqual(state.deletes, [])
                state.output = b"second\n"
                state.returncode = 0
                second = session.run(["second"], cwd="two", output=second_sink)
                self.assertFalse(session.poisoned)

        self.assertEqual(first.returncode, 9)
        self.assertEqual(second.returncode, 0)
        self.assertEqual(first_sink.getvalue(), b"first\n")
        self.assertEqual(second_sink.getvalue(), b"second\n")
        self.assertEqual(len(state.posts), 1)
        self.assertEqual(len(state.websocket_paths), 1)
        self.assertEqual(state.deletes, [requested])
        self.assertEqual([value["argv"] for value in state.payloads], [["first"], ["second"]])
        self.assertEqual(
            [value["cwd"] for value in state.payloads],
            [f"{REMOTE_ROOT}/one", f"{REMOTE_ROOT}/two"],
        )
        self.assertNotEqual(state.payloads[0]["nonce"], state.payloads[1]["nonce"])

    def test_invalid_argv_and_cwd_fail_before_network(self) -> None:
        client = terminal.JupyterTerminalClient(
            TOKEN,
            config=_config(),
            origin="http://127.0.0.1:1",
            allow_insecure_for_tests=True,
        )
        with self.assertRaisesRegex(terminal.TerminalClientError, "configured remote root"):
            client.run(["true"], cwd="../escape")
        with self.assertRaisesRegex(terminal.TerminalClientError, "argv"):
            client.run([])

    def test_real_launcher_preserves_binary_exit_output_cap_and_timeout(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="icrn-launcher-", dir="/private/tmp"
        ) as temporary:
            root = Path(temporary)
            child = (
                "import os,sys; "
                "os.write(sys.stdout.fileno(),b'out\\xff'); "
                "os.write(sys.stderr.fileno(),b'err'); "
                "raise SystemExit(23)"
            )
            output, result, _elapsed = run_real_launcher(
                root, [sys.executable, "-c", child]
            )
            self.assertEqual(output, b"out\xfferr")
            self.assertEqual(result["returncode"], 23)
            self.assertFalse(result["timed_out"])

            output, result, _elapsed = run_real_launcher(
                root,
                [sys.executable, "-c", "import os; os.write(1,b'x'*1000000)"],
                output_limit=17,
            )
            self.assertEqual(output, b"x" * 17)
            self.assertEqual(result["returncode"], 125)
            self.assertTrue(result["output_truncated"])

            output, result, elapsed = run_real_launcher(
                root,
                [sys.executable, "-c", "import time; time.sleep(30)"],
                timeout=0.05,
            )
            self.assertEqual(output, b"")
            self.assertEqual(result["returncode"], 124)
            self.assertTrue(result["timed_out"])
            self.assertLess(elapsed, 4)

    def test_real_launcher_cwd_creation_reuse_and_symlink_confinement(self) -> None:
        with (
            tempfile.TemporaryDirectory(prefix="icrn-root-", dir="/private/tmp") as remote,
            tempfile.TemporaryDirectory(
                prefix="icrn-outside-", dir="/private/tmp"
            ) as outside,
        ):
            root = Path(remote)
            existing = root / "existing"
            existing.mkdir()
            inode = existing.stat().st_ino
            output, result, _elapsed = run_real_launcher(
                root,
                [sys.executable, "-c", "import os; print(os.getcwd())"],
                cwd=existing,
                ensure_cwd=True,
            )
            self.assertEqual(output.decode().strip(), str(existing))
            self.assertEqual(result["returncode"], 0)
            self.assertEqual(existing.stat().st_ino, inode)

            missing = root / "new" / "nested"
            output, result, _elapsed = run_real_launcher(
                root,
                [sys.executable, "-c", "import os; print(os.getcwd())"],
                cwd=missing,
                ensure_cwd=True,
            )
            self.assertEqual(output.decode().strip(), str(missing))
            self.assertEqual(result["returncode"], 0)
            created_inode = missing.stat().st_ino
            run_real_launcher(root, ["true"], cwd=missing, ensure_cwd=True)
            self.assertEqual(missing.stat().st_ino, created_inode)

            link = root / "escape-link"
            link.symlink_to(Path(outside), target_is_directory=True)
            escaped = Path(outside) / "must-not-exist"
            _output, result, _elapsed = run_real_launcher(
                root,
                ["true"],
                cwd=link / escaped.name,
                ensure_cwd=True,
            )
            self.assertEqual(result["error"], "cwd_invalid")
            self.assertFalse(escaped.exists())


if __name__ == "__main__":
    unittest.main()
