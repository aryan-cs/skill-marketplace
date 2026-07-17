# Changelog

All notable changes to the `personal` plugin are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-07-16

### Added
- `setup-cc` skill — makes Opus the default model and `xhigh` (the persistent, ultracode-equivalent) effort the default by writing input env vars to the shell profile, overriding a soft org-managed Sonnet/medium pin; installs `agent-yes` with the `claude` auto-approve wrapper; and adds macOS keep-awake helpers (`caffeinate`-wrapped `claude`/`codex`, an `awake` runner, and a `lidawake on|off` toggle over `pmset disablesleep`) so agents survive a closed lid. Ships three tested, idempotent scripts — `scripts/check-policy.sh` (is the org pin overridable?), `scripts/setup.sh` (apply), `scripts/verify.sh` (prove Opus resolves) — plus a `reference.md` with the mechanism and caveats.

## [0.1.0] - 2026-07-15

### Added
- Initial marketplace (`aryan-skills`) and `personal` plugin scaffold.
- `quality-review` example skill — code review by severity, with a reference rubric.
- `scripts/new-skill.sh` to scaffold new skills.
- Authoring guide in `docs/authoring-skills.md`.
