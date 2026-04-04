# macos-mcp

macOS system services for AI tools. Single Swift binary — runs as a CLI, MCP server, or Claude Code plugin.

## Install

```bash
make           # Build (requires Xcode CLT)
make install   # Build + restart launchd service
```

Grant Full Disk Access to the `macos-mcp` binary in System Settings > Privacy & Security.

## MCP Server

Exposes iMessage, Calendar, file transfer, and Obsidian vault tools over the [MCP protocol](https://modelcontextprotocol.io) (Streamable HTTP transport). Remote AI agents connect to it to interact with macOS services.

```bash
# Run MCP server with iMessage poller
macos-mcp serve --port 9200 \
  --webhook-url "http://hermes.example.com:8644/webhooks/imessage" \
  --webhook-secret "your-hmac-secret" \
  --phone "5551234567"
```

When `--webhook-url` is provided, the server also polls `chat.db` for inbound messages and POSTs them to the webhook with HMAC-SHA256 signing. Typing indicators are managed automatically (start on message, keepalive every 25s, stop when reply detected).

### MCP Tools

**iMessage**: `send_imessage`, `send_to_chat`, `send_file`, `check_messages`, `read_conversation`, `list_conversations`, `max_rowid`, `typing_indicator`

**Calendar**: `calendar_list`, `calendar_upcoming`, `calendar_events`, `calendar_search`, `calendar_create`

**Files**: `download_file` (URL → local path), `send_file` (local path → iMessage)

**Obsidian Vault**: `vault_read`, `vault_write`, `vault_list`, `vault_search`

## CLI Usage

```bash
# iMessage
macos-mcp messages check --phone 5551234567 --after-rowid 4800
macos-mcp messages read --phone 5551234567 --limit 10
macos-mcp send message 5551234567 "Hello!"
macos-mcp send file 5551234567 /path/to/image.png

# Calendar
macos-mcp calendar upcoming --hours 24
macos-mcp calendar create --cal CAL_ID --title "Meeting" --start 2026-03-24T14:00:00Z --end 2026-03-24T15:00:00Z

# iCloud file sync
macos-mcp icloud sync --source "Obsidian Vault" --cache /tmp/cache --files "stack.md" -- ./script.sh

# FDA process wrapper
macos-mcp launch /path/to/script.sh
```

All output is JSON to stdout. Errors are JSON to stderr.

## Two-Account Model

Runs on the **agent's macOS account** — a separate user with its own Apple ID.

- **iMessage**: The agent has its own phone number. You text the agent like a contact.
- **Calendar**: The agent has its own iCloud calendar, shared with the user.

## Launchd Service

```bash
make install   # Build + restart
make restart   # Restart only
```

Plist: `~/Library/LaunchAgents/com.macos-mcp.serve.plist` — `KeepAlive: true`.

Logs (structured JSON): `~/.local/share/work-work/logs/launchd-macos-mcp-serve.err.log`

```bash
# Watch errors
tail -f ~/.local/share/work-work/logs/launchd-macos-mcp-serve.err.log | jq 'select(.level == "error")'

# Poller health
tail -f ~/.local/share/work-work/logs/launchd-macos-mcp-serve.err.log | jq 'select(.msg == "Heartbeat")'
```

## Requirements

- macOS 13+ (Ventura)
- Messages app signed in to iMessage
- Full Disk Access for the `macos-mcp` binary
- Binary signed with `macos-mcp-dev` certificate (ad-hoc breaks TCC)
- Accessibility permission for Terminal (typing indicator)
- Calendar access permission (TCC prompt on first run)

## Project Structure

```
Sources/
  main.swift           # CLI router
  Serve.swift          # MCP server + poller + typing + vault tools
  Shared.swift         # JSON output, process runner with timeouts
  Messages.swift       # SQLite message queries
  Send.swift           # AppleScript wrappers (send, typing)
  Calendar.swift       # EventKit operations
  Attachments.swift    # Attachment processing + HEIC conversion
  ICloud.swift         # iCloud Drive file sync
  Launch.swift         # FDA process wrapper
Makefile               # Build, install (build + restart), clean
skills/
  imessage/
    daemon/            # Legacy auto-reply daemon (replaced by serve mode)
```

## License

MIT
