#!/usr/bin/env bash
# test-agent-yes-config.sh — prove the agent-yes config actually changes which option
# agent-yes picks, by running the real engine against fake Claude Code screens.
#
# This does NOT test a regex against a string. It boots `ay` in a PTY with a stand-in
# "claude" binary that paints a real captured dialog, and records the bytes agent-yes
# types back. That is the only thing that proves the fix: the engine matches against a
# terminal-rendered screen, so a regex that looks right can still never fire.
#
# Needs: bun + agent-yes installed (the skill's setup.sh does both), python3.
# Run:   bash tests/test-agent-yes-config.sh
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-yes.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail=0
fail_case() { echo "  FAIL: $*"; fail=1; }

AY="$(command -v ay 2>/dev/null || echo "$HOME/.bun/bin/ay")"
BUN="$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")"
if [ ! -x "$AY" ] || [ ! -x "$BUN" ]; then
  echo "SKIP: agent-yes ('ay') or bun not installed — run scripts/setup.sh first"
  exit 0
fi

# --- generate the config under test, exactly the way setup.sh does ----------------
mkdir -p "$TMP/home"
CC_SETUP_PROFILE="$TMP/rc" CC_AGENT_YES_CONFIG="$TMP/home/.agent-yes.config.yaml" \
  AGENT_MAC_HOME="$TMP/payload" bash "$SKILL_DIR/scripts/setup.sh" >/dev/null 2>&1 || true
if [ ! -f "$TMP/home/.agent-yes.config.yaml" ]; then
  echo "  FAIL: setup.sh did not write the agent-yes config"; exit 1
fi

# --- the stand-in CLI: paints one screen, then logs what gets typed at it ----------
cat > "$TMP/fakecli.py" <<'PYEOF'
#!/usr/bin/env python3
import sys, os, time, select, tty
try: tty.setraw(sys.stdin.fileno())
except Exception: pass
out = sys.stdout.buffer
SCREENS = {
  # WebFetch permission dialog, byte shape captured from a real ~/.agent-yes raw log
  "perm": (b" Permission rule \x1b[1mWebFetch\x1b[22m requires confirmation for this tool.\x1b[K\r\n"
           b" Do you want to allow Claude to fetch this content?\x1b[K\r\n"
           b" \x1b[38;2;177;185;249m\xe2\x9d\xaf\x1b[4G\x1b[38;2;153;153;153m1. \x1b[38;2;177;185;249mYes\r\n"
           b"\x1b[39m   \x1b[38;2;153;153;153m2. \x1b[39mYes, and don't ask again for \x1b[1marxiv.org\x1b[22m\x1b[K\r\n"
           b"   3. No, and tell Claude what to do differently \x1b[1m(esc)\x1b[22m\x1b[K\r\n"),
  # Bash dialog whose option 2 wraps onto a second line
  "bash": (b" Bash command\x1b[K\r\n   curl -s https://example.com/a/very/long/path?with=query\x1b[K\r\n"
           b" Do you want to proceed?\x1b[K\r\n"
           b" \x1b[38;2;177;185;249m\xe2\x9d\xaf\x1b[4G1. Yes\r\n"
           b"   2. Yes, and don't ask again for curl commands in\x1b[K\r\n"
           b"      /Users/someone/Desktop/project\x1b[K\r\n"
           b"   3. No, and tell Claude what to do differently \x1b[1m(esc)\x1b[22m\x1b[K\r\n"),
  # trust-this-folder: option 2 is "No, exit" -> must stay on option 1
  "trust": (b" Do you trust the files in this folder?\x1b[K\r\n"
            b" \x1b[38;2;177;185;249m\xe2\x9d\xaf\x1b[4G1. Yes, I trust this folder\r\n"
            b"   2. No, exit\x1b[K\r\n"),
  # AskUserQuestion: option 2 is one of the model's answers -> must not be picked
  "ask": (b" Which database should we use?\x1b[K\r\n"
          b" \x1b[38;2;177;185;249m\xe2\x9d\xaf\x1b[4G1. Postgres\r\n   2. MySQL\x1b[K\r\n   3. SQLite\x1b[K\r\n"),
}
READY = b"\x1b[2J\x1b[H\xe2\x9d\xaf Try \"how does <filepath> work?\"\r\n? for shortcuts\r\n"
out.write(READY); out.flush(); time.sleep(2.0)
out.write(b"\x1b[2J\x1b[H" + SCREENS[os.environ["BENCH_SCREEN"]]); out.flush()
t0, cleared = time.time(), False
log = open(os.environ["BENCH_KEYS"], "wb", buffering=0)
while time.time() - t0 < 10:
    r, _, _ = select.select([sys.stdin.fileno()], [], [], 0.2)
    if r:
        data = os.read(sys.stdin.fileno(), 1024)
        if not data: break
        log.write(repr(data).encode() + b"\n")
        if not cleared:                      # a real dialog closes once answered
            cleared = True; out.write(READY); out.flush()
log.close()
PYEOF

cat > "$TMP/run.py" <<'PYEOF'
import os, pty, select, time, signal, sys, fcntl, termios, struct
work, ay, bun = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(work)
    env = dict(os.environ); env["TERM"] = "xterm-256color"
    for k in ("CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE"): env.pop(k, None)
    os.execve(bun, [bun, ay, "claude"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 69, 79, 0, 0))
t0 = time.time()
while time.time() - t0 < 12:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try:
            if not os.read(fd, 65536): break
        except OSError: break
os.kill(pid, signal.SIGKILL)
try: os.waitpid(pid, 0)
except Exception: pass
PYEOF

# agent-yes searches $HOME then the cwd, with the cwd winning. Run from a scratch cwd
# holding the config setup.sh just generated, with the stand-in binary spliced in — HOME is
# left alone because bun and `ay` resolve their own install under the real one.
mkdir -p "$TMP/work"
python3 - "$TMP/home/.agent-yes.config.yaml" "$TMP/fakecli.py" \
  > "$TMP/work/.agent-yes.config.yaml" <<'SPLICE'
import sys
src, fake = sys.argv[1], sys.argv[2]
for line in open(src):
    sys.stdout.write(line)
    if line.rstrip("\n") == "  claude:":
        sys.stdout.write("    binary: %s\n    defaultArgs: []\n" % fake)
SPLICE
grep -q "binary: $TMP/fakecli.py" "$TMP/work/.agent-yes.config.yaml" \
  || { echo "  FAIL: could not splice the stand-in binary into the generated config"; exit 1; }
chmod +x "$TMP/fakecli.py"

# expected: what agent-yes must type at each screen
run_case() {
  local screen="$1" expect="$2" desc="$3"
  echo "== $screen: $desc =="
  : > "$TMP/keys.log"
  BENCH_SCREEN="$screen" BENCH_KEYS="$TMP/keys.log" \
    python3 "$TMP/run.py" "$TMP/work" "$AY" "$BUN" >/dev/null 2>&1
  local got; got="$(tr -d '\n' < "$TMP/keys.log")"
  [ -z "$got" ] && got="(nothing)"
  echo "  typed: $got"
  # exact match on purpose: a duplicate keystroke would land in the prompt box as a stray
  # message, so "typed it twice" has to fail too, not just "typed the wrong thing".
  if [ "$got" = "$expect" ]; then echo "  PASS"; else fail_case "expected $expect, got $got"; fi
}

run_case perm  "b'2\\n'"   "WebFetch dialog takes option 2 (don't ask again)"
run_case bash  "b'2\\n'"   "Bash dialog with a wrapped option 2 still takes option 2"
run_case trust "b'\\r'"    "trust-this-folder still takes option 1, not \"No, exit\""
run_case ask   "(nothing)"  "AskUserQuestion menu is left for the human"

echo
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED — see above"; fi
exit "$fail"
