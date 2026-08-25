# Changelog

All notable changes to the `personal` plugin are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **`setup-agent-mac`: agent-yes answered every permission prompt with option 1, so Claude Code kept asking the same question forever.** The skill installed the `ay` wrapper but never configured it, and stock agent-yes only knows one move: press Enter. Enter takes whatever the dialog cursor is already on, which is option 1 — `Yes`, just this once — never option 2, `Yes, and don't ask again for X`. Option 1 writes no rule, so the next tool call asks again: one real 9-day session prompted for `arxiv.org` **45 times** before that project's `settings.local.json` finally gained a `WebFetch(domain:arxiv.org)` entry — a rule only option 2 writes, and only a human ever pressed it. Unattended runs were answering "just this once", forever. `setup.sh` now writes `~/.agent-yes.config.yaml` with a `typingRespond` rule that *types* `2` rather than relying on cursor position, plus an `enterExclude` rule that suppresses the stock Enter on the same screens. Both halves were measured in isolation: with `enterExclude` alone and no `typingRespond`, a permission dialog gets nothing typed while the trust prompt still gets its Enter — so the exclude is genuinely honored, and option 2 is deterministic rather than a 60 ms race that happens to be won.
- **A second, narrower failure is documented rather than fixed: agent-yes has no rescan timer.** It looks at the screen only when a chunk of terminal output arrives, so a dialog that is absent from the rendered screen at that moment is never answered, and a CLI waiting on a human emits nothing further to re-trigger it. Measured both ways: with the dialog scrolled off by a repaint delivered in the same write, 35 seconds of silence produced no keystroke at all; with the dialog as the last thing painted — the ordinary case — it still matched inside a single 14 KB coalesced write, at 10 ms. A real hang mode, but not the everyday symptom; taking option 2 shrinks its exposure by leaving far fewer dialogs to miss.
- The rule is scoped by the **text of option 2 together with Claude Code's `3. No, and tell Claude what to do differently` reject line**, never by "a numbered menu is on screen". Option 2 is an arbitrary answer choice on an AskUserQuestion menu and `No, exit` on the trust-this-folder prompt, so a looser rule would answer a real question wrongly or quit the session. Verified against the live binary in a PTY, not against a string: the WebFetch dialog and a Bash dialog whose option 2 wraps across lines both take option 2, the trust prompt still auto-accepts option 1, and an AskUserQuestion menu is left untouched. Two upstream behaviors are documented in `reference.md` because they are easy to get wrong: agent-yes merges maps key by key but **replaces arrays wholesale** (adding an `enter:` key would silently drop all ten of its defaults), and the engine is a compiled binary with `default.config.yaml` embedded, so editing the copy under `node_modules/agent-yes/` does nothing.
- **`setup-agent-mac` smart-lid: the low-battery cutoff never ran with the lid open, so an agent session could still drain to 0%** ([#9](https://github.com/aryan-cs/skill-marketplace/issues/9)). `enforce_low_battery_sleep` returned early unless `prev_closed=1`, but the usual shape of a long agent run is *lid open* on battery — and `unlocked-open` pre-arms `disablesleep 1`, so the machine was held awake all the way down. Reproduced on a real Mac, which drained to empty rather than sleeping, and in simulation: at 3%/2%/1% on battery with the lid open, the daemon reported `disablesleep=1 sleepnow=0` on every sample. The guard now runs in every lid position, keyed on "are we holding the machine awake" rather than on lid state.
- **Clearing `disablesleep` was not sufficient on its own.** The `claude()`/`codex()`/`awake()` wrappers this same skill installs run under `caffeinate -dimsu`, and `-i` holds a `PreventUserIdleSystemSleep` assertion that `pmset` does not override (`-s` is AC-only, so it is `-i` that matters on battery). The daemon contained no reference to `caffeinate`, so those holds survived the cutoff. It now also signals the `caffeinate` processes. This does **not** kill the sessions: `caffeinate CMD` runs `CMD` as its *parent* and re-execs itself as a child, verified by observing the system-wide assertion count fall by one while the wrapped process stayed alive. PIDs are signalled individually and never as a process group, with a test that fails if that ever changes. Opt out with `SMART_LID_RELEASE_CAFFEINATE=0`.

### Changed
- The cutoff is now **20%** (was 10%) and configurable via `SMART_LID_LOW_BATTERY_PERCENT`. 10% leaves little margin to write memory to disk before macOS's own critical-battery handling takes over.
- Safety states are latched and released independently of lid position, and are re-evaluated every cycle rather than on the throttled sampling interval — otherwise a latch taken while closed could not be released once power returned. Phases renamed accordingly: `closed-low-battery-sleep` → `low-battery-sleep`, `closed-battery-unavailable-sleep` → `battery-unavailable-sleep`.
- Returning to AC, or recovering above the cutoff, now releases the latch and restores normal lid behavior without needing another lid event — **including re-arming the `caffeinate` holds** that were released at the cutoff. Without this, a session that survived a low-battery episode spent the rest of its life unable to prevent idle sleep. Each hold is restored with `caffeinate -dimsu -w PID`, which asserts on behalf of the wrapped command and exits when that command does, so sessions that ended in the meantime are skipped rather than leaking an assertion and the restored hold clears itself at session end.
- `setup-agent-mac` `verify.sh` check 2 now also asserts that `~/.agent-yes.config.yaml` carries both option-2 rules, and new `tests/test-agent-yes-config.sh` boots the real `ay` in a PTY against a stand-in CLI that paints captured dialog bytes, asserting the exact keystrokes that come back for four screens. Exact-match on purpose: a duplicate keystroke would land in the prompt box as a stray message, so "typed it twice" fails too. The negative control — the same screens with the config removed — types Enter, which is the bug.
- `tests/test-smart-lid.sh` grew from 18 to 27 cases, adding: the lid-open guard, AC exclusion at any charge, latch release on recovery, the `caffeinate` release (including the never-signal-a-process-group rule and the opt-out), the re-arm on recovery and the fact that nothing is re-armed when nothing was released, and two live `caffeinate` tests — one asserting the assertion drops while the wrapped command survives, one walking the full drop → restore → session-exit cycle and checking the restored hold does not leak.

## [0.10.0] - 2026-07-28

### Changed
- **`setup-claude-code` is now `setup-agent-mac`** — folder, frontmatter `name`, and therefore the `/personal:` command. The skill had outgrown the name: it configures Codex alongside Claude Code, and a growing share of what it does is machine-level macOS work (idle sleep, clamshell behavior, crash alerts) rather than configuring one CLI. The staged helper payload moved from `~/.local/share/setup-claude-code` to `~/.local/share/setup-agent-mac`; re-running `setup.sh` stages the helpers at the new path and rewrites the shell blocks to match. An already-installed smart-lid LaunchDaemon keeps running throughout, because it executes its own copy under `/usr/local/libexec` rather than the staged one, and `CC_SMART_LID_HOME` is still honored as an override for machines pinned to the old location. The old directory is left in place rather than deleted.

### Added
- `setup-agent-mac` can suppress the macOS "*app* quit unexpectedly" crash dialog, via a new `crashdialogs off|on|status` shell command backed by `scripts/disable-crash-dialogs.sh`. The dialogs are a side effect of agent tooling: Codex/Claude Code plugins shell out to headless Chrome for PDF rendering and browser automation, those launches abort during startup (`ChromeMain` → `TransformProcessType` → `_RegisterApplication` → `abort()`), and every abort raises a modal alert — often five or ten in a row. The browser actually in use is a separate long-lived process and is untouched, so the alerts carry no information. Opt-in and **not** applied by `setup.sh`, on the same footing as `lidawake smart-on`: it needs sudo, it silences crash alerts for *every* app, and it stops `.ips` crash reports from being written.
- Worked around and documented a macOS 26.x regression: `defaults write com.apple.CrashReporter DialogType none` — the fix every guide recommends — is **silently ignored** on 26.5 (build 25F84). Established by controlled test crashes, not assumption: the key reads back as `none` from both the user and `-currentHost` domains, `ReportCrash` still carries the `DialogType` key and the `none` value in its string table, and no MDM profile overrides it, yet the dialog still appears. The mechanism that works is `launchctl disable gui/<uid>/com.apple.ReportCrash`, which disables the per-user agent that presents the alert and persists across reboots. SIP does not block it — SIP protects the LaunchAgent plist, not launchd's disabled database. The script resolves the target uid from `SUDO_UID` (the domain belongs to the user, not root), drops back to the user with `sudo -u` to set the legacy preference for machines on older macOS where it *is* sufficient, and then re-reads `print-disabled` and fails loudly if nothing changed — the precise failure mode that made `DialogType` look like it had worked.
- `setup-agent-mac` `tests/test-crash-dialogs.sh` — deterministic coverage with `launchctl`/`defaults` stubbed, so the real launchd database and preference domain are never touched: off/on/status, idempotent re-runs, a stale agent that is already gone, the root guard (exit 77) with `status` still usable unprivileged, usage errors (exit 64), unreadable launchd state reported as `unknown`, and a `launchctl disable` that silently no-ops being reported as a failure rather than a success.
- `setup-agent-mac` `verify.sh` check 3 now also requires the crash-dialog helper and the `crashdialogs` shell function, and prints the live suppression state. It deliberately does not fail on that state — suppression is opt-in, so either setting is correct.

## [0.9.0] - 2026-07-28

### Added
- `setup-claude-code` smart-lid mode now has a last-resort battery cutoff: while the lid is closed, it checks battery about once per minute (and immediately on lid close); when the Mac is drawing from battery power at 10% or less, it restores `disablesleep 0` and requests immediate system sleep. Open-lid and AC-powered sessions are unaffected, while three consecutive unreadable battery samples conservatively restore sleep. `lidawake status` now reports power source, battery percentage, and the cutoff, and the deterministic suite covers threshold, AC/open-lid exclusions, real `pmset -g batt` parsing, telemetry failure, and the full daemon-to-`pmset sleepnow` path.

## [0.8.0] - 2026-07-28

### Changed
- `setup-claude-code` now launches every interactive session on **full ultracode effort with auto mode on**, keeping the model on the **latest Opus** (`claude-opus-5` today, and it rolls forward on its own). The `claude-code defaults` block keeps the track-latest `ANTHROPIC_MODEL="opus"` alias rather than pinning an exact id, so a new Opus release is picked up with no edit and no re-run (`CLAUDE_CODE_EFFORT_LEVEL="xhigh"` is unchanged — it remains the env-expressible effort *floor* for `command claude` and subagents), and the `agent-yes` `claude()` wrapper now passes `--effort ultracode --permission-mode auto` on all four of its branches. Auto mode, like effort-`ultracode`, is session-scoped with no input env var, so a per-launch flag is the only way to persist it; both stay overridable by passing your own flag (last wins) or bypassing with `command claude`. Re-running `setup.sh` upgrades an existing profile in place — the marker blocks are replaced, not duplicated.

### Added
- `setup-claude-code` `verify.sh` grew two checks: that the `claude()` wrapper actually carries `--effort ultracode --permission-mode auto`, and a live probe that launches with those flags and confirms the model reports ultracode is on. The latter makes the load-bearing "`ultracode` works as a flag but silently degrades to medium as an env var" claim tested rather than asserted (re-confirmed on Claude Code 2.1.220). The model-resolution check stays deliberately family-level — pinning an exact version there would turn the next Opus release into a spurious FAIL — and now prints the exact id the alias resolved to so version drift stays visible.
- `setup-claude-code` `check-policy.sh` warns when the org allowlist names Opus only as specific versions rather than the bare `opus` alias, in which case the alias may not carry forward and an exact id is the fallback.
- `setup-claude-code` reference.md documents auto mode: the full `--permission-mode` set, `claude auto-mode config|defaults|reset`, why the wrapper flag is used over `permissions.defaultMode` in settings.json, and that auto mode and agent-yes are independent layers (fewer prompts vs. auto-answered prompts) — both trust decisions, and both bypassed by `command claude`.

## [0.7.1] - 2026-07-23

### Fixed
- `setup-claude-code` reference.md: synced the illustrative `lidawake` keep-awake block with the shipped `setup.sh`, which now bakes the resolved absolute installer path (`local sl=…`) instead of a runtime `${CC_SMART_LID_HOME:-…}` lookup a fresh shell wouldn't have.

## [0.7.0] - 2026-07-23

### Added
- `setup-claude-code` now provides an order-aware macOS smart-lid mode. `lidawake smart-on` installs a reversible root LaunchDaemon that observes `IOConsoleLocked` and `AppleClamshellState`: closing the lid first keeps agents running even if macOS subsequently locks the display, while explicitly locking with Touch ID/power before closing restores normal sleep and requests it immediately. It fails safe on missing or ambiguous sensor state, exposes `lidawake status` and `smart-off`, and includes deterministic state-machine, restart, and isolated installer tests. The legacy unconditional `lidawake on|off` toggle remains available. Hardened before merge: install-time throttle-race poll, tested rollback fail-safe, deterministic installer path, and a root guard on `simulate`.

## [0.6.2] - 2026-07-21

### Changed
- `check-paper` writing check B3 now requires paper titles to be short, catchy, and to the point while remaining specific, accurate, and non-overclaiming. It flags filler, stacked qualifiers, unnecessary subtitles, and scope details that belong in the abstract.

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
