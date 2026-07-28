#!/usr/bin/env bash
# verify.sh — prove the setup took, using the exact working incantations.
# Makes TWO small `claude -p` API calls: one to confirm the model resolves to Opus 5, and one
# to confirm the wrapper's `--effort ultracode --permission-mode auto` flags are live (ultracode
# is only observable at runtime — the env var cannot express it).
# macOS notes baked in: no `timeout` (absent on macOS); write claude's JSON to a temp
# file and parse it separately (never pipe it through a nested-quoted one-liner).
set -uo pipefail

SHELL_BIN="${SHELL:-/bin/zsh}"
NAME="$(basename "$SHELL_BIN")"
# -ic = interactive shell, which sources the rc file (~/.zshrc or ~/.bashrc) so we test
# what a real new session sees. `command claude` bypasses the agent-yes function wrapper
# to get clean JSON on stdout.
run() { "$SHELL_BIN" -ic "$1" 2>/dev/null; }

fail=0

echo "== 1. env vars in a fresh $NAME shell =="
env_line="$(run 'printf "ANTHROPIC_MODEL=%s CLAUDE_CODE_EFFORT_LEVEL=%s\n" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_EFFORT_LEVEL"')"
echo "  $env_line"
case "$env_line" in
  *ANTHROPIC_MODEL=claude-opus-5*CLAUDE_CODE_EFFORT_LEVEL=xhigh*) echo "  PASS" ;;
  *) echo "  FAIL: expected ANTHROPIC_MODEL=claude-opus-5 and CLAUDE_CODE_EFFORT_LEVEL=xhigh"; fail=1 ;;
esac

echo "== 2. agent-yes on PATH =="
# grep the path line: an interactive shell may print startup banners we must ignore.
ay_path="$(run 'command -v ay' | grep -E '/ay$' | tail -1)"
if [ -n "$ay_path" ]; then
  echo "  $ay_path"; echo "  PASS"
else
  echo "  FAIL: 'ay' not found (agent-yes not installed / npm bin not on PATH)"; fail=1
fi

echo "== 3. smart-lid helpers are staged =="
smart_home="${CC_SMART_LID_HOME:-$HOME/.local/share/setup-claude-code}"
if [ -x "$smart_home/smart-lid-daemon.sh" ] && [ -x "$smart_home/install-smart-lid.sh" ] \
  && run 'type lidawake' | grep -q 'function'; then
  echo "  $smart_home"
  echo "  PASS"
else
  echo "  FAIL: smart-lid scripts or lidawake shell function are missing"; fail=1
fi

echo "== 4. the claude wrapper carries the ultracode + auto-mode flags =="
# The two session-scoped settings that cannot live in an env var, so the wrapper must supply
# them on every launch. Read the function body back out of a fresh interactive shell.
# `typeset -f` (not `type`) — zsh's `type` prints only "claude is a shell function from …",
# never the body, so `type` silently fails this check on the default macOS shell.
wrapper="$(run 'typeset -f claude')"
if printf '%s' "$wrapper" | grep -q -- '--effort ultracode' \
  && printf '%s' "$wrapper" | grep -q -- '--permission-mode auto'; then
  echo "  claude() passes --effort ultracode --permission-mode auto"
  echo "  PASS"
else
  echo "  FAIL: the claude() wrapper is missing --effort ultracode and/or --permission-mode auto"; fail=1
fi

echo "== 5. model actually resolves to Opus 5 (one small API call) =="
TMP="$(mktemp)"
run "command claude -p 'reply with exactly: ok' --output-format json" > "$TMP"
# Interactive-shell startup can print banners (e.g. "Restored session:") ahead of the
# JSON, so scan for the single JSON line rather than json.load-ing the whole file.
python3 - "$TMP" <<'PY'
import json, sys
d = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if line.startswith("{") and '"modelUsage"' in line:
        try: d = json.loads(line); break
        except Exception: pass
if d is None:
    print("  FAIL: no result JSON found in claude output"); sys.exit(1)
models = list(d.get("modelUsage", {}).keys())
print("  resolved models:", models)
# A background claude-haiku-* alongside the main model is normal.
sys.exit(0 if any("opus-5" in m for m in models) else 1)
PY
if [ $? -eq 0 ]; then echo "  PASS: Opus 5 is the resolved default"; else echo "  FAIL: Opus 5 did not resolve"; fail=1; fi
rm -f "$TMP"

echo "== 6. ultracode + auto mode are live at launch (one small API call) =="
# Both flags are session-scoped and invisible to `printenv`, so probe them the only way that
# proves anything: launch with them and ask whether the ultracode system context arrived.
# Under plain xhigh (or CLAUDE_CODE_EFFORT_LEVEL=ultracode, which silently degrades to medium)
# this answers "no"; only the --effort ultracode flag makes it "yes".
TMP2="$(mktemp)"
run "command claude --effort ultracode --permission-mode auto -p 'Answer with ONE word only, yes or no: does your context say that ultracode is on?' --output-format json" > "$TMP2"
python3 - "$TMP2" <<'PY'
import json, sys
d = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if line.startswith("{") and '"modelUsage"' in line:
        try: d = json.loads(line); break
        except Exception: pass
if d is None:
    print("  FAIL: no result JSON found — the flags may have been rejected"); sys.exit(1)
if d.get("is_error"):
    print("  FAIL: claude errored with those flags:", d.get("result")); sys.exit(1)
answer = str(d.get("result", "")).strip().lower()
print("  ultracode-is-on probe:", answer or "(empty)")
sys.exit(0 if answer.startswith("yes") else 1)
PY
if [ $? -eq 0 ]; then
  echo "  PASS: --permission-mode auto accepted and ultracode is on"
else
  echo "  FAIL: ultracode did not engage (or auto mode was rejected) — check the CLI version"; fail=1
fi
rm -f "$TMP2"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED. Applies to NEW sessions — open a new terminal or run: exec \$SHELL"
else
  echo "SOME CHECKS FAILED — see above. If the env vars are set but Opus won't resolve, re-run check-policy.sh: the org may hard-lock the model."
fi
exit "$fail"
