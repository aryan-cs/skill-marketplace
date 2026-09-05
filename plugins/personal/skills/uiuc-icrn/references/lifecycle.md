# Instance lifecycle

## Source of truth

Read and validate the private configuration before launch. It defines the ICRN origin, institutional identity, exact Chrome profile, remote sandbox, workbench service, and selected environment/resource. Generate the login/spawn permalink from those structured values in memory; never copy it into the skill, configuration, logs, or chat. The launcher passes it only to the configured local Chrome executable as the URL for its newly created window.

## Start or reconnect

Each compute instance lasts up to 24 hours, but a replacement can be started whenever needed. Treat a stopped, expired, or unavailable server as a recoverable lifecycle event: run the launcher, wait for exact configured readiness, and resume the user's original command or job.

Run:

```sh
scripts/open_icrn.sh --run
```

The launcher compiles its controller on demand, opens one new window in the configured Chrome profile, and follows the generated permalink. Once that new window displays a uniquely matching configured sign-in or workbench flow, the controller binds to it. After it verifies a fully loaded VS Code workbench, it closes that exact launcher-owned window and exits; the server keeps running and background terminal access does not depend on Chrome remaining open. On a later failure or timeout it closes only that proven window. If it cannot distinguish its new window from another window created at the same time, it leaves the unproven windows open and reports cleanup uncertainty instead of guessing. If a person closes the proven window first, the controller exits cleanly.

The normal browser flow is:

1. Press the ICRN federated sign-in control.
2. Select the configured identity provider and continue.
3. If Microsoft offers several accounts, choose only the tile containing the exact configured institutional email. Never choose an account by ordinal position or a merely similar label.
4. On the password page, wait briefly for Chrome Password Manager to fill the field, then press the exact enabled sign-in control. Never read, copy, log, or export the password field.
5. Decline the optional persistent Microsoft sign-in.
6. If institutional MFA appears, do not click, submit, or bypass it. Tell the user which approval is pending, keep polling when practical, and continue automatically after approval.
7. On Session Options, require the configured environment and resource selected by the generated permalink, then press **Start**.
8. Wait for the real code-server workbench, not merely a matching URL or loading title. Require the configured folder-bearing path plus multiple workbench landmarks such as Explorer, Search, Source Control, Run and Debug, Extensions, Accounts, or Manage.
9. Close and verify disappearance of only the launcher-owned Chrome window. Do not close another Chrome tab or window.

The controller retries stale known controls using fresh page/accessibility state. It exits when its window closes and removes its single-run lock.

## Determine readiness

The background terminal client performs the authoritative server check before creating a task-scoped terminal and immediately afterward. It requires JupyterHub to report the configured ready server with the configured profile, image, and resource. Sequential commands reuse only that exact live terminal/WebSocket; a restart or protocol break poisons and closes it. If attestation fails, use the launcher and retry the original operation afterward.

Other sessions can coexist with the configured server. Do not stop a session merely because it appears in a sessions table. Stop or replace a server only when the task requires that state change.
