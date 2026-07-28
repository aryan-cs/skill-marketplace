#!/bin/bash
# Deterministic tests for disable-crash-dialogs.sh. Stubs launchctl and defaults so the real
# launchd disabled-database and preference domain are never touched.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/disable-crash-dialogs.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-crash-dialogs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "expected '$2' in: $1" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "did not expect '$2' in: $1" ;; esac
}

# --- stub launchctl: keeps the disabled set in a file so state persists across calls ---------
cat > "$TMP/launchctl" <<'SH'
#!/bin/bash
set -u
state="${FAKE_LAUNCHCTL_STATE:?}"
printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_LOG:?}"
case "${1:-}" in
  disable)
    [ "${FAKE_LAUNCHCTL_DISABLE_NOOP:-0}" = 1 ] && exit 0
    printf '%s\n' "${2##*/}" >> "$state"; exit 0 ;;
  enable)
    if [ -f "$state" ]; then
      grep -vxF "${2##*/}" "$state" > "$state.tmp" 2>/dev/null || :
      mv "$state.tmp" "$state" 2>/dev/null || :
    fi
    exit 0 ;;
  bootout) exit "${FAKE_LAUNCHCTL_BOOTOUT_EXIT:-0}" ;;
  print-disabled)
    [ "${FAKE_LAUNCHCTL_PRINT_FAIL:-0}" = 1 ] && exit 1
    echo "disabled services = {"
    if [ -f "$state" ] && grep -qxF "com.apple.ReportCrash" "$state"; then
      printf '\t"com.apple.ReportCrash" => disabled\n'
    else
      printf '\t"com.apple.ReportCrash" => enabled\n'
    fi
    echo "}"; exit 0 ;;
esac
exit 0
SH

# --- stub defaults: one key, stored in a file ------------------------------------------------
cat > "$TMP/defaults" <<'SH'
#!/bin/bash
set -u
store="${FAKE_DEFAULTS_STORE:?}"
printf '%s\n' "$*" >> "${FAKE_DEFAULTS_LOG:?}"
case "${1:-}" in
  write)  printf '%s\n' "${4:-}" > "$store"; exit 0 ;;
  read)   [ -s "$store" ] && cat "$store" && exit 0; exit 1 ;;
  delete) rm -f "$store"; exit 0 ;;
esac
exit 0
SH

chmod +x "$TMP/launchctl" "$TMP/defaults"

export FAKE_LAUNCHCTL_STATE="$TMP/disabled" FAKE_LAUNCHCTL_LOG="$TMP/launchctl.log"
export FAKE_DEFAULTS_STORE="$TMP/pref" FAKE_DEFAULTS_LOG="$TMP/defaults.log"
export CRASH_DIALOGS_LAUNCHCTL="$TMP/launchctl" CRASH_DIALOGS_DEFAULTS="$TMP/defaults"
export CRASH_DIALOGS_UID=501
: > "$FAKE_LAUNCHCTL_LOG"; : > "$FAKE_DEFAULTS_LOG"

run() { CRASH_DIALOGS_TEST_ROOT=1 "$SCRIPT" "$@"; }

echo "== status reports enabled before anything is changed =="
out="$(run status)"
assert_contains "$out" "status=enabled"
assert_contains "$out" "domain=gui/501"

echo "== off disables the agent in the caller's GUI domain =="
out="$(run off)"
assert_contains "$out" "Crash dialogs disabled"
assert_contains "$(cat "$FAKE_LAUNCHCTL_LOG")" "disable gui/501/com.apple.ReportCrash"
# The dialog currently on screen belongs to a running agent, so it must be booted out too.
assert_contains "$(cat "$FAKE_LAUNCHCTL_LOG")" "bootout gui/501/com.apple.ReportCrash"

echo "== off also sets the legacy DialogType pref (inert on 26.x, correct on older macOS) =="
assert_contains "$(cat "$FAKE_DEFAULTS_LOG")" "write com.apple.CrashReporter DialogType none"
[ "$(cat "$FAKE_DEFAULTS_STORE")" = "none" ] || fail "DialogType was not set to none"

echo "== status now reports disabled, and reflects the pref =="
out="$(run status)"
assert_contains "$out" "status=disabled"
assert_contains "$out" "DialogType=none"

echo "== off is idempotent =="
out="$(run off)"
assert_contains "$out" "Crash dialogs disabled"
out="$(run status)"
assert_contains "$out" "status=disabled"

echo "== a stale agent that is already gone is not an error =="
# NOTE: these knobs must be exported, not passed as a `VAR=1 out=$(...)` prefix — that form is
# parsed as two assignments and never reaches the stub, so the case would silently test nothing.
export FAKE_LAUNCHCTL_BOOTOUT_EXIT=3   # 3 = "No such process"
out="$(run off)"
unset FAKE_LAUNCHCTL_BOOTOUT_EXIT
assert_contains "$out" "Crash dialogs disabled"

echo "== on restores the agent and clears the pref =="
out="$(run on)"
assert_contains "$out" "Crash dialogs restored"
assert_contains "$(cat "$FAKE_LAUNCHCTL_LOG")" "enable gui/501/com.apple.ReportCrash"
[ ! -f "$FAKE_DEFAULTS_STORE" ] || fail "DialogType pref should have been deleted"
out="$(run status)"
assert_contains "$out" "status=enabled"
assert_contains "$out" "DialogType=unset"

echo "== a launchctl disable that silently does nothing is reported as a failure =="
# Guards against the check being cosmetic: the script must verify the state it just asked for,
# which is exactly the failure mode that made the DialogType preference look like it worked.
rc=0
export FAKE_LAUNCHCTL_DISABLE_NOOP=1
out="$(run off 2>&1)" || rc=$?
unset FAKE_LAUNCHCTL_DISABLE_NOOP
[ "$rc" -ne 0 ] || fail "expected a non-zero exit when the agent was not actually disabled"
assert_contains "$out" "Could not confirm"

echo "== unreadable launchd state reports unknown rather than claiming success =="
export FAKE_LAUNCHCTL_PRINT_FAIL=1
out="$(run status)"
unset FAKE_LAUNCHCTL_PRINT_FAIL
assert_contains "$out" "status=unknown"

echo "== the privileged actions refuse to run without root =="
rc=0
out="$("$SCRIPT" off 2>&1)" || rc=$?
[ "$rc" -eq 77 ] || fail "expected exit 77 without root, got $rc"
assert_contains "$out" "sudo"
# status stays usable unprivileged — it only reads.
"$SCRIPT" status >/dev/null || fail "status should not require root"

echo "== an unknown subcommand is a usage error =="
rc=0
out="$(run bogus 2>&1)" || rc=$?
[ "$rc" -eq 64 ] || fail "expected exit 64 for a bad subcommand, got $rc"
assert_contains "$out" "usage:"

echo
echo "ALL CRASH-DIALOG TESTS PASSED"
