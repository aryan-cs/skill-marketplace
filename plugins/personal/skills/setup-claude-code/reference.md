# setup-claude-code — background, the env-var facts, caveats, and reverting

## Why the default kept reverting

Claude Code merges settings from several sources. Lowest to highest precedence:
user (`~/.claude/settings.json`) < project < local < CLI flags < **managed / policy**.

An org on a Claude Team/Enterprise account can push **remote-managed settings**, fetched at
startup and polled hourly, cached at `~/.claude/remote-settings.json`. They sit at the top
tier, so a policy like:

```jsonc
"model": "claude-sonnet-4-6[1m]",
"effortLevel": "medium",
"availableModels": ["sonnet-4", "opus", "haiku", "mythos"]
```

overrides a personal `model: opus` on every restart. The cache is **synced** — hand-editing
it is futile; the next fetch overwrites it. The policy follows the *account*, so it lands on
every machine you sign into (personal and work alike).

## Why the env-var override works (soft default vs hard lock)

The pin above is a **soft default**: `availableModels` *includes* `opus` and there is no
`enforceAvailableModels`, so Opus is allowed — the org merely chose Sonnet as the default.
Two **input** environment variables, read by the CLI at startup, override that soft default.
Verified empirically: both `--model opus` and `ANTHROPIC_MODEL=opus` resolve to
`claude-opus-4-8` even with the Sonnet policy active.

- `ANTHROPIC_MODEL="opus"` — sets the default model. The alias `opus` tracks the latest Opus;
  pin `claude-opus-4-8` instead for an exact version.
- `CLAUDE_CODE_EFFORT_LEVEL="xhigh"` — the real effort input var. It outranks even an
  in-session `/effort` choice.

Do **not** use `CLAUDE_EFFORT` for this — that one is *output only*: the CLI *exports* it for
hooks and subagents to read (`t.CLAUDE_EFFORT = effortLevel`), but never reads it as an input.

If the org later sets `enforceAvailableModels: true` or drops `opus` from `availableModels`,
these overrides stop working and it becomes an admin request — nothing local will fix it.

## The exact blocks the script writes

Idempotent marker blocks (matched by the `>>> <name>` / `<<< <name>` substrings, so re-runs
replace rather than duplicate). In the shell profile:

```sh
# >>> claude-code defaults >>>
# Opus + xhigh (persistent equivalent of ultracode) as the Claude Code default.
export ANTHROPIC_MODEL="opus"
export CLAUDE_CODE_EFFORT_LEVEL="xhigh"
# <<< claude-code defaults <<<

# >>> agent-yes >>>
claude() {
  if command -v caffeinate >/dev/null 2>&1; then
    if command -v ay >/dev/null 2>&1; then
      caffeinate -dimsu ay claude -- "$@"
    else
      caffeinate -dimsu claude "$@"
    fi
  else
    if command -v ay >/dev/null 2>&1; then
      command ay claude -- "$@"
    else
      command claude "$@"
    fi
  fi
}
# <<< agent-yes <<<

# >>> keep-awake >>>
awake() { caffeinate -dimsu "$@"; }
codex() { if command -v caffeinate >/dev/null 2>&1; then caffeinate -dimsu codex "$@"; else command codex "$@"; fi; }
lidawake() {
  case "${1:-on}" in
    on)  sudo pmset -a disablesleep 1 && echo "Lid-closed sleep DISABLED. Revert: lidawake off" ;;
    off) sudo pmset -a disablesleep 0 && echo "Lid behavior restored to normal." ;;
    *)   echo "usage: lidawake on|off" ;;
  esac
}
# <<< keep-awake <<<
```

Note: `caffeinate ... claude` / `caffeinate ... codex` run the **real binaries** (caffeinate
execs via PATH, so it never sees the shell function — no recursion). The no-`caffeinate`
fallbacks use `command` to bypass the function.

## agent-yes

`agent-yes` is an npm global (`npm install -g agent-yes`) that provides the `ay` command and
wraps Claude Code to auto-approve permission prompts for unattended runs. The `claude()`
function routes `claude ...` through `ay claude -- ...`; bypass it once with
`command claude ...`. This auto-approves tool actions — a trust decision — so only enable it
where you're comfortable with that. Uninstall with `npm uninstall -g agent-yes`.

## Keeping agents running with the lid closed (macOS)

Two different sleep paths matter, and they need different tools:

- **Idle sleep** (no input for a while, lid open): handled by `caffeinate`. The `claude()` and
  `codex()` wrappers already run under `caffeinate -dimsu`, so a running agent won't idle-sleep.
  Use `awake <cmd>` to give any other command the same protection.
- **Lid-closed (clamshell) sleep**: `caffeinate` does **not** prevent this on a MacBook with no
  external display — closing the lid forces sleep regardless of assertions. The only reliable knob
  is `sudo pmset disablesleep 1`, exposed here as `lidawake on` (revert: `lidawake off`).

So to run an agent overnight with the lid shut: `lidawake on`, start the task, close the lid.
Run `lidawake off` when done. `disablesleep 1` disables sleep **globally** (not just while an
agent runs) until you turn it off, so prefer AC power — a lidded Mac that never sleeps can run hot
in a bag and drain the battery.

Why the skill doesn't do this for you: `pmset` needs `sudo`, and the org's remote policy
**denies `Bash(sudo:*)`** inside Claude Code sessions — plus a global power change shouldn't run
unprompted. `lidawake` is defined in your shell so *you* run it in a normal terminal, where it
prompts for your password. On an MDM-managed Mac, power settings may be locked by the org.

## Caveats

- **Cost:** Opus is significantly pricier than the org's Sonnet default — usually the whole
  reason an org defaults to Sonnet.
- **Context window:** the policy model was Sonnet 4.6 with 1M context; Opus 4.8 is standard
  (200k). For a huge one-off, `/model` switch in-session.
- **Per machine:** these are shell env vars, so run the skill once per machine. The org policy
  follows your account; env vars do not.

## Reverting

Edit the shell profile (`~/.zshrc` on macOS zsh) and delete the `# >>> claude-code defaults >>>`
block (and the `# >>> agent-yes >>>` block if you want the plain CLI back), then run
`exec $SHELL`. To remove agent-yes entirely: `npm uninstall -g agent-yes`.
