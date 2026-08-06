#!/bin/bash
# smart-lid-daemon.sh — order-aware lid sleep with a closed-lid battery cutoff.
#
# Real mode runs as a root LaunchDaemon and controls `pmset disablesleep`.
# Simulation mode accepts `LOCKED CLOSED [POWER_SOURCE BATTERY_PERCENT]` on stdin.
set -uo pipefail

PMSET="${SMART_LID_PMSET:-/usr/bin/pmset}"
IOREG="${SMART_LID_IOREG:-/usr/sbin/ioreg}"
LOGGER="${SMART_LID_LOGGER:-/usr/bin/logger}"
SLEEP_BIN="${SMART_LID_SLEEP:-/bin/sleep}"
INTERVAL="${SMART_LID_INTERVAL:-0.10}"
RECONCILE_LOOPS="${SMART_LID_RECONCILE_LOOPS:-50}"
BATTERY_CHECK_LOOPS="${SMART_LID_BATTERY_CHECK_LOOPS:-600}"
BATTERY_RETRY_LOOPS="${SMART_LID_BATTERY_RETRY_LOOPS:-50}"
BATTERY_FAILURE_LIMIT="${SMART_LID_BATTERY_FAILURE_LIMIT:-3}"
LOW_BATTERY_PERCENT="${SMART_LID_LOW_BATTERY_PERCENT:-20}"
# `caffeinate CMD` runs CMD as its PARENT and re-execs itself as a child, so
# signalling the caffeinate PID drops its sleep assertion while the wrapped
# command keeps running. Never signal the parent or a process group: that would
# kill the agent session this guard exists to protect.
RELEASE_CAFFEINATE="${SMART_LID_RELEASE_CAFFEINATE:-1}"
PGREP="${SMART_LID_PGREP:-/usr/bin/pgrep}"
KILL_BIN="${SMART_LID_KILL:-/bin/kill}"
CAFFEINATE="${SMART_LID_CAFFEINATE:-/usr/bin/caffeinate}"
PS_BIN="${SMART_LID_PS:-/bin/ps}"
# PIDs of the sessions whose caffeinate holds were released at the cutoff, so the
# holds can be restored once power returns. Recorded as the PARENT of each
# caffeinate (the wrapped command), because that is the process that outlives the
# release and that a restored assertion must be tied to.
released_caffeinate_targets=""
STATE_FILE="${SMART_LID_STATE_FILE:-/var/run/com.aryangupta.smart-lid.state}"
LABEL="com.aryangupta.smart-lid"

phase="unknown"
prev_locked=""
prev_closed=""
desired=""
request_sleep=0
sleep_reason=""
last_applied=""
last_saved=""
reconcile_count=0
battery_check_count="$BATTERY_CHECK_LOOPS"
battery_check_target="$BATTERY_CHECK_LOOPS"
battery_read_failures=0
simulation_mode=0
simulation_power_source=""
simulation_battery_percent=""

validate_positive_integer() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*|0*)
      echo "$name must be a positive base-10 integer without leading zeros" >&2
      exit 64
      ;;
  esac
}

validate_positive_integer SMART_LID_BATTERY_CHECK_LOOPS "$BATTERY_CHECK_LOOPS"
validate_positive_integer SMART_LID_BATTERY_RETRY_LOOPS "$BATTERY_RETRY_LOOPS"
validate_positive_integer SMART_LID_BATTERY_FAILURE_LIMIT "$BATTERY_FAILURE_LIMIT"
validate_positive_integer SMART_LID_LOW_BATTERY_PERCENT "$LOW_BATTERY_PERCENT"
[ "$LOW_BATTERY_PERCENT" -le 100 ] \
  || { echo "SMART_LID_LOW_BATTERY_PERCENT must be between 1 and 100" >&2; exit 64; }

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

read_battery_status() {
  local raw power_source battery_percent
  if [ "$simulation_mode" = 1 ]; then
    power_source="$simulation_power_source"
    battery_percent="$simulation_battery_percent"
  else
    raw="$($PMSET -g batt 2>/dev/null)" || return 1
    case "$raw" in
      *"Now drawing from 'Battery Power'"*) power_source="battery" ;;
      *"Now drawing from 'AC Power'"*) power_source="ac" ;;
      *) return 1 ;;
    esac
    # `pmset -g batt` may also list external batteries or UPS devices. Use
    # only InternalBattery records, choosing the lowest percentage if macOS
    # reports more than one, so another source cannot mask a low Mac battery.
    battery_percent="$(printf '%s\n' "$raw" | awk '
      /InternalBattery/ && match($0, /[0-9][0-9]*%/) {
        value = substr($0, RSTART, RLENGTH - 1) + 0
        if (!found || value < minimum) {
          minimum = value
        }
        found = 1
      }
      END { if (found) print minimum }
    ')"
  fi

  case "$power_source" in
    battery|ac) ;;
    *) return 1 ;;
  esac
  case "$battery_percent" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$battery_percent" -le 100 ] || return 1
  printf '%s %s\n' "$power_source" "$battery_percent"
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
  # Preserve a known closed-lid policy across a daemon crash. /var/run is
  # cleared at boot, so an ambiguous post-boot closed+locked state remains fail-safe.
  [ -r "$STATE_FILE" ] || return 1
  local saved_phase
  saved_phase="$(awk -F= '$1 == "phase" {print $2; exit}' "$STATE_FILE")"
  case "$saved_phase" in
    closed-keep-awake)
      phase="$saved_phase"
      desired=1
      ;;
    low-battery-sleep|battery-unavailable-sleep)
      phase="$saved_phase"
      desired=0
      request_sleep=1
      sleep_reason="restoring saved battery safety state"
      ;;
    *)
      return 1
      ;;
  esac
}

initialize_state() {
  local locked="$1" closed="$2"
  request_sleep=0
  sleep_reason=""
  if [ "$closed" = 1 ] && load_state_for_closed_restart; then
    :
  elif [ "$closed" = 1 ] && [ "$locked" = 1 ]; then
    # No trustworthy ordering history: fail safe and put a closed Mac to sleep.
    phase="failsafe"; desired=0; request_sleep=1
    sleep_reason="ambiguous closed startup"
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
    *) phase="failsafe"; desired=0; request_sleep=0; sleep_reason=""; prev_locked=""; prev_closed=""; return ;;
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
      sleep_reason=""
    else
      phase="closed-sleep"
      desired=0
      request_sleep=1
      sleep_reason="explicit lock preceded lid close"
    fi
  elif [ "$prev_closed" = 1 ] && [ "$closed" = 0 ]; then
    if [ "$locked" = 1 ]; then
      phase="locked-open"; desired=0; request_sleep=0; sleep_reason=""
    else
      phase="unlocked-open"; desired=1; request_sleep=0; sleep_reason=""
    fi
  elif [ "$phase" = "low-battery-sleep" ] || [ "$phase" = "battery-unavailable-sleep" ]; then
    # Keep battery safety states latched in any lid position. In particular, the
    # automatic lock must not cancel a pending retry if `pmset sleepnow` failed.
    # enforce_low_battery_sleep() re-evaluates each cycle and releases the latch
    # once the machine is back on AC or above the cutoff.
    desired=0
  elif [ "$prev_locked" = 0 ] && [ "$locked" = 1 ]; then
    if [ "$closed" = 1 ] && [ "$phase" = "closed-keep-awake" ]; then
      # Ignore the automatic lock caused by a close-first keep-awake session.
      desired=1
    else
      phase="locked-open"; desired=0
      request_sleep=0
      sleep_reason=""
    fi
  elif [ "$prev_locked" = 1 ] && [ "$locked" = 0 ]; then
    if [ "$closed" = 1 ]; then
      phase="closed-keep-awake"; desired=1
      request_sleep=0
      sleep_reason=""
    else
      phase="unlocked-open"; desired=1
      request_sleep=0
      sleep_reason=""
    fi
  fi

  prev_locked="$locked"
  prev_closed="$closed"
}

# Drop caffeinate sleep assertions by signalling the caffeinate PIDs only, so the
# commands they wrap keep running and merely stop preventing sleep.
release_caffeinate_assertions() {
  [ "$RELEASE_CAFFEINATE" = 1 ] || return 0
  [ -x "$PGREP" ] || return 0
  local pids pid parent released=0
  pids="$("$PGREP" -x caffeinate 2>/dev/null)" || return 0
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] || continue
    # Record the wrapped command (caffeinate's parent) before signalling, so the
    # hold can be restored later with `caffeinate -w`.
    parent="$("$PS_BIN" -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if "$KILL_BIN" -TERM "$pid" 2>/dev/null; then
      released=$((released + 1))
      case "$parent" in
        ''|*[!0-9]*) ;;
        *) [ "$parent" -gt 1 ] \
             && released_caffeinate_targets="${released_caffeinate_targets}${released_caffeinate_targets:+ }$parent" ;;
      esac
    fi
  done
  [ "$released" -gt 0 ] || return 0
  log "released $released caffeinate sleep assertion(s); wrapped commands keep running"
}

# Restore the holds released at the cutoff, once the battery has recovered. Each
# is re-created with `caffeinate -w PID`, which asserts on behalf of the wrapped
# command and exits by itself when that command does -- so a session that ended
# in the meantime is skipped rather than leaking an assertion forever.
restore_caffeinate_assertions() {
  [ -n "$released_caffeinate_targets" ] || return 0
  local pid restored=0
  if [ "$RELEASE_CAFFEINATE" != 1 ] || [ ! -x "$CAFFEINATE" ]; then
    released_caffeinate_targets=""
    return 0
  fi
  for pid in $released_caffeinate_targets; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    # Only re-arm sessions that are still alive.
    "$KILL_BIN" -0 "$pid" 2>/dev/null || continue
    # Detached on purpose: caffeinate -w blocks until the target exits.
    "$CAFFEINATE" -dimsu -w "$pid" >/dev/null 2>&1 &
    restored=$((restored + 1))
  done
  released_caffeinate_targets=""
  [ "$restored" -gt 0 ] || return 0
  log "restored $restored caffeinate sleep assertion(s) for still-running sessions"
}

enforce_low_battery_sleep() {
  local battery_status power_source battery_percent
  # The guard runs in every lid state. A long agent run on battery usually has
  # the lid OPEN, and `unlocked-open` sets desired=1, so skipping the open case
  # left the machine pinned awake by disablesleep all the way down to 0%.
  local latched=0
  case "$phase" in
    low-battery-sleep|battery-unavailable-sleep) latched=1 ;;
  esac

  # A latched safety state holds desired=0, so it must still be evaluated each
  # cycle -- otherwise the latch could never be released once power returns.
  if [ "$desired" != 1 ] && [ "$latched" != 1 ]; then
    # Sleep is already permitted, so there is nothing to override. Reset the
    # cadence so the next keep-awake period samples the battery immediately.
    battery_check_count="$BATTERY_CHECK_LOOPS"
    battery_check_target="$BATTERY_CHECK_LOOPS"
    battery_read_failures=0
    return 0
  fi

  # A simulation line that omits the power-source/percent columns is exercising
  # lid ordering only, not the battery guard. Treat it as "no sample offered"
  # rather than as an unreadable battery, which would trip the failure path.
  if [ "$simulation_mode" = 1 ] && [ -z "$simulation_power_source" ]; then
    return 0
  fi

  # While latched, sample every cycle: the throttle exists to avoid polling the
  # battery during normal keep-awake, not to delay releasing a safety state.
  if [ "$latched" != 1 ] \
    && { [ "$simulation_mode" != 1 ] || [ "${SMART_LID_SIMULATION_RESPECT_BATTERY_INTERVAL:-0}" = 1 ]; }; then
    battery_check_count=$((battery_check_count + 1))
    [ "$battery_check_count" -ge "$battery_check_target" ] || return 0
  fi

  if ! battery_status="$(read_battery_status)"; then
    # A malformed or temporarily unavailable reading must not disable the
    # guard for another full minute. Retry after about five seconds by default.
    battery_check_count=0
    battery_check_target="$BATTERY_RETRY_LOOPS"
    battery_read_failures=$((battery_read_failures + 1))
    if [ "$battery_read_failures" -ge "$BATTERY_FAILURE_LIMIT" ]; then
      if [ "$phase" != "battery-unavailable-sleep" ]; then
        phase="battery-unavailable-sleep"
        request_sleep=1
        sleep_reason="battery status unavailable for ${battery_read_failures} consecutive checks"
        log "$sleep_reason; restoring normal sleep"
      fi
      desired=0
    fi
    return 0
  fi
  battery_check_count=0
  battery_check_target="$BATTERY_CHECK_LOOPS"
  battery_read_failures=0
  power_source="${battery_status%% *}"
  battery_percent="${battery_status#* }"

  # Back on AC, or recovered above the cutoff: release a latched safety state so
  # normal lid behaviour resumes without needing another lid event.
  if [ "$power_source" != "battery" ] || [ "$battery_percent" -gt "$LOW_BATTERY_PERCENT" ]; then
    if [ "$phase" = "low-battery-sleep" ] || [ "$phase" = "battery-unavailable-sleep" ]; then
      log "battery recovered (${power_source}, ${battery_percent}%); resuming normal lid behavior"
      phase="battery-recovered"
      request_sleep=0
      sleep_reason=""
      prev_locked=""
      prev_closed=""
      restore_caffeinate_assertions
    fi
    return 0
  fi

  if [ "$phase" != "low-battery-sleep" ]; then
    phase="low-battery-sleep"
    request_sleep=1
    sleep_reason="${battery_percent}% battery on battery power (cutoff ${LOW_BATTERY_PERCENT}%)"
    log "$sleep_reason; restoring normal sleep"
    # Clearing disablesleep is not sufficient on its own: the claude()/codex()/
    # awake() wrappers this skill installs run under `caffeinate -dimsu`, and -i
    # holds a PreventUserIdleSystemSleep assertion that pmset does not override.
    release_caffeinate_assertions
  fi
  desired=0
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
    log "${sleep_reason:-smart-lid policy requested sleep}; requesting system sleep"
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
  local locked closed power_source battery_percent
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
  simulation_mode=1
  # Releasing caffeinate holds signals REAL processes, which is a side effect on the host
  # machine and not a simulated one. A plain `./smart-lid-daemon.sh simulate` fed a
  # below-cutoff sample would otherwise drop every keep-awake hold on the Mac running it --
  # observed happening while verifying an install. Default it off here and require an
  # explicit opt-in; the tests that cover the release pass SMART_LID_RELEASE_CAFFEINATE=1
  # along with mocked pgrep/kill.
  RELEASE_CAFFEINATE="${SMART_LID_RELEASE_CAFFEINATE:-0}"
  while read -r locked closed power_source battery_percent _; do
    [ -n "${locked:-}" ] || continue
    simulation_power_source="${power_source:-}"
    simulation_battery_percent="${battery_percent:-}"
    transition_state "$locked" "$closed"
    enforce_low_battery_sleep
    save_state
    if [ "${SMART_LID_SIMULATION_APPLY:-0}" = 1 ]; then apply_power_state; fi
    print_state
  done
  if [ "${SMART_LID_SIMULATION_KEEP_STATE:-0}" != 1 ]; then
    rm -f "$STATE_FILE"
  fi
}

status() {
  local locked closed sleep_disabled battery_status power_source battery_percent
  locked="$(read_locked)" || { echo "status=error reason=lock-sensor-unavailable"; return 1; }
  closed="$(read_closed)" || { echo "status=error reason=lid-sensor-unavailable"; return 1; }
  sleep_disabled="$(read_sleep_disabled)" || sleep_disabled="unknown"
  battery_status="$(read_battery_status)" || battery_status="unknown unknown"
  power_source="${battery_status%% *}"
  battery_percent="${battery_status#* }"
  printf 'status=ok locked=%s closed=%s SleepDisabled=%s PowerSource=%s BatteryPercent=%s LowBatteryCutoff=%s\n' \
    "$locked" "$closed" "${sleep_disabled:-unknown}" "$power_source" "$battery_percent" "$LOW_BATTERY_PERCENT"
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
      enforce_low_battery_sleep
    else
      phase="failsafe"; desired=0; request_sleep=0; sleep_reason=""; prev_locked=""; prev_closed=""
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
