# Recovery

Own recovery through the user's original goal. Give concise progress updates, but do not stop at a screenshot or generic error when a safe next action is available.

## Common failures

### Server expired, stopped, is starting, or has the wrong configuration

Instances last up to 24 hours and can be restarted indefinitely. When the task needs one, run the packaged launcher, let it finish the configured sign-in/start flow, and retry the original background operation. Never run work after server attestation fails.

### Browser stalls on a known page

Capture the exact ICRN window, identify the current stage, and continue with the packaged controller. Common causes include a stale Accessibility element, Chrome autofill still settling, an account chooser, institutional MFA awaiting approval, or Session Options not yet applying the generated selection. Re-query the current page rather than reusing an old control.

### Several Microsoft accounts appear

Choose the unique semantic tile containing the exact institutional email from private configuration. Ignore all other accounts and generic fallbacks. If the configured account is absent, wait or report that precise state rather than selecting another identity.

### Start or sign-in remains visible

Let the controller retry the same exact enabled control with fresh state. A changed page or disabled/disappeared control means the prior action may be in progress; wait and reclassify before another press.

### Institutional MFA appears

Do not click, submit, or bypass MFA. Tell the user which approval is pending, keep the operation alive when practical, and resume automatically when the challenge disappears.

### Direct terminal fails

Use its sanitized error to distinguish server attestation, token, REST, WebSocket, broker transport, remote timeout, command exit, and cleanup failures. Check the scoped state with `scripts/icrn_project_terminal.sh --session-status`.

- `idle` is reusable.
- `closed` means the next command may create a fresh session.
- `outcome_uncertain` means do not replay the operation. Verify the requested postcondition first, then run `scripts/icrn_project_terminal.sh --session-close` to reconcile only the exact recorded terminal.
- `cleanup_unverified` means retain the exact record and retry cleanup after server/token access is restored. Never sweep unrelated terminals.

Recreate a terminal only after the previous exact terminal has been authoritatively deleted or absent. If the instance is not ready, repair readiness through the launcher and retry the original operation. Use `--one-shot` only before a broker command is accepted; never auto-fallback or replay after an accepted or uncertain request. Use visible terminal typing only as a last resort when direct Jupyter terminal access is unavailable and the task cannot wait.

If the private Jupyter token is invalid or revoked, use the authenticated configured Chrome profile to create a replacement through JupyterHub, write only the new token to the configured owner-only token file, and retry. Never expose the token in a browser URL, shell argument, environment variable, log, screenshot, repository, or chat. Continue browser authentication yourself and involve the user only for an actual user-only password or MFA action.

### Controller times out or its window closes

After it has proven the exact sign-in/workbench flow, the launcher closes only that bound window after verified readiness or on failure, and exits cleanly when that window is already closed. If launch provenance never becomes unique, it warns and leaves every unproven new window open for manual inspection. The remote server remains running after successful window cleanup. Confirm no controller still holds its lock before starting one replacement attempt. Never close unrelated Chrome windows.

## Completion

After recovery, finish the original request and verify its postcondition. Examples include exact file bytes and SHA-256, a zero exit status, a live PID plus log output, GPU-state evidence, or a fully loaded workbench screenshot.
