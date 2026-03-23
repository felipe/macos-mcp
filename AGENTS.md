# macos-mcp

Unified macOS system services binary for AI tools. Also works as a Claude Code plugin.

## The Rule

**Never report completion without verification.**

If you say it works, you must have tested it and seen it work.
If it fails, say so, show the error, and ask what to do.

## Two-Account Model

This runs on the **agent's macOS account**, not the user's personal account. The agent has its own Apple ID and its own system services.

- **iMessage**: The agent has its own phone number. Users text the agent, not themselves.
- **Calendar**: The agent has its own iCloud calendar. It shares that calendar with the user so events appear on the user's devices. The user shares their calendar with the agent (read-only).

The agent can be always-on on a separate machine without tying up the user's session.

## The Binary

Single universal binary (`macos-mcp`) handles all macOS system access. One Full Disk Access grant covers everything.

```
macos-mcp launch <command> [args...]              # FDA process wrapper
macos-mcp calendar list|events|upcoming|search|create|update|delete [args...]
macos-mcp messages check|read|list-conversations|attachments [args...]
macos-mcp send message|file|chat [args...]        # AppleScript via osascript
macos-mcp typing <contact> start|stop|keepalive   # Typing indicator
```

Build from source: `make` (requires Xcode CLT). Pre-built universal binary (arm64 + x86_64) ships in the repo.

## Services

### iMessage
Read, send, and auto-reply to iMessages. DB reads via SQLite C API, sending via AppleScript.

- `macos-mcp messages check --phone PHONE --since 60` — poll recent incoming
- `macos-mcp messages read --phone PHONE --limit 10` — conversation history
- `macos-mcp messages list-conversations --limit 20` — list chats
- `macos-mcp messages attachments --rowid N --convert-heic` — get attachments
- `macos-mcp send message PHONE "text"` — send iMessage (SMS fallback)
- `macos-mcp send file PHONE /path/to/file` — send attachment
- `macos-mcp send chat CHAT_ID "text"` — send to group chat
- `macos-mcp typing PHONE start|stop|keepalive` — typing indicator

### Calendar
Read, create, and search macOS calendar events via EventKit.

- `macos-mcp calendar list` — list all visible calendars
- `macos-mcp calendar events --from DATE --to DATE` — get events in range
- `macos-mcp calendar upcoming --hours 24` — upcoming events
- `macos-mcp calendar search QUERY --days 30` — search by title/notes/location
- `macos-mcp calendar create --cal ID --title TEXT --start DATE --end DATE`
- `macos-mcp calendar update --id ID --title TEXT`
- `macos-mcp calendar delete --id ID`

### Autonomous Daemon
Background poller that monitors iMessages and spawns Claude Code agent sessions.

- `skills/imessage/daemon/imessage-auto-reply-daemon.sh`
- Configurable via env vars: `IMESSAGE_CONTACT_PHONE`, `IMESSAGE_CONTACT_NAME`, etc.
- Optional agent persona: set `MACOS_MCP_AGENT_PATH` to a directory with SoulSpec files (SOUL.md, IDENTITY.md, USER.md)

## Requirements

- macOS 13+ (Ventura)
- Messages app signed in to iMessage
- Full Disk Access for the `macos-mcp` binary
- Accessibility permission for Terminal (typing indicator)
- Calendar access permission (TCC prompt on first run)

## Key Paths

- **Binary**: `./macos-mcp` (pre-built) or build with `make`
- **Sources**: `Sources/*.swift`
- **Messages DB**: `~/Library/Messages/chat.db`
- **Daemon logs**: `~/tmp/imessage/`
- **Plugin manifest**: `.claude-plugin/plugin.json`

## Guardrails

- Never send messages without explicit user confirmation (daemon mode is the exception — it's opt-in)
- Never expose the Messages database path or contents outside the local machine
- Daemon: only one instance per contact at a time
- Calendar: never write to calendars the agent doesn't own
- All output is JSON to stdout, errors as JSON to stderr
