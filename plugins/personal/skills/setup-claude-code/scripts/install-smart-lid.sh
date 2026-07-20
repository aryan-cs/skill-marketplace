#!/bin/bash
# install-smart-lid.sh — install/remove the privileged smart-lid LaunchDaemon.
set -euo pipefail

LABEL="com.aryangupta.smart-lid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${SMART_LID_TEST_ROOT:-}"
TEST_LIFECYCLE="${SMART_LID_TEST_LIFECYCLE:-0}"
ROOT="${TEST_ROOT:-}"
DAEMON_DEST="$ROOT/usr/local/libexec/$LABEL"
PLIST_DEST="$ROOT/Library/LaunchDaemons/$LABEL.plist"
STATE_FILE="$ROOT/var/run/$LABEL.state"
LAUNCHCTL="${SMART_LID_LAUNCHCTL:-/bin/launchctl}"
PMSET="${SMART_LID_PMSET:-/usr/bin/pmset}"
INSTALL="${SMART_LID_INSTALL:-/usr/bin/install}"
PLUTIL="${SMART_LID_PLUTIL:-/usr/bin/plutil}"
SLEEP_BIN="${SMART_LID_SLEEP:-/bin/sleep}"
VERIFY_DELAY="${SMART_LID_INSTALL_VERIFY_DELAY:-1}"

require_root() {
  if [ -z "$TEST_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Run this command with sudo from a normal terminal:" >&2
    echo "  sudo $0 $1" >&2
    exit 77
  fi
}

service_loaded() {
  "$LAUNCHCTL" print "system/$LABEL" >/dev/null 2>&1
}

service_running() {
  "$LAUNCHCTL" print "system/$LABEL" 2>/dev/null | /usr/bin/grep -q 'state = running'
}

write_plist() {
  local destination="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/smart-lid-plist.XXXXXX")"
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DAEMON_DEST</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>2</integer>
</dict>
</plist>
PLIST
  "$INSTALL" -m 0644 "$tmp" "$destination"
  rm -f "$tmp"
}

install_daemon() {
  require_root install
  local daemon_new="${DAEMON_DEST}.new.$$" plist_new="${PLIST_DEST}.new.$$"
  local daemon_backup="${DAEMON_DEST}.backup.$$" plist_backup="${PLIST_DEST}.backup.$$"
  local had_daemon=0 had_plist=0 was_loaded=0 transaction_active=0 committed=0
  mkdir -p "$(dirname "$DAEMON_DEST")" "$(dirname "$PLIST_DEST")" "$(dirname "$STATE_FILE")"
  /bin/bash -n "$SCRIPT_DIR/smart-lid-daemon.sh"
  "$INSTALL" -m 0755 "$SCRIPT_DIR/smart-lid-daemon.sh" "$daemon_new"
  write_plist "$plist_new"
  "$PLUTIL" -lint "$plist_new" >/dev/null

  if [ -n "$TEST_ROOT" ] && [ "$TEST_LIFECYCLE" != 1 ]; then
    mv "$daemon_new" "$DAEMON_DEST"
    mv "$plist_new" "$PLIST_DEST"
  else
    if [ -e "$DAEMON_DEST" ]; then cp -p "$DAEMON_DEST" "$daemon_backup"; had_daemon=1; fi
    if [ -e "$PLIST_DEST" ]; then cp -p "$PLIST_DEST" "$plist_backup"; had_plist=1; fi
    if service_loaded; then was_loaded=1; fi
    transaction_active=1
    rollback_install() {
      local result=$?
      trap - EXIT HUP INT TERM
      if [ "$transaction_active" = 1 ] && [ "$committed" = 0 ]; then
        echo "Install failed; rolling back the previous smart-lid service." >&2
        "$LAUNCHCTL" bootout "system/$LABEL" >/dev/null 2>&1 || true
        rm -f "$DAEMON_DEST" "$PLIST_DEST"
        if [ "$had_daemon" = 1 ]; then mv "$daemon_backup" "$DAEMON_DEST"; fi
        if [ "$had_plist" = 1 ]; then mv "$plist_backup" "$PLIST_DEST"; fi
        if [ "$was_loaded" = 1 ] && [ "$had_plist" = 1 ]; then
          "$LAUNCHCTL" bootstrap system "$PLIST_DEST" >/dev/null 2>&1 || true
        fi
        "$PMSET" -a disablesleep 0 >/dev/null 2>&1 || true
      fi
      rm -f "$daemon_new" "$plist_new" "$daemon_backup" "$plist_backup"
      exit "$result"
    }
    trap rollback_install EXIT
    trap 'exit 130' HUP INT TERM

    if [ "$was_loaded" = 1 ]; then
      "$LAUNCHCTL" bootout "system/$LABEL"
      if service_loaded; then
        echo "Could not unload the existing smart-lid service." >&2
        return 1
      fi
    fi
    mv "$daemon_new" "$DAEMON_DEST"
    mv "$plist_new" "$PLIST_DEST"

    "$LAUNCHCTL" bootstrap system "$PLIST_DEST"
    "$LAUNCHCTL" kickstart -k "system/$LABEL"
    "$SLEEP_BIN" "$VERIFY_DELAY"
    service_running
    committed=1
    transaction_active=0
    trap - EXIT HUP INT TERM
    rm -f "$daemon_backup" "$plist_backup"
    "$DAEMON_DEST" status || echo "WARNING: service is running, but live sensor status is temporarily unavailable." >&2
  fi
  echo "Installed smart lid behavior. Close-first stays awake; lock-first then close sleeps."
}

uninstall_daemon() {
  require_root uninstall
  if [ -z "$TEST_ROOT" ] || [ "$TEST_LIFECYCLE" = 1 ]; then
    if service_loaded; then
      "$LAUNCHCTL" bootout "system/$LABEL"
      if service_loaded; then
        echo "Refusing to remove files: the smart-lid service is still loaded." >&2
        return 1
      fi
    fi
    "$PMSET" -a disablesleep 0
  fi
  rm -f "$PLIST_DEST" "$DAEMON_DEST" "$STATE_FILE"
  echo "Removed smart lid behavior and restored normal sleep."
}

case "${1:-install}" in
  install) install_daemon ;;
  uninstall) uninstall_daemon ;;
  status)
    if [ ! -x "$DAEMON_DEST" ]; then
      sleep_disabled="$($PMSET -g 2>/dev/null | /usr/bin/awk '/SleepDisabled/ {print $2; exit}')"
      echo "status=not-installed SleepDisabled=${sleep_disabled:-unknown}"
    elif { [ -z "$TEST_ROOT" ] || [ "$TEST_LIFECYCLE" = 1 ]; } && ! service_running; then
      echo "status=error service=not-running"
      exit 1
    else
      "$DAEMON_DEST" status
    fi
    ;;
  *) echo "usage: $0 {install|uninstall|status}" >&2; exit 64 ;;
esac
