# Authoring skills

A skill is a folder with a `SKILL.md` at its root. Claude reads the frontmatter `description` of every installed skill at startup and loads the full skill only when that description matches what you're doing. Get the description right and the skill triggers itself.

## Anatomy

```
plugins/personal/skills/<skill-name>/
├── SKILL.md          # required — YAML frontmatter + Markdown instructions
├── reference.md      # optional — detail loaded only when SKILL.md links to it
├── examples.md       # optional — same idea
└── scripts/          # optional — helpers Claude runs (never read into context)
    └── helper.py
```

## SKILL.md frontmatter

Only two fields matter for a personal skill:

```yaml
---
name: my-skill
description: <third person> <what it does> + <when to use it, with trigger words>
---
```

- **`name`** — kebab-case, ≤ 64 chars, lowercase / digits / hyphens. Must equal the folder name. Name it for what it does; a tool-specific skill may include that tool's name (e.g. `setup-claude-code`).
- **`description`** — the single most important line. Write it in the **third person** ("Reviews…", "Generates…", "Use when…"), and make it state both **what** the skill does and **when** to use it, including the words a user would actually say. This is what Claude matches on to auto-load the skill. Keep it under ~1024 chars.

Useful optional keys:

| Key | Purpose |
| --- | --- |
| `when_to_use` | Extra trigger phrases appended to the description (note the underscore). |
| `allowed-tools` | Tools pre-approved (no permission prompt) while the skill is active, e.g. `Bash(git diff:*)`. |
| `disable-model-invocation` | `true` = manual `/personal:my-skill` only; Claude won't auto-load it. |
| `argument-hint` | Autocomplete hint for args, e.g. `[pr-number]`. |
| `model` / `effort` | Force a model or effort level while the skill runs. |

Casing is deliberately mixed: `allowed-tools` is hyphenated but `when_to_use` uses an underscore. There is no `allowed_tools` (that spelling silently does nothing).

## Template

```markdown
---
name: my-skill
description: Does X for Y. Use when the user asks to A, B, or mentions C.
---

# My Skill

<One sentence: what Claude should do when this skill runs.>

## Steps

1. ...
2. ...

## Notes

- Edge cases, gotchas, output format.
```

Or just run `./scripts/new-skill.sh my-skill` to generate this for you.

## Progressive disclosure

Only `name` + `description` are loaded at startup. The `SKILL.md` body loads when the skill triggers. Anything you link from `SKILL.md` (`[reference.md](reference.md)`) loads only when Claude follows the link, and scripts in `scripts/` are executed, never read into context. So:

- Keep `SKILL.md` to the core procedure (aim < 500 lines).
- Move long rubrics, tables, and API details into `reference.md` and link to them **one level deep** (don't chain `SKILL.md` → `a.md` → `b.md`; Claude may only partially read nested files).
- Put deterministic work in `scripts/` and call it from `SKILL.md`.

## Test before you publish

```
claude --plugin-dir ./plugins/personal
# in the session:
/reload-plugins
/personal:my-skill        # run it manually
```

Then validate the whole marketplace:

```
claude plugin validate .
```

## Publish

Bump `version` in `plugins/personal/.claude-plugin/plugin.json`, update `CHANGELOG.md`, commit, `git tag`, and push. See the README's "Publish a change" section for the exact commands.
