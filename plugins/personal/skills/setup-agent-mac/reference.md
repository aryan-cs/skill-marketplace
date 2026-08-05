# setup-agent-mac — background, the env-var facts, caveats, and reverting

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
Verified empirically: both `ANTHROPIC_MODEL=opus` and the exact `ANTHROPIC_MODEL=claude-opus-5` resolve to
`claude-opus-5` (confirmed via `--output-format json` → `modelUsage`) even with the Sonnet policy active.

- `ANTHROPIC_MODEL="opus"` — sets the default model. This skill uses the **track-latest alias** so the
  machine auto-upgrades to each new Opus with no edit and no re-run; it resolves to `claude-opus-5` today.
  Pin an exact id (`claude-opus-5`) instead only if you need to hold a specific version — an exact id
  resolves fine even though the org allowlist names the alias, since an allowlist is not a requirement that
  you *name* the model the same way. The trade-off of the alias is the flip side of its benefit: the model
  can change under you without warning, so `verify.sh` prints whichever id it actually resolved to.
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

Re-verified on Claude Code 2.1.220 while adding auto mode: launching with `--effort ultracode` and asking
the model whether its context says ultracode is on answers **yes**; the same probe under
`CLAUDE_CODE_EFFORT_LEVEL=ultracode` answers **no**. `verify.sh` check 6 is exactly that probe, so this
claim is tested rather than asserted. (Note `--effort`'s `--help` line lists only `low|medium|high|xhigh|max`
— `ultracode` is accepted but undocumented there, which is why the empirical check matters.)

### Auto mode is per-launch too

`--permission-mode auto` is the CLI's auto mode: a classifier decides which tool calls run without a
prompt, instead of asking on each one. The full set is
`acceptEdits | auto | bypassPermissions | manual | dontAsk | plan`, and the shipped rules are inspectable
with `claude auto-mode config` / `claude auto-mode defaults`, tunable in the `autoMode` section of
`~/.claude/settings.json`, and revertible with `claude auto-mode reset`.

Like effort-`ultracode`, it is **session-scoped with no input env var**, so the `claude()` wrapper supplies
it on every launch. A user-level `permissions.defaultMode` in `~/.claude/settings.json` is the alternative
(the current org policy sets `permissions.ask`/`deny` but *not* `defaultMode`, so it would take effect) —
the wrapper flag is used instead to keep every persistent choice in one shell block, and because a flag is
trivially overridable per launch (`claude --permission-mode manual …`) while a settings key is not.

Auto mode and agent-yes are independent layers: auto mode reduces how many prompts appear at all, agent-yes
answers the ones that still do. Neither implies the other, and `command claude` bypasses both.

If the org later sets `enforceAvailableModels: true`, drops `opus` from `availableModels`, or pins
`permissions.defaultMode`, these overrides stop working and it becomes an admin request — nothing local
will fix it.

## The exact blocks the script writes

Idempotent marker blocks (matched by the `>>> <name>` / `<<< <name>` substrings, so re-runs
replace rather than duplicate). In the shell profile:

```sh
# >>> claude-code defaults >>>
# Latest Opus as the default model; xhigh = effort FLOOR (the wrapper upgrades to full ultracode + auto mode).
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
      caffeinate -dimsu ay claude -- --effort ultracode --permission-mode auto "$@"
    else
      caffeinate -dimsu claude --effort ultracode --permission-mode auto "$@"
    fi
  else
    if command -v ay >/dev/null 2>&1; then
      command ay claude -- --effort ultracode --permission-mode auto "$@"
    else
      command claude --effort ultracode --permission-mode auto "$@"
    fi
  fi
}
# <<< agent-yes <<<

# >>> keep-awake >>>
awake() { caffeinate -dimsu "$@"; }
codex() { if command -v caffeinate >/dev/null 2>&1; then caffeinate -dimsu codex "$@"; else command codex "$@"; fi; }
lidawake() {
  local sl="$HOME/.local/share/setup-agent-mac/install-smart-lid.sh"   # setup.sh bakes the resolved absolute path here
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

# >>> crash-dialogs >>>
crashdialogs() {
  local cdh="$HOME/.local/share/setup-agent-mac/disable-crash-dialogs.sh"   # resolved absolute path, as above
  case "${1:-status}" in
    off)    sudo "$cdh" off ;;
    on)     sudo "$cdh" on ;;
    status) "$cdh" status ;;
    *)      echo "usage: crashdialogs off|on|status" ;;
  esac
}
# <<< crash-dialogs <<<
```

Note: `caffeinate ... claude` / `caffeinate ... codex` run the **real binaries** (caffeinate
execs via PATH, so it never sees the shell function — no recursion). The no-`caffeinate`
fallbacks use `command` to bypass the function.

## agent-yes (runs on Bun)

`agent-yes` provides the `ay` command and wraps Claude Code to auto-approve permission prompts
for unattended runs. The `claude()` function routes `claude ...` through `ay claude -- ...` and adds
`--effort ultracode --permission-mode auto`; bypass all of it once with `command claude ...`. That
combination auto-approves tool actions *and* skips many prompts outright — a trust decision — so only
enable it where you're comfortable with that.

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
| Mac on battery reaches 20%, lid open **or** closed | Restore sleep, release `caffeinate` assertions, and request sleep immediately (`disablesleep 0`, `pmset sleepnow`) | This last-resort cutoff prevents a keep-awake session from draining the battery completely. |
| Lid reopens while still locked | Restore normal sleep (`disablesleep 0`) | The close-first session has ended. |
| Sensors are unavailable or startup is ambiguously closed+locked | Restore normal sleep (`disablesleep 0`) | Failure is conservative: it never leaves an unknown lidded machine forced awake. |

If lid and lock change inside the same polling interval, the daemon treats it as close-first. This is
necessary because lid closure commonly causes the lock signal; a deliberate power-button lock is normally
observable while the lid remains open before the user closes it. For a guaranteed lock-first action, wait
until the lock screen appears before closing the lid; physically simultaneous actions cannot be ordered from
the two macOS state signals.

Whenever the daemon is holding the Mac awake, it checks `pmset -g batt` about once per minute, and immediately
when a keep-awake period begins so a Mac already at the cutoff does not wait for the periodic check. If the Mac
is drawing from **Battery Power** at 20% or below, it enters `low-battery-sleep`, restores `disablesleep 0`,
and calls `pmset sleepnow`.

The cutoff applies in **every lid position**, not only when the lid is closed. A long agent run usually has the
lid open, and that state pre-arms `disablesleep 1`, so exempting it left the Mac pinned awake all the way to 0%.
Drawing from AC never trips the cutoff at any charge, so a Mac charging from below 20% can continue a
deliberate close-first session.

Clearing `disablesleep` is not sufficient on its own. The `claude()` / `codex()` / `awake()` wrappers this skill
installs run under `caffeinate -dimsu`, and `-i` holds a `PreventUserIdleSystemSleep` assertion that `pmset` does
not override. At the cutoff the daemon therefore also signals the `caffeinate` processes. This does **not** kill
the agent sessions: `caffeinate CMD` runs `CMD` as its parent and re-execs itself as a child, so signalling the
caffeinate PID drops the assertion while the wrapped command keeps running. The daemon signals caffeinate PIDs
individually and never a process group, since signalling the group would take the session down with it. Set
`SMART_LID_RELEASE_CAFFEINATE=0` to disable this.

Once the Mac is back on AC or above the cutoff, the safety state is released and normal lid behavior resumes
without needing another lid event. `lidawake status` reports the current power source, percentage, and cutoff
alongside the lock, lid, and `SleepDisabled` state. A failed battery read retries after about five seconds rather
than waiting a minute; after three consecutive failures the daemon enters `battery-unavailable-sleep` and
conservatively restores normal sleep, because it can no longer enforce the cutoff reliably.

The cutoff defaults to 20% and is configurable with `SMART_LID_LOW_BATTERY_PERCENT`.

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
in that state; it can run hot and drain the battery before the 20% cutoff is reached. Lock first, then
close, whenever you want sleep; the cutoff is a last resort, not a substitute for intentional sleep.

## Crash-dialog suppression (macOS)

### What actually produces the dialogs

Agent tooling shells out to a real browser for headless work — Codex plugins rendering a report to PDF
(`data-analytics` → `skills/build-report/report-to-pdf` invokes
`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new`), browser automation, and
similar. Those launches routinely abort during startup:

```
Exception Type:  EXC_CRASH (SIGABRT)     abort() called
  ChromeMain → TransformProcessType → _RegisterApplication → abort
  parentProc: node      responsibleProc: ChatGPT
```

The spawned Chrome cannot register with LaunchServices/the window server from that execution context, so
it aborts before doing any work. One PDF render fires several launches, which is why the alerts arrive in
bursts. **The browser the user is actually using is a separate long-lived process and is unaffected** —
tabs survive, nothing is lost. Reinstalling Chrome or clearing its profile does nothing, because Chrome
is not what is broken.

### Why `DialogType` is not the fix on macOS 26.x

Every guide recommends `defaults write com.apple.CrashReporter DialogType none`. On macOS 26.5
(build 25F84) it is **silently ignored**. Verified by controlled test crashes rather than assumed:

- the key reads back as `none` from both the user domain and `-currentHost`, and is present on disk in
  `~/Library/Preferences/com.apple.CrashReporter.plist`;
- `ReportCrash` still contains both the `DialogType` key and the `none` value in its string table, so the
  value is not merely unrecognized;
- no MDM configuration profile overrides it (nothing matching `CrashReporter` in `/Library/Managed Preferences`);
- a deliberate `SIGABRT` still raised the dialog, with a `ReportCrash agent` process holding it open.

### What works: disable the agent that presents the alert

The alert is drawn by the per-user `com.apple.ReportCrash` **agent**. Disabling that service suppresses it:

```sh
sudo launchctl disable gui/$(id -u)/com.apple.ReportCrash
sudo launchctl bootout  gui/$(id -u)/com.apple.ReportCrash   # dismisses one already on screen
```

`launchctl disable` writes to launchd's per-user disabled database, so it **persists across reboots** and
is reversed with `launchctl enable`. SIP is irrelevant here: SIP protects the LaunchAgent plist in
`/System/Library/LaunchAgents` (so `unload -w` is not an option on a stock machine), but it does not
protect the disabled database, which is why `disable` is the supported route.

Two details the script handles:

- **The domain belongs to the user, not root.** It needs sudo, but the target is `gui/<uid>`, so the uid
  is resolved from `SUDO_UID` (falling back to `id -u`). Passing root's uid would disable nothing useful.
- **The legacy preference is still set**, dropped back to the invoking user with `sudo -u`. It is
  sufficient on macOS < 26 and inert on 26.x, so setting it costs nothing and helps on older machines.

Then it re-reads `launchctl print-disabled` and fails loudly if the state did not actually change —
the exact failure mode that made `DialogType` look like it had worked.

### Cost, and how to check or revert

- It applies to **every app**, not just the crashing headless browsers. Nothing will pop up to tell you a
  real app died; it will just be gone.
- **`.ips` crash reports stop being written** to `~/Library/Logs/DiagnosticReports`. Existing reports are
  untouched, but new ones are not generated, so re-enable before investigating a genuine crash.
- `crashdialogs status` prints the live state (`status=disabled|enabled`, plus the `DialogType` value);
  `crashdialogs on` restores both the agent and crash-report generation.

## Caveats

- **Cost:** Opus is significantly pricier than the org's Sonnet default — usually the whole
  reason an org defaults to Sonnet. Ultracode compounds it: it spawns workflows freely, so it is the
  most expensive mode of the most expensive model. This setup is a deliberate quality-over-cost choice.
- **Context window:** the policy model was Sonnet 4.6 with 1M context; Opus 5 is standard
  (200k). For a huge one-off, `/model` switch in-session.
- **Tracking, not pinned:** `opus` is an alias, so the machine auto-upgrades to each new Opus. That is
  intentional, but the model *can* change without you doing anything — including its price and context
  window. `verify.sh` prints the resolved id; `/model` or an exact `ANTHROPIC_MODEL` holds a version.
- **Auto mode is a trust setting.** It is on for every wrapper launch. Undo it for one session with
  `claude --permission-mode manual …` (last wins) or `command claude`; undo it permanently by removing
  the flag from the `agent-yes` block. `claude auto-mode config` shows the rules actually in force.
- **Crash-dialog suppression trades visibility for quiet.** It is opt-in for that reason: it hides
  crashes from *every* app and stops crash-report generation, so a genuinely broken app fails silently.
  Turn it back on with `crashdialogs on` before diagnosing a real crash.
- **Per machine:** these are shell env vars, so run the skill once per machine. The org policy
  follows your account; env vars do not.

## Reverting

Edit the shell profile (`~/.zshrc` on macOS zsh) and delete the `# >>> claude-code defaults >>>`
block (and the `# >>> agent-yes >>>` and `# >>> bun runtime >>>` blocks if you want the plain CLI
back), then run `exec $SHELL`. To remove agent-yes entirely: `npm uninstall -g agent-yes` (or
`bun remove -g agent-yes`). To remove Bun: `rm -rf ~/.bun`. If smart-lid mode was installed, run
`lidawake smart-off` first; this unloads the LaunchDaemon, removes its two installed files, and restores
normal sleep. If crash dialogs were suppressed, run `crashdialogs on` before removing the
`# >>> crash-dialogs >>>` block — the `launchctl disable` it performed lives in launchd's database, not
in the shell profile, so deleting the block alone leaves the agent disabled with no convenient way back.

**Migrating from `setup-claude-code`:** the staged payload moved from `~/.local/share/setup-claude-code`
to `~/.local/share/setup-agent-mac`. Re-running `setup.sh` stages the helpers at the new path and rewrites
the `keep-awake`/`crash-dialogs` blocks to point at it; an installed smart-lid LaunchDaemon keeps working
throughout, because it runs from its own copy under `/usr/local/libexec`. The old directory is left in
place and can be deleted once `lidawake status` works. `CC_SMART_LID_HOME` is still honored as an
override for machines pinned to the old location.
