#!/bin/bash
# smart-lid-daemon.sh — distinguish close-then-lock from lock-then-close.
#
# Real mode runs as a root LaunchDaemon and controls `pmset disablesleep`.
# Simulation mode accepts `LOCKED CLOSED` pairs on stdin for deterministic tests.
set -uo pipefail

PMSET="${SMART_LID_PMSET:-/usr/bin/pmset}"
IOREG="${SMART_LID_IOREG:-/usr/sbin/ioreg}"
LOGGER="${SMART_LID_LOGGER:-/usr/bin/logger}"
SLEEP_BIN="${SMART_LID_SLEEP:-/bin/sleep}"
INTERVAL="${SMART_LID_INTERVAL:-0.10}"
RECONCILE_LOOPS="${SMART_LID_RECONCILE_LOOPS:-50}"
STATE_FILE="${SMART_LID_STATE_FILE:-/var/run/com.aryangupta.smart-lid.state}"
LABEL="com.aryangupta.smart-lid"

phase="unknown"
prev_locked=""
prev_closed=""
desired=""
request_sleep=0
last_applied=""
last_saved=""
reconcile_count=0

log() {
  local message="$*"
  if [ -x "$LOGGER" ]; then
    "$LOGGER" -t "$LABEL" -- "$message" 2>/dev/null || true
  fi
  printf '%s\n' "$message" >&2
}

read_locked() {
  local raw
  raw="$($IOREG -n Root -d1 -r 2>/dev/null)" || return 1
  case "$raw" in
    *'"IOConsoleLocked" = Yes'*) printf '1\n' ;;
    *'"IOConsoleLocked" = No'*) printf '0\n' ;;
    *) return 1 ;;
  esac
}

read_closed() {
  local raw
  raw="$($IOREG -r -k AppleClamshellState -d4 2>/dev/null)" || return 1
  case "$raw" in
    *'"AppleClamshellState" = Yes'*) printf '1\n' ;;
    *'"AppleClamshellState" = No'*) printf '0\n' ;;
    *) return 1 ;;
  esac
}

read_sleep_disabled() {
  local key value
  while read -r key value _; do
    if [ "$key" = "SleepDisabled" ] && { [ "$value" = 0 ] || [ "$value" = 1 ]; }; then
      printf '%s\n' "$value"
      return 0
    fi
  done <<EOF
$($PMSET -g 2>/dev/null)
EOF
  return 1
}

save_state() {
  local dir tmp signature
  signature="$phase:$prev_locked:$prev_closed:$desired"
  [ "$signature" != "$last_saved" ] || return 0
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir"
  tmp="${STATE_FILE}.tmp.$$"
  printf 'phase=%s\nprev_locked=%s\nprev_closed=%s\ndesired=%s\n' \
    "$phase" "$prev_locked" "$prev_closed" "$desired" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATE_FILE"
  last_saved="$signature"
}

load_state_for_closed_restart() {
  # Preserve a close-first keep-awake session across a daemon crash. /var/run is
  # cleared at boot, so an ambiguous post-boot closed+locked state remains fail-safe.
  [ -r "$STATE_FILE" ] || return 1
  local saved_phase
  saved_phase="$(awk -F= '$1 == "phase" {print $2; exit}' "$STATE_FILE")"
  [ "$saved_phase" = "closed-keep-awake" ] || return 1
  phase="closed-keep-awake"
  desired=1
  return 0
}

initialize_state() {
  local locked="$1" closed="$2"
  request_sleep=0
  if [ "$closed" = 1 ] && [ "$locked" = 1 ] && load_state_for_closed_restart; then
    :
  elif [ "$closed" = 1 ] && [ "$locked" = 1 ]; then
    # No trustworthy ordering history: fail safe and put a closed Mac to sleep.
    phase="failsafe"; desired=0; request_sleep=1
  elif [ "$closed" = 1 ] && [ "$locked" = 0 ]; then
    phase="closed-keep-awake"; desired=1
  elif [ "$closed" = 0 ] && [ "$locked" = 1 ]; then
    phase="locked-open"; desired=0
  elif [ "$closed" = 0 ] && [ "$locked" = 0 ]; then
    phase="unlocked-open"; desired=1
  else
    phase="failsafe"; desired=0
  fi
  prev_locked="$locked"
  prev_closed="$closed"
}

transition_state() {
  local locked="$1" closed="$2"

  case "$locked:$closed" in
    0:0|0:1|1:0|1:1) ;;
    *) phase="failsafe"; desired=0; request_sleep=0; prev_locked=""; prev_closed=""; return ;;
  esac

  if [ -z "$prev_locked" ] || [ -z "$prev_closed" ]; then
    initialize_state "$locked" "$closed"
    return
  fi

  # Lid transition wins when both sensors change inside one polling interval.
  # A human lock-then-close sequence is observed as a lock transition first;
  # a close-first sequence can report closed+locked together because macOS may
  # lock the display as a consequence of closing it.
  if [ "$prev_closed" = 0 ] && [ "$closed" = 1 ]; then
    if [ "$prev_locked" = 0 ] && [ "$phase" != "locked-open" ]; then
      phase="closed-keep-awake"
      desired=1
      request_sleep=0
    else
      phase="closed-sleep"
      desired=0
      request_sleep=1
    fi
  elif [ "$prev_closed" = 1 ] && [ "$closed" = 0 ]; then
    if [ "$locked" = 1 ]; then
      phase="locked-open"; desired=0; request_sleep=0
    else
      phase="unlocked-open"; desired=1; request_sleep=0
    fi
  elif [ "$prev_locked" = 0 ] && [ "$locked" = 1 ]; then
    if [ "$closed" = 1 ] && [ "$phase" = "closed-keep-awake" ]; then
      # Ignore the automatic lock caused by a close-first keep-awake session.
      desired=1
    else
      phase="locked-open"; desired=0
      request_sleep=0
    fi
  elif [ "$prev_locked" = 1 ] && [ "$locked" = 0 ]; then
    if [ "$closed" = 1 ]; then
      phase="closed-keep-awake"; desired=1
      request_sleep=0
    else
      phase="unlocked-open"; desired=1
      request_sleep=0
    fi
  fi

  prev_locked="$locked"
  prev_closed="$closed"
}

apply_power_state() {
  local actual=""
  reconcile_count=$((reconcile_count + 1))
  if [ "$desired" != "$last_applied" ] || [ "$reconcile_count" -ge "$RECONCILE_LOOPS" ]; then
    actual="$(read_sleep_disabled)" || actual=""
    if [ "$actual" = "$desired" ]; then
      last_applied="$desired"
      reconcile_count=0
    elif "$PMSET" -a disablesleep "$desired"; then
      last_applied="$desired"
      reconcile_count=0
      log "phase=$phase locked=$prev_locked closed=$prev_closed disablesleep=$desired"
    else
      last_applied=""
      log "ERROR: failed to set disablesleep=$desired; will retry"
    fi
  fi
  if [ "$request_sleep" = 1 ]; then
    log "explicit lock preceded lid close; requesting system sleep"
    if "$PMSET" sleepnow; then
      request_sleep=0
    else
      log "ERROR: sleepnow failed; will retry while the lid remains closed"
    fi
  fi
}

print_state() {
  printf 'locked=%s closed=%s phase=%s disablesleep=%s sleepnow=%s\n' \
    "$prev_locked" "$prev_closed" "$phase" "$desired" "$request_sleep"
}

simulate() {
  local locked closed
  # 'simulate' is a test/debug path. Refuse to issue REAL power changes as root: that is what the
  # 'run' daemon (with its cleanup trap) is for, and without a trap here a `sudo ... simulate` could
  # leave disablesleep stuck at 1. Applying against a mocked pmset as a normal user stays allowed.
  if [ "${SMART_LID_SIMULATION_APPLY:-0}" = 1 ] && [ "$(id -u)" -eq 0 ]; then
    echo "refusing to run 'simulate' with SMART_LID_SIMULATION_APPLY=1 as root; use 'run' instead." >&2
    exit 77
  fi
  STATE_FILE="${SMART_LID_STATE_FILE:-/tmp/com.aryangupta.smart-lid.simulation.$$}"
  if [ "${SMART_LID_SIMULATION_KEEP_STATE:-0}" != 1 ]; then
    rm -f "$STATE_FILE"
  fi
  while read -r locked closed _; do
    [ -n "${locked:-}" ] || continue
    transition_state "$locked" "$closed"
    save_state
    if [ "${SMART_LID_SIMULATION_APPLY:-0}" = 1 ]; then apply_power_state; fi
    print_state
  done
  if [ "${SMART_LID_SIMULATION_KEEP_STATE:-0}" != 1 ]; then
    rm -f "$STATE_FILE"
  fi
}

status() {
  local locked closed sleep_disabled
  locked="$(read_locked)" || { echo "status=error reason=lock-sensor-unavailable"; return 1; }
  closed="$(read_closed)" || { echo "status=error reason=lid-sensor-unavailable"; return 1; }
  sleep_disabled="$(read_sleep_disabled)" || sleep_disabled="unknown"
  printf 'status=ok locked=%s closed=%s SleepDisabled=%s\n' "$locked" "$closed" "${sleep_disabled:-unknown}"
  if [ -r "$STATE_FILE" ]; then
    tr '\n' ' ' < "$STATE_FILE"; printf '\n'
  fi
}

run_daemon() {
  [ "${SMART_LID_ALLOW_NONROOT_TEST:-0}" = 1 ] || [ "$(id -u)" -eq 0 ] \
    || { echo "smart lid daemon must run as root" >&2; exit 77; }
  local locked closed
  cleanup() {
    "$PMSET" -a disablesleep 0 >/dev/null 2>&1 || true
  }
  shutdown() {
    trap - TERM INT EXIT
    cleanup
    exit 0
  }
  trap shutdown TERM INT
  trap cleanup EXIT
  while :; do
    if locked="$(read_locked)" && closed="$(read_closed)"; then
      transition_state "$locked" "$closed"
    else
      phase="failsafe"; desired=0; request_sleep=0; prev_locked=""; prev_closed=""
    fi
    save_state
    apply_power_state
    "$SLEEP_BIN" "$INTERVAL"
  done
}

case "${1:-run}" in
  run) run_daemon ;;
  status) status ;;
  simulate) simulate ;;
  *) echo "usage: $0 {run|status|simulate}" >&2; exit 64 ;;
esac
