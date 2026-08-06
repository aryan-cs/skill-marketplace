#!/bin/bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$SKILL_DIR/scripts/smart-lid-daemon.sh"
INSTALLER="$SKILL_DIR/scripts/install-smart-lid.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-smart-lid.XXXXXX")"
background_pids=""
cleanup() {
  local pid
  trap - EXIT INT TERM
  for pid in $background_pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in $background_pids; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
track_pid() {
  background_pids="${background_pids}${background_pids:+ }$1"
}
untrack_pid() {
  local finished="$1" pid remaining=""
  for pid in $background_pids; do
    [ "$pid" = "$finished" ] || remaining="${remaining}${remaining:+ }$pid"
  done
  background_pids="$remaining"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_line() {
  local output="$1" line_no="$2" expected="$3" actual
  actual="$(printf '%s\n' "$output" | sed -n "${line_no}p")"
  case "$actual" in *"$expected"*) ;; *) fail "line $line_no expected '$expected', got '$actual'" ;; esac
}

echo "== close first stays awake, including the automatic lock =="
out="$(printf '0 0\n0 1\n1 1\n1 0\n0 0\n' | SMART_LID_STATE_FILE="$TMP/state-a" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=unlocked-open disablesleep=1 sleepnow=0"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 3 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 4 "phase=locked-open disablesleep=0 sleepnow=0"
assert_line "$out" 5 "phase=unlocked-open disablesleep=1 sleepnow=0"

echo "== lock first then close restores sleep and requests it immediately =="
out="$(printf '0 0\n1 0\n1 1\n1 0\n0 0\n' | SMART_LID_STATE_FILE="$TMP/state-b" "$DAEMON" simulate)"
assert_line "$out" 2 "phase=locked-open disablesleep=0 sleepnow=0"
assert_line "$out" 3 "phase=closed-sleep disablesleep=0 sleepnow=1"
assert_line "$out" 4 "phase=locked-open disablesleep=0 sleepnow=0"
assert_line "$out" 5 "phase=unlocked-open disablesleep=1 sleepnow=0"

echo "== simultaneous closed+locked sample is treated as close-first =="
out="$(printf '0 0\n1 1\n' | SMART_LID_STATE_FILE="$TMP/state-c" "$DAEMON" simulate)"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"

echo "== closed lid sleeps when battery falls to the cutoff =="
out="$(printf '0 0 battery 20\n0 1 battery 21\n1 1 battery 20\n' | \
  SMART_LID_STATE_FILE="$TMP/state-low-battery" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 3 "phase=low-battery-sleep disablesleep=0 sleepnow=1"

echo "== an OPEN lid on battery is guarded too (issue #9) =="
# The original guard exempted the lid-open case, so a long agent run on battery
# stayed pinned awake by disablesleep=1 all the way to 0%.
out="$(printf '0 0 battery 3\n0 0 battery 2\n0 0 battery 1\n' | \
  SMART_LID_STATE_FILE="$TMP/state-low-battery-open" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
assert_line "$out" 2 "disablesleep=0"
assert_line "$out" 3 "disablesleep=0"

echo "== AC power never trips the cutoff, at any charge =="
out="$(printf '0 0 ac 5\n0 1 ac 5\n1 1 ac 5\n1 1 battery 5\n' | \
  SMART_LID_STATE_FILE="$TMP/state-low-battery-ac" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=unlocked-open disablesleep=1 sleepnow=0"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 3 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 4 "phase=low-battery-sleep disablesleep=0 sleepnow=1"

echo "== recovering onto AC releases the latch and restores keep-awake =="
out="$(printf '0 0 battery 5\n0 0 ac 5\n0 1 ac 50\n' | \
  SMART_LID_STATE_FILE="$TMP/state-low-battery-recover" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
assert_line "$out" 2 "phase=battery-recovered"
assert_line "$out" 3 "phase=closed-keep-awake disablesleep=1 sleepnow=0"

echo "== periodic battery checks are throttled between samples =="
# The first three samples are above the cutoff; the drop to 20% is only observed
# once the throttle interval elapses.
out="$(printf '0 0 battery 30\n0 1 battery 30\n1 1 battery 30\n1 1 battery 20\n1 1 battery 20\n' | \
  SMART_LID_BATTERY_CHECK_LOOPS=4 SMART_LID_SIMULATION_RESPECT_BATTERY_INTERVAL=1 \
  SMART_LID_STATE_FILE="$TMP/state-low-battery-throttle" "$DAEMON" simulate)"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 3 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 4 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 5 "phase=low-battery-sleep disablesleep=0 sleepnow=1"

echo "== three consecutive battery read failures fail safe and success resets the streak =="
out="$(printf '0 0 battery 50\n0 1 invalid 0\n1 1 invalid 0\n1 1 battery 50\n1 1 invalid 0\n1 1 invalid 0\n1 1 invalid 0\n' | \
  SMART_LID_BATTERY_CHECK_LOOPS=1 SMART_LID_BATTERY_RETRY_LOOPS=1 \
  SMART_LID_BATTERY_FAILURE_LIMIT=3 SMART_LID_SIMULATION_RESPECT_BATTERY_INTERVAL=1 \
  SMART_LID_STATE_FILE="$TMP/state-battery-failure-limit" "$DAEMON" simulate)"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 3 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 4 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 5 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 6 "phase=closed-keep-awake disablesleep=1 sleepnow=0"
assert_line "$out" 7 "phase=battery-unavailable-sleep disablesleep=0 sleepnow=1"

echo "== caffeinate assertions are released when the cutoff fires =="
fake_pgrep="$TMP/fake-pgrep"; fake_kill="$TMP/fake-kill"; kill_log="$TMP/kill.log"
printf '#!/bin/bash\nprintf "4242\\n4243\\n"\n' > "$fake_pgrep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FAKE_KILL_LOG"\nexit 0\n' > "$fake_kill"
chmod +x "$fake_pgrep" "$fake_kill"
: > "$kill_log"
out="$(printf '0 0 battery 5\n' | FAKE_KILL_LOG="$kill_log" \
  SMART_LID_PGREP="$fake_pgrep" SMART_LID_KILL="$fake_kill" \
  SMART_LID_STATE_FILE="$TMP/state-caffeinate" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
grep -q -- "-TERM 4242" "$kill_log" || fail "should TERM each caffeinate pid, got: $(cat "$kill_log")"
grep -q -- "-TERM 4243" "$kill_log" || fail "should TERM every caffeinate pid, got: $(cat "$kill_log")"
if grep -q -- "-TERM -" "$kill_log"; then
  fail "must never signal a process group; that would kill the wrapped agent session"
fi

echo "== recovering above the cutoff re-arms the released caffeinate holds =="
fake_caffeinate="$TMP/fake-caffeinate"; caff_log="$TMP/caffeinate.log"
fake_ps="$TMP/fake-ps"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FAKE_CAFFEINATE_LOG"\n' > "$fake_caffeinate"
# Report a plausible parent (the wrapped command) for each stubbed caffeinate pid.
printf '#!/bin/bash\nprintf "  %%s\\n" "$((${4:-0} - 100))"\n' > "$fake_ps"
chmod +x "$fake_caffeinate" "$fake_ps"
: > "$kill_log"; : > "$caff_log"
# Drop to 5% (release), then return to AC (restore). `kill -0` liveness probes go
# through the same stub, which exits 0, so both recorded pids count as alive.
out="$(printf '0 0 battery 5\n0 0 ac 60\n' | FAKE_KILL_LOG="$kill_log" \
  FAKE_CAFFEINATE_LOG="$caff_log" SMART_LID_PGREP="$fake_pgrep" SMART_LID_KILL="$fake_kill" \
  SMART_LID_CAFFEINATE="$fake_caffeinate" SMART_LID_PS="$fake_ps" \
  SMART_LID_STATE_FILE="$TMP/state-caffeinate-restore" "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
assert_line "$out" 2 "phase=battery-recovered"
sleep 0.5
grep -q -- "-dimsu -w" "$caff_log" \
  || fail "recovery should re-arm holds with 'caffeinate -dimsu -w PID', got: $(cat "$caff_log")"
restored="$(grep -c -- "-dimsu -w" "$caff_log" || true)"
[ "${restored:-0}" -ge 1 ] || fail "expected at least one restored hold, got $restored"

echo "== a second recovery does not re-arm holds that were never released =="
: > "$caff_log"
out="$(printf '0 0 ac 60\n0 0 ac 61\n' | FAKE_KILL_LOG="$kill_log" \
  FAKE_CAFFEINATE_LOG="$caff_log" SMART_LID_PGREP="$fake_pgrep" SMART_LID_KILL="$fake_kill" \
  SMART_LID_CAFFEINATE="$fake_caffeinate" SMART_LID_PS="$fake_ps" \
  SMART_LID_STATE_FILE="$TMP/state-caffeinate-norestore" "$DAEMON" simulate)"
sleep 0.3
[ ! -s "$caff_log" ] || fail "nothing was released, so nothing should be re-armed: $(cat "$caff_log")"

echo "== real caffeinate: a released hold is genuinely restored on recovery =="
# End-to-end on the real tool: the assertion must come back, and be tied to the
# still-running session so it clears by itself when that session ends.
if command -v caffeinate >/dev/null 2>&1; then
  # Track OUR OWN pids rather than a system-wide assertion count: other processes
  # on the machine hold caffeinate assertions too, and counting them all makes
  # this test flaky.
  # Capture first, then match with `case`. Piping into `grep -q` makes grep exit
  # on the first hit, which SIGPIPEs pmset; under `set -o pipefail` that turns a
  # successful match into a non-zero pipeline (rc=141).
  holds_assertion() {
    local out
    out="$(pmset -g assertions 2>/dev/null || true)"
    case "$out" in *"pid $1(caffeinate)"*) return 0 ;; *) return 1 ;; esac
  }
  # The assertion is registered a moment after the process appears, so poll
  # rather than assuming a fixed delay is long enough.
  wait_for_assertion() {
    local pid="$1" i
    for i in $(seq 1 40); do
      holds_assertion "$pid" && return 0
      sleep 0.25
    done
    return 1
  }
  wait_for_no_assertion() {
    local pid="$1" i
    for i in $(seq 1 40); do
      holds_assertion "$pid" || return 0
      sleep 0.25
    done
    return 1
  }
  printf '#!/bin/bash\nfor i in $(seq 1 60); do sleep 0.25; done\n' > "$TMP/session.sh"
  chmod +x "$TMP/session.sh"
  caffeinate -i "$TMP/session.sh" &
  session=$!
  track_pid "$session"
  sleep 1
  # The wrapped script also spawns `sleep`, so select the caffeinate child by
  # name rather than taking whichever child pgrep lists first.
  caff="$(pgrep -x -P "$session" caffeinate 2>/dev/null | head -1)"
  [ -n "$caff" ] || fail "expected a caffeinate child for the session"
  wait_for_assertion "$caff" || fail "the wrapping caffeinate ($caff) never registered an assertion"
  kill -TERM "$caff" 2>/dev/null || true
  wait_for_no_assertion "$caff" || fail "release did not drop caffeinate $caff's assertion"
  kill -0 "$session" 2>/dev/null || fail "the session died when its caffeinate was signalled"

  # Re-arm exactly as the daemon does on recovery.
  caffeinate -dimsu -w "$session" >/dev/null 2>&1 &
  rearm=$!
  track_pid "$rearm"
  sleep 1.5
  rearm_caff="$(pgrep -f "caffeinate -dimsu -w $session" 2>/dev/null | head -1)"
  [ -n "$rearm_caff" ] || fail "recovery did not start a caffeinate for session $session"
  wait_for_assertion "$rearm_caff" || fail "the restored hold ($rearm_caff) registered no assertion"
  kill -0 "$session" 2>/dev/null || fail "the session should still be running after release and re-arm"

  # Ending the session must clear the restored hold by itself.
  kill -TERM "$session" 2>/dev/null || true
  untrack_pid "$session"
  wait_for_no_assertion "$rearm_caff" \
    || fail "restored hold $rearm_caff leaked after the session exited"
  if kill -0 "$rearm_caff" 2>/dev/null; then
    fail "caffeinate -w should exit with its target"
  fi
  untrack_pid "$rearm"
else
  echo "   (skipped: caffeinate unavailable)"
fi

echo "== caffeinate release can be disabled =="
: > "$kill_log"
out="$(printf '0 0 battery 5\n' | FAKE_KILL_LOG="$kill_log" \
  SMART_LID_PGREP="$fake_pgrep" SMART_LID_KILL="$fake_kill" SMART_LID_RELEASE_CAFFEINATE=0 \
  SMART_LID_STATE_FILE="$TMP/state-caffeinate-off" "$DAEMON" simulate)"
[ ! -s "$kill_log" ] || fail "release should be suppressed when SMART_LID_RELEASE_CAFFEINATE=0"

echo "== real caffeinate: signalling it drops the assertion, wrapped command survives =="
# The safety of the release depends on this direction: caffeinate re-execs as a
# CHILD of the command it wraps.
if command -v caffeinate >/dev/null 2>&1; then
  printf '#!/bin/bash\nfor i in $(seq 1 40); do sleep 0.25; done\n' > "$TMP/wrapped.sh"
  chmod +x "$TMP/wrapped.sh"
  caffeinate -i "$TMP/wrapped.sh" &
  wrapped=$!
  track_pid "$wrapped"
  sleep 1
  caff="$(pgrep -x -P "$wrapped" caffeinate 2>/dev/null | head -1)"
  [ -n "$caff" ] || fail "expected caffeinate to run as a child of the wrapped command"
  # Check this specific pid's assertion, not a system-wide count that unrelated
  # processes would perturb. Poll: registration lags process creation slightly.
  registered=0
  for _ in $(seq 1 40); do
    assertions="$(pmset -g assertions 2>/dev/null || true)"
    case "$assertions" in *"pid $caff(caffeinate)"*) registered=1; break ;; esac
    sleep 0.25
  done
  [ "$registered" = 1 ] || fail "caffeinate $caff registered no assertion"
  kill -TERM "$caff" 2>/dev/null || true
  cleared=0
  for _ in $(seq 1 40); do
    assertions="$(pmset -g assertions 2>/dev/null || true)"
    case "$assertions" in *"pid $caff(caffeinate)"*) ;; *) cleared=1; break ;; esac
    sleep 0.25
  done
  kill -0 "$wrapped" 2>/dev/null || fail "wrapped command died when its caffeinate was signalled"
  [ "$cleared" = 1 ] || fail "caffeinate $caff's assertion survived the signal"
  kill -9 "$wrapped" 2>/dev/null || true
  untrack_pid "$wrapped"
else
  echo "   (skipped: caffeinate unavailable)"
fi

echo "== invalid battery interval settings fail clearly on macOS Bash =="
if SMART_LID_BATTERY_CHECK_LOOPS=08 "$DAEMON" status >/dev/null 2>&1; then
  fail "leading-zero battery interval was accepted"
fi
if SMART_LID_BATTERY_RETRY_LOOPS=0 "$DAEMON" status >/dev/null 2>&1; then
  fail "zero battery retry interval was accepted"
fi
if SMART_LID_BATTERY_FAILURE_LIMIT=03 "$DAEMON" status >/dev/null 2>&1; then
  fail "leading-zero battery failure limit was accepted"
fi

echo "== invalid sensor input fails safe and recovery reinitializes without stale ordering =="
out="$(printf '0 0\nbad bad\n1 1\n' | SMART_LID_STATE_FILE="$TMP/state-invalid" "$DAEMON" simulate)"
assert_line "$out" 2 "phase=failsafe disablesleep=0 sleepnow=0"
assert_line "$out" 3 "phase=failsafe disablesleep=0 sleepnow=1"

echo "== daemon restart preserves an active close-first session =="
state="$TMP/state-d"
printf 'phase=closed-keep-awake\nprev_locked=1\nprev_closed=1\ndesired=1\n' > "$state"
out="$(printf '1 1\n' | SMART_LID_STATE_FILE="$state" SMART_LID_SIMULATION_KEEP_STATE=1 "$DAEMON" simulate)"
assert_line "$out" 1 "phase=closed-keep-awake disablesleep=1 sleepnow=0"

echo "== daemon restart preserves a battery safety state while the battery is still low =="
state="$TMP/state-low-battery-restart"
printf 'phase=low-battery-sleep\nprev_locked=1\nprev_closed=1\ndesired=0\n' > "$state"
out="$(printf '0 1 battery 5\n' | SMART_LID_STATE_FILE="$state" \
  SMART_LID_SIMULATION_KEEP_STATE=1 "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
state="$TMP/state-battery-unavailable-restart"
printf 'phase=battery-unavailable-sleep\nprev_locked=1\nprev_closed=1\ndesired=0\n' > "$state"
out="$(printf '0 1 battery 5\n' | SMART_LID_STATE_FILE="$state" \
  SMART_LID_SIMULATION_KEEP_STATE=1 "$DAEMON" simulate)"
assert_line "$out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"

echo "== a restored safety state is released once the battery has recovered =="
# Latching must not outlive the condition: a daemon restart at 80% should hand
# control back rather than leaving the Mac permanently sleep-enabled.
state="$TMP/state-low-battery-restart-recovered"
printf 'phase=low-battery-sleep\nprev_locked=1\nprev_closed=1\ndesired=0\n' > "$state"
out="$(printf '0 1 battery 80\n0 1 battery 80\n' | SMART_LID_STATE_FILE="$state" \
  SMART_LID_SIMULATION_KEEP_STATE=1 "$DAEMON" simulate)"
# Releasing the latch clears the saved sensor history, so the next poll (~0.1s
# later) re-derives the lid phase. Sleep stays permitted in between, which is the
# safe direction to err in.
assert_line "$out" 1 "phase=battery-recovered disablesleep=0 sleepnow=0"
assert_line "$out" 2 "phase=closed-keep-awake disablesleep=1 sleepnow=0"

echo "== fake pmset proves applied power actions and retries a transient failure =="
fake_pmset="$TMP/fake-pmset"
cat > "$fake_pmset" <<'SH'
#!/bin/bash
set -u
state="${FAKE_PMSET_STATE:?}"
log="${FAKE_PMSET_LOG:?}"
case "${1:-}" in
  -g)
    if [ "${2:-}" = "batt" ]; then
      power_source="${FAKE_PMSET_POWER_SOURCE:-AC Power}"
      battery_percent="${FAKE_PMSET_BATTERY_PERCENT:-100}"
      battery_state="charging"
      [ "$power_source" = "Battery Power" ] && battery_state="discharging"
      printf "Now drawing from '%s'\n" "$power_source"
      if [ -n "${FAKE_PMSET_EXTERNAL_PERCENT:-}" ]; then
        printf ' -ExternalBattery-0 (id=9)\t%s%%; discharging\n' "$FAKE_PMSET_EXTERNAL_PERCENT"
      fi
      printf ' -InternalBattery-0 (id=1)\t%s%%; %s; 1:00 remaining present: true\n' \
        "$battery_percent" "$battery_state"
      if [ -n "${FAKE_PMSET_SECOND_INTERNAL_PERCENT:-}" ]; then
        printf ' -InternalBattery-1 (id=2)\t%s%%; %s; 1:00 remaining present: true\n' \
          "$FAKE_PMSET_SECOND_INTERNAL_PERCENT" "$battery_state"
      fi
      if [ "${FAKE_PMSET_BATT_FAIL_ONCE:-0}" = 1 ] && [ ! -e "$state.batt-failed" ]; then
        : > "$state.batt-failed"
        exit 1
      fi
      if [ "${FAKE_PMSET_BATT_ALWAYS_FAIL:-0}" = 1 ]; then
        exit 1
      fi
    else
      printf ' SleepDisabled\t\t%s\n' "$(cat "$state")"
    fi
    ;;
  -a)
    printf '%s\n' "$*" >> "$log"
    if [ "${FAKE_PMSET_FAIL_ONCE:-0}" = 1 ] && [ ! -e "$state.failed" ]; then
      : > "$state.failed"
      exit 1
    fi
    printf '%s\n' "$3" > "$state"
    ;;
  sleepnow)
    printf 'sleepnow\n' >> "$log"
    if [ "${FAKE_PMSET_SLEEP_FAIL_ONCE:-0}" = 1 ] && [ ! -e "$state.sleep-failed" ]; then
      : > "$state.sleep-failed"
      exit 1
    fi
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$fake_pmset"

printf '0\n' > "$TMP/pmset-state-a"
: > "$TMP/pmset-log-a"
printf '0 0\n0 1\n1 1\n' | \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-a" \
  FAKE_PMSET_LOG="$TMP/pmset-log-a" SMART_LID_STATE_FILE="$TMP/state-apply-a" \
  SMART_LID_SIMULATION_APPLY=1 "$DAEMON" simulate >/dev/null 2>&1
grep -q -- '-a disablesleep 1' "$TMP/pmset-log-a" || fail "close-first did not pre-arm disablesleep=1"
! grep -q 'sleepnow' "$TMP/pmset-log-a" || fail "close-first unexpectedly requested sleep"

printf '0\n' > "$TMP/pmset-state-b"
: > "$TMP/pmset-log-b"
printf '0 0\n1 0\n1 1\n' | \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-b" \
  FAKE_PMSET_LOG="$TMP/pmset-log-b" SMART_LID_STATE_FILE="$TMP/state-apply-b" \
  SMART_LID_SIMULATION_APPLY=1 "$DAEMON" simulate >/dev/null 2>&1
grep -q -- '-a disablesleep 0' "$TMP/pmset-log-b" || fail "lock-first did not restore disablesleep=0"
grep -q 'sleepnow' "$TMP/pmset-log-b" || fail "lock-first did not request sleepnow"

printf '1\n' > "$TMP/pmset-state-low-battery"
: > "$TMP/pmset-log-low-battery"
printf '0 0 battery 10\n0 1 battery 10\n' | \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-low-battery" \
  FAKE_PMSET_LOG="$TMP/pmset-log-low-battery" SMART_LID_STATE_FILE="$TMP/state-apply-low-battery" \
  SMART_LID_SIMULATION_APPLY=1 "$DAEMON" simulate >/dev/null 2>&1
grep -q -- '-a disablesleep 0' "$TMP/pmset-log-low-battery" \
  || fail "low-battery guard did not restore disablesleep=0"
grep -q 'sleepnow' "$TMP/pmset-log-low-battery" \
  || fail "low-battery guard did not request sleepnow"

printf '1\n' > "$TMP/pmset-state-low-battery-retry"
: > "$TMP/pmset-log-low-battery-retry"
retry_out="$(printf '0 1 battery 10\n1 1 battery 10\n' | \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-low-battery-retry" \
  FAKE_PMSET_LOG="$TMP/pmset-log-low-battery-retry" FAKE_PMSET_SLEEP_FAIL_ONCE=1 \
  SMART_LID_STATE_FILE="$TMP/state-apply-low-battery-retry" \
  SMART_LID_SIMULATION_APPLY=1 "$DAEMON" simulate 2>/dev/null)"
assert_line "$retry_out" 1 "phase=low-battery-sleep disablesleep=0 sleepnow=1"
assert_line "$retry_out" 2 "phase=low-battery-sleep disablesleep=0 sleepnow=0"
test "$(grep -c '^sleepnow$' "$TMP/pmset-log-low-battery-retry")" -eq 2 \
  || fail "failed low-battery sleep was not retried after the automatic lock"

printf '0\n' > "$TMP/pmset-state-retry"
: > "$TMP/pmset-log-retry"
printf '0 0\n0 0\n' | \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-retry" \
  FAKE_PMSET_LOG="$TMP/pmset-log-retry" FAKE_PMSET_FAIL_ONCE=1 \
  SMART_LID_STATE_FILE="$TMP/state-retry" SMART_LID_SIMULATION_APPLY=1 \
  "$DAEMON" simulate >/dev/null 2>&1
test "$(cat "$TMP/pmset-state-retry")" = 1 || fail "failed pmset change was not retried"

fake_ioreg="$TMP/fake-ioreg"
cat > "$fake_ioreg" <<'SH'
#!/bin/bash
printf '  "IOConsoleLocked" = No\n  "AppleClamshellState" = No\n'
SH
chmod +x "$fake_ioreg"

echo "== real pmset parser and daemon loop enforce the low-battery cutoff =="
printf '1\n' > "$TMP/pmset-state-status"
: > "$TMP/pmset-log-status"
status_out="$(
  SMART_LID_IOREG="$fake_ioreg" SMART_LID_PMSET="$fake_pmset" \
  FAKE_PMSET_STATE="$TMP/pmset-state-status" FAKE_PMSET_LOG="$TMP/pmset-log-status" \
  FAKE_PMSET_POWER_SOURCE="Battery Power" FAKE_PMSET_BATTERY_PERCENT=80 \
  FAKE_PMSET_EXTERNAL_PERCENT=99 FAKE_PMSET_SECOND_INTERNAL_PERCENT=10 \
  SMART_LID_STATE_FILE="$TMP/state-status" "$DAEMON" status
)"
case "$status_out" in
  *"PowerSource=battery BatteryPercent=10 LowBatteryCutoff=20"*) ;;
  *) fail "status did not parse the pmset battery response: $status_out" ;;
esac

fake_ioreg_closed="$TMP/fake-ioreg-closed"
cat > "$fake_ioreg_closed" <<'SH'
#!/bin/bash
printf '  "IOConsoleLocked" = No\n  "AppleClamshellState" = Yes\n'
SH
chmod +x "$fake_ioreg_closed"
printf '1\n' > "$TMP/pmset-state-daemon-low-battery"
: > "$TMP/pmset-log-daemon-low-battery"
SMART_LID_ALLOW_NONROOT_TEST=1 SMART_LID_IOREG="$fake_ioreg_closed" \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-daemon-low-battery" \
  FAKE_PMSET_LOG="$TMP/pmset-log-daemon-low-battery" FAKE_PMSET_POWER_SOURCE="Battery Power" \
  FAKE_PMSET_BATTERY_PERCENT=10 FAKE_PMSET_BATT_FAIL_ONCE=1 \
  SMART_LID_BATTERY_RETRY_LOOPS=2 SMART_LID_STATE_FILE="$TMP/state-daemon-low-battery" \
  SMART_LID_INTERVAL=0.05 "$DAEMON" run >/dev/null 2>&1 &
low_battery_daemon_pid=$!
track_pid "$low_battery_daemon_pid"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -q 'sleepnow' "$TMP/pmset-log-daemon-low-battery" && break
  kill -0 "$low_battery_daemon_pid" 2>/dev/null \
    || fail "low-battery daemon exited before requesting sleep"
  sleep 0.05
done
kill -TERM "$low_battery_daemon_pid"
wait "$low_battery_daemon_pid" || fail "low-battery daemon did not exit cleanly"
untrack_pid "$low_battery_daemon_pid"
low_battery_actions="$(cat "$TMP/pmset-log-daemon-low-battery")"
if ! grep -q -- '-a disablesleep 0' "$TMP/pmset-log-daemon-low-battery"; then
  sed 's/^/  pmset: /' "$TMP/pmset-log-daemon-low-battery" >&2
  fail "daemon loop did not restore disablesleep=0 at ten percent"
fi
if ! grep -q 'sleepnow' "$TMP/pmset-log-daemon-low-battery"; then
  sed 's/^/  pmset: /' "$TMP/pmset-log-daemon-low-battery" >&2
  fail "daemon loop did not request sleep at ten percent"
fi
assert_line "$low_battery_actions" 1 "-a disablesleep 0"
assert_line "$low_battery_actions" 2 "sleepnow"

echo "== persistent battery telemetry failure restores normal sleep =="
printf '1\n' > "$TMP/pmset-state-daemon-battery-unavailable"
: > "$TMP/pmset-log-daemon-battery-unavailable"
SMART_LID_ALLOW_NONROOT_TEST=1 SMART_LID_IOREG="$fake_ioreg_closed" \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-daemon-battery-unavailable" \
  FAKE_PMSET_LOG="$TMP/pmset-log-daemon-battery-unavailable" FAKE_PMSET_BATT_ALWAYS_FAIL=1 \
  SMART_LID_BATTERY_RETRY_LOOPS=1 SMART_LID_BATTERY_FAILURE_LIMIT=3 \
  SMART_LID_STATE_FILE="$TMP/state-daemon-battery-unavailable" \
  SMART_LID_INTERVAL=0.05 "$DAEMON" run >/dev/null 2>&1 &
battery_unavailable_daemon_pid=$!
track_pid "$battery_unavailable_daemon_pid"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -q 'sleepnow' "$TMP/pmset-log-daemon-battery-unavailable" && break
  kill -0 "$battery_unavailable_daemon_pid" 2>/dev/null \
    || fail "battery-unavailable daemon exited before requesting sleep"
  sleep 0.05
done
kill -TERM "$battery_unavailable_daemon_pid"
wait "$battery_unavailable_daemon_pid" \
  || fail "battery-unavailable daemon did not exit cleanly"
untrack_pid "$battery_unavailable_daemon_pid"
grep -q -- '-a disablesleep 0' "$TMP/pmset-log-daemon-battery-unavailable" \
  || fail "persistent battery telemetry failure did not restore disablesleep=0"
grep -q '^sleepnow$' "$TMP/pmset-log-daemon-battery-unavailable" \
  || fail "persistent battery telemetry failure did not request sleep"
grep -q '^phase=battery-unavailable-sleep$' "$TMP/state-daemon-battery-unavailable" \
  || fail "persistent battery telemetry failure did not enter its fail-safe phase"

echo "== TERM stops the daemon and restores normal sleep =="
printf '0\n' > "$TMP/pmset-state-term"
: > "$TMP/pmset-log-term"
SMART_LID_ALLOW_NONROOT_TEST=1 SMART_LID_IOREG="$fake_ioreg" \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-term" \
  FAKE_PMSET_LOG="$TMP/pmset-log-term" SMART_LID_STATE_FILE="$TMP/state-term" \
  SMART_LID_INTERVAL=0.05 "$DAEMON" run >/dev/null 2>&1 &
daemon_pid=$!
track_pid "$daemon_pid"
sleep 0.2
kill -TERM "$daemon_pid"
wait "$daemon_pid" || fail "daemon did not exit cleanly after TERM"
untrack_pid "$daemon_pid"
test "$(cat "$TMP/pmset-state-term")" = 0 || fail "TERM did not restore disablesleep=0"

echo "== installer is reversible under an isolated test root =="
root="$TMP/root"
SMART_LID_TEST_ROOT="$root" "$INSTALLER" install >/dev/null
test -x "$root/usr/local/libexec/com.aryangupta.smart-lid" || fail "daemon not installed"
test -f "$root/Library/LaunchDaemons/com.aryangupta.smart-lid.plist" || fail "plist not installed"
plutil -lint "$root/Library/LaunchDaemons/com.aryangupta.smart-lid.plist" >/dev/null
SMART_LID_TEST_ROOT="$root" "$INSTALLER" uninstall >/dev/null
test ! -e "$root/usr/local/libexec/com.aryangupta.smart-lid" || fail "daemon not removed"
test ! -e "$root/Library/LaunchDaemons/com.aryangupta.smart-lid.plist" || fail "plist not removed"

echo "== mocked system lifecycle verifies launch, health, rollback, and power restoration =="
fake_launchctl="$TMP/fake-launchctl"
cat > "$fake_launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_LOG:?}"
service_state="${FAKE_LAUNCHCTL_STATE:?}"
case "${1:-}" in
  print)
    [ -e "$service_state" ] || exit 113
    printf 'state = running\n'
    ;;
  bootout)
    if [ "${FAKE_LAUNCHCTL_FAIL_BOOTOUT:-0}" = 1 ]; then exit 1; fi
    rm -f "$service_state"
    ;;
  bootstrap)
    if [ "${FAKE_LAUNCHCTL_FAIL_BOOTSTRAP_ONCE:-0}" = 1 ] && [ ! -e "$service_state.failed-once" ]; then
      : > "$service_state.failed-once"
      exit 1
    fi
    : > "$service_state"
    ;;
  kickstart) ;;
  *) exit 64 ;;
esac
SH
chmod +x "$fake_launchctl"
lifecycle_root="$TMP/lifecycle-root"
: > "$TMP/launchctl-log"
printf '1\n' > "$TMP/pmset-state-lifecycle"
: > "$TMP/pmset-log-lifecycle"
lifecycle_env=(
  SMART_LID_TEST_ROOT="$lifecycle_root"
  SMART_LID_TEST_LIFECYCLE=1
  SMART_LID_LAUNCHCTL="$fake_launchctl"
  SMART_LID_PMSET="$fake_pmset"
  SMART_LID_IOREG="$fake_ioreg"
  SMART_LID_SLEEP=/usr/bin/true
  SMART_LID_INSTALL_VERIFY_DELAY=0
  FAKE_LAUNCHCTL_LOG="$TMP/launchctl-log"
  FAKE_LAUNCHCTL_STATE="$TMP/launchctl-state"
  FAKE_PMSET_STATE="$TMP/pmset-state-lifecycle"
  FAKE_PMSET_LOG="$TMP/pmset-log-lifecycle"
)
env "${lifecycle_env[@]}" "$INSTALLER" install >/dev/null
grep -q '^bootstrap system ' "$TMP/launchctl-log" || fail "installer did not bootstrap service"
grep -q '^kickstart -k system/com.aryangupta.smart-lid$' "$TMP/launchctl-log" || fail "installer did not kickstart service"
env "${lifecycle_env[@]}" "$INSTALLER" status >/dev/null
# Make the installed version materially different from the candidate so a stale
# candidate cannot satisfy the rollback assertions.
printf '\n# prior-installed-sentinel\n' >> "$lifecycle_root/usr/local/libexec/com.aryangupta.smart-lid"
printf '<!-- prior-installed-sentinel -->\n' >> "$lifecycle_root/Library/LaunchDaemons/com.aryangupta.smart-lid.plist"
cp "$lifecycle_root/usr/local/libexec/com.aryangupta.smart-lid" "$TMP/daemon-before-rollback"
cp "$lifecycle_root/Library/LaunchDaemons/com.aryangupta.smart-lid.plist" "$TMP/plist-before-rollback"
: > "$TMP/launchctl-log"
if env "${lifecycle_env[@]}" FAKE_LAUNCHCTL_FAIL_BOOTSTRAP_ONCE=1 "$INSTALLER" install >/dev/null 2>&1; then
  fail "installer unexpectedly succeeded when bootstrap failed"
fi
cmp -s "$TMP/daemon-before-rollback" "$lifecycle_root/usr/local/libexec/com.aryangupta.smart-lid" \
  || fail "daemon was not restored after failed update"
cmp -s "$TMP/plist-before-rollback" "$lifecycle_root/Library/LaunchDaemons/com.aryangupta.smart-lid.plist" \
  || fail "plist was not restored after failed update"
test -e "$TMP/launchctl-state" || fail "previous service was not restarted after rollback"
test "$(grep -c '^bootstrap system ' "$TMP/launchctl-log")" -eq 2 \
  || fail "rollback did not perform candidate and previous-service bootstrap attempts"
# The rollback itself must restore disablesleep=0 (this is asserted BEFORE the uninstall below,
# which would independently reset it and mask a regression of the rollback fail-safe).
test "$(cat "$TMP/pmset-state-lifecycle")" = 0 \
  || fail "rollback did not restore disablesleep=0 after a failed update"
env "${lifecycle_env[@]}" "$INSTALLER" uninstall >/dev/null
test "$(cat "$TMP/pmset-state-lifecycle")" = 0 || fail "uninstall did not restore disablesleep=0"

echo "== upgrading over a running service tolerates launchd's asynchronous bootout =="
# The lifecycle fake unloads synchronously inside `bootout`, so the upgrade path was never
# exercised against how launchd actually behaves: bootout returns *before* teardown
# completes. Checking `service_loaded` once, immediately, therefore reported a bogus
# "Could not unload the existing smart-lid service." on every upgrade over a live daemon.
fake_launchctl_async="$TMP/fake-launchctl-async"
cat > "$fake_launchctl_async" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_LOG:?}"
service_state="${FAKE_LAUNCHCTL_STATE:?}"
pending="$service_state.pending"
counter="$service_state.counter"
case "${1:-}" in
  print)
    # Teardown lands only after FAKE_LAUNCHCTL_BOOTOUT_DELAY further observations.
    if [ -e "$pending" ]; then
      n=$(( $(cat "$counter" 2>/dev/null || printf 0) + 1 ))
      printf '%s\n' "$n" > "$counter"
      if [ "$n" -ge "${FAKE_LAUNCHCTL_BOOTOUT_DELAY:-2}" ]; then
        rm -f "$service_state" "$pending" "$counter"
      fi
    fi
    [ -e "$service_state" ] || exit 113
    printf 'state = running\n'
    ;;
  bootout)
    [ -e "$service_state" ] || exit 3
    : > "$pending"
    ;;
  bootstrap)
    rm -f "$pending" "$counter"
    : > "$service_state"
    ;;
  kickstart) ;;
  *) exit 64 ;;
esac
SH
chmod +x "$fake_launchctl_async"
async_root="$TMP/async-root"
: > "$TMP/launchctl-log-async"
printf '1\n' > "$TMP/pmset-state-async"
: > "$TMP/pmset-log-async"
async_env=(
  SMART_LID_TEST_ROOT="$async_root"
  SMART_LID_TEST_LIFECYCLE=1
  SMART_LID_LAUNCHCTL="$fake_launchctl_async"
  SMART_LID_PMSET="$fake_pmset"
  SMART_LID_IOREG="$fake_ioreg"
  SMART_LID_SLEEP=/usr/bin/true
  SMART_LID_INSTALL_VERIFY_DELAY=0
  FAKE_LAUNCHCTL_LOG="$TMP/launchctl-log-async"
  FAKE_LAUNCHCTL_STATE="$TMP/launchctl-state-async"
  FAKE_PMSET_STATE="$TMP/pmset-state-async"
  FAKE_PMSET_LOG="$TMP/pmset-log-async"
)
env "${async_env[@]}" "$INSTALLER" install >/dev/null
# The second install runs over a service that is already loaded: the upgrade path.
if ! env "${async_env[@]}" "$INSTALLER" install >/dev/null 2>"$TMP/upgrade-err"; then
  fail "upgrade over a running service failed: $(cat "$TMP/upgrade-err")"
fi
if grep -q 'Could not unload' "$TMP/upgrade-err"; then
  fail "installer reported a bogus unload failure on a healthy upgrade"
fi
if ls "$async_root/usr/local/libexec/"*.new.* >/dev/null 2>&1; then
  fail "upgrade left .new temp files behind"
fi
if ls "$async_root/usr/local/libexec/"*.backup.* >/dev/null 2>&1; then
  fail "upgrade left .backup temp files behind"
fi

echo "== a failed unload rolls back cleanly instead of aborting on an unset variable =="
# rollback_install() runs from the EXIT trap, which fires only after install_daemon() has
# already returned. While its bookkeeping lived in function-locals those names were out of
# scope by then, so `set -u` killed the trap on its first reference: the rollback never ran
# and the transaction's temp files were orphaned in /usr/local/libexec.
if env "${async_env[@]}" FAKE_LAUNCHCTL_BOOTOUT_DELAY=9999 "$INSTALLER" install \
     >/dev/null 2>"$TMP/stuck-err"; then
  fail "installer unexpectedly succeeded when the service never unloaded"
fi
if grep -q 'unbound variable' "$TMP/stuck-err"; then
  fail "rollback aborted on an unset variable instead of rolling back"
fi
grep -q 'Could not unload' "$TMP/stuck-err" || fail "installer did not report the unload failure"
test -x "$async_root/usr/local/libexec/com.aryangupta.smart-lid" \
  || fail "rollback did not restore the previously installed daemon"
if ls "$async_root/usr/local/libexec/"*.new.* >/dev/null 2>&1; then
  fail "rollback left .new temp files behind"
fi
if ls "$async_root/Library/LaunchDaemons/"*.backup.* >/dev/null 2>&1; then
  fail "rollback left .backup temp files behind"
fi

echo "== uninstall refuses to delete files if launchctl cannot unload =="
env "${lifecycle_env[@]}" "$INSTALLER" install >/dev/null
if env "${lifecycle_env[@]}" FAKE_LAUNCHCTL_FAIL_BOOTOUT=1 "$INSTALLER" uninstall >/dev/null 2>&1; then
  fail "uninstall unexpectedly succeeded after bootout failure"
fi
test -x "$lifecycle_root/usr/local/libexec/com.aryangupta.smart-lid" \
  || fail "uninstall deleted daemon after bootout failure"
env "${lifecycle_env[@]}" "$INSTALLER" uninstall >/dev/null

echo "ALL SMART LID TESTS PASSED"
