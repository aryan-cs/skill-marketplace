#!/usr/bin/env bash
# codex-run.sh — one safe way to call Codex.
#
# Wraps every footgun we hit building this: the stdin-blocking trap, the
# --approve-for-me/--sandbox conflict, and the resume --last race. Prints the
# answer on stdout and the thread id on stderr as "THREAD_ID=<uuid>", so a
# follow-up turn can resume the exact conversation instead of "the last one".
#
# Model/effort are deliberately NOT hardcoded. With no override, Codex uses the
# defaults in ~/.codex/config.toml, so raising the ceiling there (or Codex
# shipping a stronger default) lifts this automatically — nothing to edit here.
#
# Usage:
#   codex-run.sh "prompt"                      # read-only analysis (default)
#   codex-run.sh --write "prompt"              # allow edits in cwd
#   codex-run.sh --resume <THREAD_ID> "prompt" # continue an exact conversation
#   codex-run.sh --dir <PATH> "prompt"         # run against another directory
#   codex-run.sh --raw "prompt"                # show reasoning (don't hide stderr)
#
# Env overrides (rarely needed):
#   CODEX_MODEL=gpt-5.6-terra CODEX_EFFORT=high codex-run.sh "prompt"

set -uo pipefail

WRITE=0; RAW=0; RESUME=""; DIR=""; PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write)  WRITE=1; shift ;;
    --raw)    RAW=1; shift ;;
    --resume) RESUME="${2:-}"; shift 2 ;;
    --dir)    DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *)        PROMPT="$1"; shift ;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "codex-run.sh: no prompt given" >&2; exit 2
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "codex-run.sh: codex not on PATH. Run: npm i -g @openai/codex@latest" >&2; exit 127
fi

ERRF="$(mktemp)"; ANSF="$(mktemp)"
cleanup() { rm -f "$ERRF" "$ANSF"; }
trap cleanup EXIT

# Only pass -m/-c when explicitly overridden; otherwise inherit config.toml.
OPTS=()
[ -n "${CODEX_MODEL:-}" ]  && OPTS+=(-m "$CODEX_MODEL")
[ -n "${CODEX_EFFORT:-}" ] && OPTS+=(-c "model_reasoning_effort=$CODEX_EFFORT")
[ -n "$DIR" ] && OPTS+=(-C "$DIR")

if [ -n "$RESUME" ]; then
  # Resume takes its prompt THROUGH stdin. Redirecting stdin here would
  # silently discard it and exit 0 with no output, so we pipe instead.
  printf '%s' "$PROMPT" | codex exec ${OPTS[@]+"${OPTS[@]}"} --skip-git-repo-check \
    -o "$ANSF" resume "$RESUME" 2>"$ERRF" >/dev/null
  RC=$?
else
  # --approve-for-me already implies workspace-write and REFUSES to be combined
  # with --sandbox, so the two branches are mutually exclusive by construction.
  if [ "$WRITE" -eq 1 ]; then OPTS+=(--approve-for-me); else OPTS+=(--sandbox read-only); fi
  # </dev/null matters: plain `codex exec` reads stdin even with a positional
  # prompt, and hangs forever if stdin is open-but-empty (common under a harness).
  codex exec ${OPTS[@]+"${OPTS[@]}"} --skip-git-repo-check -o "$ANSF" "$PROMPT" \
    </dev/null 2>"$ERRF" >/dev/null
  RC=$?
fi

TID="$(grep -oE 'session id: [0-9a-f-]+' "$ERRF" | head -1 | awk '{print $3}')"
[ -n "$TID" ] && echo "THREAD_ID=$TID" >&2

if [ "$RC" -ne 0 ]; then
  echo "codex-run.sh: codex exited $RC" >&2
  grep -iE 'error|not supported|requires a newer|unknown variant' "$ERRF" | head -5 >&2
  exit "$RC"
fi

cat "$ANSF"
echo
[ "$RAW" -eq 1 ] && { echo "--- codex reasoning (stderr) ---" >&2; cat "$ERRF" >&2; }
exit 0
