#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly CACHE_ROOT="${TMPDIR:-/tmp}/uiuc-icrn-capture-${UID}"

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [OUTPUT.png]\n' "$0" >&2
  exit 2
fi

output="${1:-${TMPDIR:-/tmp}/icrn-vscode-window.png}"
CONFIG_EXPORTS=""
if ! CONFIG_EXPORTS="$(/usr/bin/python3 "$SCRIPT_DIR/icrn_config.py" shell-env)"; then
  exit 1
fi
readonly CONFIG_EXPORTS
eval "$CONFIG_EXPORTS"
mkdir -p "$CACHE_ROOT/swift" "$CACHE_ROOT/clang"

SWIFT_MODULECACHE_PATH="$CACHE_ROOT/swift" \
CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
  /usr/bin/swift "$SCRIPT_DIR/capture_icrn_window.swift" "$output"
