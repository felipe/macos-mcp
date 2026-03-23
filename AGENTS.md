# macos-mcp

MCP server exposing macOS system services to AI tools. Also works as a Claude Code plugin.

## The Rule

**Never report completion without verification.**

If you say it works, you must have tested it and seen it work.
If it fails, say so, show the error, and ask what to do.

## Two-Account Model

This runs on the **agent's macOS account**, not the user's personal account. The agent has its own Apple ID and its own system services.

- **iMessage**: The agent has its own phone number. Users text the agent, not themselves.
- **Calendar**: The agent has its own iCloud calendar. It shares that calendar with the user so events appear on the user's devices. The user shares their calendar with the agent (read-only).

The agent can be always-on on a separate machine without tying up the user's session.

## Services

### iMessage (`skills/imessage/`)
Read, send, and auto-reply to iMessages via shell scripts + SQLite + AppleScript.

- **Direct skills** — individual iMessage commands
- **Autonomous daemon** — background poller that spawns Claude Code agent sessions

### Calendar (`skills/calendar/`)
Read, create, and search macOS calendar events via EventKit.

- Swift CLI tool (`mac-calendar`) — build with `swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit`
- Bash wrapper scripts matching the iMessage pattern
- Read all visible calendars (own + shared), write only to own

## Requirements

- macOS 13+ (Ventura)
- Messages app signed in to iMessage
- Full Disk Access for Terminal
- Accessibility permission for Terminal (typing indicator)
- Calendar access permission (TCC prompt on first run of mac-calendar)
- `sqlite3`, `osascript`, `sips`, `bc` (all ship with macOS)

## Key Paths

- **Messages DB**: `~/Library/Messages/chat.db`
- **Daemon logs**: `~/tmp/imessage/`
- **Env config**: `~/.claude-imessage.env`
- **Plugin manifest**: `.claude-plugin/plugin.json`

## Guardrails

- Never send messages without explicit user confirmation (daemon mode is the exception — it's opt-in)
- Never expose the Messages database path or contents outside the local machine
- Daemon: only one instance per contact at a time
- Calendar: never write to calendars the agent doesn't own
- Test all AppleScript commands with a known contact before automating
