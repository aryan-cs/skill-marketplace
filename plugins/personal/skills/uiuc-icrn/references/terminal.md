# Background terminal and GPU work

## Project mapping

Keep work in the remote counterpart of the current local directory. Take the current Git/workspace root's basename, use the same child beneath the configured remote sandbox, and preserve any subdirectory relative to that root.

```text
local workspace root:  <local-parent>/<project-name>
remote project root:   <configured-remote-sandbox>/<project-name>
current subdirectory:  preserved relative to <project-name>
```

Use `scripts/icrn_project_terminal.sh` to derive and pass that path automatically. If the exact mapped directory exists, reuse it. If it does not exist, create that path once beneath the sandbox and then work only there. Never create a numbered duplicate, fall back to the sandbox root, or operate in a similarly named directory.

## How it works

`scripts/icrn_project_terminal.sh` normally talks to a private local broker. On the first command in the current agent task, the broker reads the Jupyter token from the owner-only file named in private configuration and creates one cryptographically named Jupyter terminal on the attested ready instance. It keeps that authenticated TLS WebSocket open for sequential commands, while every command receives fresh protocol nonces, an explicit cwd, its own process group, a timeout, an output bound, and a verified exit status. A terminal is reusable only after authenticated completion and a confirmed idle marker following cleanup and echo restoration.

The broker is task-scoped by a digest of the current agent task and canonical local project root. Its Unix socket and state are owner-only. It serializes commands, keeps the token only in the broker process, and closes the exact remote terminal on explicit close, ambiguity, idle expiry, or absolute expiry. It never scans or deletes unrelated terminals.

This is direct background access to the instance. It does not drive the VS Code terminal UI, foreground Chrome, use SSH, expose a network listener, or require browser remote-debug approval.

## Run commands

Commands are argv, not an implicitly interpolated shell string:

```sh
scripts/icrn_project_terminal.sh -- pwd
scripts/icrn_project_terminal.sh -- nvidia-smi
scripts/icrn_project_terminal.sh --timeout 900 -- python3 train.py
```

Related calls in the same task reuse the terminal. At task completion, including error paths, release it:

```sh
scripts/icrn_project_terminal.sh --session-status
scripts/icrn_project_terminal.sh --session-close
```

Use `--one-shot` before ordinary arguments only when isolation is preferable or the requested foreground timeout exceeds the broker's remaining absolute lifetime. It creates and deletes one exact terminal for that command:

```sh
scripts/icrn_project_terminal.sh --one-shot --timeout 2400 -- python3 long_foreground.py
```

Relative `--cwd` paths start beneath the configured remote sandbox. Absolute paths must remain inside it.

Use a shell only when shell syntax is deliberately needed:

```sh
scripts/icrn_project_terminal.sh -- \
  bash -lc 'nohup setsid python3 train.py > run.log 2>&1 < /dev/null & echo $!'
```

The command runner cleans up descendants left in its own process group. Use an explicit new session, as above, only when the user wants a job to persist after the command returns. After starting a detached job, verify its PID, log file, and GPU allocation with another direct command. For long foreground work, set an explicit `--timeout` large enough for the job.

## Work with files

Create files without shell-quoting ambiguity by invoking Python directly:

```sh
scripts/icrn_project_terminal.sh -- python3 -c \
  'from pathlib import Path; Path("example.txt").write_text("hello\n", encoding="utf-8")'

scripts/icrn_project_terminal.sh -- cat example.txt
```

Prefer no-clobber or idempotent writes when retrying after an uncertain network result. Verify important artifacts independently by checking existence, type, size, content hash, and relevant job/process state.

## Limits and security

- The client is intended for noninteractive commands. Password prompts, full-screen terminal programs, and workflows requiring a live TTY conversation need a different interaction path.
- Remote output and runtime are bounded. Redirect large logs remotely and inspect a bounded tail. A blocked local output sink can delay the client itself; write or redirect local output to a regular file when the consumer may stop reading.
- A nonzero command exit, authenticated timeout, or bounded output truncation leaves the session reusable. A missing idle marker, protocol failure, broken local transport after acceptance, or uncertain result poisons the session and triggers exact cleanup. Verify the command's postcondition before retrying an uncertain operation.
- The broker never preserves implicit shell state between commands. Pass cwd and argv explicitly; do not rely on environment changes, aliases, virtual environments, or shell variables from a previous command.
- The token is equivalent to terminal authority for the Jupyter server. Keep its file owner-only; never place it in a URL, command argument, environment variable, log, chat response, or repository.
- If the token is missing, revoked, expired, or the server is stopped, use the lifecycle/recovery flow instead of typing commands through the visible VS Code terminal.
