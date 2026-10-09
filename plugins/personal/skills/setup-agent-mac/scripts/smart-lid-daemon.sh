#!/bin/bash
# smart-lid-daemon.sh — order-aware lid sleep with a closed-lid battery cutoff and
# closed-lid idle sleep.
#
# Real mode runs as a root LaunchDaemon and controls `pmset disablesleep`.
# Simulation mode accepts `LOCKED CLOSED [POWER_SOURCE BATTERY_PERCENT [ACTIVITY]]`
# on stdin, where ACTIVITY is `busy` or `idle` and each line advances a simulated
# clock by SMART_LID_SIMULATION_STEP_SECONDS.
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
# On battery, a low-battery latch is released only once the charge is this many
# points above the cutoff, so a reading that flickers around it (20, 21, 20, ...)
# cannot re-arm keep-awake between samples. AC power releases it at any charge.
RECOVERY_MARGIN_PERCENT="${SMART_LID_RECOVERY_MARGIN_PERCENT:-5}"
# A close-first session exists so work can finish with the lid shut. Once nothing
# has needed the Mac awake for IDLE_SLEEP_SECONDS (0 disables this), it sleeps as
# an open Mac would on idle. Activity is sampled every ACTIVITY_CHECK_SECONDS.
IDLE_SLEEP_SECONDS="${SMART_LID_IDLE_SLEEP_SECONDS:-300}"
ACTIVITY_CHECK_SECONDS="${SMART_LID_ACTIVITY_CHECK_SECONDS:-30}"
SIMULATION_STEP_SECONDS="${SMART_LID_SIMULATION_STEP_SECONDS:-60}"
# While a battery latch is held, this world-readable flag tells agent-hold.sh not
# to take new holds: the cutoff released them so the Mac can sleep, and an agent
# hook would otherwise re-arm one at its next tool call.
LOW_BATTERY_FLAG="${SMART_LID_LOW_BATTERY_FLAG-/var/run/com.aryangupta.smart-lid.low-battery}"
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
simulation_activity=""
simulation_clock=0
idle_elapsed=""
last_idle_check=0
next_activity_check=0
low_battery_flag_state=""

validate_positive_integer() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*|0*)
      echo "$name must be a positive base-10 integer without leading zeros" >&2
      exit 64
      ;;
  esac
}

validate_nonnegative_integer() {
  [ "$2" = 0 ] || validate_positive_integer "$1" "$2"
}

validate_positive_integer SMART_LID_BATTERY_CHECK_LOOPS "$BATTERY_CHECK_LOOPS"
validate_positive_integer SMART_LID_BATTERY_RETRY_LOOPS "$BATTERY_RETRY_LOOPS"
validate_positive_integer SMART_LID_BATTERY_FAILURE_LIMIT "$BATTERY_FAILURE_LIMIT"
validate_positive_integer SMART_LID_LOW_BATTERY_PERCENT "$LOW_BATTERY_PERCENT"
[ "$LOW_BATTERY_PERCENT" -le 100 ] \
  || { echo "SMART_LID_LOW_BATTERY_PERCENT must be between 1 and 100" >&2; exit 64; }
[ "$RECOVERY_MARGIN_PERCENT" = 0 ] \
  || validate_positive_integer SMART_LID_RECOVERY_MARGIN_PERCENT "$RECOVERY_MARGIN_PERCENT"
[ $((LOW_BATTERY_PERCENT + RECOVERY_MARGIN_PERCENT)) -le 100 ] \
  || { echo "SMART_LID_LOW_BATTERY_PERCENT plus SMART_LID_RECOVERY_MARGIN_PERCENT must not exceed 100" >&2; exit 64; }
validate_nonnegative_integer SMART_LID_IDLE_SLEEP_SECONDS "$IDLE_SLEEP_SECONDS"
validate_positive_integer SMART_LID_ACTIVITY_CHECK_SECONDS "$ACTIVITY_CHECK_SECONDS"
validate_positive_integer SMART_LID_SIMULATION_STEP_SECONDS "$SIMULATION_STEP_SECONDS"

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

# Is anything doing work that needs the Mac awake? Prints what, and returns 0 if
# so, 1 if not, or 2 if that cannot be determined. Work is whatever would keep an
# open Mac from idle-sleeping: an idle-sleep assertion from any process (an agent
# turn via the agent-hold hooks, the Claude app's keep-awake while a session
# works, `awake`/caffeinate, audio playback, ...) or input since the last check
# (clamshell use with an external keyboard). powerd's own assertions are ignored
# except "display is on", which with the lid shut means an external display is in
# use; so are sharingd's short-lived Handoff holds.
read_activity() {
  local raw found idle_ns
  if [ "$simulation_mode" = 1 ]; then
    case "$simulation_activity" in
      busy) printf 'simulated activity\n'; return 0 ;;
      idle) return 1 ;;
      *) return 2 ;;
    esac
  fi
  raw="$($PMSET -g assertions 2>/dev/null)" || return 2
  case "$raw" in *"Listed by owning process"*) ;; *) return 2 ;; esac
  # Lines look like:   pid 61987(Claude): [0x0004bd0c0001a1b4] 33:27:25 NoIdleSleepAssertion named: "Electron"
  # Owner names can contain spaces, so split on "(" / "): [" rather than on fields.
  found="$(awk '
    /Listed by owning process/ { listed = 1; next }
    /^[^[:space:]]/ { listed = 0 }
    !listed || $1 != "pid" || found { next }
    {
      lp = index($0, "("); rp = index($0, "): [")
      if (!lp || rp <= lp) next
      owner = substr($0, lp + 1, rp - lp - 1)
      rest = substr($0, rp + 3)
      split(rest, field, " ")
      type = field[3]
      name = rest; sub(/^[^"]*named: "/, "", name); sub(/"[[:space:]]*$/, "", name)
      if (type != "PreventUserIdleSystemSleep" && type != "PreventSystemSleep" && type != "NoIdleSleepAssertion") next
      if (owner == "powerd" && name !~ /display is on/) next
      if (owner == "sharingd") next
      print owner " (" name ")"; found = 1
    }
  ' <<<"$raw")"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  idle_ns="$($IOREG -c IOHIDSystem -d 4 -r -k HIDIdleTime 2>/dev/null \
    | awk '/"HIDIdleTime" =/ { value = $NF } END { if (value != "") print value }')"
  case "$idle_ns" in
    ''|*[!0-9]*) ;;
    *) if [ "$idle_ns" -lt $((ACTIVITY_CHECK_SECONDS * 1000000000)) ]; then
         printf 'recent keyboard or trackpad input\n'
         return 0
       fi ;;
  esac
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
  # Preserve a known closed-lid policy across a daemon crash. /var/run is
  # cleared at boot, so an ambiguous post-boot closed+locked state remains fail-safe.
  [ -r "$STATE_FILE" ] || return 1
  local saved_phase
  saved_phase="$(awk -F= '$1 == "phase" {print $2; exit}' "$STATE_FILE")"
  case "$saved_phase" in
    closed-keep-awake|closed-idle-sleep)
      # A pending idle sleep is re-earned rather than replayed: work may have
      # started since, and enforce_closed_idle_sleep() re-checks within a cycle.
      phase="closed-keep-awake"
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

  if [ "$phase" = "low-battery-sleep" ] || [ "$phase" = "battery-unavailable-sleep" ]; then
    # Keep battery safety states latched in any lid position, lid events
    # included: reopening the lid must not re-arm keep-awake, or the guard trips
    # again a minute later and sleeps the Mac under whoever just opened it.
    # enforce_low_battery_sleep() releases the latch once the machine is back on
    # AC or above the cutoff. It samples only every few seconds while latched,
    # so a lid event samples first: plugging in and then closing the lid inside
    # that window must start a close-first session, not sleep.
    local battery_status
    if [ "$prev_closed" != "$closed" ] \
      && battery_status="$(read_battery_status)" \
      && battery_releases_latch "$battery_status"; then
      # Fall through to the ordinary lid transition below; prev_* still holds
      # the previous sample, so the lock-before-close ordering is preserved.
      release_battery_latch "$battery_status"
    else
      desired=0
      if [ "$closed" = 0 ]; then
        # An open lid may mean someone is using the Mac: allow idle sleep, never
        # force it.
        request_sleep=0
        sleep_reason=""
      elif [ "$prev_closed" = 0 ]; then
        request_sleep=1
        sleep_reason="lid closed while the battery guard is active"
      fi
      # Otherwise the lid stayed closed: the automatic lock must not cancel a
      # pending retry if `pmset sleepnow` failed.
      prev_locked="$locked"
      prev_closed="$closed"
      return
    fi
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
  elif [ "$prev_locked" = 0 ] && [ "$locked" = 1 ]; then
    if [ "$closed" = 1 ] && [ "$phase" = "closed-keep-awake" ]; then
      # Ignore the automatic lock caused by a close-first keep-awake session.
      desired=1
    elif [ "$closed" = 1 ] && [ "$phase" = "closed-idle-sleep" ]; then
      # Nor may a late lock cancel a pending idle sleep or its retry.
      :
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
  local pids pid args target agent_turn released=0
  pids="$("$PGREP" -x caffeinate 2>/dev/null)" || return 0
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] || continue
    # Record the session the hold protects before signalling, so it can be
    # restored later with `caffeinate -w`. For `caffeinate -w PID` that is the
    # -w target -- including the holds this daemon restores, whose parent is the
    # daemon itself: recording that parent would make the next recovery run
    # `caffeinate -w <daemon>`, a hold that never ends. Otherwise caffeinate
    # wraps its parent. Only caffeinate's own options are read: the scan stops
    # at the wrapped command, whose arguments (`claude -w NAME`) are not ours.
    args="$("$PS_BIN" -o args= -p "$pid" 2>/dev/null)"
    target="$(awk '{
      for (i = 2; i <= NF; i++) {
        if ($i == "-w") { if (i < NF) print $(i + 1); exit }
        if ($i == "-t") { i++; continue }
        if ($i !~ /^-[dimsu]+$/) exit
      }
    }' <<<"$args")"
    [ -n "$target" ] || target="$("$PS_BIN" -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    # An agent turn's hold (agent-hold.sh: `caffeinate -i -w AGENT`) is not
    # re-armed on recovery: the turn may have ended in the meantime, and if it
    # has not, its next tool call takes a fresh hold through the hook.
    agent_turn=0
    case "$args" in *"caffeinate -i -w $target") agent_turn=1 ;; esac
    if "$KILL_BIN" -TERM "$pid" 2>/dev/null; then
      released=$((released + 1))
      [ "$agent_turn" = 0 ] || continue
      case "$target" in
        ''|*[!0-9]*) ;;
        *) [ "$target" -gt 1 ] \
             && released_caffeinate_targets="${released_caffeinate_targets}${released_caffeinate_targets:+ }$target" ;;
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

# Entering a battery safety state always restores normal sleep (desired=0), but
# only a closed lid is put to sleep on the spot. With the lid open someone may be
# mid-task, so the Mac is left to sleep normally on idle or when the lid closes;
# macOS's own critical-battery sleep still applies once disablesleep is cleared.
request_battery_sleep() {
  if [ "$prev_closed" = 1 ]; then
    request_sleep=1
    log "$sleep_reason; restoring normal sleep"
  else
    request_sleep=0
    log "$sleep_reason; lid open, so keep-awake is off but sleep is not forced"
  fi
  # Clearing disablesleep is not sufficient on its own: the claude()/codex()/
  # awake() wrappers this skill installs run under `caffeinate -dimsu`, and -i
  # holds a PreventUserIdleSystemSleep assertion that pmset does not override.
  # With the lid open and no sleepnow, these holds would keep the Mac awake.
  release_caffeinate_assertions
}

# True when a battery sample ("SOURCE PERCENT") shows AC power or a charge
# above the cutoff.
battery_above_cutoff() {
  local power_source="${1%% *}" battery_percent="${1#* }"
  [ "$power_source" != "battery" ] || [ "$battery_percent" -gt "$LOW_BATTERY_PERCENT" ]
}

# True when a sample releases the current battery latch: AC power, or a charge
# above the cutoff -- for a low-battery latch, above it by the recovery margin,
# so a reading that flickers around the cutoff cannot release it. A
# battery-unavailable latch is about telemetry, not charge, and needs no margin.
battery_releases_latch() {
  local power_source="${1%% *}" battery_percent="${1#* }" floor="$LOW_BATTERY_PERCENT"
  [ "$phase" != "low-battery-sleep" ] || floor=$((LOW_BATTERY_PERCENT + RECOVERY_MARGIN_PERCENT))
  [ "$power_source" != "battery" ] || [ "$battery_percent" -gt "$floor" ]
}

# Leave a battery safety state: normal lid behavior resumes and the caffeinate
# holds released at the cutoff are re-armed. The caller decides how the lid
# phase is re-derived.
release_battery_latch() {
  log "battery recovered (${1%% *}, ${1#* }%); resuming normal lid behavior"
  phase="battery-recovered"
  request_sleep=0
  sleep_reason=""
  battery_check_count=0
  battery_check_target="$BATTERY_CHECK_LOOPS"
  battery_read_failures=0
  restore_caffeinate_assertions
}

enforce_low_battery_sleep() {
  local battery_status battery_percent
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

  # While latched, sample on the short retry cadence (~5s) rather than the full
  # interval, so plugging in releases the latch promptly. Not every cycle: with
  # the lid open the latch can last as long as the remaining battery, and forking
  # pmset ten times a second would spend that battery.
  if [ "$simulation_mode" != 1 ] || [ "${SMART_LID_SIMULATION_RESPECT_BATTERY_INTERVAL:-0}" = 1 ]; then
    local check_target="$battery_check_target"
    if [ "$latched" = 1 ] && [ "$check_target" -gt "$BATTERY_RETRY_LOOPS" ]; then
      check_target="$BATTERY_RETRY_LOOPS"
    fi
    battery_check_count=$((battery_check_count + 1))
    [ "$battery_check_count" -ge "$check_target" ] || return 0
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
        sleep_reason="battery status unavailable for ${battery_read_failures} consecutive checks"
        request_battery_sleep
      fi
      desired=0
    fi
    return 0
  fi
  battery_check_count=0
  battery_check_target="$BATTERY_CHECK_LOOPS"
  battery_read_failures=0
  battery_percent="${battery_status#* }"

  # Back on AC, or recovered clear of the cutoff: release a latched safety state
  # so normal lid behaviour resumes without needing another lid event.
  if [ "$latched" = 1 ] && battery_releases_latch "$battery_status"; then
    release_battery_latch "$battery_status"
    # The latch does not record the lid phase, so re-derive it from the sensors.
    prev_locked=""
    prev_closed=""
    return 0
  fi
  # Above the cutoff there is nothing to enforce. A low-battery latch that is
  # still inside the recovery margin stays held (transition_state keeps desired=0).
  if battery_above_cutoff "$battery_status"; then
    return 0
  fi

  if [ "$phase" != "low-battery-sleep" ]; then
    phase="low-battery-sleep"
    sleep_reason="${battery_percent}% battery on battery power (cutoff ${LOW_BATTERY_PERCENT}%)"
    request_battery_sleep
  fi
  desired=0
}

# With the lid shut in a close-first session, sleep once nothing has needed the
# Mac awake for IDLE_SLEEP_SECONDS -- the agent's turn finished, the app let go
# of its keep-awake -- rather than staying up until the battery cutoff.
enforce_closed_idle_sleep() {
  [ "$IDLE_SLEEP_SECONDS" -gt 0 ] || return 0
  if [ "$phase" != "closed-keep-awake" ]; then
    idle_elapsed=""
    next_activity_check=0
    return 0
  fi
  # A simulation line without the activity column is not exercising this guard.
  if [ "$simulation_mode" = 1 ] && [ -z "$simulation_activity" ]; then
    return 0
  fi
  local now="$SECONDS" activity rc step
  [ "$simulation_mode" != 1 ] || now="$simulation_clock"
  [ "$now" -ge "$next_activity_check" ] || return 0
  next_activity_check=$((now + ACTIVITY_CHECK_SECONDS))

  activity="$(read_activity)"
  rc=$?
  if [ "$rc" != 1 ]; then
    # Busy, or unknown: an unreadable sample must never sleep a Mac mid-task.
    if [ -n "$idle_elapsed" ]; then
      log "work resumed with the lid closed: ${activity:-activity unknown}"
    fi
    idle_elapsed=""
    return 0
  fi
  if [ -z "$idle_elapsed" ]; then
    idle_elapsed=0
    log "lid closed and nothing needs the Mac awake; sleeping in ${IDLE_SLEEP_SECONDS}s unless work resumes"
  else
    # Count only plausible time between samples: $SECONDS follows the wall clock,
    # and a clock step must not cut the window short.
    step=$((now - last_idle_check))
    [ "$step" -ge 0 ] || step=0
    [ "$step" -le $((2 * ACTIVITY_CHECK_SECONDS)) ] || step=$((2 * ACTIVITY_CHECK_SECONDS))
    idle_elapsed=$((idle_elapsed + step))
  fi
  last_idle_check="$now"
  [ "$idle_elapsed" -ge "$IDLE_SLEEP_SECONDS" ] || return 0
  phase="closed-idle-sleep"
  desired=0
  request_sleep=1
  sleep_reason="lid closed and nothing has needed the Mac awake for ${idle_elapsed}s"
  log "$sleep_reason; restoring normal sleep"
  idle_elapsed=""
}

# Keep the low-battery flag in step with the battery latch (see LOW_BATTERY_FLAG).
sync_low_battery_flag() {
  [ -n "$LOW_BATTERY_FLAG" ] || return 0
  local want=0
  case "$phase" in low-battery-sleep|battery-unavailable-sleep) want=1 ;; esac
  [ "$want" != "$low_battery_flag_state" ] || return 0
  if [ "$want" = 1 ]; then
    if (umask 022; : > "$LOW_BATTERY_FLAG") 2>/dev/null; then low_battery_flag_state=1; fi
  else
    if rm -f "$LOW_BATTERY_FLAG" 2>/dev/null; then low_battery_flag_state=0; fi
  fi
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
  local locked closed power_source battery_percent activity
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
  # Likewise the low-battery flag is a real file other processes read.
  LOW_BATTERY_FLAG="${SMART_LID_LOW_BATTERY_FLAG:-}"
  while read -r locked closed power_source battery_percent activity _; do
    [ -n "${locked:-}" ] || continue
    simulation_power_source="${power_source:-}"
    simulation_battery_percent="${battery_percent:-}"
    simulation_activity="${activity:-}"
    simulation_clock=$((simulation_clock + SIMULATION_STEP_SECONDS))
    transition_state "$locked" "$closed"
    enforce_low_battery_sleep
    enforce_closed_idle_sleep
    sync_low_battery_flag
    save_state
    if [ "${SMART_LID_SIMULATION_APPLY:-0}" = 1 ]; then apply_power_state; fi
    print_state
  done
  if [ "${SMART_LID_SIMULATION_KEEP_STATE:-0}" != 1 ]; then
    rm -f "$STATE_FILE"
  fi
}

status() {
  local locked closed sleep_disabled battery_status power_source battery_percent activity
  locked="$(read_locked)" || { echo "status=error reason=lock-sensor-unavailable"; return 1; }
  closed="$(read_closed)" || { echo "status=error reason=lid-sensor-unavailable"; return 1; }
  sleep_disabled="$(read_sleep_disabled)" || sleep_disabled="unknown"
  battery_status="$(read_battery_status)" || battery_status="unknown unknown"
  power_source="${battery_status%% *}"
  battery_percent="${battery_status#* }"
  activity="$(read_activity)"
  case $? in
    0) activity="busy: $activity" ;;
    1) activity="idle" ;;
    *) activity="unknown" ;;
  esac
  printf 'status=ok locked=%s closed=%s SleepDisabled=%s PowerSource=%s BatteryPercent=%s LowBatteryCutoff=%s IdleSleepSeconds=%s\n' \
    "$locked" "$closed" "${sleep_disabled:-unknown}" "$power_source" "$battery_percent" "$LOW_BATTERY_PERCENT" "$IDLE_SLEEP_SECONDS"
  # What would keep a closed lid awake right now, if it were closed.
  printf 'activity=%s\n' "$activity"
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
    [ -z "$LOW_BATTERY_FLAG" ] || rm -f "$LOW_BATTERY_FLAG" 2>/dev/null || true
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
      enforce_closed_idle_sleep
    else
      phase="failsafe"; desired=0; request_sleep=0; sleep_reason=""; prev_locked=""; prev_closed=""
      # This drops any battery latch, so sample as soon as the sensors return
      # rather than holding the Mac awake for a full interval at low battery.
      battery_check_count="$BATTERY_CHECK_LOOPS"; battery_check_target="$BATTERY_CHECK_LOOPS"
    fi
    sync_low_battery_flag
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
