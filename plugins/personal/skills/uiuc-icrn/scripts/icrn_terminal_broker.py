#!/usr/bin/env python3
"""Reuse one authenticated ICRN terminal for a bounded agent task.

The broker is local-only.  It keeps the Jupyter token in memory, owns exactly one
cryptographically named remote terminal, serializes commands, and deletes that terminal
on explicit close, idle expiry, absolute expiry, signal, or any ambiguous protocol error.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import functools
import hashlib
import json
import os
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

import icrn_jupyter_terminal as terminal
import icrn_config

PROTOCOL_VERSION = 1
SCHEMA_VERSION = 1
DEFAULT_IDLE_SECONDS = 300.0
DEFAULT_MAX_AGE_SECONDS = 1_800.0
START_TIMEOUT_SECONDS = 45.0
LIFECYCLE_TIMEOUT_SECONDS = 15.0
MAX_REQUEST_BYTES = 1024 * 1024
MAX_FRAME_BYTES = 256 * 1024
SOCKET_TIMEOUT_GRACE_SECONDS = 30.0
SCOPE_PATTERN = re.compile(r"[0-9a-f]{64}")
REQUEST_ID_PATTERN = re.compile(r"[0-9a-f]{32}")


class BrokerError(Exception):
    """A sanitized local broker failure."""


class BrokerExit(BaseException):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


@functools.lru_cache(maxsize=1)
def _configuration() -> icrn_config.ICRNConfig:
    """Pin one validated config snapshot for this local broker/CLI process."""

    try:
        return icrn_config.load_config()
    except icrn_config.ConfigError as error:
        raise BrokerError(str(error)) from None


@dataclass(frozen=True)
class BrokerPaths:
    root: Path
    scope: Path
    socket: Path
    lifecycle_lock: Path
    broker_lock: Path
    pid: Path
    lease: Path
    startup_error: Path
    uncertain: Path


def _state_root() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return base / "uiuc-icrn-terminal"


def _canonical_project_root(value: str | Path) -> Path:
    try:
        resolved = Path(value).expanduser().resolve(strict=True)
        info = resolved.stat()
    except OSError as error:
        raise BrokerError(f"Could not resolve the local project root ({error.strerror}).") from None
    if not stat.S_ISDIR(info.st_mode):
        raise BrokerError("The local project root is not a directory.")
    try:
        git = subprocess.run(
            ["/usr/bin/git", "-C", str(resolved), "rev-parse", "--show-toplevel"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        git = None
    if git is not None and git.returncode == 0:
        try:
            actual_root = Path(git.stdout.strip()).resolve(strict=True)
        except OSError:
            raise BrokerError("Git returned an invalid local project root.") from None
        if actual_root != resolved:
            raise BrokerError("The broker scope root must be the exact local Git root.")
    return resolved


def scope_id(project_root: str | Path, *, task_identity: str | None = None) -> str:
    """Derive a non-reversible scope from the agent task and canonical project root."""

    root = _canonical_project_root(project_root)
    identity = (
        task_identity
        or os.environ.get("CODEX_THREAD_ID")
        or os.environ.get("CODEX_SESSION_ID")
        or os.environ.get("CLAUDE_CODE_SESSION_ID")
        or f"manual-session:{os.getsid(0)}"
    )
    config_fingerprint = _configuration().fingerprint()
    material = f"{os.getuid()}\0{identity}\0{root}\0{config_fingerprint}".encode()
    return hashlib.sha256(material).hexdigest()


def _paths(scope: str, *, root: Path | None = None) -> BrokerPaths:
    if SCOPE_PATTERN.fullmatch(scope) is None:
        raise BrokerError("The broker scope identifier is invalid.")
    state = root or _state_root()
    directory = state / scope[:32]
    result = BrokerPaths(
        root=state,
        scope=directory,
        socket=directory / "broker.sock",
        lifecycle_lock=directory / "lifecycle.lock",
        broker_lock=directory / "broker.lock",
        pid=directory / "broker.pid.json",
        lease=directory / "lease.json",
        startup_error=directory / "startup-error.json",
        uncertain=directory / "outcome-uncertain.json",
    )
    if len(os.fsencode(result.socket)) >= 100:
        raise BrokerError("The private broker socket path is too long for Unix sockets.")
    return result


def _ensure_private_directory(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = path.lstat()
    except OSError as error:
        raise BrokerError(f"Could not prepare private broker state ({error.strerror}).") from None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise BrokerError("A private broker state path is not a real directory.")
    if info.st_uid != os.getuid():
        raise BrokerError("A private broker state directory has the wrong owner.")
    try:
        path.chmod(0o700)
        final = path.lstat()
    except OSError as error:
        raise BrokerError(f"Could not protect private broker state ({error.strerror}).") from None
    if stat.S_IMODE(final.st_mode) != 0o700:
        raise BrokerError("A private broker state directory is not mode 0700.")


def _prepare_paths(paths: BrokerPaths) -> None:
    _ensure_private_directory(paths.root)
    _ensure_private_directory(paths.scope)


def _open_lock(path: Path) -> int:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise BrokerError(f"Could not open a private broker lock ({error.strerror}).") from None
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        os.close(descriptor)
        raise BrokerError("A private broker lock is not a safe current-user regular file.")
    os.fchmod(descriptor, 0o600)
    return descriptor


@contextlib.contextmanager
def _lifecycle_lock(paths: BrokerPaths) -> Any:
    _prepare_paths(paths)
    descriptor = _open_lock(paths.lifecycle_lock)
    deadline = time.monotonic() + LIFECYCLE_TIMEOUT_SECONDS
    acquired = False
    try:
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise BrokerError(
                        "Another terminal-session lifecycle operation is active."
                    ) from None
                time.sleep(0.05)
        yield
    finally:
        if acquired:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _atomic_private_json(path: Path, value: dict[str, Any]) -> None:
    data = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise BrokerError("Could not finish a private broker state write.")
            offset += written
        os.fsync(descriptor)
    except BaseException:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise


def _read_private_json(path: Path, *, required: bool = False) -> dict[str, Any] | None:
    try:
        before = path.lstat()
    except FileNotFoundError:
        if required:
            raise BrokerError("A required private broker record is missing.") from None
        return None
    except OSError as error:
        raise BrokerError(f"Could not inspect private broker state ({error.strerror}).") from None
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise BrokerError("A private broker record is not a regular non-symlink file.")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(path, flags)
    try:
        current = os.fstat(descriptor)
        if (
            (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino)
            or current.st_uid != os.getuid()
            or current.st_nlink != 1
            or stat.S_IMODE(current.st_mode) != 0o600
            or current.st_size > MAX_REQUEST_BYTES
        ):
            raise BrokerError("A private broker record failed its integrity check.")
        data = bytearray()
        while len(data) <= MAX_REQUEST_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_REQUEST_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
    finally:
        os.close(descriptor)
    if len(data) > MAX_REQUEST_BYTES:
        raise BrokerError("A private broker record is too large.")
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BrokerError("A private broker record is invalid JSON.") from None
    if not isinstance(value, dict):
        raise BrokerError("A private broker record is invalid.")
    return value


def _unlink_private(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return
    directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


@functools.lru_cache(maxsize=1)
def _source_id() -> str:
    digest = hashlib.sha256(f"uiuc-icrn-broker-v{PROTOCOL_VERSION}\0".encode())
    for path in (
        Path(__file__).resolve(),
        Path(terminal.__file__).resolve(),
        Path(icrn_config.__file__).resolve(),
    ):
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    digest.update(_configuration().fingerprint().encode("ascii"))
    return digest.hexdigest()


def _validated_terminal_name(value: Any) -> str:
    if not isinstance(value, str) or terminal.TERMINAL_NAME_PATTERN.fullmatch(value) is None:
        raise BrokerError("A broker lease contains an invalid terminal name.")
    return value


def _lease_value(
    scope: str,
    terminal_name: str,
    *,
    state: str,
    request_id: str | None = None,
    result: dict[str, Any] | None = None,
    commands: int = 0,
) -> dict[str, Any]:
    return {
        "schema": SCHEMA_VERSION,
        "source_id": _source_id(),
        "scope_id": scope,
        "terminal_name": terminal_name,
        "state": state,
        "request_id": request_id,
        "result": result,
        "commands": commands,
        "updated_at": time.time(),
    }


def _validate_lease(value: dict[str, Any], scope: str) -> dict[str, Any]:
    allowed = {
        "schema",
        "source_id",
        "scope_id",
        "terminal_name",
        "state",
        "request_id",
        "result",
        "commands",
        "updated_at",
    }
    if (
        set(value) != allowed
        or value.get("schema") != SCHEMA_VERSION
        or value.get("scope_id") != scope
    ):
        raise BrokerError("A broker lease has an unsupported shape or scope.")
    _validated_terminal_name(value.get("terminal_name"))
    if value.get("state") not in {
        "reserved",
        "idle",
        "running",
        "completed",
        "closing",
        "cleanup_unverified",
    }:
        raise BrokerError("A broker lease has an invalid state.")
    request_id = value.get("request_id")
    if request_id is not None and (
        not isinstance(request_id, str) or REQUEST_ID_PATTERN.fullmatch(request_id) is None
    ):
        raise BrokerError("A broker lease has an invalid request id.")
    if (
        not isinstance(value.get("commands"), int)
        or isinstance(value.get("commands"), bool)
        or value["commands"] < 0
    ):
        raise BrokerError("A broker lease has an invalid command count.")
    if not isinstance(value.get("updated_at"), (int, float)):  # noqa: UP038
        raise BrokerError("A broker lease has an invalid timestamp.")
    return value


def _socket_record(paths: BrokerPaths, scope: str) -> dict[str, Any] | None:
    record = _read_private_json(paths.pid)
    if record is None:
        return None
    allowed = {"schema", "source_id", "scope_id", "pid", "started_at"}
    if (
        set(record) != allowed
        or record.get("schema") != SCHEMA_VERSION
        or record.get("scope_id") != scope
    ):
        raise BrokerError("The broker PID record is invalid.")
    pid = record.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        raise BrokerError("The broker PID record is invalid.")
    return record


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _pid_is_exact_broker(pid: int, scope: str) -> bool:
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "uid=", "-o", "command="],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if result.returncode != 0:
        return False
    line = result.stdout.strip()
    if not line:
        return False
    pieces = line.split(None, 1)
    if len(pieces) != 2 or pieces[0] != str(os.getuid()):
        return False
    command = pieces[1]
    return str(Path(__file__).resolve()) in command and "_serve" in command and scope in command


def _send_frame(
    connection: socket.socket,
    value: dict[str, Any],
    *,
    limit: int = MAX_FRAME_BYTES,
) -> None:
    data = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    if len(data) > limit:
        raise BrokerError("A broker frame exceeded the byte limit.")
    connection.sendall(data)


class _FrameReader:
    """Read newline-delimited JSON without losing coalesced stream frames."""

    def __init__(self, connection: socket.socket, *, limit: int) -> None:
        self.connection = connection
        self.limit = limit
        self.buffer = bytearray()

    def receive(self) -> dict[str, Any]:
        while b"\n" not in self.buffer:
            remaining = self.limit + 1 - len(self.buffer)
            if remaining <= 0:
                raise BrokerError("A broker frame exceeded the byte limit.")
            chunk = self.connection.recv(min(65536, remaining))
            if not chunk:
                raise BrokerError("The broker connection closed before a complete frame.")
            self.buffer.extend(chunk)
        line, remainder = bytes(self.buffer).split(b"\n", 1)
        self.buffer = bytearray(remainder)
        if len(line) > self.limit:
            raise BrokerError("A broker frame exceeded the byte limit.")
        try:
            value = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise BrokerError("A broker frame was invalid JSON.") from None
        if not isinstance(value, dict):
            raise BrokerError("A broker frame was invalid.")
        return value


class _SocketOutput:
    def __init__(self, connection: socket.socket, request_id: str) -> None:
        self.connection = connection
        self.request_id = request_id
        self.sequence = 0

    def write(self, data: bytes) -> int:
        for offset in range(0, len(data), 48 * 1024):
            chunk = data[offset : offset + 48 * 1024]
            _send_frame(
                self.connection,
                {
                    "v": PROTOCOL_VERSION,
                    "type": "stdout",
                    "request_id": self.request_id,
                    "seq": self.sequence,
                    "data_b64": base64.b64encode(chunk).decode("ascii"),
                },
            )
            self.sequence += 1
        return len(data)

    def flush(self) -> None:
        return


def _result_payload(result: terminal.ExecutionResult) -> dict[str, Any]:
    return {
        "returncode": result.returncode,
        "timed_out": result.timed_out,
        "interrupted": result.interrupted,
        "truncated": result.truncated,
        "output_bytes": result.output_bytes,
    }


def _execution_result_from_frame(
    frame: dict[str, Any],
    request_id: str,
    received_bytes: int,
) -> terminal.ExecutionResult:
    expected = {
        "v",
        "type",
        "request_id",
        "returncode",
        "timed_out",
        "interrupted",
        "truncated",
        "output_bytes",
        "reused",
    }
    returncode = frame.get("returncode")
    output_bytes = frame.get("output_bytes")
    if (
        set(frame) != expected
        or frame.get("v") != PROTOCOL_VERSION
        or frame.get("type") != "result"
        or frame.get("request_id") != request_id
        or not isinstance(returncode, int)
        or isinstance(returncode, bool)
        or not -255 <= returncode <= 255
        or not isinstance(frame.get("timed_out"), bool)
        or not isinstance(frame.get("interrupted"), bool)
        or not isinstance(frame.get("truncated"), bool)
        or not isinstance(frame.get("reused"), bool)
        or not isinstance(output_bytes, int)
        or isinstance(output_bytes, bool)
        or output_bytes < 0
        or output_bytes != received_bytes
    ):
        raise BrokerError("The broker result frame was invalid.")
    return terminal.ExecutionResult(
        returncode=returncode,
        timed_out=frame["timed_out"],
        interrupted=frame["interrupted"],
        truncated=frame["truncated"],
        output_bytes=output_bytes,
    )


class TerminalBroker:
    def __init__(
        self,
        scope: str,
        paths: BrokerPaths,
        *,
        idle_seconds: float = DEFAULT_IDLE_SECONDS,
        max_age_seconds: float = DEFAULT_MAX_AGE_SECONDS,
        client_factory: Callable[[], terminal.JupyterTerminalClient] | None = None,
    ) -> None:
        if SCOPE_PATTERN.fullmatch(scope) is None:
            raise BrokerError("The broker scope identifier is invalid.")
        if not 0 < idle_seconds <= max_age_seconds or max_age_seconds > 24 * 3600:
            raise BrokerError("The broker lifetime limits are invalid.")
        self.scope_id = scope
        self.paths = paths
        self.idle_seconds = float(idle_seconds)
        self.max_age_seconds = float(max_age_seconds)
        self.remote_root = _configuration().workspace.remote_root
        self.client_factory = client_factory or self._default_client
        self.client: terminal.JupyterTerminalClient | None = None
        self.session: terminal.JupyterTerminalSession | None = None
        self.lease: dict[str, Any] | None = None
        self.server: socket.socket | None = None
        self.started_monotonic = time.monotonic()
        self.last_used_monotonic = self.started_monotonic
        self.stop_requested = False
        self.outcome_uncertain = False

    @staticmethod
    def _default_client() -> terminal.JupyterTerminalClient:
        config = _configuration()
        token = terminal.read_private_token(config.credentials.jupyter_token_file)
        return terminal.JupyterTerminalClient(token, config=config)

    def _reconcile_stale_lease(self) -> None:
        assert self.client is not None
        value = _read_private_json(self.paths.lease)
        if value is None:
            return
        lease = _validate_lease(value, self.scope_id)
        name = _validated_terminal_name(lease["terminal_name"])
        try:
            self.client.cleanup_terminal(name)
        except BaseException:
            lease["state"] = "cleanup_unverified"
            lease["updated_at"] = time.time()
            _atomic_private_json(self.paths.lease, lease)
            raise
        if lease["state"] in {"running", "completed"}:
            _atomic_private_json(
                self.paths.uncertain,
                {
                    "schema": SCHEMA_VERSION,
                    "scope_id": self.scope_id,
                    "request_id": lease.get("request_id"),
                    "prior_state": lease["state"],
                    "recorded_at": time.time(),
                },
            )
        _unlink_private(self.paths.lease)

    def _open_remote(self) -> None:
        self.client = self.client_factory()
        if self.client.root != self.remote_root:
            raise BrokerError("The terminal client root did not match the pinned configuration.")
        self._reconcile_stale_lease()
        if _read_private_json(self.paths.uncertain) is not None:
            raise BrokerError(
                "A prior broker command has an uncertain outcome; verify its "
                "postcondition, then close the scoped session before retrying."
            )
        name = f"icrn_{secrets.token_hex(16)}"
        self.lease = _lease_value(self.scope_id, name, state="reserved")
        _atomic_private_json(self.paths.lease, self.lease)
        try:
            self.session = self.client.open_session(name)
        except BaseException:
            try:
                self.client.cleanup_terminal(name)
            except BaseException:
                assert self.lease is not None
                self.lease["state"] = "cleanup_unverified"
                self.lease["updated_at"] = time.time()
                _atomic_private_json(self.paths.lease, self.lease)
            else:
                _unlink_private(self.paths.lease)
            raise
        self.lease["state"] = "idle"
        self.lease["updated_at"] = time.time()
        _atomic_private_json(self.paths.lease, self.lease)

    def _bind(self) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.paths.socket.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(self.paths.socket))
            os.chmod(self.paths.socket, 0o600)
            info = self.paths.socket.lstat()
            if (
                not stat.S_ISSOCK(info.st_mode)
                or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise BrokerError("The private broker socket failed its integrity check.")
            server.listen(16)
            server.settimeout(0.5)
        except BaseException:
            server.close()
            with contextlib.suppress(FileNotFoundError):
                self.paths.socket.unlink()
            raise
        self.server = server
        _atomic_private_json(
            self.paths.pid,
            {
                "schema": SCHEMA_VERSION,
                "source_id": _source_id(),
                "scope_id": self.scope_id,
                "pid": os.getpid(),
                "started_at": time.time(),
            },
        )

    def _write_lease(
        self, state: str, *, request_id: str | None = None, result: dict[str, Any] | None = None
    ) -> None:
        assert self.lease is not None
        self.lease["state"] = state
        self.lease["request_id"] = request_id
        self.lease["result"] = result
        self.lease["updated_at"] = time.time()
        _atomic_private_json(self.paths.lease, self.lease)

    def _record_uncertainty(self, request_id: str, prior_state: str) -> None:
        _atomic_private_json(
            self.paths.uncertain,
            {
                "schema": SCHEMA_VERSION,
                "scope_id": self.scope_id,
                "request_id": request_id,
                "prior_state": prior_state,
                "recorded_at": time.time(),
            },
        )

    def _status(self) -> dict[str, Any]:
        assert self.lease is not None
        return {
            "v": PROTOCOL_VERSION,
            "type": "status",
            "scope_id": self.scope_id,
            "state": self.lease["state"],
            "commands": self.lease["commands"],
            "idle_remaining": max(
                0.0, self.idle_seconds - (time.monotonic() - self.last_used_monotonic)
            ),
            "age_remaining": max(
                0.0, self.max_age_seconds - (time.monotonic() - self.started_monotonic)
            ),
            "source_id": _source_id(),
        }

    def _validate_request(self, value: dict[str, Any]) -> tuple[str, str | None]:
        op = value.get("op")
        request_id = value.get("request_id")
        if (
            value.get("v") != PROTOCOL_VERSION
            or value.get("source_id") != _source_id()
            or value.get("scope_id") != self.scope_id
        ):
            raise BrokerError("The broker request protocol, source, or scope did not match.")
        if op not in {"health", "status", "exec", "close"}:
            raise BrokerError("The broker operation is unsupported.")
        if op == "exec":
            if not isinstance(request_id, str) or REQUEST_ID_PATTERN.fullmatch(request_id) is None:
                raise BrokerError("The broker request id is invalid.")
            allowed = {
                "v",
                "source_id",
                "scope_id",
                "op",
                "request_id",
                "argv",
                "cwd",
                "ensure_cwd",
                "timeout_seconds",
            }
        else:
            if request_id is not None:
                raise BrokerError("This broker operation must not include a request id.")
            allowed = {"v", "source_id", "scope_id", "op"}
        if set(value) != allowed:
            raise BrokerError("The broker request contained unexpected or missing fields.")
        return op, request_id

    def _close_remote(self) -> None:
        if self.lease is None:
            return
        if self.client is None:
            raise BrokerError("The broker lost its exact terminal cleanup authority.")
        name = _validated_terminal_name(self.lease["terminal_name"])
        journal_error: BaseException | None = None
        if not self.outcome_uncertain:
            try:
                self._write_lease("closing")
            except BaseException as error:
                journal_error = error
        close_error: BaseException | None = None
        try:
            if self.session is not None:
                self.session.close()
        except BaseException as error:
            close_error = error
        try:
            self.client.cleanup_terminal(name)
        except BaseException as error:
            self._write_lease("cleanup_unverified")
            if isinstance(  # noqa: UP038
                error, (BrokerError, terminal.TerminalClientError)
            ):
                raise
            if close_error is not None:
                raise BrokerError(
                    "Exact terminal cleanup remained unverified after "
                    f"{type(close_error).__name__}."
                ) from None
            raise
        self.session = None
        if not self.outcome_uncertain or _read_private_json(self.paths.uncertain) is not None:
            _unlink_private(self.paths.lease)
            self.lease = None
        if journal_error is not None:
            raise journal_error

    def _handle(self, connection: socket.socket) -> None:
        reader = _FrameReader(connection, limit=MAX_REQUEST_BYTES)
        value = reader.receive()
        if reader.buffer.strip():
            raise BrokerError("A broker connection sent more than one request.")
        op, request_id = self._validate_request(value)
        if op in {"health", "status"}:
            _send_frame(connection, self._status())
            return
        if op == "close":
            self._close_remote()
            _send_frame(
                connection, {"v": PROTOCOL_VERSION, "type": "closed", "scope_id": self.scope_id}
            )
            self.stop_requested = True
            return
        assert (
            op == "exec"
            and request_id is not None
            and self.session is not None
            and self.lease is not None
        )
        command_argv = terminal.validate_argv(value["argv"])
        command_cwd = terminal.validate_cwd(value["cwd"], root=self.remote_root)
        ensure_cwd = value["ensure_cwd"]
        timeout_seconds = value["timeout_seconds"]
        if not isinstance(ensure_cwd, bool):
            raise BrokerError("ensure_cwd must be boolean.")
        if (
            not isinstance(timeout_seconds, (int, float))  # noqa: UP038
            or isinstance(timeout_seconds, bool)
            or not 0 < float(timeout_seconds) <= terminal.MAX_TIMEOUT_SECONDS
        ):
            raise BrokerError(f"timeout must be in (0, {terminal.MAX_TIMEOUT_SECONDS}].")
        remaining_age = self.max_age_seconds - (time.monotonic() - self.started_monotonic)
        if remaining_age <= 0:
            raise BrokerError("The task-scoped terminal reached its absolute lifetime.")
        timeout_seconds = min(float(timeout_seconds), remaining_age)
        self._write_lease("running", request_id=request_id)
        _send_frame(
            connection, {"v": PROTOCOL_VERSION, "type": "accepted", "request_id": request_id}
        )
        connection.settimeout(min(5.0, timeout_seconds + SOCKET_TIMEOUT_GRACE_SECONDS))
        try:
            result = self.session.run(
                command_argv,
                cwd=command_cwd,
                ensure_cwd=ensure_cwd,
                timeout_seconds=timeout_seconds,
                output=_SocketOutput(connection, request_id),
            )
            payload = _result_payload(result)
            self.lease["commands"] += 1
            self._write_lease("completed", request_id=request_id, result=payload)
            _send_frame(
                connection,
                {
                    "v": PROTOCOL_VERSION,
                    "type": "result",
                    "request_id": request_id,
                    **payload,
                    "reused": self.lease["commands"] > 1,
                },
            )
            self._write_lease("idle")
        except BaseException as error:
            prior_state = self.lease["state"]
            self.outcome_uncertain = True
            with contextlib.suppress(BaseException):
                self._record_uncertainty(request_id, prior_state)
            with contextlib.suppress(BaseException):
                _send_frame(
                    connection,
                    {
                        "v": PROTOCOL_VERSION,
                        "type": "error",
                        "request_id": request_id,
                        "code": "command_failed",
                        "message": str(error)[:512]
                        if isinstance(  # noqa: UP038
                            error, (BrokerError, terminal.TerminalClientError)
                        )
                        else type(error).__name__,
                        "outcome_uncertain": True,
                        "session_closed": bool(self.session.closed),
                    },
                )
            self.stop_requested = True
            raise
        finally:
            self.last_used_monotonic = time.monotonic()

    def serve(self) -> int:
        _prepare_paths(self.paths)
        lock = _open_lock(self.paths.broker_lock)
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise BrokerError("A broker already owns this exact task scope.") from None
            self._open_remote()
            self._bind()
            _unlink_private(self.paths.startup_error)
            while not self.stop_requested:
                now = time.monotonic()
                if (
                    now - self.last_used_monotonic >= self.idle_seconds
                    or now - self.started_monotonic >= self.max_age_seconds
                ):
                    break
                assert self.server is not None
                try:
                    connection, _address = self.server.accept()
                # macOS /usr/bin/python3 3.9 does not alias socket.timeout to
                # TimeoutError, even though newer Python versions do.
                except socket.timeout:  # noqa: UP041
                    continue
                with connection:
                    connection.settimeout(5.0)
                    try:
                        self._handle(connection)
                    except (BrokenPipeError, ConnectionError, OSError):
                        self.stop_requested = True
                    except BrokerError as error:
                        with contextlib.suppress(BaseException):
                            _send_frame(
                                connection,
                                {
                                    "v": PROTOCOL_VERSION,
                                    "type": "error",
                                    "code": "invalid_request",
                                    "message": str(error)[:512],
                                    "outcome_uncertain": False,
                                    "session_closed": False,
                                },
                            )
            return 0
        finally:
            if self.server is not None:
                self.server.close()
                self.server = None
            with contextlib.suppress(FileNotFoundError):
                self.paths.socket.unlink()
            cleanup_error: BaseException | None = None
            try:
                self._close_remote()
            except BaseException as error:
                cleanup_error = error
            _unlink_private(self.paths.pid)
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.close(lock)
            if cleanup_error is not None:
                raise cleanup_error


def _live_record(paths: BrokerPaths, scope: str) -> dict[str, Any] | None:
    record = _socket_record(paths, scope)
    if record is None:
        return None
    pid = record["pid"]
    if not _pid_alive(pid):
        return None
    if not _pid_is_exact_broker(pid, scope):
        raise BrokerError("The recorded live PID is not the exact scoped broker process.")
    return record


def _connect(paths: BrokerPaths, timeout: float) -> socket.socket:
    try:
        info = paths.socket.lstat()
    except OSError as error:
        raise BrokerError(f"The private broker socket is unavailable ({error.strerror}).") from None
    if (
        not stat.S_ISSOCK(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise BrokerError("The private broker socket failed its integrity check.")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(str(paths.socket))
    except OSError as error:
        client.close()
        raise BrokerError(
            f"Could not connect to the scoped terminal broker ({type(error).__name__})."
        ) from None
    return client


def _base_request(scope: str, op: str) -> dict[str, Any]:
    return {"v": PROTOCOL_VERSION, "source_id": _source_id(), "scope_id": scope, "op": op}


def _single_response(
    paths: BrokerPaths, request: dict[str, Any], *, timeout: float = 5.0
) -> dict[str, Any]:
    with _connect(paths, timeout) as client:
        _send_frame(client, request, limit=MAX_REQUEST_BYTES)
        return _FrameReader(client, limit=MAX_FRAME_BYTES).receive()


def _spawn_broker(paths: BrokerPaths, scope: str) -> None:
    interpreter = (
        Path("/usr/bin/python3") if Path("/usr/bin/python3").is_file() else Path(sys.executable)
    )
    process = subprocess.Popen(
        [str(interpreter), str(Path(__file__).resolve()), "_serve", "--scope-id", scope],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    deadline = time.monotonic() + START_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None:
            error = _read_private_json(paths.startup_error)
            message = error.get("message") if isinstance(error, dict) else None
            raise BrokerError(
                message
                if isinstance(message, str)
                else "The scoped terminal broker failed to start."
            )
        if paths.socket.exists() and paths.pid.exists():
            try:
                response = _single_response(paths, _base_request(scope, "health"), timeout=2)
            except BrokerError:
                time.sleep(0.05)
                continue
            if response.get("type") == "status" and response.get("source_id") == _source_id():
                return
        time.sleep(0.05)
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    raise BrokerError("Timed out starting the scoped terminal broker.")


def ensure_broker(paths: BrokerPaths, scope: str) -> None:
    with _lifecycle_lock(paths):
        record = _live_record(paths, scope)
        if record is not None and paths.socket.exists():
            if record.get("source_id") != _source_id():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(record["pid"], signal.SIGTERM)
                deadline = time.monotonic() + 5
                while _pid_alive(record["pid"]) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if _pid_alive(record["pid"]):
                    raise BrokerError("The previous broker version is still running.")
            else:
                return
        elif record is not None:
            raise BrokerError("The scoped broker is alive but its private socket is unavailable.")
        stale = _socket_record(paths, scope)
        if stale is not None and _pid_alive(stale["pid"]):
            raise BrokerError("Refusing to replace an unverified live broker process.")
        _unlink_private(paths.pid)
        with contextlib.suppress(FileNotFoundError):
            paths.socket.unlink()
        _spawn_broker(paths, scope)


def _stop_broker_after_client_abort(paths: BrokerPaths, scope: str) -> bool:
    """Ask only the exact scoped broker to clean up, then bound the wait."""

    record = _socket_record(paths, scope)
    if record is None:
        return _read_private_json(paths.lease) is None
    pid = record["pid"]
    if not _pid_alive(pid) or not _pid_is_exact_broker(pid, scope):
        return False
    with contextlib.suppress(OSError):
        os.kill(pid, signal.SIGINT)
    deadline = time.monotonic() + (2 * terminal.DELETE_TIMEOUT_SECONDS + 5.0)
    while _pid_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    return not _pid_alive(pid) and _read_private_json(paths.lease) is None


def execute(
    paths: BrokerPaths,
    scope: str,
    *,
    argv: list[str],
    cwd: str,
    ensure_cwd: bool,
    timeout_seconds: float,
    output: BinaryIO,
) -> terminal.ExecutionResult:
    ensure_broker(paths, scope)
    request_id = secrets.token_hex(16)
    request = {
        **_base_request(scope, "exec"),
        "request_id": request_id,
        "argv": argv,
        "cwd": cwd,
        "ensure_cwd": ensure_cwd,
        "timeout_seconds": timeout_seconds,
    }
    accepted = False
    expected_sequence = 0
    received_bytes = 0
    try:
        with _connect(paths, timeout_seconds + SOCKET_TIMEOUT_GRACE_SECONDS) as client:
            _send_frame(client, request, limit=MAX_REQUEST_BYTES)
            reader = _FrameReader(client, limit=MAX_FRAME_BYTES)
            while True:
                frame = reader.receive()
                if frame.get("v") != PROTOCOL_VERSION:
                    raise BrokerError("The broker response protocol did not match.")
                frame_type = frame.get("type")
                if frame_type == "accepted":
                    if (
                        set(frame) != {"v", "type", "request_id"}
                        or accepted
                        or frame.get("request_id") != request_id
                    ):
                        raise BrokerError("The broker sent an invalid acceptance frame.")
                    accepted = True
                    continue
                if frame_type == "stdout":
                    if (
                        set(frame) != {"v", "type", "request_id", "seq", "data_b64"}
                        or not accepted
                        or frame.get("request_id") != request_id
                        or frame.get("seq") != expected_sequence
                    ):
                        raise BrokerError("The broker output sequence was invalid.")
                    try:
                        data = base64.b64decode(frame.get("data_b64"), validate=True)
                    except (TypeError, ValueError, base64.binascii.Error):
                        raise BrokerError("The broker output frame was invalid.") from None
                    output.write(data)
                    output.flush()
                    received_bytes += len(data)
                    expected_sequence += 1
                    continue
                if frame_type == "result":
                    if not accepted:
                        raise BrokerError("The broker returned a result before acceptance.")
                    return _execution_result_from_frame(frame, request_id, received_bytes)
                if frame_type == "error":
                    uncertain = bool(frame.get("outcome_uncertain")) or accepted
                    suffix = (
                        " The command outcome is uncertain; verify its postcondition "
                        "before retrying."
                        if uncertain
                        else ""
                    )
                    raise BrokerError(
                        str(frame.get("message", "The broker command failed."))[:512] + suffix
                    )
                raise BrokerError("The broker sent an unsupported response frame.")
    except KeyboardInterrupt:
        with contextlib.suppress(BaseException):
            _stop_broker_after_client_abort(paths, scope)
        raise
    except BrokenPipeError:
        with contextlib.suppress(BaseException):
            _stop_broker_after_client_abort(paths, scope)
        raise
    except BrokerError as error:
        if accepted:
            with contextlib.suppress(BaseException):
                _stop_broker_after_client_abort(paths, scope)
            raise BrokerError(
                f"{error} The accepted command outcome is uncertain; verify its "
                "postcondition before retrying."
            ) from None
        raise
    except OSError as error:
        if accepted:
            with contextlib.suppress(BaseException):
                _stop_broker_after_client_abort(paths, scope)
            raise BrokerError(
                "The broker transport failed after acceptance; the command outcome is "
                "uncertain. Verify its postcondition before retrying."
            ) from None
        raise BrokerError(f"The broker transport failed ({type(error).__name__}).") from None


def close_scope(paths: BrokerPaths, scope: str) -> None:
    with _lifecycle_lock(paths):
        record = _live_record(paths, scope)
        if record is not None:
            if not paths.socket.exists():
                raise BrokerError(
                    "The exact scoped broker is alive but its private socket is unavailable."
                )
            response = _single_response(
                paths, _base_request(scope, "close"), timeout=terminal.MAX_TIMEOUT_SECONDS + 30
            )
            if response.get("type") != "closed":
                raise BrokerError("The scoped broker did not confirm exact terminal cleanup.")
            deadline = time.monotonic() + 10
            while _pid_alive(record["pid"]) and time.monotonic() < deadline:
                time.sleep(0.05)
            if _pid_alive(record["pid"]):
                raise BrokerError("The scoped broker did not exit after cleanup.")
        else:
            lease_value = _read_private_json(paths.lease)
            if lease_value is not None:
                lease = _validate_lease(lease_value, scope)
                config = _configuration()
                client = terminal.JupyterTerminalClient(
                    terminal.read_private_token(config.credentials.jupyter_token_file),
                    config=config,
                )
                client.cleanup_terminal(_validated_terminal_name(lease["terminal_name"]))
                _unlink_private(paths.lease)
        _unlink_private(paths.uncertain)
        _unlink_private(paths.startup_error)
        stale = _socket_record(paths, scope)
        if stale is None or not _pid_alive(stale["pid"]):
            _unlink_private(paths.pid)
            with contextlib.suppress(FileNotFoundError):
                paths.socket.unlink()


def status_scope(paths: BrokerPaths, scope: str) -> dict[str, Any]:
    record = _live_record(paths, scope)
    if record is not None:
        if not paths.socket.exists():
            raise BrokerError(
                "The exact scoped broker is alive but its private socket is unavailable."
            )
        return _single_response(paths, _base_request(scope, "status"), timeout=5)
    lease = _read_private_json(paths.lease)
    if lease is not None:
        value = _validate_lease(lease, scope)
        return {
            "v": PROTOCOL_VERSION,
            "type": "status",
            "scope_id": scope,
            "state": value["state"],
            "commands": value["commands"],
            "source_id": value["source_id"],
        }
    if _read_private_json(paths.uncertain) is not None:
        return {
            "v": PROTOCOL_VERSION,
            "type": "status",
            "scope_id": scope,
            "state": "outcome_uncertain",
            "commands": 0,
            "source_id": _source_id(),
        }
    return {
        "v": PROTOCOL_VERSION,
        "type": "status",
        "scope_id": scope,
        "state": "closed",
        "commands": 0,
        "source_id": _source_id(),
    }


def _serve_main(scope: str) -> int:
    paths = _paths(scope)
    _prepare_paths(paths)
    broker = TerminalBroker(scope, paths)
    handled = [
        value
        for value in (signal.SIGINT, signal.SIGTERM, getattr(signal, "SIGHUP", None))
        if value is not None
    ]
    previous: dict[int, Any] = {}

    def terminate(signum: int, _frame: Any) -> None:
        for handled_signal in handled:
            signal.signal(handled_signal, signal.SIG_IGN)
        raise BrokerExit(signum)

    for item in handled:
        previous[item] = signal.signal(item, terminate)
    try:
        return broker.serve()
    except BrokerExit as error:
        return min(255, 128 + error.signum)
    except BaseException as error:
        with contextlib.suppress(BaseException):
            _atomic_private_json(
                paths.startup_error,
                {
                    "schema": SCHEMA_VERSION,
                    "message": str(error)[:512]
                    if isinstance(  # noqa: UP038
                        error, (BrokerError, terminal.TerminalClientError)
                    )
                    else type(error).__name__,
                    "recorded_at": time.time(),
                },
            )
        return 1
    finally:
        for item, handler in previous.items():
            signal.signal(item, handler)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("exec", "close", "status"):
        command = subparsers.add_parser(operation)
        command.add_argument("--scope-root", required=True)
        if operation == "exec":
            command.add_argument("--cwd", required=True)
            command.add_argument("--ensure-cwd", action="store_true")
            command.add_argument(
                "--timeout",
                type=terminal._timeout_argument,
                default=terminal.DEFAULT_TIMEOUT_SECONDS,
            )
            command.add_argument("argv", nargs=argparse.REMAINDER)
    serve = subparsers.add_parser("_serve", help=argparse.SUPPRESS)
    serve.add_argument("--scope-id", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    if arguments.operation == "_serve":
        return _serve_main(arguments.scope_id)
    scope = scope_id(arguments.scope_root)
    paths = _paths(scope)
    try:
        if arguments.operation == "close":
            close_scope(paths, scope)
            return 0
        if arguments.operation == "status":
            print(json.dumps(status_scope(paths, scope), separators=(",", ":"), sort_keys=True))
            return 0
        command = list(arguments.argv)
        if command and command[0] == "--":
            command.pop(0)
        terminal.validate_argv(command)
        result = execute(
            paths,
            scope,
            argv=command,
            cwd=arguments.cwd,
            ensure_cwd=arguments.ensure_cwd,
            timeout_seconds=arguments.timeout,
            output=sys.stdout.buffer,
        )
        if result.truncated:
            print(
                f"\nICRN terminal output truncated at {result.output_bytes} bytes.", file=sys.stderr
            )
        return min(
            255, result.returncode if result.returncode >= 0 else 128 + abs(result.returncode)
        )
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        return 141
    except (BrokerError, terminal.TerminalClientError) as error:
        print(f"icrn-terminal-broker: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
