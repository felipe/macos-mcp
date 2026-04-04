# macos-mcp

macOS system services binary for AI tools. Runs as a CLI, MCP server, or Claude Code plugin.

## The Rule

**Never report completion without verification.**

If you say it works, you must have tested it and seen it work.
If it fails, say so, show the error, and ask what to do.

## Architecture

Two modes of operation:

### CLI Mode
Direct command execution — used by local scripts, launchd agents, and the MCP server internally.

### MCP Server Mode (`macos-mcp serve`)
Runs an MCP server (Streamable HTTP) that exposes all tools to remote agents. Includes a built-in iMessage poller that watches chat.db and forwards inbound messages to a webhook.

**Current deployment**: Hermes Agent on K8s (kube-node) connects to the MCP server via Tailscale. Hermes handles the AI (GPT-5.4), sessions, and memory. The Mac host handles macOS-specific operations (iMessage, calendar, typing indicators, Obsidian vault writes).

```
[Phone] ←iMessage→ [Messages.app]
                        ↕ chat.db
              [macos-mcp serve] (Mac host, launchd)
                ├── poller: watches chat.db → POST to hermes webhook
                ├── MCP server: tools for send/read/calendar/vault
                └── typing: indicators with keepalive + auto-stop
                        ↕ Tailscale
              [Hermes Agent] (K8s pod)
                ├── GPT-5.4 via OpenAI Codex
                ├── Session persistence per contact
                ├── Obsidian vault (Obsidian Vault) mounted at /vault (ro)
                └── Webhook platform for inbound messages
```

## Two-Account Model

This runs on the **agent's macOS account**, not the user's personal account. The agent has its own Apple ID and its own system services.

- **iMessage**: The agent has its own phone number. Users text the agent, not themselves.
- **Calendar**: The agent has its own iCloud calendar, shared with the user.

## The Binary

Single universal binary handles all macOS system access. One Full Disk Access grant covers everything.

```
macos-mcp serve [--port 9200] [--host 0.0.0.0]   # MCP server + iMessage poller
  [--webhook-url URL] [--webhook-secret SECRET]    # Hermes webhook for inbound
  [--phone PHONE] [--poll-interval 1] [--debounce 3]
macos-mcp launch <command> [args...]               # FDA process wrapper
macos-mcp icloud sync --source DIR --cache DIR --files F1,F2 [-- cmd args...]
macos-mcp calendar list|events|upcoming|search|create|update|delete [args...]
macos-mcp messages check|read|list-conversations|attachments [args...]
macos-mcp send message|file|chat [args...]         # AppleScript via osascript
macos-mcp typing <contact> start|stop|keepalive    # Typing indicator
```

Build: `make` — Restart service after build: `make install`

## MCP Tools (exposed via `serve`)

### iMessage
- `send_imessage` — send text to a phone number
- `send_to_chat` — send to a group chat
- `send_file` — send image/file attachment
- `check_messages` — poll for new messages (by rowid)
- `read_conversation` — conversation history
- `list_conversations` — list recent chats
- `max_rowid` — current watermark for polling
- `typing_indicator` — start/stop/keepalive

### Calendar
- `calendar_list` — list calendars
- `calendar_upcoming` — next N hours
- `calendar_events` — date range query
- `calendar_search` — search by text
- `calendar_create` — create event

### Files
- `download_file` — download URL to Mac, returns local path
- `send_file` — send local file via iMessage

### Obsidian Vault (Obsidian Vault)
- `vault_read` — read a file (relative path)
- `vault_write` — write/update a file
- `vault_list` — list directory contents
- `vault_search` — search by filename or content

Vault root: `OBSIDIAN_VAULT_PATH` env var or `~/Library/Mobile Documents/com~apple~CloudDocs/Obsidian Vault`

## Hermes Integration

Hermes Agent runs on K8s with:
- MCP server config pointing at `http://<mac-tailscale-ip>:9200/mcp`
- Webhook platform on port 8644 with HMAC-signed `imessage` route
- `OBSIDIAN_VAULT_PATH=/vault` (hostPath mount, read-only)
- Session persistence patched via ConfigMap (stable key from `{from}` field)
- USER.md + MEMORY.md seeded in `/opt/data/`

### Key hermes config paths (inside pod)
- `/opt/data/config.yaml` — model, toolsets, MCP servers
- `/opt/data/USER.md` — user profile (seeded from Obsidian Vault)
- `/opt/data/MEMORY.md` — memory index
- `/vault/` — Obsidian Vault (Obsidian vault, read-only mount)

## Logging

`macos-mcp serve` emits structured JSON logs to stderr:

```json
{"ts":"...","level":"info","component":"poller","msg":"New message","rowid":4866,"thread":"+1..."}
{"ts":"...","level":"error","component":"mcp","msg":"Tool failed","tool":"send_imessage","exit_code":1,"error":"..."}
{"ts":"...","level":"info","component":"poller","msg":"Heartbeat","watermark":4866,"pending":0}
```

Components: `server`, `mcp`, `poller`, `typing`, `webhook`, `vault`

Filter errors: `tail -f <log> | jq 'select(.level == "error")'`

Log location: `~/.local/share/work-work/logs/launchd-macos-mcp-serve.err.log`

## Launchd Service

```
~/Library/LaunchAgents/com.macos-mcp.serve.plist
```

Managed via: `make install` (build + restart) or `make restart`

`KeepAlive: true` — auto-restarts on crash.

## Requirements

- macOS 13+ (Ventura)
- Messages app signed in to iMessage
- Full Disk Access for the `macos-mcp` binary
- Binary must be signed with `macos-mcp-dev` certificate (ad-hoc breaks TCC)
- Accessibility permission for Terminal (typing indicator)
- Calendar access permission (TCC prompt on first run)

## Key Paths

- **Binary**: `./macos-mcp` (build with `make`)
- **Sources**: `Sources/*.swift`
- **Messages DB**: `~/Library/Messages/chat.db`
- **Service logs**: `~/.local/share/work-work/logs/launchd-macos-mcp-serve.err.log`
- **Watermark**: `~/tmp/imessage/watermark`
- **Downloads**: `~/tmp/imessage/downloads/`
- **Launchd plist**: `~/Library/LaunchAgents/com.macos-mcp.serve.plist`

## Guardrails

- Never send messages without explicit user confirmation (serve mode is the exception — it's opt-in via webhook)
- Never expose the Messages database path or contents outside the local machine
- Typing indicators have 10s subprocess timeouts — can't block the poller
- Calendar: never write to calendars the agent doesn't own
- All CLI output is JSON to stdout, errors as JSON to stderr
- Serve mode logs structured JSON to stderr
