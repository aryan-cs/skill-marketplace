# Personal Skill Marketplace

A personal [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) for building and versioning your own [skills](https://code.claude.com/docs/en/skills). **The repo is the marketplace; git is the versioned history.**

## How it works

This repo is one marketplace (`aryan-skills`) that ships one plugin (`personal`). Every skill you write lives inside that plugin under `plugins/personal/skills/`. You install the plugin once; after that, editing a skill is just a commit + push, and pulling the change is a `/plugin update`.

```
skill-marketplace/
├── .claude-plugin/
│   └── marketplace.json                # the catalog — declares this repo as a marketplace
├── plugins/
│   └── personal/                       # one plugin bundling all your skills
│       ├── .claude-plugin/
│       │   └── plugin.json             # plugin manifest — the version lives here
│       └── skills/
│           └── quality-review/         # each skill is a folder with a SKILL.md
│               ├── SKILL.md            # entrypoint (frontmatter + instructions)
│               └── reference.md        # optional detail, loaded on demand
├── docs/
│   └── authoring-skills.md             # how to write a new skill (with a template)
├── scripts/
│   └── new-skill.sh                    # scaffolds a new skill folder for you
├── CHANGELOG.md
├── LICENSE
└── README.md
```

The `quality-review` skill is a **working example** — keep it, edit it, or delete the folder.

## Install it (once, on any machine)

Inside a Claude Code session:

```
/plugin marketplace add aryan-cs/skill-marketplace
/plugin install personal@aryan-skills
```

`personal@aryan-skills` is `<plugin-name>@<marketplace-name>`. The marketplace name is the `name` field in `marketplace.json` — not the repo name.

Your skills then appear in the `/` menu, namespaced by the plugin: `/personal:quality-review`.

## Add a new skill

Fastest path — scaffold, then edit:

```
./scripts/new-skill.sh my-new-skill
```

That creates `plugins/personal/skills/my-new-skill/SKILL.md` from a template. Fill in the `description` (it's what makes Claude auto-trigger the skill) and the body. See **[docs/authoring-skills.md](docs/authoring-skills.md)** for the full guide.

Test it locally without publishing:

```
claude --plugin-dir ./plugins/personal
# then, in the session:
/reload-plugins
/personal:my-new-skill
```

## Publish a change

1. **Bump the version** in `plugins/personal/.claude-plugin/plugin.json` (e.g. `0.1.0` → `0.2.0`) and add a line to `CHANGELOG.md`.
2. Commit, tag, and push:
   ```
   git add -A
   git commit -m "Add my-new-skill"
   git tag v0.2.0
   git push && git push --tags
   ```
3. Pull it wherever the plugin is installed:
   ```
   /plugin marketplace update aryan-skills
   /plugin update personal
   /reload-plugins
   ```

> **Why the version bump matters.** `/plugin update` is a **no-op if the version string didn't change**. If you push new skill content but forget to bump `version` in `plugin.json`, installed copies won't update. (Alternatively: delete the `version` line entirely and every commit auto-versions by its git SHA — convenient while iterating heavily, at the cost of clean release numbers. Pick one; don't do both.)

## Versioning model — the rules that bite

- A plugin's version resolves from `plugin.json` → else the marketplace entry → else the git commit SHA. Keep `version` in **one place only** (`plugin.json`). Never also put it in the marketplace entry — `plugin.json` wins silently and can mask it.
- `git tag vX.Y.Z` on each release gives you the human-readable versioned history; `git log` gives per-skill history for free.
- To pin an install to an exact commit/tag, add a `ref` or `sha` to the plugin's `source` object in `marketplace.json` (see the [plugins reference](https://code.claude.com/docs/en/plugins-reference)).

## Notes

- Skills are **auto-discovered** from `skills/<name>/SKILL.md` — you never list them in `plugin.json`.
- The command name comes from the **folder** name (`quality-review/` → `/personal:quality-review`), not the frontmatter `name`. Keep them equal to avoid confusion.
- Keep each `SKILL.md` focused (aim under ~500 lines); push detail into sibling files like `reference.md` and link to them one level deep.
- A skill `name` must be kebab-case and must **not** contain `claude` or `anthropic` (reserved).
