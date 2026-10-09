---
name: codex
description: Delegates work to OpenAI Codex as an autonomous peer — hands off self-contained tasks, argues a design across multiple turns, and fans out parallel sub-agents. Use whenever a second opinion would sharpen an answer, whenever an independent review or implementation of unfamiliar code would help, whenever stuck or uncertain and wanting to think a problem through with another model, whenever work splits into independent parallel chunks, and whenever the user mentions codex, GPT, OpenAI, "ask the other model", "get a second opinion", or "have something else look at this". Reach for it on your own initiative — no need to be told to, and no need to ask permission first.
---

# Codex as a peer

Codex is another frontier coding agent. Treat it as a capable colleague sitting next to you: hand it work, ask what it thinks, or disagree with it. It has its own model lineage and its own blind spots, which is exactly what makes it useful — it fails differently than you do.

Run everything through the wrapper:

```
${CLAUDE_PLUGIN_ROOT}/skills/codex/scripts/codex-run.sh
```

(or resolve `scripts/codex-run.sh` relative to this file). It exists because raw `codex exec` has traps that each fail *silently* — empty output, exit 0, no error — and rediscovering them mid-task wastes a turn. If you find yourself hand-writing a `codex exec` line, use the wrapper instead.

**Prerequisite:** the `codex` CLI on `PATH`, authenticated. If it reports `command not found`, run `npm i -g @openai/codex@latest`.

## Work autonomously

Never stop to ask which model or reasoning effort to use, and never ask permission to consult Codex. Assume the user is away and cannot answer — a question they never see is just a stalled task.

**Model and effort: use the strongest available at the highest effort it supports.** Don't hardcode a model name. The wrapper passes no `-m`/`-c`, so Codex inherits `~/.codex/config.toml` — meaning a stronger model is picked up by editing that config, with nothing to change here. That indirection is the point: a hardcoded model name looks correct forever while quietly going stale.

Running at the ceiling is cheap on easy work — cost and latency scale with difficulty rather than being a flat tax (a trivial prompt returned in ~5s at max effort). Step down with `CODEX_EFFORT=high` only when the user explicitly asks for speed or lower cost.

If a model is ever rejected, the two errors mean opposite things and deserve opposite responses:

| Error | Meaning | Do |
|---|---|---|
| `requires a newer version of Codex` | The **CLI** is stale, not the model | `npm i -g @openai/codex@latest`, retry the *same* model. Do not step down. |
| `not supported when using Codex with a ChatGPT account` | Not licensed for this account | Step down one model. |

Getting this backwards is costly: treating a stale CLI as "model unavailable" silently pins you to a weaker model forever.

## The three ways to use it

### 1. Delegate — hand off a self-contained task

```bash
codex-run.sh "Review src/auth.ts for race conditions. Be specific about line numbers."
codex-run.sh --write "Add a --dry-run flag to cli.py, matching the existing flag style."
codex-run.sh --dir ~/proj "Summarize what this service does in 5 bullets."
```

Read-only by default. `--write` lets it edit files in the working directory.

Codex cannot see your conversation, so the prompt must carry its own context. A prompt that means something only to someone who read the last twenty messages will get a confidently irrelevant answer. Name files, paste the relevant snippet, state the constraint.

### 2. Consult — think a problem through with it

The wrapper prints `THREAD_ID=<uuid>` on stderr. Capture it and pass `--resume` to continue that exact conversation:

```bash
ans=$(codex-run.sh "I'm choosing between X and Y for <problem>. Argue for whichever you think is right." 2>t.err)
tid=$(grep -oE 'THREAD_ID=[0-9a-f-]+' t.err | cut -d= -f2)
codex-run.sh --resume "$tid" "That assumes <Z>, which doesn't hold here because <reason>. Does your answer change?"
```

Always resume by captured id, never `resume --last`. If any other Codex run happens in between — another terminal, a background agent, the user's own session — `--last` silently attaches to *that* conversation and answers confidently from unrelated context. Codex itself flagged this as the single most likely way to get a plausible wrong answer.

Use this when you're genuinely uncertain, not to rubber-stamp a decision you've already made. The value is the disagreement.

### 3. Fan out — parallel sub-agents

For independent chunks, spawn detached Codex agents via [agent-yes](https://www.npmjs.com/package/agent-yes) (installed by the `setup-agent-mac` skill):

```bash
ay codex -- "Audit module A for unhandled promise rejections. Report file:line."
ay codex -- "Audit module B for the same."
ay ls                  # watch them
ay result <pid>        # collect when done
```

Use this when chunks are genuinely independent — if chunk B needs chunk A's answer, just run them in sequence.

**Reach for `ay` whenever a job might exceed ~10 minutes.** A synchronous call is simpler and usually right, but harness command timeouts are often around 600s, and a killed Codex process produces *empty output with no error* — indistinguishable from "it had nothing to say". Detaching removes that failure mode.

## Judge the output, don't just relay it

Codex is a peer, not an oracle. It has a different knowledge cutoff and will state wrong things with total confidence — especially about recent library versions, API changes, and model names.

When you believe it's wrong, say so to the user, give your evidence, and consider putting the disagreement back to Codex — it may have a point you missed, or it may fold:

```bash
codex-run.sh --resume "$tid" "This is Claude (<your model>) following up. I disagree with <X> because <evidence>. What's your take?"
```

Frame these as discussions between peers. Either of you can be wrong, and the case where you're wrong is the one that makes this worth doing. When you relay a Codex finding to the user, say it came from Codex and whether you verified it — an unverified claim passed along as fact is worse than not asking at all.

## Pitfalls the wrapper already handles

Listed so you recognize the symptoms if you ever bypass it. Every one fails *quietly*.

| Trap | Symptom | Why |
|---|---|---|
| stdin left open on `exec` | Hangs forever, 0 bytes, 0 CPU | `codex exec` reads stdin even with a positional prompt. Needs `</dev/null`. |
| `</dev/null` on `resume` | Empty output, **exit 0** | Resume delivers its prompt *through* stdin; redirecting discards it. |
| `--approve-for-me` + `--sandbox` | `cannot be used with` error | `--approve-for-me` already implies `workspace-write`. Never pass both. |
| `--full-auto` | `unexpected argument` | Removed from current Codex. `--approve-for-me` replaced it. |
| Parsing a uuid from stderr | Resumes the wrong thread, or `no rollout found` | The temp-file *path* in stderr contains a uuid too. Anchor on `session id:`. |
| Empty bash array under `set -u` | `unbound variable` | macOS ships bash 3.2. Use `${ARR[@]+"${ARR[@]}"}`. |

## Environment

- **Codex Enterprise**: `approval_policy = never` is rejected (allowed: `UnlessTrusted`, `OnRequest`). `--approve-for-me` is the sanctioned auto-approval path — it still runs sandboxed with automatic review, so it is bounded, not a blank cheque. The wrapper uses it for `--write`.
- Still pause before anything needing `--sandbox danger-full-access`; that disables sandboxing outright and is worth a question even when the user is away.
- Keep a single `codex` install. Two copies (npm global plus a Homebrew cask) shadow each other, and the stale one silently wins after a `nvm` version switch.
- Thinking tokens go to stderr and are hidden by default to protect your context. Pass `--raw` to see Codex's reasoning when debugging.

## The mirror: letting Codex call Claude

`codex-side/` holds the reverse skill, so Codex can delegate to Claude the same way. It is not a Claude skill and is not auto-loaded — it installs into Codex's own skill directory:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/codex/codex-side/install.sh"
```

That copies a `claude` skill into `~/.codex/skills/`, giving Codex the same three modes pointed back at Claude. Consulting each other in a loop is possible and occasionally useful, but keep it bounded — two agents can talk past each other indefinitely, and each turn costs real tokens.
