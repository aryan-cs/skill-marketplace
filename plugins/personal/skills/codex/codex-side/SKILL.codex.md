---
name: "claude"
description: "Delegates work to Claude Code as an autonomous peer — a second engineer you can hand a task to, argue a design with, or get an independent review from. Use whenever a second opinion would sharpen your answer, whenever you want an independent implementation or review of code you did not write, whenever you are stuck or uncertain and want to think a problem through with someone, and whenever the user mentions Claude, Anthropic, Opus, 'ask the other model', 'get a second opinion', or 'have something else look at this'. Reach for it on your own initiative — you do not need to be told to, and you should not ask permission first."
---

# Claude as a peer

Claude Code is another frontier coding agent on this machine. Treat it as a capable colleague sitting next to you: hand it work, ask what it thinks, or disagree with it. It has a different model lineage and different blind spots, which is exactly what makes it useful — it fails differently than you do.

Run everything through the wrapper:

```
~/.codex/skills/claude/scripts/claude-run.sh
```

It exists because the raw CLI has traps that fail *silently*, and rediscovering them mid-task wastes a turn. If you find yourself hand-writing a `claude -p` line, use the wrapper instead.

## Work autonomously

Never stop to ask which model or effort to use, and never ask permission to consult Claude. Assume the user is away — a question they never see is just a stalled task.

**Use the strongest model at the highest effort.** Don't hardcode a model name. The wrapper passes no `--model`, so Claude inherits `~/.claude/settings.json`, which is set to `opus` — a rolling alias for the latest Opus. When a new one ships it is picked up with nothing to edit here. Effort is pinned to `max` because the machine's floor is only `xhigh` and we want the ceiling. That indirection is the point: a hardcoded model name looks correct forever while quietly going stale.

Step down with `CLAUDE_EFFORT=high` only when the user explicitly asks for speed or lower cost.

## The three ways to use it

### 1. Delegate — hand off a self-contained task

```bash
~/.codex/skills/claude/scripts/claude-run.sh "Review src/auth.ts for race conditions. Be specific about line numbers."
~/.codex/skills/claude/scripts/claude-run.sh --write "Add a --dry-run flag to cli.py, matching the existing flag style."
~/.codex/skills/claude/scripts/claude-run.sh --dir ~/proj "Summarize what this service does in 5 bullets."
```

Read-only by default: Claude can read, search, and look things up, but cannot edit or run commands. `--write` lets it edit files in the working directory.

Claude cannot see your conversation, so the prompt must carry its own context. A prompt that only makes sense to someone who read the last twenty messages will get a confidently irrelevant answer. Name files, paste the relevant snippet, state the constraint.

### 2. Consult — think a problem through with it

The wrapper prints `SESSION_ID=<uuid>` on stderr. Capture it and pass `--resume` to continue that exact conversation:

```bash
ans=$(~/.codex/skills/claude/scripts/claude-run.sh "I'm choosing between X and Y for <problem>. Argue for whichever you think is right." 2>s.err)
sid=$(grep -oE 'SESSION_ID=[0-9a-f-]+' s.err | cut -d= -f2)
~/.codex/skills/claude/scripts/claude-run.sh --resume "$sid" "That assumes <Z>, which doesn't hold here because <reason>. Does your answer change?"
```

Always resume by captured id. Continuing "the most recent session" is unreliable when anything else might have run in between — you would attach to an unrelated conversation and get a confident answer drawn from the wrong context.

Use this when you're genuinely uncertain, not to rubber-stamp a decision you've already made. The value is in the disagreement.

### 3. Long or parallel work

A `claude -p` call at max effort can run for many minutes. If your harness has a command timeout, a killed call looks like an empty answer rather than an error. For anything long, run it in the background and collect the result rather than blocking:

```bash
~/.codex/skills/claude/scripts/claude-run.sh "<big task>" > out.txt 2> sid.err &
```

For genuinely independent chunks, launch several and collect them all. If chunk B needs chunk A's answer, just run them in sequence.

## Judge the output, don't just relay it

Claude is a peer, not an oracle. It has its own knowledge cutoff and will state wrong things confidently — especially about recent library versions, API changes, and model names.

When you believe it's wrong, say so to the user, give your evidence, and consider putting the disagreement back to Claude — it may have a point you missed, or it may fold:

```bash
~/.codex/skills/claude/scripts/claude-run.sh --resume "$sid" "This is Codex following up. I disagree with <X> because <evidence>. What's your take?"
```

Frame these as discussions between peers. Either of you can be wrong, and the case where *you* are wrong is the one that makes this worth doing. When you relay a Claude finding to the user, say it came from Claude and whether you verified it — an unverified claim passed along as fact is worse than not asking at all.

## Pitfalls the wrapper already handles

Listed so you recognize the symptoms if you ever bypass it.

| Trap | Symptom | Why |
|---|---|---|
| Calling bare `claude` from an interactive shell | Returns instantly, no answer | A `claude` shell function here routes through agent-yes and spawns a *detached* agent. The wrapper calls the real binary at `~/.local/bin/claude`. |
| Forgetting `-p` | Hangs waiting for a TTY | Without `--print`, the CLI starts an interactive session. |
| Parsing plain text output | No session id, no continuity | `--output-format json` is what exposes `session_id` and `result`. |
| Empty bash array under `set -u` | `unbound variable` | macOS ships bash 3.2. Use `${ARR[@]+"${ARR[@]}"}`. |

## Environment

- Read-only mode allows `Read,Grep,Glob,WebSearch,WebFetch` — no edits, no shell.
- `--write` uses `--permission-mode acceptEdits`, the deliberate analogue of your own `--approve-for-me`: useful, but short of bypassing permission checks entirely. Don't reach past it to `--dangerously-skip-permissions`; if a task seems to need that, ask the user first.
- Claude has the mirror of this skill pointed back at you, so it can delegate to Codex the same way. Consulting each other in a loop is possible and occasionally useful, but keep it bounded — two agents can talk past each other indefinitely, and each turn costs real tokens.
