# Changelog

All notable changes to the `personal` plugin are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [0.7.0] - 2026-07-20

### Added
- `setup-claude-code` now provides an order-aware macOS smart-lid mode. `lidawake smart-on` installs a reversible root LaunchDaemon that observes `IOConsoleLocked` and `AppleClamshellState`: closing the lid first keeps agents running even if macOS subsequently locks the display, while explicitly locking with Touch ID/power before closing restores normal sleep and requests it immediately. It fails safe on missing or ambiguous sensor state, exposes `lidawake status` and `smart-off`, and includes deterministic state-machine, restart, and isolated installer tests. The legacy unconditional `lidawake on|off` toggle remains available.

## [0.6.1] - 2026-07-17

### Changed
- `check-paper` bundled preprint template: stripped the template-y decorations for a clean, published-looking title block in the spirit of "Attention Is All You Need" — removed the "A Preprint" label (both under the title and in the running header), the auto `\today` date, and the green ORCID logo icon (the author name still hyperlinks to ORCID). Dropped the now-unused `orcid.pdf` asset. (Keywords line and the University of Illinois Urbana-Champaign affiliation were set in 0.6.0.)

## [0.6.0] - 2026-07-17

### Added
- `check-paper` bundles a ready-to-use, prefilled **arXiv/NeurIPS-style preprint template** in `template/` (MIT-licensed arxiv-style — `template.tex`, `arxiv.sty`, `orcid.pdf`, `references.bib`, license). Prefilled single author Aryan Gupta with ORCID `0009-0005-1413-3773` linked via the green iD and email `aryan.cs.app@gmail.com`; "A Preprint" header, no line numbers, no anonymity, `hidelinks` for a clean look. Verified to compile with `tectonic`. Wired into check A1 and a "Starting a new paper" section.
- Writing checks **B8** (no em dashes) and **B9** (reads human, not AI — no inflated diction, mechanical structure, hedged filler, or spurious "nuanced" context-window details a real author wouldn't include), plus `scripts/check-ai-tells.sh` to locate em dashes and high-signal AI-tell words/phrases, and a "senior-researcher voice" section in `reference.md`.

## [0.5.1] - 2026-07-17

### Added
- `check-paper` reference: a "Preprints and the NeurIPS style modes" section — documents that the NeurIPS style file defaults to *submission* mode (line numbers, "Anonymous Author(s)", and the "Submitted to … Do not distribute." footer), that `\usepackage[preprint]{neurips_2025}` strips all three for arXiv, and points to the community `arxiv-style` (kourgeorge/arxiv-style) and bioRxiv fork for a standalone NeurIPS-looking preprint.

## [0.5.0] - 2026-07-17

### Added
- `check-paper` skill — a model/tool-agnostic paper-review checklist grouped as: structure & venue compliance (correct *unmodified* template, anonymization for double-blind review, required sections, resolved cross-references), writing (narrative prose, results-first abstract in the "Attention Is All You Need" shape, explicit contributions, claims-match-evidence, consistent notation/terminology), citations (completeness + a semantic hand-check, plus `scripts/check-citations.sh` for undefined/unused/duplicate LaTeX+BibTeX keys), rigor & reproducibility (baselines/ablations/error bars/seeds/compute, math & notation, limitations/ethics), and visuals (Turbo colormap, semantic color, matched fonts, ~20px table whitespace, paragraph alignment, no label overlap, legibility). `reference.md` includes a compare/contrast table of premier ML venue templates (NeurIPS, ICML, ICLR, CVPR/ICCV, ACL, AAAI, JMLR/TMLR, IEEE, Typst) with current links, the abstract template, and the visual recipes.

## [0.4.0] - 2026-07-17

### Changed
- `setup-claude-code` now defaults the interactive `claude` wrapper to **full ultracode** (`--effort ultracode` = xhigh effort + standing workflow orchestration) instead of plain xhigh. `CLAUDE_CODE_EFFORT_LEVEL=xhigh` stays as the effort floor for `command claude` and subagents, because — verified empirically — `ultracode` is **not** a valid `CLAUDE_CODE_EFFORT_LEVEL` value: the effort parser only aliases `med→medium`, so `CLAUDE_CODE_EFFORT_LEVEL=ultracode` silently drops to *medium* (same reasoning-token volume as medium). Ultracode is session-scoped by design, so the per-launch `--effort ultracode` flag is the only persistent mechanism; `--effort ultracode` verifiably injects the live "Ultracode is on…" context where the env var and plain xhigh do not. Pass your own `--effort X` to override (last wins); subcommands and duplicate `--effort` are both safe.

## [0.3.1] - 2026-07-17

### Fixed
- `setup-claude-code`: the `agent-yes` wrapper broke `claude` with `env: bun: No such file or directory` because `ay` is a Bun script (`#!/usr/bin/env bun`) but `setup.sh` only installed it via npm and never ensured the Bun runtime. `setup.sh` now installs Bun user-local at `~/.bun` (no sudo), adds a `bun runtime` PATH block, and falls back to `bun install -g agent-yes` when npm is absent (e.g. a machine that only has Codex's bundled `node`, which ships no npm). Downloads now go to a scratch dir removed on exit via a trap, so setup leaves no temp files behind. Documented the Bun dependency in `SKILL.md`/`reference.md` and added a "clean up temp files" step to the skill.

## [0.3.0] - 2026-07-17

### Changed
- Renamed the `setup-cc` skill to `setup-claude-code`. Claude Code does not reserve "claude"/"anthropic" in skill names (verified — it loads as `personal:setup-claude-code`); the abbreviation was only working around this repo's own scaffold rule. Relaxed that rule in `scripts/new-skill.sh` and `docs/authoring-skills.md` so a tool-specific skill can be named for its tool.

## [0.2.0] - 2026-07-16

### Added
- `setup-cc` skill — makes Opus the default model and `xhigh` (the persistent, ultracode-equivalent) effort the default by writing input env vars to the shell profile, overriding a soft org-managed Sonnet/medium pin; installs `agent-yes` with the `claude` auto-approve wrapper; and adds macOS keep-awake helpers (`caffeinate`-wrapped `claude`/`codex`, an `awake` runner, and a `lidawake on|off` toggle over `pmset disablesleep`) so agents survive a closed lid. Ships three tested, idempotent scripts — `scripts/check-policy.sh` (is the org pin overridable?), `scripts/setup.sh` (apply), `scripts/verify.sh` (prove Opus resolves) — plus a `reference.md` with the mechanism and caveats.

## [0.1.0] - 2026-07-15

### Added
- Initial marketplace (`aryan-skills`) and `personal` plugin scaffold.
- `quality-review` example skill — code review by severity, with a reference rubric.
- `scripts/new-skill.sh` to scaffold new skills.
- Authoring guide in `docs/authoring-skills.md`.
