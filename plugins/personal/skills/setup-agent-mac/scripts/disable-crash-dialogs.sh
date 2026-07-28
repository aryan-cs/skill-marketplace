#!/bin/bash
# disable-crash-dialogs.sh — suppress the macOS "<app> quit unexpectedly" crash dialog.
#
# Why this exists: agent tooling launches short-lived headless browsers (Codex/Claude Code
# plugins shelling out to Chrome for PDF rendering, browser automation, etc.). Those launches
# routinely abort during startup, and each abort raises a modal crash dialog — often five or
# ten in a row — over whatever you are working on. The crashes are harmless: the browser you
# are actually using is a separate long-lived process and is unaffected.
#
# Apple's documented switch for this is `defaults write com.apple.CrashReporter DialogType none`.
# It is IGNORED on macOS 26.x (verified on 26.5 / build 25F84: the key reads back correctly from
# both the user and -currentHost domains and the dialog still appears). The mechanism that does
# work is disabling the per-user ReportCrash *agent*, which is what presents the dialog.
#
# `launchctl disable` writes to launchd's per-user disabled database, so it survives reboots and
# is reversed by `launchctl enable`. It needs root, but it targets the *user's* GUI domain — hence
# the uid resolution below.
set -euo pipefail

LABEL="com.apple.ReportCrash"
LAUNCHCTL="${CRASH_DIALOGS_LAUNCHCTL:-/bin/launchctl}"
DEFAULTS="${CRASH_DIALOGS_DEFAULTS:-/usr/bin/defaults}"
SUDO_BIN="${CRASH_DIALOGS_SUDO:-/usr/bin/sudo}"
GREP="${CRASH_DIALOGS_GREP:-/usr/bin/grep}"

# The GUI domain belongs to the logged-in user, never root, so resolve the real uid even when
# this script is invoked through sudo. SUDO_UID is set by sudo to the calling user's id.
TARGET_UID="${CRASH_DIALOGS_UID:-${SUDO_UID:-$(id -u)}}"
DOMAIN="gui/$TARGET_UID"
TEST_ROOT="${CRASH_DIALOGS_TEST_ROOT:-}"

require_root() {
  if [ -z "$TEST_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Run this command with sudo from a normal terminal:" >&2
    echo "  sudo $0 $1" >&2
    exit 77
  fi
}

# Drop back to the invoking user for unprivileged work: `defaults write` as root would land in
# root's preference domain, not the user's, and silently do nothing useful.
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_UID" != "0" ]; then
    "$SUDO_BIN" -u "#$TARGET_UID" "$@"
  else
    "$@"
  fi
}

# launchd has printed both `=> true` (older) and `=> disabled` (current) for a disabled service.
# Accept either rather than pinning to whichever this machine happens to emit.
dialogs_disabled() {
  "$LAUNCHCTL" print-disabled "$DOMAIN" 2>/dev/null \
    | "$GREP" -qE "\"$LABEL\"[[:space:]]*=>[[:space:]]*(true|disabled)"
}

disable_dialogs() {
  require_root off
  "$LAUNCHCTL" disable "$DOMAIN/$LABEL"
  # Boots out an agent that is currently holding a dialog on screen. Fails harmlessly with
  # "No such process" when nothing is running, which is the common case.
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  # Belt and braces: on macOS < 26 this preference alone is sufficient, and it costs nothing to
  # set where it is inert. Never fatal — the launchctl change above is the load-bearing part.
  as_user "$DEFAULTS" write com.apple.CrashReporter DialogType none >/dev/null 2>&1 || true

  if ! dialogs_disabled; then
    echo "Could not confirm the ReportCrash agent is disabled in $DOMAIN." >&2
    return 1
  fi
  echo "Crash dialogs disabled. Apps that crash no longer raise a 'quit unexpectedly' alert."
  echo "Side effect: .ips crash reports stop being written to ~/Library/Logs/DiagnosticReports."
  echo "Revert with: crashdialogs on"
}

restore_dialogs() {
  require_root on
  "$LAUNCHCTL" enable "$DOMAIN/$LABEL"
  as_user "$DEFAULTS" delete com.apple.CrashReporter DialogType >/dev/null 2>&1 || true

  if dialogs_disabled; then
    echo "Could not confirm the ReportCrash agent was re-enabled in $DOMAIN." >&2
    return 1
  fi
  echo "Crash dialogs restored, along with .ips crash report generation."
}

print_status() {
  local pref
  pref="$(as_user "$DEFAULTS" read com.apple.CrashReporter DialogType 2>/dev/null || echo unset)"
  if "$LAUNCHCTL" print-disabled "$DOMAIN" >/dev/null 2>&1; then
    if dialogs_disabled; then
      echo "status=disabled domain=$DOMAIN agent=$LABEL DialogType=$pref"
    else
      echo "status=enabled domain=$DOMAIN agent=$LABEL DialogType=$pref"
    fi
  else
    echo "status=unknown domain=$DOMAIN agent=$LABEL DialogType=$pref (could not read launchd state)"
  fi
}

case "${1:-status}" in
  off|disable|install) disable_dialogs ;;
  on|enable|uninstall) restore_dialogs ;;
  status)              print_status ;;
  *) echo "usage: $0 {off|on|status}" >&2; exit 64 ;;
esac
