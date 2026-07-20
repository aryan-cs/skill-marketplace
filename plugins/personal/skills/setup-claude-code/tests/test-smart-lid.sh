#!/bin/bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$SKILL_DIR/scripts/smart-lid-daemon.sh"
INSTALLER="$SKILL_DIR/scripts/install-smart-lid.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-smart-lid.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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

echo "== invalid sensor input fails safe and recovery reinitializes without stale ordering =="
out="$(printf '0 0\nbad bad\n1 1\n' | SMART_LID_STATE_FILE="$TMP/state-invalid" "$DAEMON" simulate)"
assert_line "$out" 2 "phase=failsafe disablesleep=0 sleepnow=0"
assert_line "$out" 3 "phase=failsafe disablesleep=0 sleepnow=1"

echo "== daemon restart preserves an active close-first session =="
state="$TMP/state-d"
printf 'phase=closed-keep-awake\nprev_locked=1\nprev_closed=1\ndesired=1\n' > "$state"
out="$(printf '1 1\n' | SMART_LID_STATE_FILE="$state" SMART_LID_SIMULATION_KEEP_STATE=1 "$DAEMON" simulate)"
assert_line "$out" 1 "phase=closed-keep-awake disablesleep=1 sleepnow=0"

echo "== fake pmset proves applied power actions and retries a transient failure =="
fake_pmset="$TMP/fake-pmset"
cat > "$fake_pmset" <<'SH'
#!/bin/bash
set -u
state="${FAKE_PMSET_STATE:?}"
log="${FAKE_PMSET_LOG:?}"
case "${1:-}" in
  -g)
    printf ' SleepDisabled\t\t%s\n' "$(cat "$state")"
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

printf '0\n' > "$TMP/pmset-state-retry"
: > "$TMP/pmset-log-retry"
printf '0 0\n0 0\n' | \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-retry" \
  FAKE_PMSET_LOG="$TMP/pmset-log-retry" FAKE_PMSET_FAIL_ONCE=1 \
  SMART_LID_STATE_FILE="$TMP/state-retry" SMART_LID_SIMULATION_APPLY=1 \
  "$DAEMON" simulate >/dev/null 2>&1
test "$(cat "$TMP/pmset-state-retry")" = 1 || fail "failed pmset change was not retried"

echo "== TERM stops the daemon and restores normal sleep =="
fake_ioreg="$TMP/fake-ioreg"
cat > "$fake_ioreg" <<'SH'
#!/bin/bash
printf '  "IOConsoleLocked" = No\n  "AppleClamshellState" = No\n'
SH
chmod +x "$fake_ioreg"
printf '0\n' > "$TMP/pmset-state-term"
: > "$TMP/pmset-log-term"
SMART_LID_ALLOW_NONROOT_TEST=1 SMART_LID_IOREG="$fake_ioreg" \
  SMART_LID_PMSET="$fake_pmset" FAKE_PMSET_STATE="$TMP/pmset-state-term" \
  FAKE_PMSET_LOG="$TMP/pmset-log-term" SMART_LID_STATE_FILE="$TMP/state-term" \
  SMART_LID_INTERVAL=0.05 "$DAEMON" run >/dev/null 2>&1 &
daemon_pid=$!
sleep 0.2
kill -TERM "$daemon_pid"
wait "$daemon_pid" || fail "daemon did not exit cleanly after TERM"
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
env "${lifecycle_env[@]}" "$INSTALLER" uninstall >/dev/null
test "$(cat "$TMP/pmset-state-lifecycle")" = 0 || fail "uninstall did not restore disablesleep=0"

echo "== uninstall refuses to delete files if launchctl cannot unload =="
env "${lifecycle_env[@]}" "$INSTALLER" install >/dev/null
if env "${lifecycle_env[@]}" FAKE_LAUNCHCTL_FAIL_BOOTOUT=1 "$INSTALLER" uninstall >/dev/null 2>&1; then
  fail "uninstall unexpectedly succeeded after bootout failure"
fi
test -x "$lifecycle_root/usr/local/libexec/com.aryangupta.smart-lid" \
  || fail "uninstall deleted daemon after bootout failure"
env "${lifecycle_env[@]}" "$INSTALLER" uninstall >/dev/null

echo "ALL SMART LID TESTS PASSED"
