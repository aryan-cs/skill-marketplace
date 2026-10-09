#!/usr/bin/env bash
# claude-run.sh — one safe way to call Claude Code from Codex.
#
# Mirror of the Claude-side codex-run.sh, pointing the other direction.
# Prints Claude's answer on stdout and the session id on stderr as
# "SESSION_ID=<uuid>", so a follow-up turn can resume that exact conversation.
#
# Model is deliberately NOT hardcoded: with no --model, Claude uses the default
# in ~/.claude/settings.json ("opus" — a rolling alias for the latest Opus), so
# a new release is picked up with nothing to edit here. Effort IS pinned to the
# ceiling, because the machine's floor is xhigh and we want the strongest run.
#
# Usage:
#   claude-run.sh "prompt"                      # read-only consult (default)
#   claude-run.sh --write "prompt"              # allow file edits in cwd
#   claude-run.sh --resume <SESSION_ID> "prompt" # continue an exact conversation
#   claude-run.sh --dir <PATH> "prompt"         # run against another directory
#
# Env overrides (rarely needed):
#   CLAUDE_MODEL=sonnet CLAUDE_EFFORT=high claude-run.sh "prompt"

set -uo pipefail

WRITE=0; RESUME=""; DIR=""; PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write)  WRITE=1; shift ;;
    --resume) RESUME="${2:-}"; shift 2 ;;
    --dir)    DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *)        PROMPT="$1"; shift ;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "claude-run.sh: no prompt given" >&2; exit 2
fi

# Resolve the real binary. An interactive zsh here has a `claude` shell function
# that routes through agent-yes and would spawn a DETACHED agent instead of
# answering — which looks like a hang with no output. Prefer the explicit path.
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then
  if [ -x "$HOME/.local/bin/claude" ]; then CLAUDE_BIN="$HOME/.local/bin/claude"
  else CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"; fi
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  echo "claude-run.sh: claude CLI not found. Set CLAUDE_BIN=/path/to/claude" >&2; exit 127
fi

[ -n "$DIR" ] && { cd "$DIR" || { echo "claude-run.sh: cannot cd to $DIR" >&2; exit 1; }; }

OPTS=(-p "$PROMPT" --output-format json)
[ -n "${CLAUDE_MODEL:-}" ] && OPTS+=(--model "$CLAUDE_MODEL")
OPTS+=(--effort "${CLAUDE_EFFORT:-max}")
[ -n "$RESUME" ] && OPTS+=(--resume "$RESUME")

if [ "$WRITE" -eq 1 ]; then
  # acceptEdits lets Claude write files. This is the deliberate analogue of
  # Codex's --approve-for-me: broad enough to be useful, still short of
  # bypassing permission checks entirely.
  OPTS+=(--permission-mode acceptEdits)
else
  # Read-only: Claude can inspect the repo and look things up, but cannot edit
  # or run commands. Keeps a "what do you think?" call from mutating anything.
  OPTS+=(--allowed-tools "Read,Grep,Glob,WebSearch,WebFetch")
fi

OUTF="$(mktemp)"; trap 'rm -f "$OUTF"' EXIT
"$CLAUDE_BIN" ${OPTS[@]+"${OPTS[@]}"} >"$OUTF" 2>/dev/null
RC=$?

if [ "$RC" -ne 0 ] || [ ! -s "$OUTF" ]; then
  echo "claude-run.sh: claude exited $RC with no usable output" >&2
  head -c 500 "$OUTF" >&2
  exit "${RC:-1}"
fi

python3 - "$OUTF" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"claude-run.sh: could not parse response ({e})", file=sys.stderr); sys.exit(1)
sid = d.get("session_id")
if sid:
    print(f"SESSION_ID={sid}", file=sys.stderr)
if d.get("is_error"):
    print(f"claude-run.sh: claude reported an error: {d.get('result','')}", file=sys.stderr); sys.exit(1)
print(d.get("result", ""))
PY
