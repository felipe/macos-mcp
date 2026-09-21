# MCP tool permissions

The server checks a host-controlled JSON policy before every MCP tool call, including tools that run inside the server process. It hides disabled tools from `tools/list` and returns `isError: true` if a client calls one directly.

Default location: `~/.config/macos-mcp/permissions.json`. Set `MACOS_MCP_PERMISSIONS_FILE` to use another path. The policy is reloaded for each request; restarting is unnecessary after editing it. Changes apply to new requests, not operations already in progress.

## Defaults

- Without a file at the default location, only the server's explicitly classified read-only tools are enabled. File writes, downloads, sends, drafts, moves, flag changes, typing indicators, and calendar mutations are blocked.
- Once a file exists, only tools with `"allow": true` are enabled. Omitted tools are denied, including reads.
- An invalid or unreadable policy denies all tools. An explicitly configured missing file also denies all tools. Deleting the default file restores the read-only defaults.
- Unknown tool names, unknown fields, invalid modes, and constraints on unsupported tools invalidate the policy. New tools are disabled until granted.

A [complete example](../examples/permissions.json) lists every current tool. It enables reads and disables mutations. Copy it into place and enable only the functions you want:

```sh
mkdir -p ~/.config/macos-mcp
cp examples/permissions.json ~/.config/macos-mcp/permissions.json
chmod 600 ~/.config/macos-mcp/permissions.json
```

For example, this permits mail search and reading, plus appending anchored sections under `Projects` in the existing `notes` path mapping:

```json
{
  "version": 1,
  "tools": {
    "mail_search": { "allow": true },
    "mail_read": { "allow": true },
    "scoped_write": {
      "allow": true,
      "path_names": ["notes"],
      "modes": ["append-section"],
      "paths": ["Projects"]
    }
  }
}
```

All other tools are denied by this example. `ALLOWED_PATHS_JSON` still defines where `notes` points; the policy narrows those existing roots rather than granting access to new directories.

## File constraints

| Field | Tools | Meaning |
| --- | --- | --- |
| `allow` | Every tool | Required boolean. `false` disables the tool. |
| `path_names` | `scoped_read`, `scoped_write` | Allowed names from `ALLOWED_PATHS_JSON`. |
| `modes` | `scoped_write` | Any subset of `upsert`, `append-section`, `supersede`. |
| `paths` | `scoped_read`, `scoped_write`, `vault_read`, `vault_write`, `vault_list` | Relative files or subtrees under the selected root. |

Omitting a constraint leaves the tool's existing limits in place. An empty constraint array grants no matching operations. `paths: ["."]` explicitly grants the entire existing root. Prefixes match path components, so `Projects` does not grant `Projects-private`. Existing symlinks are resolved even when the final file does not exist. A link escaping the permitted subtree is denied. `vault_search` supports only the per-tool switch; it cannot be narrowed with `paths`.

MCP writes cannot overwrite the active policy directly, through symlinks or hardlinks, or by replacing a parent directory. The same protection covers downloads and the scoped-write audit log plus its five rotation destinations. Requests that would modify the policy through auditing fail before writing the requested content.

## Scope and deployment

This policy applies to MCP `tools/call` and discovery. Local CLI commands, the inbound poller, other programs running as the same macOS user, and macOS TCC permissions remain separate. It is not an operating-system sandbox or a per-client policy. Existing iMessage recipient allowlists, vault boundaries, and scoped-file roots still apply in addition to this policy.

Installing this version changes the previous permissive behavior: existing MCP workflows that mutate data need explicit grants. Keep the policy outside directories writable by untrusted local programs. Deploy the new binary before relying on enforcement; copying the JSON file alone does not change an older server.

## Verification

```sh
make test-logic-docker
make test-build test-mail test-permissions
```

The permission smoke test starts a temporary server and verifies that denied calls leave files unchanged, approved append operations work, symlink escapes and policy rewrites fail, grants can be revoked live, and malformed or missing configuration denies calls. It never sends messages or invokes live application mutations.
