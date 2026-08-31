#!/usr/bin/env bash
# Install the mirror skill into Codex, so Codex can delegate to Claude.
#
# The `codex` skill in this plugin lets Claude call Codex. This installs the
# reverse: a `claude` skill in Codex's own skill directory. It lives here rather
# than in skills/ because Claude's plugin system only deploys Claude skills —
# Codex loads from ~/.codex/skills/ and would never see it otherwise.
#
# Usage: bash install.sh [--force]
set -euo pipefail

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}/claude"
force=0
[ "${1:-}" = "--force" ] && force=1

if [ ! -d "$(dirname "$dest")" ]; then
  echo "error: $(dirname "$dest") does not exist — is the Codex CLI installed?" >&2
  echo "  install it with: npm i -g @openai/codex@latest" >&2
  exit 1
fi

if [ -e "$dest" ] && [ "$force" -eq 0 ]; then
  echo "error: $dest already exists. Re-run with --force to overwrite." >&2
  exit 1
fi

mkdir -p "$dest/scripts"
# Named SKILL.codex.md in the repo so Claude's skill auto-discovery doesn't try
# to load a Codex skill; Codex expects it as SKILL.md, so rename on install.
cp "$src_dir/SKILL.codex.md" "$dest/SKILL.md"
cp "$src_dir/scripts/claude-run.sh" "$dest/scripts/claude-run.sh"
chmod +x "$dest/scripts/claude-run.sh"

echo "Installed Codex skill 'claude' -> $dest"
echo
echo "Verify with:"
echo "  codex exec --sandbox read-only --skip-git-repo-check \\"
echo "    \"Do you have a skill named 'claude'? Answer YES or NO.\" </dev/null 2>/dev/null"
echo
echo "Codex will then be able to run:"
echo "  $dest/scripts/claude-run.sh \"<prompt>\""
