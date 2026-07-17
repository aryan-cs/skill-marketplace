---
name: setup-claude-code
description: Sets up Claude Code on a machine the way Aryan likes it — forces Opus as the default model and xhigh (the persistent, ultracode-equivalent) effort via shell env vars, installs agent-yes with the auto-approve `claude` wrapper, and adds keep-awake helpers so agents survive a closed laptop lid. Use when the user asks to set up Claude Code, configure a new machine/laptop, make Opus or xhigh/ultracode the default, stop the model reverting to Sonnet or medium effort on restart, install agent-yes, or keep Claude Code/Codex running when the lid is closed or the Mac sleeps.
---

# Set up Claude Code

Make **Opus + xhigh effort** the persistent default for Claude Code on this machine, and install **agent-yes** with its `claude` auto-approve wrapper. This reproduces Aryan's standard setup and survives restarts.

Why it's needed: an org can push a *remote-managed* policy (`~/.claude/remote-settings.json`) that pins the default model to Sonnet and effort to medium. That policy outranks `~/.claude/settings.json`, so editing settings there doesn't stick. The fix is two **input** environment variables that override the *soft* org default. Full background, the env-var facts, and caveats are in [reference.md](reference.md) — read it if anything below is surprising or fails.

All deterministic work is in three tested scripts beside this file. Run them by absolute path —
`bash "${CLAUDE_PLUGIN_ROOT}/skills/setup-claude-code/scripts/<name>"`, or resolve `scripts/<name>`
relative to this SKILL.md if `CLAUDE_PLUGIN_ROOT` isn't set. Don't reinvent their commands.

## Steps

1. **Check the org policy is overridable — do not skip.** Run `scripts/check-policy.sh`. It reads
   `~/.claude/remote-settings.json` and applies the exact `availableModels` / `enforceAvailableModels`
   rules. **Exit 0** = Opus is allowed → proceed. **Exit 2** = Opus is hard-locked by the org → stop,
   tell the user this is an org-admin change (not a local one), and do not run the rest.

2. **Apply the setup.** Run `scripts/setup.sh`. Idempotent (safe to re-run — every change is a marker
   block). In the login shell's profile (`~/.zshrc` for zsh, `~/.bashrc`/`~/.bash_profile` for bash) it:
   - writes a `claude-code defaults` block: `export ANTHROPIC_MODEL="opus"` and `export CLAUDE_CODE_EFFORT_LEVEL="xhigh"`;
   - installs the **Bun runtime** user-local at `~/.bun` if missing (agent-yes's `ay` is a Bun script — see Notes)
     and writes a `bun runtime` block adding `~/.bun/bin` to PATH;
   - installs `agent-yes` if `ay` isn't on PATH — via `npm install -g agent-yes`, or `bun install -g agent-yes`
     when npm is absent — and writes the `agent-yes` block: a `claude()` wrapper that routes through `ay` and
     holds a `caffeinate` assertion so runs never idle-sleep;
   - writes a `keep-awake` block: `awake` (run any command with no idle sleep), a `caffeinate`-wrapped
     `codex`, and `lidawake on|off` (toggles `sudo pmset disablesleep` for lid-closed operation).
   - any archive it downloads (e.g. the Bun release) goes to a scratch dir removed on exit — the script leaves no temp files behind.

3. **Verify.** Run `scripts/verify.sh`. It sources a fresh shell and checks: both env vars are set, `ay`
   is on PATH, and — via one small `claude -p` API call — that the model actually resolves to Opus. It
   prints PASS/FAIL per check and exits non-zero on any failure. (If env vars are set but Opus won't
   resolve, re-run step 1: the org may hard-lock the model.)

4. **Report.** State plainly:
   - It applies to **new** sessions — open a new terminal or run `exec $SHELL`; the current one is unchanged.
   - **To keep agents (Claude Code / Codex) running with the lid CLOSED**, the user runs once in their own
     terminal: `lidawake on` (prompts for their password; best on AC power), revert with `lidawake off`.
     Why the hand-off: `caffeinate` (already automatic in the wrappers) only stops *idle* sleep — a closed
     lid needs `sudo pmset disablesleep`, which can't run inside a Claude Code session (org policy denies
     sudo) and shouldn't run unprompted.
   - Two model caveats: Opus costs more than the org's Sonnet default, and Opus uses standard context, not the policy's 1M.
   - Point to [reference.md](reference.md) for the mechanism, reverting, and the per-machine note.

5. **Clean up.** Delete any temporary files created while running this skill — downloaded archives,
   extracted dirs, or a scratch clone of this repo (e.g. under `/tmp`). `setup.sh` already removes its
   own scratch dir on exit; remove anything *you* fetched (a Node/Bun/`gh` download, a temp checkout) so
   the machine is left tidy. Do **not** delete the installed runtimes (`~/.bun`, and any user-local Node).

If a script can't be located, replicate its effect from [reference.md](reference.md) (it lists the exact
blocks and marker names) — never hand-append without the marker blocks, or re-runs will duplicate.

## Notes

- **"ultracode":** `xhigh` is the persistent effort this sets. Ultracode's *standing workflow orchestration* is session-scoped by design — trigger it per session with `/effort` or the `ultracode` keyword. There is no persistent "ultracode" setting; `xhigh` is the durable equivalent.
- **agent-yes auto-approves tool prompts** — a trust decision. If the user doesn't want unattended approvals, install the defaults block but skip the agent-yes wrapper.
- **agent-yes runs on Bun.** Its `ay` binary starts with `#!/usr/bin/env bun`, so without Bun on PATH the `claude` wrapper dies at `env: bun: No such file or directory` (the package's `engines` claims `node>=22`, but the shipped entry is a Bun script). `setup.sh` installs Bun user-local (`~/.bun`, no sudo) and can also install agent-yes itself via `bun install -g` when npm is missing. Bypass the wrapper anytime with `command claude`.
- **Keep-awake is macOS-only** (`caffeinate`, `pmset`). On other platforms skip block 4; the model/effort/agent-yes parts still apply.
- **`lidawake on` disables sleep globally** until `lidawake off` — prefer AC power (a lidded Mac that never sleeps can run hot in a bag and drain the battery).
