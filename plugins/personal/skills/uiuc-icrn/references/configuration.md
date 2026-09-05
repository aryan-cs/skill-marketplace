# Private configuration

The public skill contains no account, service URL, home path, Chrome profile, allocation identifier, password, cookie, or token. Supply deployment-specific values through one private JSON file and store the Jupyter token in a separate owner-only file.

## Set up

1. Create the immediate configuration directory at `${XDG_CONFIG_HOME:-$HOME/.config}/uiuc-icrn` as a real, current-user-owned directory with mode `0700`.
2. Copy `config.example.json` there as `config.json`. Set `UIUC_ICRN_CONFIG` to an absolute path only when using another location; its immediate parent must satisfy the same ownership and mode checks.
3. Replace every angle-bracket placeholder. Do not paste a complete login permalink; provide structured origin, identity, browser, workspace, and target values so the launcher can generate it safely. Use Chrome's exact profile-directory form, such as `Default` or `Profile N`.
4. Put the Jupyter token alone in the file named by `credentials.jupyter_token_file`. Do not put the token value in JSON or an environment variable.
5. Set both files to mode `0600` and ensure they are regular, single-link files owned by the current user. Keep them outside source control.
6. Validate before launch:

```sh
python3 scripts/icrn_config.py validate
```

The loader rejects missing or extra keys, unfilled placeholders, insecure file ownership/mode, symlinks, malformed identities, non-HTTPS origins, origins containing credentials/query/fragment, non-absolute or non-normalized remote roots, unsafe target identifiers, and invalid authentication-domain entries.

The `shell-env` configuration operation is an internal launcher interface: the packaged wrappers capture it directly and do not display it. Do not invoke it interactively or record its output, because the generated values include private account, path, browser-profile, and launch information. It never contains the Jupyter token itself.

## Schema

Use `config.example.json` as the machine-readable template. Its structure is:

```json
{
  "schema_version": 1,
  "origin": "<https-origin>",
  "identity": {
    "jupyter_username": "<netid>",
    "microsoft_account": "<institutional-email>",
    "identity_provider_label": "<identity-provider-label>"
  },
  "browser": {
    "profile_directory": "<chrome-profile-directory>",
    "user_data_directory": "<chrome-user-data-directory>",
    "executable": "<chrome-executable>"
  },
  "workspace": {
    "remote_root": "<absolute-remote-sandbox>"
  },
  "target": {
    "workbench_service": "<service-key>",
    "hub_server_key": "<server-key-or-empty>",
    "profile": "<profile-key>",
    "image": "<image-key>",
    "resource": "<resource-key>",
    "environment_label": "<visible-environment-label>",
    "resource_label": "<visible-resource-label>",
    "remote_python": "<absolute-remote-python>"
  },
  "credentials": {
    "jupyter_token_file": "<private-token-file>"
  },
  "allowed_auth_domains": {
    "identity_provider": ["<exact-identity-provider-domain>"],
    "institution": ["<exact-institution-domain>"],
    "microsoft": ["<exact-microsoft-domain>"],
    "mfa": []
  }
}
```

Use exact semantic labels from the legitimate ICRN pages, not ordinal positions. Restrict each authentication role to the minimum exact hosts required by the institution's current sign-in flow; `mfa` may be empty when that flow has no separate MFA host. Revalidate intentionally whenever the service changes its host, provider label, environment key, resource key, or visible selection label.

## Where each value comes from

- `origin` is only the HTTPS scheme and host of the legitimate ICRN JupyterHub, with no path, query, fragment, or credentials.
- `identity` contains the user's Hub username, the exact institutional Microsoft account shown in Chrome, and the exact visible identity-provider choice.
- `browser.profile_directory` is the directory identifier shown for the intended profile by Chrome's version page (`Default` or `Profile N`), not the profile's display name. `browser.user_data_directory` is its parent Chrome data directory, and `browser.executable` is the absolute Chrome executable.
- `workspace.remote_root` is the absolute remote sandbox beneath which same-named project directories may be reused or created.
- `target` comes from the user's legitimate Session Options page: its service/server identifiers, submitted profile/image/resource values, exact visible environment/resource labels, and an absolute Python executable available in that image. An unnamed/default Hub server uses an empty `hub_server_key`.
- `allowed_auth_domains` contains exact lower-case hostnames observed for each role in that user's legitimate sign-in flow. Do not enter URL paths, wildcard patterns, parent-domain shortcuts, or unrelated hosts.
- `credentials.jupyter_token_file` is only an absolute path to the separate private token file; it is never the token value.

An agent configuring the skill should inspect the user's existing legitimate browser flow and local Chrome profile, write the private files outside the repository, validate them, and continue the original task. It must not guess missing deployment values or copy them into source code.

## Secret-handling rules

- Let the configured Chrome profile and its password manager own web credentials. The scripts interact only with page semantics and never extract a password or cookie.
- Pass the token only through the authenticated client's in-process authorization header. Never expose it in URLs, argv, process listings, stdout/stderr, screenshots, chat, or generated examples.
- Treat errors and diagnostics as public: report field names and failure categories, not private values.
- Never commit the real JSON file or token file. A public-tree scan should contain only angle-bracket placeholders and generic examples.
