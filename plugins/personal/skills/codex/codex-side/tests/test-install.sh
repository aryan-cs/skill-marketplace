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
test -x "$installed/scripts/claude-run.sh"

if CODEX_SKILLS_DIR="$skills_dir" bash "$source_dir/install.sh" >/dev/null 2>&1; then
  echo "expected a second install without --force to fail" >&2
  exit 1
fi

printf 'stale\n' >"$installed/SKILL.md"
CODEX_SKILLS_DIR="$skills_dir" bash "$source_dir/install.sh" --force >/dev/null
cmp "$source_dir/SKILL.codex.md" "$installed/SKILL.md"

echo "codex-side install tests passed"
