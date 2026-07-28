---
name: setup-claude-code
description: "Sets up Claude Code on a machine the way Aryan likes it — defaults the model to the latest Opus (Opus 5 today, and it rolls forward on its own) with xhigh as the env effort floor, launches every interactive session on full ultracode effort with auto mode on, installs agent-yes with the auto-approve `claude` wrapper, and adds macOS keep-awake helpers including order-aware lid behavior: close first to keep running, lock first and then close to sleep, and automatically restore sleep at 10% battery while closed. Use when the user asks to set up Claude Code, configure a new machine/laptop, make Opus or ultracode/xhigh the default, auto-upgrade to the newest Opus, turn auto mode (`--permission-mode auto`) on by default, stop the model reverting to Sonnet or medium effort on restart, install agent-yes, keep Claude Code/Codex running with the lid closed, make lid sleep depend on whether the Mac was explicitly locked first, or prevent closed-lid keep-awake mode from draining the battery completely."
---

# Set up Claude Code

Make **the latest Opus + full ultracode effort + auto mode** the persistent default for Claude Code on this machine, and install **agent-yes** with its `claude` auto-approve wrapper. This reproduces Aryan's standard setup and survives restarts.

Model and effort-floor live in env vars; ultracode and auto mode are session-scoped and so ride on a
per-launch flag: `ANTHROPIC_MODEL=opus` (the track-latest alias — Opus 5 today, and it picks up the next
Opus with no edit) and `CLAUDE_CODE_EFFORT_LEVEL=xhigh` (the floor) are exported, while `--effort ultracode`
and `--permission-mode auto` are added by the `claude()` wrapper on every launch.

Why it's needed: an org can push a *remote-managed* policy (`~/.claude/remote-settings.json`) that pins the default model to Sonnet and effort to medium. That policy outranks `~/.claude/settings.json`, so editing settings there doesn't stick. The fix is two **input** environment variables that override the *soft* org default. Full background, the env-var facts, and caveats are in [reference.md](reference.md) — read it if anything below is surprising or fails.

All deterministic work is in the tested scripts beside this file. Run them by absolute path —
`bash "${CLAUDE_PLUGIN_ROOT}/skills/setup-claude-code/scripts/<name>"`, or resolve `scripts/<name>`
relative to this SKILL.md if `CLAUDE_PLUGIN_ROOT` isn't set. Don't reinvent their commands.

## Steps

1. **Check the org policy is overridable — do not skip.** Run `scripts/check-policy.sh`. It reads
   `~/.claude/remote-settings.json` and applies the exact `availableModels` / `enforceAvailableModels`
   rules. **Exit 0** = Opus is allowed → proceed. **Exit 2** = Opus is hard-locked by the org → stop,
   tell the user this is an org-admin change (not a local one), and do not run the rest.

2. **Apply the setup.** Run `scripts/setup.sh`. Idempotent (safe to re-run — every change is a marker
   block). In the login shell's profile (`~/.zshrc` for zsh, `~/.bashrc`/`~/.bash_profile` for bash) it:
   - writes a `claude-code defaults` block: `export ANTHROPIC_MODEL="opus"` (the track-latest alias, so new Opus releases are picked up automatically) and `export CLAUDE_CODE_EFFORT_LEVEL="xhigh"` (the effort **floor** — see the ultracode note below);
   - installs the **Bun runtime** user-local at `~/.bun` if missing (agent-yes's `ay` is a Bun script — see Notes)
     and writes a `bun runtime` block adding `~/.bun/bin` to PATH;
   - installs `agent-yes` if `ay` isn't on PATH — via `npm install -g agent-yes`, or `bun install -g agent-yes`
     when npm is absent — and writes the `agent-yes` block: a `claude()` wrapper that routes through `ay`,
     defaults each launch to **full ultracode** (`--effort ultracode`) and **auto mode**
     (`--permission-mode auto`), and holds a `caffeinate` assertion so runs never idle-sleep;
   - stages the smart-lid daemon and installer under `~/.local/share/setup-claude-code`, then writes a
     `keep-awake` block: `awake` (run any command with no idle sleep), a `caffeinate`-wrapped `codex`,
     legacy global `lidawake on|off`, and the recommended order-aware `lidawake smart-on|smart-off|status`.
   - any archive it downloads (e.g. the Bun release) goes to a scratch dir removed on exit — the script leaves no temp files behind.

3. **Verify.** Run `scripts/verify.sh`. It sources a fresh shell and checks: both env vars are set, `ay`
   is on PATH, the smart-lid payload and shell commands exist, the `claude()` wrapper carries both
   `--effort ultracode` and `--permission-mode auto`, and — via two small `claude -p` API calls — that the
   model actually resolves to an Opus (it prints the exact id the alias landed on) and that ultracode is
   genuinely on at launch (auto mode is accepted in the same call). It prints PASS/FAIL per check and exits
   non-zero on any failure. For
   development or review, also run `tests/test-smart-lid.sh`; it deterministically exercises close-first,
   lock-first, simultaneous sensor changes, the closed-lid 10% battery cutoff, daemon restart, and
   install/uninstall behavior.

4. **Report.** State plainly:
   - It applies to **new** sessions — open a new terminal or run `exec $SHELL`; the current one is unchanged.
   - **For order-aware lid behavior**, run `lidawake smart-on` once in a normal terminal. Closing the lid
     while unlocked keeps the Mac and its agents running; pressing Touch ID/power to lock while the lid is
     open arms normal sleep, so closing it afterward sleeps immediately. If a close-first session runs on
     battery and reaches 10% while still closed, the daemon restores normal sleep and requests it
     immediately; AC power and an open lid do not trigger the cutoff. If battery status cannot be read three
     consecutive times, it conservatively restores sleep rather than running closed without a working guard.
     Inspect the lid, power source, percentage, and cutoff with `lidawake status`, and fully revert with
     `lidawake smart-off`. The one-time install prompts for sudo because the state watcher must run as a root
     LaunchDaemon and change `pmset` safely.
   - Legacy `lidawake on|off` remains available for an unconditional global toggle, but `smart-on` is the
     recommended mode.
   - **Auto mode is on for every wrapper launch** (`--permission-mode auto`): a classifier decides what
     runs without asking, on top of agent-yes auto-approving whatever prompts still appear. Both are trust
     decisions — say so. Override per launch with your own `--permission-mode` (last wins), or use
     `command claude` for the stock prompting behavior.
   - Two model caveats: Opus costs more than the org's Sonnet default, and it uses standard context, not the policy's 1M.
   - The model **auto-upgrades**: `opus` is a track-latest alias, so the machine moves to the next Opus as
     soon as it ships, with no re-run. That is the intent, but it means the model can change under you —
     `verify.sh` prints the exact id it resolved to, and `/model` pins a specific version for one session.
   - Point to [reference.md](reference.md) for the mechanism, reverting, and the per-machine note.

5. **Clean up.** Delete any temporary files created while running this skill — downloaded archives,
   extracted dirs, or a scratch clone of this repo (e.g. under `/tmp`). `setup.sh` already removes its
   own scratch dir on exit; remove anything *you* fetched (a Node/Bun/`gh` download, a temp checkout) so
   the machine is left tidy. Do **not** delete the installed runtimes (`~/.bun`, and any user-local Node).

If a script can't be located, replicate its effect from [reference.md](reference.md) (it lists the exact
blocks and marker names) — never hand-append without the marker blocks, or re-runs will duplicate.

## Notes

- **Ultracode is the interactive default** (xhigh effort + standing workflow orchestration), applied by the wrapper's `--effort ultracode` on every launch. It **can't** be an env var — `CLAUDE_CODE_EFFORT_LEVEL=ultracode` silently drops to *medium* (verified), so `xhigh` stays as the env **floor** for `command claude`/subagents. Ultracode is session-scoped by design, so the per-launch flag *is* the persistence. Pass your own `--effort X` to override (last wins). Cost note: ultracode spawns workflows freely — it's the most expensive mode.
- **Auto mode is also per-launch, for the same reason.** `--permission-mode auto` is a session setting with no input env var, so the wrapper supplies it alongside `--effort ultracode`. Auto mode lets a classifier decide which tool calls run without a prompt (inspect or reset the rules with `claude auto-mode config` / `claude auto-mode reset`); it is *distinct* from agent-yes, which answers whatever prompts still surface. They compose — auto mode means fewer prompts exist, agent-yes means the remaining ones get a yes. Override per launch with `--permission-mode manual` (or `plan`, `acceptEdits`, …); last wins.
- **agent-yes auto-approves tool prompts, and auto mode skips many of them entirely** — both are trust decisions. If the user doesn't want unattended approvals, install the defaults block but skip the agent-yes wrapper (or drop `--permission-mode auto` from it and keep the ultracode flag).
- **agent-yes runs on Bun.** Its `ay` binary starts with `#!/usr/bin/env bun`, so without Bun on PATH the `claude` wrapper dies at `env: bun: No such file or directory` (the package's `engines` claims `node>=22`, but the shipped entry is a Bun script). `setup.sh` installs Bun user-local (`~/.bun`, no sudo) and can also install agent-yes itself via `bun install -g` when npm is missing. Bypass the wrapper anytime with `command claude`.
- **Keep-awake is macOS-only** (`caffeinate`, `ioreg`, `launchd`, `pmset`). On other platforms skip block 4; the model/effort/agent-yes parts still apply.
- **`lidawake smart-on` intentionally keeps an unlocked, lid-closed Mac awake.** Prefer AC power and do not place it in a bag in that state: it can run hot and drain the battery. Lock before closing whenever you want normal sleep. As a last-resort battery guard, a closed Mac on battery automatically restores sleep at 10%; an open or AC-powered Mac is unaffected. Sensor-read errors and ambiguous post-boot states fail safe by restoring normal sleep.
- **Smart mode pre-arms `disablesleep 1` while the lid is open and the session is unlocked.** This is necessary to beat immediate clamshell sleep, so ordinary system sleep is also suppressed in that state; the automatic `caffeinate` wrappers still handle agent-specific idle assertions. A bare `lidawake` is read-only and shows status.
- **`lidawake on` is the legacy global override** and disables sleep until `lidawake off`; do not combine it with smart mode.
