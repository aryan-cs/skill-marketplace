#!/bin/bash
# agent-hold.sh — hold the Mac awake only while a Claude Code or Codex turn runs.
#
# setup.sh registers this as a hook in ~/.claude/settings.json and ~/.codex/hooks.json:
#   start   UserPromptSubmit                                   hold `caffeinate -i -w AGENT`
#   stop    Stop, StopFailure, SessionEnd, Interrupt, idle     release it
# AGENT is the CLI process running the hook, so a hold never outlives its session
# even when no stop event arrives (an API error, a killed terminal). The smart-lid
# daemon counts these holds as work in progress: with the lid closed it lets the
# Mac sleep once none remain. An open session that is waiting at its prompt holds
# nothing, which is the point -- the old wrappers held the Mac for the whole session.
#
# A hook must never get in the agent's way: this prints nothing (UserPromptSubmit
# stdout is injected into the conversation) and always exits 0 (a non-zero exit can
# block the prompt).
set -u

CAFFEINATE="${AGENT_HOLD_CAFFEINATE:-/usr/bin/caffeinate}"
PS_BIN="${AGENT_HOLD_PS:-/bin/ps}"
PKILL="${AGENT_HOLD_PKILL:-/usr/bin/pkill}"
STATE_DIR="${AGENT_HOLD_STATE_DIR:-$HOME/.local/state/setup-agent-mac/agent-hold}"

# The CLI process that ran this hook. Claude Code and Codex both run hooks as direct
# children; a shell in between is allowed, but nothing further up, so a hook-like
# call from some other program never attaches to an unrelated session above it.
agent_pid() {
  local pid="$PPID" comm
  comm="$("$PS_BIN" -o comm= -p "$pid" 2>/dev/null)" || return 1
  case "${comm##*/}" in
    sh|bash|zsh|dash|-sh|-bash|-zsh)
      pid="$("$PS_BIN" -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
      case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
      comm="$("$PS_BIN" -o comm= -p "$pid" 2>/dev/null)" || return 1
      ;;
  esac
  case "${comm##*/}" in
    claude|codex) printf '%s\n' "$pid" ;;
    *) return 1 ;;
  esac
}

# True when $1 is a live `caffeinate ... -w $2` hold.
hold_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$("$PS_BIN" -o args= -p "$1" 2>/dev/null)" in
    *caffeinate*" -w $2") return 0 ;;
  esac
  return 1
}

start_hold() {
  local agent="$1" file hold entry
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  # Forget sessions that have ended; their holds ended with them.
  for entry in "$STATE_DIR"/*; do
    [ -e "$entry" ] || continue
    kill -0 "${entry##*/}" 2>/dev/null || rm -f "$entry"
  done
  file="$STATE_DIR/$agent"
  if hold="$(cat "$file" 2>/dev/null)" && hold_alive "$hold" "$agent"; then
    return 0
  fi
  # Every descriptor redirected: an inherited stdout would keep the hook "running".
  "$CAFFEINATE" -i -w "$agent" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$file"
}

stop_hold() {
  local agent="$1" file="$STATE_DIR/$1" hold
  if hold="$(cat "$file" 2>/dev/null)" && hold_alive "$hold" "$agent"; then
    kill "$hold" 2>/dev/null
  fi
  rm -f "$file"
  # Also a hold the smart-lid daemon re-armed for this session after a low-battery
  # cutoff. It runs those as the session's user, so they can be released here.
  "$PKILL" -U "$(id -u)" -f "caffeinate -[dimsu]+ -w ${agent}\$" >/dev/null 2>&1
  return 0
}

cat >/dev/null 2>&1   # the hook's JSON payload; nothing in it is needed
agent="$(agent_pid)" || exit 0
case "${1:-}" in
  start) start_hold "$agent" ;;
  stop) stop_hold "$agent" ;;
esac
exit 0
