---
name: uiuc-icrn
description: Operate a configured UIUC/NCSA Illinois Computes Research Notebooks environment end to end. Use when an agent needs to start, restart, sign in to, recover, inspect, or test an ICRN Visual Studio Code instance; run remote terminal commands or GPU jobs; create, read, or modify files in the matching remote project; or capture the exact ICRN Chrome window.
---

# UIUC ICRN

Own the requested task from instance startup through verified completion. Use the packaged scripts instead of rebuilding the browser or terminal integrations.

## Configure once

Require a private configuration and separate private Jupyter token file before connecting. If setup is incomplete, read [configuration.md](references/configuration.md), help the user finish it without exposing secrets, and resume the original task. Never replace a missing value with an embedded account, URL, path, browser profile, resource identifier, password, cookie, or token.

## Choose the shortest path

- For commands, files, processes, logs, or GPU work, run `scripts/icrn_project_terminal.sh`. It derives the current project, operates its same-named remote directory directly in the background, and reuses one private Jupyter terminal for sequential commands in the current agent task. It does not use SSH, the keyboard, pointer, visible screen, or browser remote debugging.
- Compute instances last at most 24 hours but can be restarted indefinitely. If the configured instance is stopped, expired, incorrectly configured, or unavailable, run `scripts/open_icrn.sh --run`, wait for the configured VS Code workbench, then resume the original operation. The launcher closes only the Chrome window it created; the server remains available to the background terminal.
- For visual inspection, run `scripts/capture_icrn_window.sh OUTPUT.png`, then inspect that image. It captures the matching Chrome window itself even when another window is frontmost; never substitute a desktop screenshot.

Read only the reference relevant to the work:

- Private setup and configuration: [configuration.md](references/configuration.md)
- Instance startup and authentication: [lifecycle.md](references/lifecycle.md)
- Commands, files, processes, and GPU jobs: [terminal.md](references/terminal.md)
- Exact-window screenshots: [screenshots.md](references/screenshots.md)
- Failures and recovery: [recovery.md](references/recovery.md)

## Operating behavior

1. Preserve the user's original task while making the environment ready.
2. Mirror the current local directory under the configured remote sandbox. Derive the local Git/workspace root's basename at runtime, use the same-named child of the configured sandbox, and preserve the current subdirectory relative to that root. Reuse that exact directory if it exists; otherwise create it once. Do not hard-code a project name, create duplicate variants, silently use the sandbox root, or switch projects.
3. Prefer the background terminal after the configured server is ready. Reuse its task-scoped session for related commands, then run `scripts/icrn_project_terminal.sh --session-close` in task-level cleanup before the final response. The broker also enforces idle and absolute lifetime limits.
4. Continue known browser stages automatically. When an account chooser appears, select only the exact institutional account from private configuration. Let Chrome own password autofill; never retrieve, inspect, or print the password. If institutional MFA requires a user action, explain the exact pending action, keep the workflow alive when practical, and resume automatically afterward.
5. If a stage fails, inspect the exact ICRN window and sanitized command error, repair or retry the failing stage, and continue the original task. Do not hand routine sign-in, startup, terminal, or recovery steps back to the user.
6. Verify the requested result independently: check file bytes, process state, exit status, job logs, GPU state, or the loaded VS Code workbench as appropriate.
7. In a `finally`-equivalent cleanup step, close the task-scoped terminal and report any cleanup uncertainty. Never expose the Jupyter token, browser cookies, password, private configuration, or unrelated Chrome content.

## Packaged entrypoints

```sh
# Validate private configuration before doing remote work.
python3 scripts/icrn_config.py validate

# Make the configured VS Code/GPU instance ready.
scripts/open_icrn.sh --run

# Run argv commands in one reusable task-scoped terminal.
scripts/icrn_project_terminal.sh -- pwd
scripts/icrn_project_terminal.sh -- nvidia-smi

# Always release the exact task-scoped terminal when the task is done.
scripts/icrn_project_terminal.sh --session-close

# Capture the exact configured ICRN Chrome window.
scripts/capture_icrn_window.sh /private/tmp/icrn-window.png
```

Resolve these paths relative to this skill directory, not the caller's working directory.
