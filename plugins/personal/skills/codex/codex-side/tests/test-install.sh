#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "$test_dir/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

skills_dir="$scratch/skills"
mkdir -p "$skills_dir"

CODEX_SKILLS_DIR="$skills_dir" bash "$source_dir/install.sh" >/dev/null

installed="$skills_dir/claude"
cmp "$source_dir/SKILL.codex.md" "$installed/SKILL.md"
cmp "$source_dir/scripts/claude-run.sh" "$installed/scripts/claude-run.sh"
cmp "$source_dir/agents/openai.yaml" "$installed/agents/openai.yaml"
cmp "$source_dir/assets/claude.png" "$installed/assets/claude.png"
test -x "$installed/scripts/claude-run.sh"

python3 - "$source_dir/assets/claude.png" <<'PY'
import struct
import sys
from pathlib import Path

header = Path(sys.argv[1]).read_bytes()[:24]
assert header[:8] == b"\x89PNG\r\n\x1a\n"
assert header[12:16] == b"IHDR"
assert struct.unpack(">II", header[16:24]) == (600, 600)
PY

if CODEX_SKILLS_DIR="$skills_dir" bash "$source_dir/install.sh" >/dev/null 2>&1; then
  echo "expected a second install without --force to fail" >&2
  exit 1
fi

printf 'stale\n' >"$installed/SKILL.md"
printf 'stale\n' >"$installed/assets/claude.png"
CODEX_SKILLS_DIR="$skills_dir" bash "$source_dir/install.sh" --force >/dev/null
cmp "$source_dir/SKILL.codex.md" "$installed/SKILL.md"
cmp "$source_dir/assets/claude.png" "$installed/assets/claude.png"

echo "codex-side install tests passed"
