#!/usr/bin/env bash
# setup.sh — make Opus + xhigh the persistent default for Claude Code, wire up agent-yes, and
# stage the macOS helpers (keep-awake, smart lid, crash-dialog suppression).
# Idempotent: every change is a marker block, so re-running never duplicates.
#
# Override the target profile for testing with: CC_SETUP_PROFILE=/tmp/rc ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where privileged helper payloads are staged so they survive a marketplace refresh.
# CC_SMART_LID_HOME is the pre-rename variable, still honored for machines that were set up
# while this skill was called setup-claude-code.
AGENT_MAC_HOME="${AGENT_MAC_HOME:-${CC_SMART_LID_HOME:-$HOME/.local/share/setup-agent-mac}}"

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

# --- scratch space ----------------------------------------------------------
# Any archives this script downloads (e.g. the Bun runtime) go under here and
# are deleted on exit — the setup leaves no temp files behind.
CC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup-agent-mac.XXXXXX")"
cleanup() { rm -rf "$CC_TMP"; }
trap cleanup EXIT

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
  if [ -s "$PROFILE" ]; then printf '\n' >> "$PROFILE"; fi
  { printf '%s\n' "$bf"; printf '%s\n' "$content"; printf '%s\n' "$ef"; } >> "$PROFILE"
  echo "  wrote block: ${name}"
}

# --- install the Bun runtime user-local (no sudo) ---------------------------
# agent-yes ships its bins with a `#!/usr/bin/env bun` shebang, so `ay` fails
# with "env: bun: No such file or directory" if Bun isn't present — even when
# `engines` claims node>=22. Download the matching release into $CC_TMP (removed
# on exit) and drop the binary at ~/.bun/bin/bun. Returns non-zero on failure.
ensure_bun() {
  command -v bun >/dev/null 2>&1 && return 0
  [ -x "$HOME/.bun/bin/bun" ] && return 0
  local os arch asset
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux  ;;
    *) echo "  bun: unsupported OS $(uname -s) — install manually (https://bun.sh)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64)  arch=x64 ;;
    *) echo "  bun: unsupported arch $(uname -m) — install manually (https://bun.sh)" >&2; return 1 ;;
  esac
  command -v unzip >/dev/null 2>&1 || { echo "  bun: 'unzip' not found — cannot install Bun" >&2; return 1; }
  asset="bun-${os}-${arch}.zip"
  echo "  bun: downloading ${asset} ..."
  curl -fsSL -o "$CC_TMP/$asset" "https://github.com/oven-sh/bun/releases/latest/download/$asset" || return 1
  mkdir -p "$CC_TMP/bun-extract"
  unzip -oq "$CC_TMP/$asset" -d "$CC_TMP/bun-extract" || return 1
  local binp; binp="$(find "$CC_TMP/bun-extract" -type f -name bun | head -1)"
  [ -n "$binp" ] || { echo "  bun: archive had no 'bun' binary" >&2; return 1; }
  mkdir -p "$HOME/.bun/bin"
  cp "$binp" "$HOME/.bun/bin/bun" && chmod +x "$HOME/.bun/bin/bun"
}

echo "Profile: $PROFILE"

# --- 1. model + effort defaults --------------------------------------------
upsert_block "claude-code defaults" '# Latest Opus as the default model; xhigh as the effort FLOOR for non-interactive / subagent
# runs and `command claude`. INPUT env vars overriding a soft org-managed default. The interactive `claude`
# wrapper upgrades to full ultracode via `--effort ultracode` — that value is NOT valid as an env var (it
# silently drops to medium), so xhigh is the closest env-expressible floor. The `opus` alias tracks the
# newest Opus (Opus 5 today) and rolls forward on its own; pin an exact id like `claude-opus-5` instead if
# you ever need to hold a specific version. Revert: delete, then `exec $SHELL`.
export ANTHROPIC_MODEL="opus"
export CLAUDE_CODE_EFFORT_LEVEL="xhigh"'

# --- 2. Bun runtime + agent-yes ---------------------------------------------
# Order matters: agent-yes's `ay` is a Bun script, so Bun must be present for the
# wrapper to work at all. Install Bun first, then agent-yes — via npm if it's
# there, else via Bun (a machine may only have Codex's bundled `node`, which has
# no npm). Without this, `claude` dies at "env: bun: No such file or directory".
if command -v bun >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/bun" ]; then
  echo "  bun: already present ($(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun"))"
else
  echo "  bun: installing (agent-yes runs on Bun) ..."
  if ensure_bun; then echo "  bun: installed ($HOME/.bun/bin/bun)"; else
    echo "  bun: install failed — 'ay' will not run until Bun is on PATH (https://bun.sh)" >&2
  fi
fi
BUN="$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")"

# Put ~/.bun/bin on PATH so the `#!/usr/bin/env bun` shebang in `ay` resolves.
upsert_block "bun runtime" '# Bun runtime — agent-yes (`ay`) is a Bun script (#!/usr/bin/env bun) and fails without it.
# Revert: delete this block, then `exec $SHELL` (and `rm -rf ~/.bun` to remove Bun).
export PATH="$HOME/.bun/bin:$PATH"'

if command -v ay >/dev/null 2>&1; then
  echo "  agent-yes: already installed ($(command -v ay))"
elif command -v npm >/dev/null 2>&1; then
  echo "  agent-yes: installing via 'npm install -g agent-yes' ..."
  if npm install -g agent-yes >/dev/null 2>&1; then
    echo "  agent-yes: installed"
  else
    echo "  agent-yes: npm install failed (needs a writable npm prefix or sudo); skipping" >&2
  fi
elif [ -x "$BUN" ]; then
  echo "  agent-yes: npm not found — installing via 'bun install -g agent-yes' ..."
  if "$BUN" install -g agent-yes >/dev/null 2>&1; then
    echo "  agent-yes: installed (via bun → ~/.bun/bin)"
  else
    echo "  agent-yes: bun install failed; skipping" >&2
  fi
else
  echo "  agent-yes: neither npm nor bun available — install Node.js or Bun, then re-run" >&2
fi

# --- 3. agent-yes wrapper function (caffeinate-wrapped so runs never idle-sleep) -----------
# NOTE on the caffeinate branches: caffeinate execs its target via PATH, so `caffeinate ... claude`
# runs the real binary, NOT this function (no recursion). The no-caffeinate fallbacks use
# `command` to bypass the function. Order-aware lid behavior uses `lidawake smart-on` (see block 4).
upsert_block "agent-yes" '# Route `claude` through agent-yes (auto-approves prompts), default to full ultracode
# (`--effort ultracode` = xhigh effort + standing workflow orchestration) and auto mode
# (`--permission-mode auto` = the classifier decides what runs without asking), and hold a caffeinate
# assertion so a run never idle-sleeps. Pass your own --effort / --permission-mode to override (last wins);
# bypass all of it with `command claude`.
claude() {
  if command -v caffeinate >/dev/null 2>&1; then
    if command -v ay >/dev/null 2>&1; then
      caffeinate -dimsu ay claude -- --effort ultracode --permission-mode auto "$@"
    else
      caffeinate -dimsu claude --effort ultracode --permission-mode auto "$@"
    fi
  else
    if command -v ay >/dev/null 2>&1; then
      command ay claude -- --effort ultracode --permission-mode auto "$@"
    else
      command claude --effort ultracode --permission-mode auto "$@"
    fi
  fi
}'

# --- 3b. teach agent-yes to answer permission dialogs with "don't ask again" -----------------
# Stock agent-yes only ever presses Enter, and Enter takes whatever the dialog cursor is
# already on — option 1, a one-shot "yes". Claude Code then asks again on the very next tool
# call, so one long run can burn through dozens of identical prompts for the same domain.
# This config makes it type "2" instead: the "Yes, and don't ask again for X" answer.
#
# Not a shell block, so upsert_block can't do it: agent-yes reads ~/.agent-yes.config.yaml.
# Ownership is tracked with the same ">>> name <<<" marker convention, and a file we did not
# write is never clobbered — the user is told what to add instead.
AGENT_YES_CONFIG="${CC_AGENT_YES_CONFIG:-$HOME/.agent-yes.config.yaml}"
AY_MARKER=">>> setup-agent-mac"

# Matching the "2. Yes, ..." line alone is not safe: option 2 is an arbitrary answer choice on
# an AskUserQuestion menu and "No, exit" on the trust-this-folder prompt. Requiring Claude
# Code's "3. No, and tell Claude what to do differently" reject line on the same screen pins
# this to permission dialogs only. The {0,400} span absorbs an option 2 that wraps across lines.
read -r -d '' AY_CONFIG_BODY <<'AYCONF' || true
clis:
  claude:
    enterExclude:
      - pattern: "^\\s*2\\. Yes,[\\s\\S]{0,400}^\\s*3\\. No, and tell Claude what to do differently"
        flags: m
    typingRespond:
      "2\n":
        - pattern: "^\\s*2\\. Yes,[\\s\\S]{0,400}^\\s*3\\. No, and tell Claude what to do differently"
          flags: m
AYCONF

write_agent_yes_config() {
  mkdir -p "$(dirname "$AGENT_YES_CONFIG")"
  cat > "$AGENT_YES_CONFIG" <<AYHEAD
# yaml-language-server: \$schema=https://raw.githubusercontent.com/snomiao/agent-yes/main/agent-yes.config.schema.json
# $AY_MARKER >>>
# Written by the setup-agent-mac skill. Delete this file to go back to stock agent-yes
# behavior; re-run the skill's scripts/setup.sh to restore it.
#
# A Claude Code permission dialog looks like this:
#
#     Permission rule WebFetch requires confirmation for this tool.
#     Do you want to allow Claude to fetch this content?
#     > 1. Yes
#       2. Yes, and don't ask again for arxiv.org
#       3. No, and tell Claude what to do differently (esc)
#
# enterExclude suppresses the stock Enter on exactly these screens, so taking option 2 is
# deterministic rather than a race between the two rules.
#
# Careful when editing: agent-yes merges maps key by key but REPLACES arrays wholesale.
# Adding \`enter:\` here would silently drop all ten of its defaults (trust-folder, theme
# picker, resume menu, "Press Enter to continue"), which is why this file only touches
# \`enterExclude\` and \`typingRespond\`.
$AY_CONFIG_BODY
# <<< setup-agent-mac <<<
AYHEAD
}

if [ ! -e "$AGENT_YES_CONFIG" ]; then
  write_agent_yes_config
  echo "  agent-yes config: wrote $AGENT_YES_CONFIG (permission dialogs answer \"don't ask again\")"
elif grep -qF "$AY_MARKER" "$AGENT_YES_CONFIG" 2>/dev/null; then
  write_agent_yes_config
  echo "  agent-yes config: refreshed $AGENT_YES_CONFIG"
else
  echo "  agent-yes config: $AGENT_YES_CONFIG already exists and was not written by this skill" >&2
  echo "  agent-yes config: leaving it alone — add this under clis.claude to get option 2:" >&2
  printf '%s\n' "$AY_CONFIG_BODY" | sed 's/^/      /' >&2
fi

# --- 4. macOS helper payloads + keep-awake helpers ------------------------------------------
# Copy the privileged helper payloads out of the plugin cache so they remain available after a
# marketplace refresh. Installing/removing them still requires one explicit sudo each.
mkdir -p "$AGENT_MAC_HOME"
install -m 0755 "$SCRIPT_DIR/smart-lid-daemon.sh" "$AGENT_MAC_HOME/smart-lid-daemon.sh"
install -m 0755 "$SCRIPT_DIR/install-smart-lid.sh" "$AGENT_MAC_HOME/install-smart-lid.sh"
install -m 0755 "$SCRIPT_DIR/disable-crash-dialogs.sh" "$AGENT_MAC_HOME/disable-crash-dialogs.sh"
echo "  macOS helpers: staged payload at $AGENT_MAC_HOME"

upsert_block "keep-awake" '# Keep long agent runs alive on macOS. caffeinate stops idle/display/system sleep;
# `lidawake smart-on` adds order-aware behavior: close-first stays awake; lock-first then close sleeps.
awake() { caffeinate -dimsu "$@"; }                          # run any command with no idle sleep
codex() { if command -v caffeinate >/dev/null 2>&1; then caffeinate -dimsu codex "$@"; else command codex "$@"; fi; }
lidawake() {
  local sl="'"$AGENT_MAC_HOME"'/install-smart-lid.sh"
  case "${1:-status}" in
    on)  sudo "$sl" uninstall >/dev/null && sudo pmset -a disablesleep 1 && echo "Legacy global mode enabled — the Mac stays awake with the lid shut. Revert: lidawake off" ;;
    off) sudo "$sl" uninstall ;;
    smart-on)  sudo "$sl" install ;;
    smart-off) sudo "$sl" uninstall ;;
    status)    "$sl" status ;;
    *)   echo "usage: lidawake on|off|smart-on|smart-off|status" ;;
  esac
}'

# --- 5. crash-dialog suppression --------------------------------------------------------------
# Not applied automatically: it silences the crash alert for EVERY app and stops .ips crash
# reports, so it stays an explicit opt-in like lidawake.
upsert_block "crash-dialogs" '# Suppress the macOS "<app> quit unexpectedly" alert. Agent tooling launches short-lived
# headless browsers (Chrome for PDF rendering, browser automation) that abort during startup, and
# every abort raises a modal dialog — often five or ten in a row. The browser you are actually
# using is a separate process and is unaffected, so the alerts are pure noise.
# `crashdialogs off` disables the per-user ReportCrash agent: it survives reboots, applies to all
# apps, and also stops .ips crash reports. The documented DialogType preference does NOT work on
# macOS 26.x — see the skill reference.md. Revert with `crashdialogs on`.
crashdialogs() {
  local cdh="'"$AGENT_MAC_HOME"'/disable-crash-dialogs.sh"
  case "${1:-status}" in
    off)    sudo "$cdh" off ;;
    on)     sudo "$cdh" on ;;
    status) "$cdh" status ;;
    *)      echo "usage: crashdialogs off|on|status" ;;
  esac
}'

echo
echo "Done. Open a NEW terminal (or run: exec \$SHELL) for the changes to take effect."
echo "Recommended smart behavior (asks once for your password): lidawake smart-on"
echo "  close lid first -> stays awake; lock first, then close -> sleeps"
echo "Optional (asks once for your password): crashdialogs off"
echo "  silences 'quit unexpectedly' alerts from crashing headless browsers, for every app"
