#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly CACHE_ROOT="${TMPDIR:-/tmp}/open-icrn-${UID}"
readonly LOCK_DIR="${TMPDIR:-/tmp}/open-icrn-${UID}.lock"

usage() {
  printf 'Usage: %s [--run|--observe]\n' "$0" >&2
}

mode="${1:---run}"
case "$mode" in
  --run|--observe) ;;
  *) usage; exit 2 ;;
esac

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

CONFIG_EXPORTS=""
if ! CONFIG_EXPORTS="$(/usr/bin/python3 "$SCRIPT_DIR/icrn_config.py" shell-env)"; then
  exit 1
fi
readonly CONFIG_EXPORTS
eval "$CONFIG_EXPORTS"

if [[ ! -x "$ICRN_BROWSER_EXECUTABLE" ]]; then
  printf 'The configured Chrome executable was not found.\n' >&2
  exit 1
fi

readonly PROFILE_DIR="$ICRN_BROWSER_USER_DATA_DIRECTORY/$ICRN_BROWSER_PROFILE_DIRECTORY"
if [[ ! -d "$PROFILE_DIR" ]]; then
  printf 'The configured Chrome profile directory was not found.\n' >&2
  exit 1
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf 'Another ICRN controller is already running.\n' >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

mkdir -p "$CACHE_ROOT/swift" "$CACHE_ROOT/clang"

export OPEN_ICRN_CHROME="$ICRN_BROWSER_EXECUTABLE"
export OPEN_ICRN_PROFILE="$ICRN_BROWSER_PROFILE_DIRECTORY"
export OPEN_ICRN_USER_DATA_DIR="$ICRN_BROWSER_USER_DATA_DIRECTORY"
export OPEN_ICRN_URL="$ICRN_LAUNCH_URL"
SWIFT_MODULECACHE_PATH="$CACHE_ROOT/swift" \
CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
  /usr/bin/swift "$SCRIPT_DIR/open_icrn.swift" "$mode"
