#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

/usr/bin/python3 "$SCRIPT_DIR/icrn_config.py" validate >/dev/null

if project_root="$(/usr/bin/git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
  project_prefix="$(/usr/bin/git -C "$PWD" rev-parse --show-prefix)"
else
  project_root="$(pwd -P)"
  project_prefix=""
fi

project_name="${project_root##*/}"
if [[ -z "$project_name" || "$project_name" == "." || "$project_name" == ".." || "$project_name" == */* ]]; then
  printf 'Could not derive a safe project directory name from %s\n' "$project_root" >&2
  exit 2
fi

remote_cwd="$project_name"
if [[ -n "$project_prefix" ]]; then
  remote_cwd="$remote_cwd/${project_prefix%/}"
fi

case "${1:-}" in
  --session-close)
    shift
    if [[ $# -ne 0 ]]; then
      printf '%s\n' '--session-close does not accept command arguments' >&2
      exit 2
    fi
    exec /usr/bin/python3 "$SCRIPT_DIR/icrn_terminal_broker.py" close \
      --scope-root "$project_root"
    ;;
  --session-status)
    shift
    if [[ $# -ne 0 ]]; then
      printf '%s\n' '--session-status does not accept command arguments' >&2
      exit 2
    fi
    exec /usr/bin/python3 "$SCRIPT_DIR/icrn_terminal_broker.py" status \
      --scope-root "$project_root"
    ;;
  --one-shot)
    shift
    exec /usr/bin/python3 "$SCRIPT_DIR/icrn_jupyter_terminal.py" \
      --ensure-cwd --cwd "$remote_cwd" "$@"
    ;;
esac

exec /usr/bin/python3 "$SCRIPT_DIR/icrn_terminal_broker.py" exec \
  --scope-root "$project_root" --ensure-cwd --cwd "$remote_cwd" "$@"
