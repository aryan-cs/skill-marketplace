# Exact-window screenshots

The desktop or currently focused screen is not reliable evidence: another application or Chrome window may be in front. Capture the exact Chrome window for the configured ICRN VS Code workbench.

Run:

```sh
scripts/capture_icrn_window.sh /private/tmp/icrn-window.png
```

Then inspect the returned absolute PNG path with the local image-viewing tool.

The capture helper:

1. finds the unique Chrome Accessibility window whose top-level web area matches the configured ICRN origin, workbench service, user, and sandbox folder;
2. binds that Accessibility window to the matching layer-0 Core Graphics window using PID, bounds, and window identity;
3. invokes macOS `screencapture` for that window ID only; and
4. validates that a readable, nonempty PNG was produced.

It does not activate the window, change focus, capture the desktop, or crop a full-screen image. If more than one matching ICRN window exists, close the stale duplicate or use the launcher-owned window rather than guessing.

During sign-in recovery, retain the launcher-created window as the target. Do not infer the intended tab from whichever Chrome window is focused, and do not click Chrome toolbar controls that merely resemble page controls.

The normal launcher closes its exact window after readiness because the running server and background terminal no longer need Chrome. Capture an in-flight recovery window before readiness, or open a separately matching workbench window when the task specifically requires post-start visual evidence. Never keep the ordinary launcher window open merely for background command execution.
