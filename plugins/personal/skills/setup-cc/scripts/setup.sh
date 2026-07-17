#!/usr/bin/env bash
# setup.sh — make Opus + xhigh the persistent default for Claude Code and wire up
# agent-yes. Idempotent: every change is a marker block, so re-running never duplicates.
#
# Override the target profile for testing with: CC_SETUP_PROFILE=/tmp/rc ./setup.sh
set -euo pipefail

# --- pick the shell profile -------------------------------------------------
detect_profile() {
  case "$(basename "${SHELL:-/bin/zsh}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) if [ -f "$HOME/.bashrc" ]; then echo "$HOME/.bashrc"; else echo "$HOME/.bash_profile"; fi ;;
    *)    echo "$HOME/.profile" ;;
  esac
}
PROFILE="${CC_SETUP_PROFILE:-$(detect_profile)}"
touch "$PROFILE"
cp "$PROFILE" "$PROFILE.cc.bak" 2>/dev/null || true   # rolling backup of the pre-run profile

# --- idempotent marker-block upsert ----------------------------------------
# upsert_block <marker-name> <content>. Matches any existing block by the
# ">>> <name>" / "<<< <name>" substrings (tolerates old blocks with extra text
# on the marker line), removes it, then appends a fresh canonical block.
upsert_block() {
  local name="$1" content="$2"
  local kb=">>> ${name}" ke="<<< ${name}"
  local bf="# >>> ${name} >>>" ef="# <<< ${name} <<<"
  if grep -qF "$kb" "$PROFILE" 2>/dev/null; then
    # Drop the old block; collapse blank runs and trim leading/trailing blanks so
    # repeated runs don't accumulate gaps where old blocks used to be.
    awk -v kb="$kb" -v ke="$ke" '
      index($0, kb) { skip = 1; next }
      index($0, ke) { skip = 0; next }
      skip          { next }
      /^[[:space:]]*$/ { blank = 1; next }
      { if (seen && blank) print ""; print; seen = 1; blank = 0 }
    ' "$PROFILE" > "$PROFILE.cctmp" && mv "$PROFILE.cctmp" "$PROFILE"
  fi
  { printf '\n%s\n' "$bf"; printf '%s\n' "$content"; printf '%s\n' "$ef"; } >> "$PROFILE"
  echo "  wrote block: ${name}"
}

echo "Profile: $PROFILE"

# --- 1. model + effort defaults --------------------------------------------
upsert_block "claude-code defaults" '# Opus + xhigh (persistent equivalent of ultracode) as the Claude Code default.
# INPUT env vars that override a soft org-managed default. Revert: delete this block, then `exec $SHELL`.
export ANTHROPIC_MODEL="opus"
export CLAUDE_CODE_EFFORT_LEVEL="xhigh"'

# --- 2. agent-yes install ---------------------------------------------------
if command -v ay >/dev/null 2>&1; then
  echo "  agent-yes: already installed ($(command -v ay))"
elif command -v npm >/dev/null 2>&1; then
  echo "  agent-yes: installing via 'npm install -g agent-yes' ..."
  if npm install -g agent-yes >/dev/null 2>&1; then
    echo "  agent-yes: installed"
  else
    echo "  agent-yes: npm install failed (needs a writable npm prefix or sudo); skipping" >&2
  fi
else
  echo "  agent-yes: npm not found — install Node.js/npm, then re-run to get the wrapper" >&2
fi

# --- 3. agent-yes wrapper function (caffeinate-wrapped so runs never idle-sleep) -----------
# NOTE on the caffeinate branches: caffeinate execs its target via PATH, so `caffeinate ... claude`
# runs the real binary, NOT this function (no recursion). The no-caffeinate fallbacks use
# `command` to bypass the function. Lid-closed survival still needs `lidawake on` (see block 4).
upsert_block "agent-yes" '# Route `claude` through agent-yes (auto-approves prompts) and hold a caffeinate
# assertion so a run never idle-sleeps. Bypass once: command claude ...  (lid-closed: lidawake on)
claude() {
  if command -v caffeinate >/dev/null 2>&1; then
    if command -v ay >/dev/null 2>&1; then
      caffeinate -dimsu ay claude -- "$@"
    else
      caffeinate -dimsu claude "$@"
    fi
  else
    if command -v ay >/dev/null 2>&1; then
      command ay claude -- "$@"
    else
      command claude "$@"
    fi
  fi
}'

# --- 4. keep-awake helpers (idle sleep + lid-closed operation) ------------------------------
upsert_block "keep-awake" '# Keep long agent runs alive on macOS. caffeinate stops idle/display/system sleep;
# surviving a CLOSED lid additionally needs `lidawake on` (sudo pmset disablesleep). Revert: lidawake off.
awake() { caffeinate -dimsu "$@"; }                          # run any command with no idle sleep
codex() { if command -v caffeinate >/dev/null 2>&1; then caffeinate -dimsu codex "$@"; else command codex "$@"; fi; }
lidawake() {                                                 # toggle lid-closed operation (asks for sudo)
  case "${1:-on}" in
    on)  sudo pmset -a disablesleep 1 && echo "Lid-closed sleep DISABLED — the Mac stays awake with the lid shut (use on AC power). Revert: lidawake off" ;;
    off) sudo pmset -a disablesleep 0 && echo "Lid behavior restored to normal." ;;
    *)   echo "usage: lidawake on|off" ;;
  esac
}'

echo
echo "Done. Open a NEW terminal (or run: exec \$SHELL) for the changes to take effect."
echo "To keep agents running with the LID CLOSED, run once (asks for your password): lidawake on"
