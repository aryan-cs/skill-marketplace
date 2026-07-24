#!/usr/bin/env bash
# verify.sh — prove the setup took, using the exact working incantations.
# Makes ONE small `claude -p` API call to confirm the model actually resolves to Opus.
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
  *ANTHROPIC_MODEL=opus*CLAUDE_CODE_EFFORT_LEVEL=xhigh*) echo "  PASS" ;;
  *) echo "  FAIL: expected ANTHROPIC_MODEL=opus and CLAUDE_CODE_EFFORT_LEVEL=xhigh"; fail=1 ;;
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

echo "== 4. model actually resolves to Opus (one small API call) =="
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
sys.exit(0 if any("opus" in m for m in models) else 1)
PY
if [ $? -eq 0 ]; then echo "  PASS: Opus is the resolved default"; else echo "  FAIL: Opus did not resolve"; fail=1; fi
rm -f "$TMP"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED. Applies to NEW sessions — open a new terminal or run: exec \$SHELL"
else
  echo "SOME CHECKS FAILED — see above. If the env vars are set but Opus won't resolve, re-run check-policy.sh: the org may hard-lock the model."
fi
exit "$fail"
