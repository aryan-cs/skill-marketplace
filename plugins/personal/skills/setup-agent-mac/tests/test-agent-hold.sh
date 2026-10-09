#!/bin/bash
# test-agent-hold.sh — the turn-scoped keep-awake hooks: agent-hold.sh itself, their
# registration by agent-hooks.js, and the wrappers setup.sh writes around them.
#
# agent-hold.sh finds its agent by process name, so the stand-in agent is a copy of
# /bin/bash named `claude`. caffeinate is a stub that just waits to be signalled, so
# no real power assertion is taken. Everything runs under a temp dir.
# Run: bash tests/test-agent-hold.sh
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOLD="$SKILL_DIR/scripts/agent-hold.sh"
HOOKS_JS="$SKILL_DIR/scripts/agent-hooks.js"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-hold.XXXXXX")"
agent=""
cleanup() {
  [ -z "$agent" ] || kill "$agent" 2>/dev/null
  pkill -f "$TMP/bin/caffeinate" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/state"
cp /bin/bash "$TMP/bin/claude"
cat > "$TMP/bin/caffeinate" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_CAFFEINATE_LOG:?}"
trap 'exit 0' TERM
while :; do sleep 0.1; done
SH
chmod +x "$TMP/bin/caffeinate"
export AGENT_HOLD_CAFFEINATE="$TMP/bin/caffeinate" AGENT_HOLD_STATE_DIR="$TMP/state"
export AGENT_HOLD_LOW_BATTERY_FLAG="$TMP/low-battery"
export FAKE_CAFFEINATE_LOG="$TMP/caffeinate.log"
: > "$FAKE_CAFFEINATE_LOG"

# The stand-in agent runs one hook per line written to its control fifo, as a direct
# child the way Claude Code and Codex run hooks, and appends each hook's stdout to out.
mkfifo "$TMP/ctl"
"$TMP/bin/claude" -c '
  exec 3<"$1"
  while read -r verb <&3; do
    printf "{\"hook_event_name\":\"x\"}" | "$2" "$verb" >>"$3"
    echo "rc=$?" >>"$4"
  done
' agent "$TMP/ctl" "$HOLD" "$TMP/out" "$TMP/ack" &
agent=$!
exec 4>"$TMP/ctl"
: > "$TMP/out"; : > "$TMP/ack"
hook() {   # hook <start|stop>: run it inside the agent and wait for it to finish
  local before after
  before="$(wc -l < "$TMP/ack")"
  echo "$1" >&4
  for _ in $(seq 1 50); do
    after="$(wc -l < "$TMP/ack")"
    [ "$after" -gt "$before" ] && return 0
    sleep 0.1
  done
  fail "hook $1 did not finish"
}
holds() { pgrep -f "$TMP/bin/caffeinate -[dimsu]+ -w $agent\$" | wc -l | tr -d ' '; }

echo "== start holds caffeinate -i -w <agent>, once per agent =="
hook start
sleep 0.3
grep -qx -- "-i -w $agent" "$FAKE_CAFFEINATE_LOG" || fail "expected '-i -w $agent', got: $(cat "$FAKE_CAFFEINATE_LOG")"
[ "$(holds)" = 1 ] || fail "expected one live hold, found $(holds)"
[ -f "$TMP/state/$agent" ] || fail "no state recorded for agent $agent"
hook start
sleep 0.3
[ "$(holds)" = 1 ] || fail "a second start must reuse the live hold, found $(holds)"

echo "== stop releases it =="
hook stop
sleep 0.3
[ "$(holds)" = 0 ] || fail "stop left $(holds) hold(s) running"
[ ! -e "$TMP/state/$agent" ] || fail "stop left the state file behind"

echo "== stop releases only its own hold =="
# A hold the user took for this session themselves is theirs to keep.
"$TMP/bin/caffeinate" -dimsu -w "$agent" & user_hold=$!
sleep 0.3
hook start
sleep 0.3
hook stop
sleep 0.3
kill -0 "$user_hold" 2>/dev/null || fail "stop released a hold it did not take"
kill "$user_hold" 2>/dev/null; wait "$user_hold" 2>/dev/null

echo "== no new holds while the battery cutoff is in force =="
: > "$AGENT_HOLD_LOW_BATTERY_FLAG"
hook start
sleep 0.3
[ "$(holds)" = 0 ] || fail "took a hold while the low-battery flag was set"
rm -f "$AGENT_HOLD_LOW_BATTERY_FLAG"
hook start
sleep 0.3
[ "$(holds)" = 1 ] || fail "the next start after recovery should take a hold"
hook stop

echo "== hooks print nothing and always exit 0 =="
[ ! -s "$TMP/out" ] || fail "hooks wrote to stdout (UserPromptSubmit would inject it): $(cat "$TMP/out")"
if grep -qv '^rc=0$' "$TMP/ack"; then fail "a hook exited non-zero: $(sort -u "$TMP/ack")"; fi

echo "== outside an agent it does nothing =="
: > "$FAKE_CAFFEINATE_LOG"
out="$(printf '{}' | "$HOLD" start; echo "rc=$?")"
[ "$out" = "rc=0" ] || fail "expected silent exit 0 outside an agent, got: $out"
sleep 0.2
[ ! -s "$FAKE_CAFFEINATE_LOG" ] || fail "held the Mac awake for a process that is not an agent"

echo "== state for ended sessions is pruned =="
printf '1\n' > "$TMP/state/999999"
hook start
[ ! -e "$TMP/state/999999" ] || fail "stale state for a dead agent was not pruned"
hook stop

echo "== the hold ends with its agent even without a stop =="
hook start
sleep 0.3
exec 4>&-
kill "$agent" 2>/dev/null; wait "$agent" 2>/dev/null
dead_agent="$agent"; agent=""
# The stub stands in for `caffeinate -w`, which exits with its target; check the real one.
if [ -x /usr/bin/caffeinate ]; then
  /bin/sleep 30 & target=$!
  /usr/bin/caffeinate -i -w "$target" & real=$!
  sleep 0.3
  kill "$target"; wait "$target" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$real" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$real" 2>/dev/null; then kill "$real"; fail "caffeinate -w outlived its target"; fi
fi
pkill -f "$TMP/bin/caffeinate -i -w $dead_agent\$" 2>/dev/null

echo "== an npm install of the CLI (running as node) is recognised =="
cp /bin/bash "$TMP/bin/node"
: > "$FAKE_CAFFEINATE_LOG"
"$TMP/bin/node" -c '"$1" start </dev/null; sleep 2' /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js "$HOLD" &
node_agent=$!
sleep 0.6
grep -qx -- "-i -w $node_agent" "$FAKE_CAFFEINATE_LOG" || fail "no hold for a node-hosted Claude Code: $(cat "$FAKE_CAFFEINATE_LOG")"
"$TMP/bin/node" -c '"$1" start </dev/null; sleep 1' /usr/local/lib/node_modules/some-other-tool/index.js "$HOLD" &
other_node=$!
sleep 0.6
if grep -q -- "-w $other_node\$" "$FAKE_CAFFEINATE_LOG"; then fail "held the Mac for an unrelated node process"; fi
wait "$node_agent" "$other_node" 2>/dev/null
pkill -f "$TMP/bin/caffeinate -i -w $node_agent\$" 2>/dev/null

echo "== agent-hooks.js: registers, is idempotent, keeps other hooks, uninstalls exactly =="
js() { /usr/bin/osascript -l JavaScript "$HOOKS_JS" "$@" >/dev/null; }
settings="$TMP/claude/settings.json"
mkdir -p "$TMP/claude"
cat > "$settings" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }]
  }
}
JSON
cp "$settings" "$TMP/original.json"
js install "$settings" "/opt/x/agent-hold.sh" claude || fail "install failed"
for event in UserPromptSubmit PreToolUse Stop StopFailure SessionEnd Notification; do
  /usr/bin/plutil -extract "hooks.$event" json -o - "$settings" | grep -q 'agent-hold.sh' \
    || fail "$event hook not registered"
done
/usr/bin/plutil -extract hooks.UserPromptSubmit json -o - "$settings" | grep -q "agent-hold.sh' start" \
  || fail "UserPromptSubmit should start a hold"
/usr/bin/plutil -extract hooks.Notification.0.matcher raw -o - "$settings" | grep -qx 'idle_prompt' \
  || fail "the Notification hook should match idle_prompt only"
/usr/bin/plutil -extract hooks.PreToolUse.0.hooks.0.command raw -o - "$settings" | grep -q "agent-hold.sh' start" \
  || fail "PreToolUse should re-take the hold for a resumed turn"
/usr/bin/plutil -extract hooks.Stop json -o - "$settings" | grep -q 'say done' || fail "dropped the user's own Stop hook"
/usr/bin/plutil -extract model raw -o - "$settings" | grep -qx opus || fail "dropped an unrelated key"
cp "$settings" "$TMP/once.json"
js install "$settings" "/opt/x/agent-hold.sh" claude || fail "second install failed"
cmp -s "$TMP/once.json" "$settings" || fail "a second install changed the file"
js uninstall "$settings" "/opt/x/agent-hold.sh" claude || fail "uninstall failed"
if grep -q 'agent-hold.sh' "$settings"; then fail "uninstall left agent-hold hooks behind"; fi
/usr/bin/plutil -extract hooks.Stop json -o - "$settings" | grep -q 'say done' || fail "uninstall dropped the user's hook"

echo "== agent-hooks.js: symlinks, permissions, and files it has no business rewriting =="
mkdir -p "$TMP/dotfiles"
printf '{ "model": "opus" }\n' > "$TMP/dotfiles/settings.json"
chmod 640 "$TMP/dotfiles/settings.json"
ln -s "$TMP/dotfiles/settings.json" "$TMP/claude/linked.json"
js install "$TMP/claude/linked.json" "/opt/x/agent-hold.sh" claude || fail "install through a symlink failed"
[ -L "$TMP/claude/linked.json" ] || fail "a symlinked settings file was replaced by a regular file"
grep -q 'agent-hold.sh' "$TMP/dotfiles/settings.json" || fail "the symlink's target was not updated"
[ "$(stat -f '%Lp' "$TMP/dotfiles/settings.json")" = 640 ] || fail "the file's permissions were not kept"
[ "$(stat -f '%Lp' "$TMP/dotfiles/settings.json.agent-hold.bak")" = 640 ] || fail "the backup is more readable than the file"
js install "$TMP/claude/brand-new.json" "/opt/x/agent-hold.sh" claude || fail "install into a new file failed"
[ "$(stat -f '%Lp' "$TMP/claude/brand-new.json")" = 600 ] || fail "a new settings file should be private (0600)"
printf '{"hooks":[1]}\n' > "$TMP/arr.json"
if js install "$TMP/arr.json" "/opt/x/agent-hold.sh" claude 2>/dev/null; then fail "accepted a non-object hooks value"; fi
[ "$(cat "$TMP/arr.json")" = '{"hooks":[1]}' ] || fail "modified a file whose hooks value it cannot merge into"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo agent-hold.sh rocks"}]}]}}' > "$TMP/mention.json"
cp "$TMP/mention.json" "$TMP/mention.orig"
js uninstall "$TMP/mention.json" "/opt/x/agent-hold.sh" claude || fail "uninstall failed"
cmp -s "$TMP/mention.orig" "$TMP/mention.json" || fail "uninstall rewrote a file holding none of its hooks"

echo "== agent-hooks.js: Codex flavor, and an invalid file is left untouched =="
js install "$TMP/codex/hooks.json" "/opt/x/agent-hold.sh" codex || fail "codex install into a new file failed"
for event in UserPromptSubmit PreToolUse Stop Interrupt SessionEnd; do
  /usr/bin/plutil -extract "hooks.$event" json -o - "$TMP/codex/hooks.json" | grep -q 'agent-hold.sh' \
    || fail "codex $event hook not registered"
done
/usr/bin/plutil -extract hooks.SessionEnd.0.hooks.0.timeout raw -o - "$TMP/codex/hooks.json" | grep -qx 3 \
  || fail "codex SessionEnd hooks are capped at 3 seconds"
printf '{ not json' > "$TMP/bad.json"
if js install "$TMP/bad.json" "/opt/x/agent-hold.sh" claude 2>/dev/null; then fail "accepted invalid JSON"; fi
[ "$(cat "$TMP/bad.json")" = "{ not json" ] || fail "modified an invalid settings file"

echo "== setup.sh: hooks registered, wrappers drop their whole-session hold =="
run_setup() {   # run_setup <dir> [claude settings]
  local dir="$1" settings="${2:-$1/home/.claude/settings.json}"
  mkdir -p "$dir/home"
  CC_SETUP_PROFILE="$dir/rc" CC_AGENT_YES_CONFIG="$dir/home/.agent-yes.config.yaml" \
    AGENT_MAC_HOME="$dir/payload" CC_CLAUDE_SETTINGS="$settings" \
    CC_CODEX_HOOKS="$dir/home/.codex/hooks.json" \
    bash "$SKILL_DIR/scripts/setup.sh" >"$dir/setup.log" 2>&1
}
fn_body() { sed -n "/^$2() {/,/^}/p" "$1"; }
if ! command -v ay >/dev/null 2>&1 && [ ! -x "$HOME/.bun/bin/ay" ]; then
  echo "   (skipped: setup.sh would install agent-yes; run it once first)"
else
  run_setup "$TMP/s1" || fail "setup.sh failed: $(tail -5 "$TMP/s1/setup.log")"
  [ -x "$TMP/s1/payload/agent-hold.sh" ] || fail "agent-hold.sh was not staged"
  grep -q "agent-hold.sh' start" "$TMP/s1/home/.claude/settings.json" || fail "Claude hooks not registered"
  grep -q "agent-hold.sh' stop" "$TMP/s1/home/.codex/hooks.json" || fail "Codex hooks not registered"
  body="$(fn_body "$TMP/s1/rc" claude)"
  [ -n "$body" ] || fail "no claude() wrapper written"
  if printf '%s' "$body" | grep -q caffeinate; then fail "claude() still holds the whole session: $body"; fi
  printf '%s' "$body" | grep -q -- '--effort ultracode --permission-mode auto' || fail "claude() lost its flags"
  if grep -q '^codex()' "$TMP/s1/rc"; then fail "codex() wrapper still written although its hooks are registered"; fi
  starts="$(grep -c "agent-hold.sh' start" "$TMP/s1/home/.claude/settings.json")"
  [ "$starts" = 2 ] || fail "expected UserPromptSubmit and PreToolUse to start a hold, found $starts"
  run_setup "$TMP/s1" || fail "re-running setup.sh failed"
  [ "$(grep -c "agent-hold.sh' start" "$TMP/s1/home/.claude/settings.json")" = "$starts" ] || fail "re-run duplicated the hooks"

  # If the settings file cannot be updated, the old whole-session hold stays.
  mkdir -p "$TMP/s2/home/.claude"
  printf '{ not json' > "$TMP/s2/home/.claude/settings.json"
  run_setup "$TMP/s2" || fail "setup.sh should not abort when the hooks cannot be registered"
  fn_body "$TMP/s2/rc" claude | grep -q 'caffeinate -dimsu ay claude' \
    || fail "claude() should fall back to a whole-session hold"
  [ "$(cat "$TMP/s2/home/.claude/settings.json")" = "{ not json" ] || fail "setup.sh modified an invalid settings file"
fi

echo "ALL AGENT-HOLD TESTS PASSED"
