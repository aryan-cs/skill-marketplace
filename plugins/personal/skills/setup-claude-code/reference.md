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
- `CLAUDE_CODE_EFFORT_LEVEL="xhigh"` — the real effort input var and the effort **floor** for
  non-interactive/subagent runs and `command claude`. It outranks even an in-session `/effort` choice.

Do **not** use `CLAUDE_EFFORT` for this — that one is *output only*: the CLI *exports* it for
hooks and subagents to read (`t.CLAUDE_EFFORT = effortLevel`), but never reads it as an input.

### Full ultracode is the interactive default — set by the wrapper flag, not the env var

Ultracode = xhigh effort **plus** standing workflow orchestration, and it is *session-scoped* by
design. Its value is **not** accepted by `CLAUDE_CODE_EFFORT_LEVEL`: set the env var to `ultracode`
and the parser silently drops it to **medium** — a regression, not an upgrade. (Verified: `ultracode`
as an env value gives identical reasoning-token volume to `medium`; the effort parser only aliases
`med→medium`, never `ultracode`.) The one persistent mechanism is the **`--effort ultracode` flag**
on each launch, which the `claude()` wrapper adds. Verified empirically: under `--effort ultracode`
the model receives the live *"Ultracode is on…"* system context and higher thinking volume; under the
env var or plain `xhigh` it does not. Pass your own `--effort X` to override (last wins), or
`command claude` to fall back to the xhigh env floor.

If the org later sets `enforceAvailableModels: true` or drops `opus` from `availableModels`,
these overrides stop working and it becomes an admin request — nothing local will fix it.

## The exact blocks the script writes

Idempotent marker blocks (matched by the `>>> <name>` / `<<< <name>` substrings, so re-runs
replace rather than duplicate). In the shell profile:

```sh
# >>> claude-code defaults >>>
# Opus default model; xhigh = effort FLOOR (the interactive wrapper upgrades to full ultracode).
export ANTHROPIC_MODEL="opus"
export CLAUDE_CODE_EFFORT_LEVEL="xhigh"
# <<< claude-code defaults <<<

# >>> bun runtime >>>
# Bun runtime — agent-yes (`ay`) is a Bun script (#!/usr/bin/env bun) and fails without it.
export PATH="$HOME/.bun/bin:$PATH"
# <<< bun runtime <<<

# >>> agent-yes >>>
claude() {
  if command -v caffeinate >/dev/null 2>&1; then
    if command -v ay >/dev/null 2>&1; then
      caffeinate -dimsu ay claude -- --effort ultracode "$@"
    else
      caffeinate -dimsu claude --effort ultracode "$@"
    fi
  else
    if command -v ay >/dev/null 2>&1; then
      command ay claude -- --effort ultracode "$@"
    else
      command claude --effort ultracode "$@"
    fi
  fi
}
# <<< agent-yes <<<

# >>> keep-awake >>>
awake() { caffeinate -dimsu "$@"; }
codex() { if command -v caffeinate >/dev/null 2>&1; then caffeinate -dimsu codex "$@"; else command codex "$@"; fi; }
lidawake() {
  local sl="$HOME/.local/share/setup-claude-code/install-smart-lid.sh"   # setup.sh bakes the resolved absolute path here
  case "${1:-status}" in
    on)  sudo "$sl" uninstall >/dev/null && sudo pmset -a disablesleep 1 && echo "Legacy global mode enabled. Revert: lidawake off" ;;
    off) sudo "$sl" uninstall ;;
    smart-on)  sudo "$sl" install ;;
    smart-off) sudo "$sl" uninstall ;;
    status)    "$sl" status ;;
    *)   echo "usage: lidawake on|off|smart-on|smart-off|status" ;;
  esac
}
# <<< keep-awake <<<
```

Note: `caffeinate ... claude` / `caffeinate ... codex` run the **real binaries** (caffeinate
execs via PATH, so it never sees the shell function — no recursion). The no-`caffeinate`
fallbacks use `command` to bypass the function.

## agent-yes (runs on Bun)

`agent-yes` provides the `ay` command and wraps Claude Code to auto-approve permission prompts
for unattended runs. The `claude()` function routes `claude ...` through `ay claude -- ...`;
bypass it once with `command claude ...`. This auto-approves tool actions — a trust decision —
so only enable it where you're comfortable with that.

**It requires the Bun runtime.** `ay` (and every `*-yes` bin) starts with `#!/usr/bin/env bun`,
so with only Node installed it fails at runtime — the wrapper never launches Claude Code:

```
env: bun: No such file or directory
```

…even though the package's `engines` field claims `node>=22`. `setup.sh` therefore installs Bun
user-local at `~/.bun` (no sudo, via the `bun-<os>-<arch>.zip` release) and adds `~/.bun/bin` to
PATH through the `bun runtime` block. It then installs agent-yes with `npm install -g agent-yes`
— or, when npm is absent (e.g. a box that only has Codex's bundled `node`, which ships no npm),
with `bun install -g agent-yes` into `~/.bun/bin`.

Uninstall agent-yes with `npm uninstall -g agent-yes` (or `bun remove -g agent-yes`); remove Bun
with `rm -rf ~/.bun` and delete the `bun runtime` block.

## Order-aware lid behavior (macOS)

Two different sleep paths matter, and they need different tools:

- **Idle sleep** (no input for a while, lid open): handled by `caffeinate`. The `claude()` and
  `codex()` wrappers already run under `caffeinate -dimsu`, so a running agent won't idle-sleep.
  Use `awake <cmd>` to give any other command the same protection.
- **Lid-closed (clamshell) sleep**: `caffeinate` does **not** prevent this on a MacBook with no
  external display — closing the lid forces sleep regardless of assertions. Preventing it requires
  `pmset disablesleep 1`, which is privileged.

The recommended `lidawake smart-on` installs a root LaunchDaemon that watches two macOS I/O Registry
signals every 100 ms: `IOConsoleLocked` and `AppleClamshellState`. It tracks **which transition happened
first**, because closing the lid can itself make `IOConsoleLocked` change to `Yes`:

| Event order | Result | Why |
|---|---|---|
| Lid closes while unlocked | Keep awake (`disablesleep 1`) | This was an intentional close-first agent session; a later automatic lock is ignored until the lid opens. |
| Touch ID/power locks while lid is open, then lid closes | Restore sleep and request it immediately (`disablesleep 0`, `pmset sleepnow`) | The explicit lock-first transition arms normal clamshell sleep. |
| Lid reopens while still locked | Restore normal sleep (`disablesleep 0`) | The close-first session has ended. |
| Sensors are unavailable or startup is ambiguously closed+locked | Restore normal sleep (`disablesleep 0`) | Failure is conservative: it never leaves an unknown lidded machine forced awake. |

If lid and lock change inside the same polling interval, the daemon treats it as close-first. This is
necessary because lid closure commonly causes the lock signal; a deliberate power-button lock is normally
observable while the lid remains open before the user closes it. For a guaranteed lock-first action, wait
until the lock screen appears before closing the lid; physically simultaneous actions cannot be ordered from
the two macOS state signals.

Smart mode pre-arms `disablesleep 1` whenever the lid is open and the console is unlocked, because enabling it
only after lid closure may be too late. Consequently, ordinary system sleep is suppressed in that state too.
The daemon restores `disablesleep 0` as soon as it observes an explicit lock while open. A bare `lidawake`
does not change power state; it is equivalent to `lidawake status`.

The installed files are `/usr/local/libexec/com.aryangupta.smart-lid` and
`/Library/LaunchDaemons/com.aryangupta.smart-lid.plist`. Inspect with `lidawake status`; remove both and
restore `disablesleep 0` with `lidawake smart-off`. The state file under `/var/run` preserves an active
close-first session across an unexpected daemon restart but is cleared at boot.

For the older unconditional behavior, `lidawake on` first removes smart mode and then sets `disablesleep 1`
globally; `lidawake off` removes smart mode if present and restores `disablesleep 0`. The modes therefore
cannot fight over the power setting.

Why installation needs a normal terminal: `pmset` and a system LaunchDaemon require `sudo`; some
managed environments deny sudo inside Claude Code sessions. On an MDM-managed Mac, power settings may
also be locked by the organization.

Safety: close-first deliberately leaves a lidded Mac running. Prefer AC power and never put it in a bag
in that state; it can run hot and drain the battery. Lock first, then close, whenever you want sleep.

## Caveats

- **Cost:** Opus is significantly pricier than the org's Sonnet default — usually the whole
  reason an org defaults to Sonnet.
- **Context window:** the policy model was Sonnet 4.6 with 1M context; Opus 4.8 is standard
  (200k). For a huge one-off, `/model` switch in-session.
- **Per machine:** these are shell env vars, so run the skill once per machine. The org policy
  follows your account; env vars do not.

## Reverting

Edit the shell profile (`~/.zshrc` on macOS zsh) and delete the `# >>> claude-code defaults >>>`
block (and the `# >>> agent-yes >>>` and `# >>> bun runtime >>>` blocks if you want the plain CLI
back), then run `exec $SHELL`. To remove agent-yes entirely: `npm uninstall -g agent-yes` (or
`bun remove -g agent-yes`). To remove Bun: `rm -rf ~/.bun`. If smart-lid mode was installed, run
`lidawake smart-off` first; this unloads the LaunchDaemon, removes its two installed files, and restores
normal sleep.
