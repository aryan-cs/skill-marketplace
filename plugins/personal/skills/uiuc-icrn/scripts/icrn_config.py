#!/usr/bin/env python3
"""Load and validate the private, machine-local UIUC ICRN configuration."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import stat
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote, urlencode, urlsplit

SCHEMA_VERSION = 1
MAX_CONFIG_BYTES = 64 * 1024
CONFIG_ENVIRONMENT_VARIABLE = "UIUC_ICRN_CONFIG"
AUTH_ROLES = ("identity_provider", "institution", "microsoft", "mfa")

_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
_DOMAIN = re.compile(
    r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
)
_EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+")
_CHROME_PROFILE = re.compile(r"(?:Default|Profile [1-9][0-9]{0,5})")
_REMOTE_EXECUTABLE_COMPONENT = re.compile(r"[A-Za-z0-9._+-]+")


class ConfigError(Exception):
    """A sanitized configuration or configuration-file integrity failure."""


@dataclass(frozen=True)
class IdentityConfig:
    jupyter_username: str
    microsoft_account: str
    identity_provider_label: str


@dataclass(frozen=True)
class BrowserConfig:
    profile_directory: str
    user_data_directory: Path
    executable: Path


@dataclass(frozen=True)
class WorkspaceConfig:
    remote_root: str


@dataclass(frozen=True)
class TargetConfig:
    workbench_service: str
    hub_server_key: str
    profile: str
    image: str
    resource: str
    environment_label: str
    resource_label: str
    remote_python: str


@dataclass(frozen=True)
class CredentialsConfig:
    jupyter_token_file: Path


@dataclass(frozen=True)
class ICRNConfig:
    path: Path
    origin: str
    identity: IdentityConfig
    browser: BrowserConfig
    workspace: WorkspaceConfig
    target: TargetConfig
    credentials: CredentialsConfig
    allowed_auth_domains: dict[str, tuple[str, ...]]

    @property
    def origin_hostname(self) -> str:
        hostname = urlsplit(self.origin).hostname
        assert hostname is not None
        return hostname

    @property
    def server_base(self) -> str:
        username = quote(self.identity.jupyter_username, safe="")
        if self.target.hub_server_key:
            key = quote(self.target.hub_server_key, safe="")
            return f"/user/{username}/{key}/"
        return f"/user/{username}/"

    def launch_url(self) -> str:
        """Build the ordered duplicate-next JupyterHub permalink from trusted fields."""

        username = quote(self.identity.jupyter_username, safe="")
        service = quote(self.target.workbench_service, safe="")
        server_segment = (
            f"/{quote(self.target.hub_server_key, safe='')}"
            if self.target.hub_server_key
            else ""
        )
        workbench_path = f"/hub/user/{username}{server_segment}/{service}/"
        workbench_query = urlencode(
            (("folder", self.workspace.remote_root), ("redirects", "2"))
        )
        first_next = f"{workbench_path}?{workbench_query}"
        if self.target.hub_server_key:
            spawn_path = (
                f"/hub/spawn/{username}/"
                f"{quote(self.target.hub_server_key, safe='')}"
            )
        else:
            spawn_path = "/hub/spawn"
        fancy = {
            "profile": self.target.profile,
            "image": self.target.image,
            "image:unlisted_choice": "",
            "resource": self.target.resource,
            "resource:unlisted_choice": "",
        }
        spawn_fragment = "fancy-forms-config=" + json.dumps(
            fancy, separators=(",", ":"), ensure_ascii=True
        )
        second_next = f"{spawn_path}#{spawn_fragment}"
        query = urlencode((("next", first_next), ("next", second_next)))
        url = f"{self.origin}/hub/login?{query}"
        parsed = urlsplit(url)
        if f"{parsed.scheme}://{parsed.netloc}" != self.origin:
            raise ConfigError("The generated ICRN launch URL escaped the configured origin.")
        return url

    def shell_environment(self) -> dict[str, str]:
        return {
            CONFIG_ENVIRONMENT_VARIABLE: str(self.path),
            "ICRN_ORIGIN": self.origin,
            "ICRN_USERNAME": self.identity.jupyter_username,
            "ICRN_MICROSOFT_ACCOUNT": self.identity.microsoft_account,
            "ICRN_IDENTITY_PROVIDER_LABEL": self.identity.identity_provider_label,
            "ICRN_BROWSER_PROFILE_DIRECTORY": self.browser.profile_directory,
            "ICRN_BROWSER_USER_DATA_DIRECTORY": str(self.browser.user_data_directory),
            "ICRN_BROWSER_EXECUTABLE": str(self.browser.executable),
            "ICRN_REMOTE_ROOT": self.workspace.remote_root,
            "ICRN_WORKBENCH_SERVICE": self.target.workbench_service,
            "ICRN_SERVER_KEY": self.target.hub_server_key,
            "ICRN_PROFILE": self.target.profile,
            "ICRN_IMAGE": self.target.image,
            "ICRN_RESOURCE": self.target.resource,
            "ICRN_ENVIRONMENT_LABEL": self.target.environment_label,
            "ICRN_RESOURCE_LABEL": self.target.resource_label,
            "ICRN_REMOTE_PYTHON": self.target.remote_python,
            "ICRN_TOKEN_FILE": str(self.credentials.jupyter_token_file),
            "ICRN_ALLOWED_AUTH_DOMAINS_JSON": json.dumps(
                self.allowed_auth_domains,
                separators=(",", ":"),
                sort_keys=True,
            ),
            "ICRN_LAUNCH_URL": self.launch_url(),
        }

    def fingerprint(self) -> str:
        """Return a non-reversible compatibility identity for every configured field."""

        canonical = {
            "schema_version": SCHEMA_VERSION,
            "origin": self.origin,
            "identity": {
                "jupyter_username": self.identity.jupyter_username,
                "microsoft_account": self.identity.microsoft_account,
                "identity_provider_label": self.identity.identity_provider_label,
            },
            "browser": {
                "profile_directory": self.browser.profile_directory,
                "user_data_directory": str(self.browser.user_data_directory),
                "executable": str(self.browser.executable),
            },
            "workspace": {"remote_root": self.workspace.remote_root},
            "target": {
                "workbench_service": self.target.workbench_service,
                "hub_server_key": self.target.hub_server_key,
                "profile": self.target.profile,
                "image": self.target.image,
                "resource": self.target.resource,
                "environment_label": self.target.environment_label,
                "resource_label": self.target.resource_label,
                "remote_python": self.target.remote_python,
            },
            "credentials": {
                "jupyter_token_file": str(self.credentials.jupyter_token_file)
            },
            "allowed_auth_domains": self.allowed_auth_domains,
        }
        data = json.dumps(
            canonical, ensure_ascii=True, separators=(",", ":"), sort_keys=True
        ).encode("ascii")
        return hashlib.sha256(b"uiuc-icrn-config-v1\0" + data).hexdigest()


def default_config_path() -> Path:
    override = os.environ.get(CONFIG_ENVIRONMENT_VARIABLE)
    if override is not None:
        if not override:
            raise ConfigError(f"{CONFIG_ENVIRONMENT_VARIABLE} must not be empty.")
        return _absolute_local_path(override, CONFIG_ENVIRONMENT_VARIABLE)
    base = os.environ.get("XDG_CONFIG_HOME")
    if base:
        config_home = _absolute_local_path(base, "XDG_CONFIG_HOME")
    else:
        config_home = Path.home() / ".config"
    return config_home / "uiuc-icrn" / "config.json"


def _absolute_local_path(value: str, field: str) -> Path:
    if not isinstance(value, str) or not value or "\0" in value or "\n" in value or "\r" in value:
        raise ConfigError(f"{field} must be a nonempty local path without control characters.")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ConfigError(f"{field} must be an absolute path.")
    return Path(os.path.normpath(str(path)))


def _read_private_json(path: Path) -> dict[str, Any]:
    parent = path.parent
    try:
        parent_before = parent.lstat()
    except OSError as error:
        raise ConfigError(
            f"Could not inspect the private ICRN config directory: {error.strerror}."
        ) from None
    if stat.S_ISLNK(parent_before.st_mode) or not stat.S_ISDIR(parent_before.st_mode):
        raise ConfigError("The ICRN config directory must be a real non-symlink directory.")
    parent_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        parent_descriptor = os.open(parent, parent_flags)
    except OSError as error:
        raise ConfigError(
            f"Could not open the private ICRN config directory: {error.strerror}."
        ) from None
    try:
        parent_current = os.fstat(parent_descriptor)
        if (parent_before.st_dev, parent_before.st_ino) != (
            parent_current.st_dev,
            parent_current.st_ino,
        ):
            raise ConfigError("The ICRN config directory changed while it was opened.")
        if (
            not stat.S_ISDIR(parent_current.st_mode)
            or parent_current.st_uid != os.getuid()
            or stat.S_IMODE(parent_current.st_mode) != 0o700
        ):
            raise ConfigError(
                "The ICRN config directory must be current-user-owned and mode 0700."
            )
    finally:
        os.close(parent_descriptor)
    try:
        before = path.lstat()
    except OSError as error:
        raise ConfigError(f"Could not inspect the private ICRN config: {error.strerror}.") from None
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ConfigError("The ICRN config must be a regular non-symlink file.")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ConfigError(f"Could not open the private ICRN config: {error.strerror}.") from None
    try:
        current = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise ConfigError("The ICRN config changed while it was being opened.")
        if not stat.S_ISREG(current.st_mode):
            raise ConfigError("The ICRN config is not a regular file.")
        if current.st_uid != os.getuid():
            raise ConfigError("The ICRN config is not owned by the current user.")
        if stat.S_IMODE(current.st_mode) != 0o600:
            raise ConfigError("The ICRN config must have mode 0600.")
        if current.st_nlink != 1:
            raise ConfigError("The ICRN config must have exactly one hard link.")
        data = bytearray()
        while len(data) <= MAX_CONFIG_BYTES:
            chunk = os.read(descriptor, min(4096, MAX_CONFIG_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
    finally:
        os.close(descriptor)
    if not data or len(data) > MAX_CONFIG_BYTES:
        raise ConfigError("The ICRN config is empty or too large.")
    def exact_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ConfigError("The ICRN config contains a duplicate JSON key.")
            value[key] = item
        return value

    try:
        value = json.loads(data, object_pairs_hook=exact_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ConfigError("The ICRN config is not valid UTF-8 JSON.") from None
    if not isinstance(value, dict):
        raise ConfigError("The ICRN config root must be a JSON object.")
    return value


def _exact_object(value: Any, keys: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ConfigError(f"{field} must contain exactly: {', '.join(sorted(keys))}.")
    return value


def _text(value: Any, field: str, *, maximum: int = 256, allow_empty: bool = False) -> str:
    if (
        not isinstance(value, str)
        or (not allow_empty and not value)
        or len(value.encode("utf-8")) > maximum
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
    ):
        raise ConfigError(f"{field} is invalid.")
    if "<" in value or ">" in value:
        raise ConfigError(f"{field} still contains a public-example placeholder.")
    return value


def _identifier(value: Any, field: str, *, allow_empty: bool = False) -> str:
    value = _text(value, field, maximum=128, allow_empty=allow_empty)
    if value == "" and allow_empty:
        return value
    if _IDENTIFIER.fullmatch(value) is None:
        raise ConfigError(f"{field} must use only letters, numbers, dot, underscore, or hyphen.")
    return value


def _chrome_profile(value: Any) -> str:
    value = _text(value, "browser.profile_directory", maximum=32)
    if _CHROME_PROFILE.fullmatch(value) is None:
        raise ConfigError(
            "browser.profile_directory must be Default or Profile followed by a positive number."
        )
    return value


def _remote_path(value: Any, field: str, *, allow_root: bool = True) -> str:
    value = _text(value, field, maximum=4096)
    path = PurePosixPath(value)
    if not path.is_absolute() or str(path) != str(PurePosixPath(os.path.normpath(value))):
        raise ConfigError(f"{field} must be an absolute normalized POSIX path.")
    if not allow_root and path == PurePosixPath("/"):
        raise ConfigError(f"{field} must not be the filesystem root.")
    if any(part in {"", ".", ".."} for part in path.parts[1:]):
        raise ConfigError(f"{field} contains an unsafe path component.")
    return str(path)


def _remote_executable(value: Any, field: str) -> str:
    path = _remote_path(value, field, allow_root=False)
    if any(
        _REMOTE_EXECUTABLE_COMPONENT.fullmatch(part) is None
        for part in PurePosixPath(path).parts[1:]
    ):
        raise ConfigError(
            f"{field} contains characters that are unsafe in a remote executable path."
        )
    return path


def _origin(value: Any) -> str:
    value = _text(value, "origin", maximum=2048)
    parsed = urlsplit(value)
    hostname = parsed.hostname
    try:
        port = parsed.port
    except ValueError:
        raise ConfigError("origin contains an invalid port.") from None
    if (
        parsed.scheme != "https"
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
        or port not in {None, 443}
    ):
        raise ConfigError("origin must be one HTTPS origin without credentials, path, query, or fragment.")
    if hostname.endswith("."):
        raise ConfigError("origin must not use a trailing-dot hostname.")
    try:
        canonical_host = hostname.encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise ConfigError("origin must use a valid DNS hostname.") from None
    if _DOMAIN.fullmatch(canonical_host) is None:
        raise ConfigError("origin must use a valid DNS hostname.")
    if canonical_host != "illinois.edu" and not canonical_host.endswith(".illinois.edu"):
        raise ConfigError("origin must be an illinois.edu host.")
    netloc = canonical_host if port is None else f"{canonical_host}:{port}"
    return f"https://{netloc}"


def _auth_domains(value: Any) -> dict[str, tuple[str, ...]]:
    mapping = _exact_object(value, set(AUTH_ROLES), "allowed_auth_domains")
    result: dict[str, tuple[str, ...]] = {}
    for role in AUTH_ROLES:
        domains = mapping[role]
        if not isinstance(domains, list) or len(domains) > 32:
            raise ConfigError(f"allowed_auth_domains.{role} must be an array of at most 32 domains.")
        normalized: list[str] = []
        for domain in domains:
            domain = _text(domain, f"allowed_auth_domains.{role}", maximum=253).lower()
            try:
                domain = domain.encode("idna").decode("ascii")
            except UnicodeError:
                raise ConfigError(f"allowed_auth_domains.{role} contains an invalid domain.") from None
            if _DOMAIN.fullmatch(domain) is None:
                raise ConfigError(f"allowed_auth_domains.{role} contains an invalid domain.")
            normalized.append(domain)
        if len(set(normalized)) != len(normalized):
            raise ConfigError(f"allowed_auth_domains.{role} contains a duplicate domain.")
        result[role] = tuple(normalized)
    if not result["identity_provider"] or not result["institution"] or not result["microsoft"]:
        raise ConfigError("Identity-provider, institution, and Microsoft auth-domain lists must be nonempty.")
    assigned = [
        (role, domain)
        for role, domains in result.items()
        for domain in domains
    ]
    for index, (role, domain) in enumerate(assigned):
        for other_role, other_domain in assigned[index + 1 :]:
            if role == other_role:
                continue
            if (
                domain == other_domain
                or domain.endswith("." + other_domain)
                or other_domain.endswith("." + domain)
            ):
                raise ConfigError(
                    "Overlapping auth domains may not belong to different authentication roles."
                )
    return result


def load_config(path: Path | None = None) -> ICRNConfig:
    config_path = default_config_path() if path is None else _absolute_local_path(str(path), "config path")
    raw = _exact_object(
        _read_private_json(config_path),
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
        "config",
    )
    if raw["schema_version"] != SCHEMA_VERSION:
        raise ConfigError(f"schema_version must be {SCHEMA_VERSION}.")
    identity = _exact_object(
        raw["identity"],
        {"jupyter_username", "microsoft_account", "identity_provider_label"},
        "identity",
    )
    account = _text(identity["microsoft_account"], "identity.microsoft_account", maximum=254)
    if _EMAIL.fullmatch(account) is None or ".." in account.rsplit("@", 1)[1]:
        raise ConfigError("identity.microsoft_account must be an exact email address.")
    if account.rsplit("@", 1)[1].lower() != "illinois.edu":
        raise ConfigError("identity.microsoft_account must be an illinois.edu account.")
    browser = _exact_object(
        raw["browser"],
        {"profile_directory", "user_data_directory", "executable"},
        "browser",
    )
    target = _exact_object(
        raw["target"],
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
        "target",
    )
    workspace = _exact_object(raw["workspace"], {"remote_root"}, "workspace")
    credentials = _exact_object(
        raw["credentials"], {"jupyter_token_file"}, "credentials"
    )
    return ICRNConfig(
        path=config_path,
        origin=_origin(raw["origin"]),
        identity=IdentityConfig(
            jupyter_username=_identifier(
                identity["jupyter_username"], "identity.jupyter_username"
            ),
            microsoft_account=account,
            identity_provider_label=_text(
                identity["identity_provider_label"], "identity.identity_provider_label"
            ),
        ),
        browser=BrowserConfig(
            profile_directory=_chrome_profile(browser["profile_directory"]),
            user_data_directory=_absolute_local_path(
                browser["user_data_directory"], "browser.user_data_directory"
            ),
            executable=_absolute_local_path(browser["executable"], "browser.executable"),
        ),
        workspace=WorkspaceConfig(
            remote_root=_remote_path(
                workspace["remote_root"], "workspace.remote_root", allow_root=False
            )
        ),
        target=TargetConfig(
            workbench_service=_identifier(
                target["workbench_service"], "target.workbench_service"
            ),
            hub_server_key=_identifier(
                target["hub_server_key"], "target.hub_server_key", allow_empty=True
            ),
            profile=_identifier(target["profile"], "target.profile"),
            image=_identifier(target["image"], "target.image"),
            resource=_identifier(target["resource"], "target.resource"),
            environment_label=_text(target["environment_label"], "target.environment_label"),
            resource_label=_text(target["resource_label"], "target.resource_label"),
            remote_python=_remote_executable(
                target["remote_python"], "target.remote_python"
            ),
        ),
        credentials=CredentialsConfig(
            jupyter_token_file=_absolute_local_path(
                credentials["jupyter_token_file"], "credentials.jupyter_token_file"
            )
        ),
        allowed_auth_domains=_auth_domains(raw["allowed_auth_domains"]),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="Override the private config path")
    parser.add_argument("operation", choices=("validate", "shell-env"))
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        config = load_config(arguments.config)
        if arguments.operation == "shell-env":
            for name, value in config.shell_environment().items():
                print(f"export {name}={shlex.quote(value)}")
        return 0
    except ConfigError as error:
        print(f"icrn-config: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
