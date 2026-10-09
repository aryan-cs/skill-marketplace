#!/usr/bin/env python3
# ruff: noqa: E501, UP038 -- remote launcher is minified and must run on Python 3.9.
"""Run argv commands through authenticated ICRN Jupyter terminals.

The client talks directly to the JupyterHub and single-user Jupyter Server APIs.  It
can keep one cryptographically named terminal for sequential commands in a bounded session;
the compatibility CLI creates one for one command and deletes that exact terminal on every
handled exit path.  User argv values are carried as JSON/base64 data to a fixed Python
launcher; they are never interpolated into a shell command.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import shlex
import signal
import socket
import ssl
import stat
import struct
import sys
import threading
import time
import zlib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO
from urllib.parse import quote, urljoin, urlsplit

import icrn_config

DEFAULT_TIMEOUT_SECONDS = 30.0
MAX_TIMEOUT_SECONDS = 3_600.0
DEFAULT_MAX_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_HTTP_BODY_BYTES = 1024 * 1024
MAX_WEBSOCKET_MESSAGE_BYTES = 1024 * 1024
MAX_ARGV_ITEMS = 256
MAX_ARGV_BYTES = 64 * 1024
# A valid command may consist entirely of JSON control characters (six encoded bytes
# per input byte), plus the bounded cwd and envelope, before base64's 4/3 expansion.
# Keep this shared local/remote cap above that true worst case so every argv accepted
# by validate_argv remains transportable.
MAX_PAYLOAD_BASE64_BYTES = 768 * 1024
MAX_CWD_BYTES = 4_096
MAX_TOKEN_BYTES = 4_096
PAYLOAD_CHUNK_BYTES = 1_024
READY_TIMEOUT_SECONDS = 10.0
INTERRUPT_GRACE_SECONDS = 4.0
DELETE_TIMEOUT_SECONDS = 10.0
TERMINAL_NAME_PATTERN = re.compile(r"icrn_[0-9a-f]{32}")


class TerminalClientError(Exception):
    """An expected, sanitized client or remote-protocol failure."""


class TerminalTimeout(TerminalClientError):
    """The terminal did not produce its authenticated completion marker in time."""


class TerminalCleanupInterrupt(KeyboardInterrupt):
    """Ctrl-C succeeded locally, but exact remote-terminal cleanup was unverified."""


class TerminalProcessSignal(BaseException):
    """A handled local TERM/HUP that must unwind through exact terminal cleanup."""

    def __init__(self, signum: int, cleanup_message: str | None = None) -> None:
        super().__init__(cleanup_message)
        self.signum = signum
        self.cleanup_message = cleanup_message


@dataclass(frozen=True)
class ExecutionResult:
    returncode: int
    timed_out: bool
    interrupted: bool
    truncated: bool
    output_bytes: int


def read_private_token(path: Path) -> str:
    """Read an ASCII token from one exact current-user mode-0600 regular file."""

    expanded = path.expanduser()
    try:
        before = expanded.lstat()
    except OSError as error:
        raise TerminalClientError(
            f"Could not inspect the private token file: {error.strerror}."
        ) from None
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise TerminalClientError("The token path must be a regular non-symlink file.")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(expanded, flags)
    except OSError as error:
        raise TerminalClientError(
            f"Could not open the private token file: {error.strerror}."
        ) from None
    try:
        current = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise TerminalClientError("The token file changed while it was being opened.")
        if not stat.S_ISREG(current.st_mode):
            raise TerminalClientError("The token file is not regular.")
        if current.st_uid != os.getuid():
            raise TerminalClientError("The token file is not owned by the current user.")
        if stat.S_IMODE(current.st_mode) != 0o600:
            raise TerminalClientError("The token file must have mode 0600.")
        if current.st_nlink != 1:
            raise TerminalClientError("The token file must have exactly one hard link.")
        data = bytearray()
        while len(data) <= MAX_TOKEN_BYTES:
            chunk = os.read(descriptor, min(1024, MAX_TOKEN_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
    finally:
        os.close(descriptor)
    if not data or len(data) > MAX_TOKEN_BYTES:
        raise TerminalClientError("The token file is empty or too large.")
    if data.endswith(b"\n"):
        del data[-1:]
    if not data or any(byte < 0x21 or byte > 0x7E for byte in data):
        raise TerminalClientError("The token file must contain one nonempty printable ASCII line.")
    try:
        return data.decode("ascii")
    except UnicodeDecodeError:
        raise TerminalClientError("The token file must contain an ASCII token.") from None


def validate_argv(argv: list[str]) -> list[str]:
    if not argv or len(argv) > MAX_ARGV_ITEMS:
        raise TerminalClientError(f"argv must contain between 1 and {MAX_ARGV_ITEMS} items.")
    total = 0
    for value in argv:
        if not isinstance(value, str) or not value or "\0" in value:
            raise TerminalClientError(
                "Every argv item must be a nonempty string without NUL bytes."
            )
        total += len(value.encode("utf-8"))
    if total > MAX_ARGV_BYTES:
        raise TerminalClientError(f"argv exceeds the {MAX_ARGV_BYTES}-byte limit.")
    return list(argv)


def _runtime_config() -> icrn_config.ICRNConfig:
    try:
        return icrn_config.load_config()
    except icrn_config.ConfigError as error:
        raise TerminalClientError(str(error)) from None


def validate_cwd(cwd: str, *, root: str | None = None) -> str:
    if not isinstance(cwd, str) or not cwd or "\0" in cwd:
        raise TerminalClientError("cwd must be a nonempty path without NUL bytes.")
    if len(cwd.encode("utf-8")) > MAX_CWD_BYTES:
        raise TerminalClientError("cwd exceeds the byte limit.")
    configured_root = root if root is not None else _runtime_config().workspace.remote_root
    root_path = PurePosixPath(configured_root)
    candidate = PurePosixPath(cwd)
    if not candidate.is_absolute():
        candidate = root_path / candidate
    normalized = PurePosixPath(os.path.normpath(str(candidate)))
    try:
        normalized.relative_to(root_path)
    except ValueError:
        raise TerminalClientError("cwd must remain inside the configured remote root.") from None
    return str(normalized)


class _NoRedirectJSONClient:
    def __init__(
        self,
        origin: str,
        token: str,
        *,
        timeout_seconds: float = 15.0,
        allow_insecure_for_tests: bool = False,
    ) -> None:
        parsed = urlsplit(origin)
        if parsed.scheme not in ({"http", "https"} if allow_insecure_for_tests else {"https"}):
            raise TerminalClientError("The Jupyter origin must use HTTPS.")
        if (
            not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or parsed.path not in {"", "/"}
        ):
            raise TerminalClientError("The Jupyter origin is invalid.")
        self.origin = f"{parsed.scheme}://{parsed.netloc}"
        self.parsed = parsed
        self.token = token
        self.timeout_seconds = timeout_seconds
        self.allow_insecure_for_tests = allow_insecure_for_tests

    def _connection(self, timeout: float | None = None) -> http.client.HTTPConnection:
        request_timeout = self.timeout_seconds if timeout is None else timeout
        if self.parsed.scheme == "https":
            return http.client.HTTPSConnection(
                self.parsed.hostname,
                self.parsed.port,
                timeout=request_timeout,
                context=ssl.create_default_context(),
            )
        return http.client.HTTPConnection(
            self.parsed.hostname,
            self.parsed.port,
            timeout=request_timeout,
        )

    def request_json(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
        expected: set[int] | None = None,
        timeout: float | None = None,
    ) -> tuple[int, Any]:
        if not path.startswith("/") or "\r" in path or "\n" in path:
            raise TerminalClientError("Refused an invalid Jupyter API path.")
        body = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"token {self.token}",
            "Cache-Control": "no-store",
            "Origin": self.origin,
        }
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("ascii")
            headers["Content-Type"] = "application/json"
        connection = self._connection(timeout)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            declared = response.getheader("Content-Length")
            if declared is not None:
                try:
                    if int(declared) > MAX_HTTP_BODY_BYTES:
                        raise TerminalClientError("A Jupyter API response exceeded the byte limit.")
                except ValueError:
                    raise TerminalClientError(
                        "A Jupyter API response had an invalid length."
                    ) from None
            response_body = response.read(MAX_HTTP_BODY_BYTES + 1)
            if len(response_body) > MAX_HTTP_BODY_BYTES:
                raise TerminalClientError("A Jupyter API response exceeded the byte limit.")
            status = response.status
            allowed = expected if expected is not None else {200}
            if status not in allowed:
                raise TerminalClientError(
                    f"A Jupyter API {method} request returned HTTP {status}."
                )
            if not response_body:
                return status, None
            content_type = response.getheader("Content-Type", "").lower()
            if "json" not in content_type:
                raise TerminalClientError("A Jupyter API response was not JSON.")
            try:
                decoded = response_body.decode("utf-8")
                return status, json.loads(decoded)
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise TerminalClientError(
                    "A Jupyter API response contained invalid JSON."
                ) from None
        except (OSError, http.client.HTTPException, TimeoutError) as error:
            raise TerminalClientError(
                f"A Jupyter API {method} request failed ({type(error).__name__})."
            ) from None
        finally:
            connection.close()


class _WebSocket:
    """Small RFC 6455 text client sufficient for Jupyter's terminal protocol."""

    def __init__(self, sock: socket.socket, buffered: bytes = b"") -> None:
        self.sock = sock
        self.buffered = bytearray(buffered)
        self.closed = False

    @classmethod
    def connect(
        cls,
        rest: _NoRedirectJSONClient,
        path: str,
        *,
        timeout: float,
    ) -> _WebSocket:
        host = rest.parsed.hostname
        if host is None:
            raise TerminalClientError("The WebSocket host is invalid.")
        port = rest.parsed.port or (443 if rest.parsed.scheme == "https" else 80)
        try:
            raw = socket.create_connection((host, port), timeout=timeout)
            if rest.parsed.scheme == "https":
                raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
            raw.settimeout(timeout)
            key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
            host_header = host if port in {80, 443} else f"{host}:{port}"
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host_header}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                f"Origin: {rest.origin}\r\n"
                f"Authorization: token {rest.token}\r\n"
                "Cache-Control: no-store\r\n\r\n"
            ).encode("ascii")
            raw.sendall(request)
            response = bytearray()
            while b"\r\n\r\n" not in response:
                chunk = raw.recv(4096)
                if not chunk:
                    raise TerminalClientError("The terminal WebSocket closed during its handshake.")
                response.extend(chunk)
                if len(response) > 64 * 1024:
                    raise TerminalClientError("The terminal WebSocket handshake was too large.")
            header_block, buffered = bytes(response).split(b"\r\n\r\n", 1)
            try:
                lines = header_block.decode("ascii").split("\r\n")
            except UnicodeDecodeError:
                raise TerminalClientError("The terminal WebSocket handshake was invalid.") from None
            if not lines or not re.fullmatch(r"HTTP/1\.[01] 101(?: .*)?", lines[0]):
                status = lines[0].split(" ", 2)[1] if lines and " " in lines[0] else "invalid"
                raise TerminalClientError(
                    f"The terminal WebSocket handshake returned HTTP {status}."
                )
            headers: dict[str, list[str]] = {}
            for line in lines[1:]:
                if ":" not in line:
                    raise TerminalClientError("The terminal WebSocket handshake was malformed.")
                name, value = line.split(":", 1)
                headers.setdefault(name.strip().lower(), []).append(value.strip())
            if "websocket" not in ",".join(headers.get("upgrade", [])).lower().split(","):
                raise TerminalClientError("The terminal WebSocket upgrade header was invalid.")
            connection_tokens = {
                item.strip().lower()
                for value in headers.get("connection", [])
                for item in value.split(",")
            }
            if "upgrade" not in connection_tokens:
                raise TerminalClientError("The terminal WebSocket connection header was invalid.")
            accepts = headers.get("sec-websocket-accept", [])
            expected_accept = base64.b64encode(
                hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii"),
                    usedforsecurity=False,
                ).digest()
            ).decode("ascii")
            if len(accepts) != 1 or not hmac.compare_digest(accepts[0], expected_accept):
                raise TerminalClientError("The terminal WebSocket accept value was invalid.")
            if "sec-websocket-extensions" in headers or "sec-websocket-protocol" in headers:
                raise TerminalClientError(
                    "The terminal WebSocket selected an unsolicited extension or subprotocol."
                )
            return cls(raw, buffered)
        except TerminalClientError:
            with contextlib.suppress(OSError, UnboundLocalError):
                raw.close()
            raise
        except (OSError, ssl.SSLError, TimeoutError) as error:
            with contextlib.suppress(OSError, UnboundLocalError):
                raw.close()
            raise TerminalClientError(
                f"The terminal WebSocket connection failed ({type(error).__name__})."
            ) from None

    def _recv_exact(self, count: int, deadline: float) -> bytes:
        while len(self.buffered) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TerminalTimeout("Timed out waiting for terminal output.")
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(max(4096, count - len(self.buffered)))
            # macOS /usr/bin/python3 3.9 does not alias socket.timeout to
            # TimeoutError, even though newer Python versions do.
            except socket.timeout:  # noqa: UP041
                raise TerminalTimeout("Timed out waiting for terminal output.") from None
            if not chunk:
                raise TerminalClientError("The terminal WebSocket closed unexpectedly.")
            self.buffered.extend(chunk)
        result = bytes(self.buffered[:count])
        del self.buffered[:count]
        return result

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.closed:
            raise TerminalClientError("The terminal WebSocket is closed.")
        mask = secrets.token_bytes(4)
        length = len(payload)
        if length < 126:
            header = bytes([0x80 | opcode, 0x80 | length])
        elif length <= 0xFFFF:
            header = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack("!H", length)
        else:
            header = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack("!Q", length)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        try:
            self.sock.sendall(header + mask + masked)
        except OSError as error:
            raise TerminalClientError(
                f"Writing to the terminal WebSocket failed ({type(error).__name__})."
            ) from None

    def send_json(self, value: list[Any]) -> None:
        payload = json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("ascii")
        if len(payload) > MAX_WEBSOCKET_MESSAGE_BYTES:
            raise TerminalClientError("A terminal input message exceeded the byte limit.")
        self._send_frame(0x1, payload)

    def receive_text(self, deadline: float) -> str:
        fragments = bytearray()
        expected_continuation = False
        while True:
            first, second = self._recv_exact(2, deadline)
            fin = bool(first & 0x80)
            opcode = first & 0x0F
            if first & 0x70 or second & 0x80:
                raise TerminalClientError("The terminal WebSocket sent an invalid frame.")
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2, deadline))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8, deadline))[0]
                if length & (1 << 63):
                    raise TerminalClientError(
                        "The terminal WebSocket sent an invalid frame length."
                    )
            if opcode >= 0x8:
                if not fin or length > 125:
                    raise TerminalClientError(
                        "The terminal WebSocket sent an invalid control frame."
                    )
                control = self._recv_exact(length, deadline)
                if opcode == 0x8:
                    if not self.closed:
                        self._send_frame(0x8, control[:125])
                    self.closed = True
                    raise TerminalClientError(
                        "The terminal WebSocket closed before command completion."
                    )
                if opcode == 0x9:
                    self._send_frame(0xA, control)
                elif opcode != 0xA:
                    raise TerminalClientError(
                        "The terminal WebSocket sent an unknown control frame."
                    )
                continue
            if opcode == 0x1:
                if expected_continuation or fragments:
                    raise TerminalClientError("The terminal WebSocket sent nested text messages.")
                expected_continuation = not fin
            elif opcode == 0x0:
                if not expected_continuation:
                    raise TerminalClientError(
                        "The terminal WebSocket sent an unexpected continuation."
                    )
                expected_continuation = not fin
            else:
                raise TerminalClientError("The terminal WebSocket sent a non-text message.")
            if len(fragments) + length > MAX_WEBSOCKET_MESSAGE_BYTES:
                raise TerminalClientError("A terminal WebSocket message exceeded the byte limit.")
            fragments.extend(self._recv_exact(length, deadline))
            if fin:
                try:
                    return fragments.decode("utf-8")
                except UnicodeDecodeError:
                    raise TerminalClientError(
                        "The terminal WebSocket sent invalid UTF-8."
                    ) from None

    def close(self) -> None:
        if self.closed:
            return
        with contextlib.suppress(TerminalClientError):
            self._send_frame(0x8, struct.pack("!H", 1000))
        self.closed = True
        with contextlib.suppress(OSError):
            self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()


def _remote_launcher_source(ready: str, *, root: str) -> bytes:
    source = f"""import base64,json,os,pathlib,selectors,signal,subprocess,sys,time
READY={ready!r}; ROOT=pathlib.Path({root!r}); child=None
def emit(value):
    sys.stdout.write("\\n"+value+"\\n"); sys.stdout.flush()
def marker(kind,nonce): return "ICRN_DIRECT_"+kind+"_"+nonce+(":" if kind in ("CHUNK","END") else "")
def finish(nonce,returncode,timed_out=False,interrupted=False,truncated=False,error=None):
    value={{"returncode":int(returncode),"timed_out":bool(timed_out),"interrupted":bool(interrupted),"output_truncated":bool(truncated)}}
    if error is not None: value["error"]=error
    encoded=base64.urlsafe_b64encode(json.dumps(value,separators=(",",":"),sort_keys=True).encode()).decode().rstrip("=")
    emit(marker("END",nonce)+encoded)
def stop_group(sig):
    if child is not None:
        try: os.killpg(child.pid,sig)
        except (ProcessLookupError,PermissionError): pass
def reap_group(first_signal):
    if child is None: return
    stop_group(first_signal)
    try: child.wait(timeout=2)
    except subprocess.TimeoutExpired: stop_group(signal.SIGKILL); child.wait()
    time.sleep(0.05); stop_group(signal.SIGKILL)
def interrupted(sig,frame):
    reap_group(sig); raise KeyboardInterrupt
signal.signal(signal.SIGINT,interrupted); signal.signal(signal.SIGTERM,interrupted); signal.signal(signal.SIGHUP,interrupted)
emit(READY); nonce="0"*48
try:
    chunks=[]; total=0
    while True:
        line=sys.stdin.buffer.readline({PAYLOAD_CHUNK_BYTES + 2})
        if not line: raise ValueError("payload_eof")
        line=line.rstrip(b"\\r\\n")
        if line==b".": break
        if len(line)>{PAYLOAD_CHUNK_BYTES}: raise ValueError("payload_chunk")
        total+=len(line)
        if total>{MAX_PAYLOAD_BASE64_BYTES}: raise ValueError("payload_size")
        chunks.append(line)
    payload=json.loads(base64.b64decode(b"".join(chunks),validate=True))
    nonce=payload.get("nonce")
    if not isinstance(nonce,str) or len(nonce)!=48 or any(c not in "0123456789abcdef" for c in nonce): raise ValueError("nonce_invalid")
    emit(marker("BEGIN",nonce))
    argv=payload.get("argv"); cwd_value=payload.get("cwd"); ensure_cwd=payload.get("ensure_cwd")
    timeout=float(payload.get("timeout")); output_limit=payload.get("max_output_bytes")
    if not isinstance(argv,list) or not argv or len(argv)>{MAX_ARGV_ITEMS}: raise ValueError("argv_invalid")
    if any(not isinstance(item,str) or not item or "\\0" in item for item in argv): raise ValueError("argv_invalid")
    if sum(len(item.encode()) for item in argv)>{MAX_ARGV_BYTES}: raise ValueError("argv_size")
    if not isinstance(cwd_value,str) or "\\0" in cwd_value: raise ValueError("cwd_invalid")
    if not isinstance(ensure_cwd,bool): raise ValueError("ensure_cwd_invalid")
    if not isinstance(output_limit,int) or isinstance(output_limit,bool) or not 0<=output_limit<=64*1024*1024: raise ValueError("output_limit_invalid")
    if not 0<timeout<={MAX_TIMEOUT_SECONDS}: raise ValueError("timeout_invalid")
    requested=pathlib.PurePosixPath(cwd_value)
    try: parts=requested.relative_to(pathlib.PurePosixPath(ROOT)).parts
    except ValueError: raise ValueError("cwd_escape")
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    try:
        cwd_fd=os.open(ROOT,flags)
        for part in parts:
            if part in ("",".",".."): raise ValueError("cwd_invalid")
            if ensure_cwd:
                try: os.mkdir(part,0o700,dir_fd=cwd_fd)
                except FileExistsError: pass
            next_fd=os.open(part,flags,dir_fd=cwd_fd); os.close(cwd_fd); cwd_fd=next_fd
        os.fchdir(cwd_fd); os.close(cwd_fd)
    except OSError: raise ValueError("cwd_invalid")
    if os.path.realpath(".")!=cwd_value: raise ValueError("cwd_mismatch")
    child=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,bufsize=0)
    assert child.stdout is not None
    selector=selectors.DefaultSelector(); selector.register(child.stdout,selectors.EVENT_READ)
    deadline=time.monotonic()+timeout; observed=0; truncated=False; timed_out=False; forced_cleanup=False; drain_deadline=None
    while selector.get_map():
        if drain_deadline is not None and time.monotonic()>=drain_deadline: break
        remaining=deadline-time.monotonic()
        if remaining<=0 and not forced_cleanup:
            timed_out=True; forced_cleanup=True; reap_group(signal.SIGTERM); drain_deadline=time.monotonic()+1
        events=selector.select(0.1 if forced_cleanup else min(0.1,max(0,remaining)))
        if not events and drain_deadline is not None and time.monotonic()>=drain_deadline: break
        for key,_mask in events:
            data=os.read(key.fd,65536)
            if not data:
                selector.unregister(key.fileobj); continue
            available=max(0,output_limit-observed); accepted=data[:available]
            if accepted:
                observed+=len(accepted); emit(marker("CHUNK",nonce)+base64.b64encode(accepted).decode())
            if len(accepted)!=len(data) and not truncated:
                truncated=True; forced_cleanup=True; reap_group(signal.SIGTERM); drain_deadline=time.monotonic()+1
    selector.close(); child.stdout.close()
    if child.returncode is None:
        try: child.wait(timeout=max(0,deadline-time.monotonic()))
        except subprocess.TimeoutExpired: timed_out=True; reap_group(signal.SIGTERM)
    direct_returncode=child.wait()
    stop_group(signal.SIGTERM); time.sleep(0.05); stop_group(signal.SIGKILL)
    returncode=124 if timed_out else (125 if truncated else direct_returncode)
    finish(nonce,returncode,timed_out=timed_out,truncated=truncated)
except KeyboardInterrupt:
    reap_group(signal.SIGINT); finish(nonce,130,interrupted=True)
except (OSError,ValueError,TypeError,json.JSONDecodeError,base64.binascii.Error) as error:
    reap_group(signal.SIGTERM)
    code=str(error) if isinstance(error,ValueError) else "launcher_failure"
    finish(nonce,126,error=code)
except BaseException:
    reap_group(signal.SIGTERM); finish(nonce,126,error="launcher_failure")
finally:
    if child is not None:
        stop_group(signal.SIGTERM); time.sleep(0.05); stop_group(signal.SIGKILL)
        if child.returncode is None:
            try: child.wait(timeout=1)
            except subprocess.TimeoutExpired: stop_group(signal.SIGKILL); child.wait()
"""
    return source.encode("utf-8")


def _remote_shell_command(source: bytes, *, remote_python: str, idle: str) -> str:
    """Build the fixed loader command with one shell-quoted configured executable."""

    compressed = base64.b64encode(zlib.compress(source, level=9)).decode("ascii")
    python_command = shlex.quote(remote_python)
    shell_command = (
        "if command stty -echo; then trap 'command stty echo' EXIT HUP INT TERM; "
        f"command {python_command} -I -S -c 'import base64,zlib;exec(compile(zlib.decompress(base64.b64decode(\""
        + compressed
        + '")),"<icrn-direct>","exec"))\'; '
        "command stty echo && trap - EXIT HUP INT TERM && "
        f"command printf '\\n{idle}\\n'; else false; fi"
    )
    if len(shell_command.encode("ascii")) > MAX_CWD_BYTES:
        raise TerminalClientError("The fixed remote launcher exceeded its safe line limit.")
    return shell_command


class _MarkerParser:
    def __init__(
        self,
        ready: str,
        begin: str,
        chunk: str,
        end: str,
        idle: str,
        emit: Callable[[bytes], None],
    ) -> None:
        self.ready_needle = f"\n{ready}\n"
        self.begin_needle = f"\n{begin}\n"
        self.chunk_prefix = chunk
        self.end_prefix = end
        self.idle_needle = f"\n{idle}\n"
        self.emit = emit
        self.stage = "ready"
        self.buffer = ""
        self.trailing_cr = False
        self.result: dict[str, Any] | None = None

    def feed(self, data: str) -> None:
        if self.trailing_cr:
            data = "\r" + data
            self.trailing_cr = False
        if data.endswith("\r"):
            data = data[:-1]
            self.trailing_cr = True
        self.buffer += data.replace("\r\n", "\n")
        while True:
            if self.stage == "ready":
                if not self._discard_through(self.ready_needle):
                    return
                self.stage = "begin"
                continue
            if self.stage == "begin":
                if not self._discard_through(self.begin_needle):
                    return
                self.stage = "output"
                continue
            if self.stage == "output":
                newline = self.buffer.find("\n")
                if newline < 0:
                    if len(self.buffer) > 2 * MAX_WEBSOCKET_MESSAGE_BYTES:
                        raise TerminalClientError(
                            "A terminal protocol line exceeded the byte limit."
                        )
                    return
                line = self.buffer[:newline]
                self.buffer = self.buffer[newline + 1 :]
                if not line:
                    continue
                if line.startswith(self.chunk_prefix):
                    encoded = line.removeprefix(self.chunk_prefix)
                    try:
                        decoded = base64.b64decode(encoded, validate=True)
                    except (ValueError, base64.binascii.Error):
                        raise TerminalClientError("A terminal output chunk was invalid.") from None
                    if len(decoded) > 65_536:
                        raise TerminalClientError(
                            "A terminal output chunk exceeded the byte limit."
                        )
                    self.emit(decoded)
                    continue
                if line.startswith(self.end_prefix):
                    self._parse_result(line.removeprefix(self.end_prefix))
                    self.stage = "idle"
                    continue
                raise TerminalClientError("The terminal launcher emitted an invalid protocol line.")
            if self.stage == "idle":
                if not self._discard_through(self.idle_needle):
                    return
                self.stage = "done"
                return
            return

    def _parse_result(self, encoded: str) -> None:
        if len(encoded) > 4096:
            raise TerminalClientError("The terminal result marker was too large.")
        try:
            padding = "=" * (-len(encoded) % 4)
            value = json.loads(base64.b64decode(encoded + padding, altchars=b"-_", validate=True))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            raise TerminalClientError("The terminal result marker was invalid.") from None
        if not isinstance(value, dict):
            raise TerminalClientError("The terminal result marker was invalid.")
        self.result = value

    def _discard_through(self, needle: str) -> bool:
        location = self.buffer.find(needle)
        if location < 0:
            keep = len(needle) - 1
            if len(self.buffer) > keep:
                self.buffer = self.buffer[-keep:]
            return False
        self.buffer = self.buffer[location + len(needle) :]
        return True


class JupyterTerminalClient:
    def __init__(
        self,
        token: str,
        *,
        config: icrn_config.ICRNConfig | None = None,
        origin: str | None = None,
        username: str | None = None,
        root: str | None = None,
        server_key: str | None = None,
        profile: str | None = None,
        image: str | None = None,
        resource: str | None = None,
        remote_python: str | None = None,
        max_output_bytes: int = DEFAULT_MAX_OUTPUT_BYTES,
        allow_insecure_for_tests: bool = False,
    ) -> None:
        configured = config or _runtime_config()
        overrides = (origin, username, root, server_key, profile, image, resource, remote_python)
        if any(value is not None for value in overrides) and not allow_insecure_for_tests:
            raise TerminalClientError("Target overrides are allowed only by the test harness.")
        origin = configured.origin if origin is None else origin
        username = configured.identity.jupyter_username if username is None else username
        root = configured.workspace.remote_root if root is None else root
        server_key = configured.target.hub_server_key if server_key is None else server_key
        profile = configured.target.profile if profile is None else profile
        image = configured.target.image if image is None else image
        resource = configured.target.resource if resource is None else resource
        remote_python = configured.target.remote_python if remote_python is None else remote_python
        if not isinstance(max_output_bytes, int) or not 0 <= max_output_bytes <= 64 * 1024 * 1024:
            raise TerminalClientError("The output byte limit is invalid.")
        if not all(
            isinstance(value, str)
            for value in (username, root, server_key, profile, image, resource, remote_python)
        ):
            raise TerminalClientError("The configured Jupyter target is invalid.")
        self.username = username
        self.root = root
        self.server_key = server_key
        self.expected_options = {
            "profile": profile,
            "image": image,
            "resource": resource,
        }
        self.remote_python = remote_python
        self.max_output_bytes = max_output_bytes
        self.rest = _NoRedirectJSONClient(
            origin,
            token,
            allow_insecure_for_tests=allow_insecure_for_tests,
        )
        if server_key:
            self.server_base = (
                f"/user/{quote(username, safe='')}/{quote(server_key, safe='')}/"
            )
        else:
            self.server_base = f"/user/{quote(username, safe='')}/"

    def attest(self) -> set[str]:
        _, user = self.rest.request_json("GET", "/hub/api/user")
        if not isinstance(user, dict) or user.get("name") != self.username:
            raise TerminalClientError("JupyterHub returned an unexpected current-user model.")
        servers = user.get("servers")
        if (
            not isinstance(servers, dict)
            or self.server_key not in servers
            or not isinstance(servers[self.server_key], dict)
        ):
            raise TerminalClientError("JupyterHub did not report the exact configured server.")
        server = servers[self.server_key]
        options = server.get("user_options")
        expected_semantic_options = self.expected_options
        expected_options_with_empty_choices = {
            **expected_semantic_options,
            "image:unlisted_choice": "",
            "resource:unlisted_choice": "",
        }
        server_url = server.get("url")
        if not isinstance(server_url, str):
            raise TerminalClientError("JupyterHub returned an invalid configured-server URL.")
        resolved = urlsplit(urljoin(self.rest.origin, server_url))
        if (
            f"{resolved.scheme}://{resolved.netloc}" != self.rest.origin
            or resolved.path != self.server_base
            or resolved.query
            or resolved.fragment
            or server.get("ready") is not True
            or server.get("pending") is not None
            or options not in (expected_semantic_options, expected_options_with_empty_choices)
        ):
            raise TerminalClientError(
                "The server is not the exact configured ICRN environment."
            )
        _, status = self.rest.request_json("GET", f"{self.server_base}api/status")
        if not isinstance(status, dict):
            raise TerminalClientError("The single-user Jupyter status response was invalid.")
        _, models = self.rest.request_json("GET", f"{self.server_base}api/terminals")
        if not isinstance(models, list):
            raise TerminalClientError("The Jupyter terminal inventory was invalid.")
        names: set[str] = set()
        for model in models:
            name = model.get("name") if isinstance(model, dict) else None
            if not isinstance(name, str):
                raise TerminalClientError("The Jupyter terminal inventory was invalid.")
            names.add(name)
        return names

    def _cleanup_owned_terminal(
        self,
        websocket: _WebSocket | None,
        terminal_name: str,
        creation_attempted: bool,
    ) -> tuple[BaseException | None, BaseException | None, BaseException | None]:
        close_error: BaseException | None = None
        cleanup_error: BaseException | None = None
        deferred_signal: BaseException | None = None
        cleanup_signals = {
            value
            for value in (getattr(signal, "SIGHUP", None), signal.SIGINT, signal.SIGTERM)
            if value is not None
        }
        old_mask: set[signal.Signals] | None = None
        if hasattr(signal, "pthread_sigmask"):
            try:
                old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, cleanup_signals)
            except BaseException as error:
                deferred_signal = error
        try:
            try:
                if websocket is not None:
                    websocket.close()
            except BaseException as error:
                close_error = error
            finally:
                if creation_attempted:
                    for attempt in range(2):
                        try:
                            self.rest.request_json(
                                "DELETE",
                                f"{self.server_base}api/terminals/{quote(terminal_name, safe='')}",
                                expected={204, 404},
                                timeout=DELETE_TIMEOUT_SECONDS,
                            )
                            cleanup_error = None
                            break
                        except (KeyboardInterrupt, TerminalProcessSignal) as error:
                            cleanup_error = error
                            if attempt == 0:
                                continue
                            break
                        except BaseException as error:
                            cleanup_error = error
                            break
        finally:
            if old_mask is not None:
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
                except BaseException as error:
                    deferred_signal = error
        return close_error, cleanup_error, deferred_signal

    @staticmethod
    def _validate_terminal_name(terminal_name: str) -> str:
        if (
            not isinstance(terminal_name, str)
            or TERMINAL_NAME_PATTERN.fullmatch(terminal_name) is None
        ):
            raise TerminalClientError(
                "A terminal name must match the exact icrn_<32 lowercase hex> form."
            )
        return terminal_name

    @staticmethod
    def _resolve_cleanup(
        primary: BaseException | None,
        close_error: BaseException | None,
        cleanup_error: BaseException | None,
        deferred_signal: BaseException | None,
        terminal_name: str,
    ) -> BaseException | None:
        if cleanup_error is not None:
            cleanup_message = (
                f"Cleanup unverified for exact temporary Jupyter terminal {terminal_name}."
            )
            process_signal = next(
                (
                    error
                    for error in (primary, close_error, cleanup_error, deferred_signal)
                    if isinstance(error, TerminalProcessSignal)
                ),
                None,
            )
            if process_signal is not None:
                return TerminalProcessSignal(process_signal.signum, cleanup_message)
            if any(
                isinstance(error, KeyboardInterrupt)
                for error in (primary, close_error, cleanup_error, deferred_signal)
            ):
                return TerminalCleanupInterrupt(cleanup_message)
            if primary is None:
                return TerminalClientError(cleanup_message)
            return TerminalClientError(
                f"The command failed and cleanup was unverified for terminal {terminal_name}."
            )
        if deferred_signal is not None:
            return deferred_signal
        if close_error is not None and primary is None:
            if isinstance(close_error, TerminalProcessSignal):
                return close_error
            if isinstance(close_error, KeyboardInterrupt):
                return KeyboardInterrupt()
            return TerminalClientError(
                "The WebSocket close failed after the exact temporary terminal was deleted."
            )
        return primary

    def cleanup_terminal(self, terminal_name: str) -> bool:
        """Delete one validated exact terminal name and verify authoritative absence."""

        terminal_name = self._validate_terminal_name(terminal_name)
        before = self.attest()
        if terminal_name not in before:
            return False
        self.rest.request_json(
            "DELETE",
            f"{self.server_base}api/terminals/{quote(terminal_name, safe='')}",
            expected={204, 404},
            timeout=DELETE_TIMEOUT_SECONDS,
        )
        if terminal_name in self.attest():
            raise TerminalClientError(
                f"Cleanup remains unverified for exact temporary Jupyter terminal {terminal_name}."
            )
        return True

    def open_session(self, terminal_name: str | None = None) -> JupyterTerminalSession:
        """Create and attest one reusable task-scoped Jupyter terminal session."""

        if terminal_name is not None:
            terminal_name = self._validate_terminal_name(terminal_name)
        baseline = self.attest()
        if terminal_name is None:
            terminal_name = f"icrn_{secrets.token_hex(16)}"
        terminal_name = self._validate_terminal_name(terminal_name)
        if terminal_name in baseline:
            raise TerminalClientError("The requested terminal name was already present.")
        creation_attempted = False
        websocket: _WebSocket | None = None
        try:
            creation_attempted = True
            _, model = self.rest.request_json(
                "POST",
                f"{self.server_base}api/terminals",
                payload={"name": terminal_name, "cwd": self.root},
            )
            if not isinstance(model, dict) or model.get("name") != terminal_name:
                raise TerminalClientError("Jupyter did not create the exact requested terminal.")
            if terminal_name not in self.attest():
                raise TerminalClientError(
                    "The exact temporary terminal was absent during post-create re-attestation."
                )
            websocket = _WebSocket.connect(
                self.rest,
                f"{self.server_base}terminals/websocket/{quote(terminal_name, safe='')}",
                timeout=READY_TIMEOUT_SECONDS,
            )
            websocket.send_json(["set_size", 24, 80, 0, 0])
        except BaseException as primary:
            close_error, cleanup_error, deferred_signal = self._cleanup_owned_terminal(
                websocket,
                terminal_name,
                creation_attempted,
            )
            resolved = self._resolve_cleanup(
                primary,
                close_error,
                cleanup_error,
                deferred_signal,
                terminal_name,
            )
            assert resolved is not None
            raise resolved from None
        assert websocket is not None
        return JupyterTerminalSession(self, terminal_name, websocket)

    def run(
        self,
        argv: list[str],
        *,
        cwd: str = ".",
        ensure_cwd: bool = False,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        output: BinaryIO | None = None,
    ) -> ExecutionResult:
        argv = validate_argv(argv)
        cwd = validate_cwd(cwd, root=self.root)
        if not isinstance(ensure_cwd, bool):
            raise TerminalClientError("ensure_cwd must be boolean.")
        if (
            not isinstance(timeout_seconds, (int, float))
            or isinstance(timeout_seconds, bool)
            or not 0 < float(timeout_seconds) <= MAX_TIMEOUT_SECONDS
        ):
            raise TerminalClientError(f"timeout must be in (0, {MAX_TIMEOUT_SECONDS}].")
        timeout_seconds = float(timeout_seconds)
        with self.open_session() as session:
            return session.run(
                argv,
                cwd=cwd,
                ensure_cwd=ensure_cwd,
                timeout_seconds=timeout_seconds,
                output=output,
            )

    def _execute(
        self,
        websocket: _WebSocket,
        argv: list[str],
        cwd: str,
        ensure_cwd: bool,
        timeout_seconds: float,
        output: BinaryIO | None,
    ) -> ExecutionResult:
        loader_nonce = secrets.token_hex(24)
        nonce = secrets.token_hex(24)
        idle_nonce = secrets.token_hex(24)
        ready = f"ICRN_DIRECT_READY_{loader_nonce}"
        begin = f"ICRN_DIRECT_BEGIN_{nonce}"
        chunk = f"ICRN_DIRECT_CHUNK_{nonce}:"
        end = f"ICRN_DIRECT_END_{nonce}:"
        idle = f"ICRN_DIRECT_IDLE_{idle_nonce}"
        source = _remote_launcher_source(ready, root=self.root)
        shell_command = _remote_shell_command(
            source,
            remote_python=self.remote_python,
            idle=idle,
        )
        emitted_bytes = 0
        truncated = False

        def emit(encoded: bytes) -> None:
            nonlocal emitted_bytes, truncated
            remaining = self.max_output_bytes - emitted_bytes
            if len(encoded) > remaining:
                truncated = True
                encoded = encoded[: max(0, remaining)]
            if encoded and output is not None:
                output.write(encoded)
                output.flush()
            emitted_bytes += len(encoded)

        payload = base64.b64encode(
            json.dumps(
                {
                    "nonce": nonce,
                    "argv": argv,
                    "cwd": cwd,
                    "ensure_cwd": ensure_cwd,
                    "timeout": timeout_seconds,
                    "max_output_bytes": self.max_output_bytes,
                },
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
        ).decode("ascii")
        if len(payload.encode("ascii")) > MAX_PAYLOAD_BASE64_BYTES:
            raise TerminalClientError(
                f"The encoded command payload exceeds {MAX_PAYLOAD_BASE64_BYTES} bytes."
            )
        parser = _MarkerParser(ready, begin, chunk, end, idle, emit)
        websocket.send_json(["stdin", shell_command + "\r"])
        self._pump_until(
            websocket,
            parser,
            lambda: parser.stage != "ready",
            time.monotonic() + READY_TIMEOUT_SECONDS,
        )
        for offset in range(0, len(payload), PAYLOAD_CHUNK_BYTES):
            websocket.send_json(["stdin", payload[offset : offset + PAYLOAD_CHUNK_BYTES] + "\r"])
        websocket.send_json(["stdin", ".\r"])
        deadline = time.monotonic() + timeout_seconds + INTERRUPT_GRACE_SECONDS + 2.0
        try:
            self._pump_until(websocket, parser, lambda: parser.stage == "done", deadline)
        except (KeyboardInterrupt, TerminalTimeout) as error:
            try:
                websocket.send_json(["stdin", "\x03"])
            except TerminalClientError:
                raise error from None
            try:
                self._pump_until(
                    websocket,
                    parser,
                    lambda: parser.stage == "done",
                    time.monotonic() + INTERRUPT_GRACE_SECONDS,
                )
            except TerminalClientError:
                raise error from None
            if isinstance(error, KeyboardInterrupt):
                raise
            raise error from None
        assert parser.result is not None
        value = parser.result
        returncode = value.get("returncode")
        timed_out = value.get("timed_out")
        interrupted = value.get("interrupted")
        output_truncated = value.get("output_truncated")
        if (
            not isinstance(returncode, int)
            or isinstance(returncode, bool)
            or not -255 <= returncode <= 255
            or not isinstance(timed_out, bool)
            or not isinstance(interrupted, bool)
            or not isinstance(output_truncated, bool)
        ):
            raise TerminalClientError("The remote launcher returned invalid completion metadata.")
        if value.get("error") is not None:
            error_code = value["error"]
            if not isinstance(error_code, str) or not re.fullmatch(r"[a-z_]{1,64}", error_code):
                error_code = "launcher_failure"
            raise TerminalClientError(f"The remote launcher failed ({error_code}).")
        return ExecutionResult(
            returncode=returncode,
            timed_out=timed_out,
            interrupted=interrupted,
            truncated=truncated or output_truncated,
            output_bytes=emitted_bytes,
        )

    @staticmethod
    def _pump_until(
        websocket: _WebSocket,
        parser: _MarkerParser,
        complete: Callable[[], bool],
        deadline: float,
    ) -> None:
        while not complete():
            message = websocket.receive_text(deadline)
            try:
                packet = json.loads(message)
            except json.JSONDecodeError:
                raise TerminalClientError("The terminal WebSocket sent invalid JSON.") from None
            if not isinstance(packet, list) or len(packet) < 2 or not isinstance(packet[0], str):
                raise TerminalClientError(
                    "The terminal WebSocket sent an invalid terminal message."
                )
            if packet[0] == "setup":
                continue
            if packet[0] == "stdout" and len(packet) == 2 and isinstance(packet[1], str):
                parser.feed(packet[1])
                continue
            if packet[0] == "disconnect":
                raise TerminalClientError("The Jupyter terminal disconnected before completion.")
            raise TerminalClientError(
                "The terminal WebSocket sent an unsupported terminal message."
            )


class JupyterTerminalSession:
    """One exact task-scoped Jupyter terminal shared by sequential commands."""

    def __init__(
        self,
        client: JupyterTerminalClient,
        terminal_name: str,
        websocket: _WebSocket,
    ) -> None:
        self._client = client
        self.terminal_name = terminal_name
        self._websocket: _WebSocket | None = websocket
        self._creation_attempted = True
        self._closed = False
        self._poisoned = False
        self._owner_pid = os.getpid()
        self._lock = threading.Lock()
        self._active_thread: int | None = None

    @property
    def poisoned(self) -> bool:
        return self._poisoned

    @property
    def closed(self) -> bool:
        return self._closed

    def __enter__(self) -> JupyterTerminalSession:
        self._check_owner()
        if self._closed:
            raise TerminalClientError("The Jupyter terminal session is already closed.")
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        exc: BaseException | None,
        _traceback: Any,
    ) -> bool:
        self._check_owner()
        if self._active_thread == threading.get_ident():
            raise TerminalClientError("Cannot close a terminal session from its active command.")
        with self._lock:
            resolved = self._close_locked(exc)
        if resolved is exc:
            return False
        if resolved is not None:
            raise resolved
        return False

    def _check_owner(self) -> None:
        if os.getpid() != self._owner_pid:
            raise TerminalClientError(
                "A Jupyter terminal session cannot be used from a forked process."
            )

    def _validate_request(
        self,
        argv: list[str],
        cwd: str,
        ensure_cwd: bool,
        timeout_seconds: float,
    ) -> tuple[list[str], str, float]:
        validated_argv = validate_argv(argv)
        remote_cwd = validate_cwd(cwd, root=self._client.root)
        if not isinstance(ensure_cwd, bool):
            raise TerminalClientError("ensure_cwd must be boolean.")
        if (
            not isinstance(timeout_seconds, (int, float))
            or isinstance(timeout_seconds, bool)
            or not 0 < float(timeout_seconds) <= MAX_TIMEOUT_SECONDS
        ):
            raise TerminalClientError(f"timeout must be in (0, {MAX_TIMEOUT_SECONDS}].")
        return validated_argv, remote_cwd, float(timeout_seconds)

    def run(
        self,
        argv: list[str],
        *,
        cwd: str = ".",
        ensure_cwd: bool = False,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        output: BinaryIO | None = None,
    ) -> ExecutionResult:
        argv, remote_cwd, timeout_seconds = self._validate_request(
            argv,
            cwd,
            ensure_cwd,
            timeout_seconds,
        )
        self._check_owner()
        current_thread = threading.get_ident()
        if self._active_thread == current_thread:
            raise TerminalClientError("A terminal session command cannot be re-entered.")
        with self._lock:
            if self._closed:
                raise TerminalClientError("The Jupyter terminal session is closed.")
            if self._poisoned:
                raise TerminalClientError("The Jupyter terminal session is poisoned.")
            assert self._websocket is not None
            self._active_thread = current_thread
            try:
                return self._client._execute(
                    self._websocket,
                    argv,
                    remote_cwd,
                    ensure_cwd,
                    timeout_seconds,
                    output,
                )
            except BaseException as primary:
                self._poisoned = True
                resolved = self._close_locked(primary)
                assert resolved is not None
                raise resolved from None
            finally:
                self._active_thread = None

    def close(self) -> None:
        self._check_owner()
        if self._active_thread == threading.get_ident():
            raise TerminalClientError("Cannot close a terminal session from its active command.")
        with self._lock:
            resolved = self._close_locked(None)
        if resolved is not None:
            raise resolved

    def _close_locked(self, primary: BaseException | None) -> BaseException | None:
        if self._closed:
            return primary
        websocket = self._websocket
        self._websocket = None
        close_error, cleanup_error, deferred_signal = self._client._cleanup_owned_terminal(
            websocket,
            self.terminal_name,
            self._creation_attempted,
        )
        if cleanup_error is None:
            self._creation_attempted = False
            self._closed = True
        else:
            self._poisoned = True
        return self._client._resolve_cleanup(
            primary,
            close_error,
            cleanup_error,
            deferred_signal,
            self.terminal_name,
        )


def _timeout_argument(value: str) -> float:
    try:
        timeout = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("timeout must be a number") from None
    if not 0 < timeout <= MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(f"timeout must be in (0, {MAX_TIMEOUT_SECONDS}]")
    return timeout


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", default=".", help="Working directory below the configured root")
    parser.add_argument(
        "--ensure-cwd",
        action="store_true",
        help="Create missing cwd components safely below the configured remote root",
    )
    parser.add_argument("--timeout", type=_timeout_argument, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("argv", nargs=argparse.REMAINDER, help="Command argv after --")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    command = list(arguments.argv)
    if command and command[0] == "--":
        command.pop(0)
    handled_signals = [
        value for value in (getattr(signal, "SIGHUP", None), signal.SIGTERM) if value
    ]
    previous_handlers: dict[int, Any] = {}

    def terminate(signum: int, _frame: Any) -> None:
        for handled in handled_signals:
            signal.signal(handled, signal.SIG_IGN)
        raise TerminalProcessSignal(signum)

    for handled in handled_signals:
        previous_handlers[handled] = signal.signal(handled, terminate)
    try:
        config = _runtime_config()
        token = read_private_token(config.credentials.jupyter_token_file)
        client = JupyterTerminalClient(token, config=config)
        result = client.run(
            command,
            cwd=arguments.cwd,
            ensure_cwd=arguments.ensure_cwd,
            timeout_seconds=arguments.timeout,
            output=sys.stdout.buffer,
        )
        if result.truncated:
            print(
                f"\nICRN terminal output truncated at {result.output_bytes} bytes.",
                file=sys.stderr,
            )
        if result.returncode < 0:
            return min(255, 128 + abs(result.returncode))
        return min(255, result.returncode)
    except TerminalCleanupInterrupt as error:
        print(f"icrn-jupyter-terminal: {error}", file=sys.stderr)
        return 130
    except TerminalProcessSignal as error:
        if error.cleanup_message:
            print(f"icrn-jupyter-terminal: {error.cleanup_message}", file=sys.stderr)
        return min(255, 128 + error.signum)
    except BrokenPipeError:
        return 141
    except KeyboardInterrupt:
        return 130
    except TerminalClientError as error:
        print(f"icrn-jupyter-terminal: {error}", file=sys.stderr)
        return 1
    finally:
        for handled, previous in previous_handlers.items():
            signal.signal(handled, previous)


if __name__ == "__main__":
    raise SystemExit(main())
