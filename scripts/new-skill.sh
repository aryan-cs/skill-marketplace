#!/usr/bin/env bash
# Scaffold a new skill in the `personal` plugin.
# Usage: scripts/new-skill.sh <skill-name>
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"
skills_dir="$repo_root/plugins/personal/skills"

name="${1:-}"

if [ -z "$name" ]; then
  echo "usage: $(basename "$0") <skill-name>" >&2
  echo "  <skill-name> must be kebab-case: lowercase letters, digits, and hyphens." >&2
  exit 1
fi

if ! printf '%s' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
  echo "error: '$name' is not valid kebab-case (lowercase letters, digits, single hyphens; no leading/trailing hyphen)." >&2
  exit 1
fi

case "$name" in
  *claude*|*anthropic*)
    echo "error: a skill name may not contain 'claude' or 'anthropic' (reserved)." >&2
    exit 1
    ;;
esac

skill_dir="$skills_dir/$name"
if [ -e "$skill_dir" ]; then
  echo "error: $skill_dir already exists." >&2
  exit 1
fi

title="$(printf '%s' "$name" | tr '-' ' ')"

mkdir -p "$skill_dir"
cat > "$skill_dir/SKILL.md" <<EOF
---
name: ${name}
description: TODO — one sentence in the third person stating WHAT this skill does and WHEN to use it (include the trigger words a user would actually say).
---

# ${title}

TODO: describe what Claude should do when this skill is active.

## Steps

1. First step.
2. Second step.

## Notes

- Keep this file focused (aim for under ~500 lines). Move detailed reference material into a sibling file such as reference.md and link to it one level deep from here.
EOF

echo "Created $skill_dir/SKILL.md"
echo
echo "Next:"
echo "  1. Edit the frontmatter 'description' — it decides when Claude auto-loads the skill."
echo "  2. Write the body, then test locally:"
echo "       claude --plugin-dir \"$repo_root/plugins/personal\"   (then /reload-plugins)"
echo "  3. Bump 'version' in plugins/personal/.claude-plugin/plugin.json and update CHANGELOG.md."
echo "  4. Commit & push, then: /plugin marketplace update aryan-skills && /plugin update personal"
