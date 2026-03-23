# macos-mcp

MCP server exposing macOS system services (iMessage, Calendar, more) to AI tools. Also works as a Claude Code plugin.

## Install (Claude Code Plugin)

```bash
/plugin marketplace add felipe/macos-mcp
/plugin install macos@macos-mcp
```

## Services

### iMessage

Read, send, and auto-reply to iMessages using shell scripts, SQLite, and AppleScript.

| Script | Description |
|--------|-------------|
| `read-messages-db.sh` | Read message history from SQLite database (preferred) |
| `read-messages.sh` | Read messages via AppleScript (fallback) |
| `check-new-messages-db.sh` | Check recent incoming messages via SQLite |
| `check-new-messages.sh` | Check unread message counts via AppleScript |
| `send-message.sh` | Send to a contact (iMessage first, SMS fallback) |
| `send-to-chat.sh` | Send to a group chat by chat identifier |
| `send-file.sh` | Send a file attachment |
| `list-conversations.sh` | List recent conversations |
| `get-message-attachments.sh` | Retrieve and process message attachments |
| `typing-indicator.sh` | Trigger native iMessage typing bubble via System Events |

#### Autonomous Daemon

Background daemon that monitors incoming iMessages from a specific contact and spawns Claude Code agent sessions to respond automatically.

```bash
# Configure
cp examples/.env.example ~/.claude-imessage.env
nano ~/.claude-imessage.env  # Set IMESSAGE_CONTACT_PHONE and IMESSAGE_CONTACT_NAME

# Manage via slash command
/imessage-daemon start
/imessage-daemon status
/imessage-daemon stop
```

See [daemon/README.md](skills/imessage/daemon/README.md) for full documentation.

### Calendar

Read, create, and search macOS calendar events via EventKit.

```bash
# Build the Swift CLI (one time)
cd skills/calendar
swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit
```

| Script | Description |
|--------|-------------|
| `list-calendars.sh` | List all visible calendars (own + shared) |
| `get-events.sh` | Get events in a date range |
| `upcoming.sh` | Get upcoming events (default: next 24 hours) |
| `create-event.sh` | Create an event on a writable calendar |
| `search-events.sh` | Search events by title, notes, or location |

Update and delete via `mac-calendar` directly:

```bash
./mac-calendar update --id EVENT_ID --title "New title"
./mac-calendar delete --id EVENT_ID
```

## Two-Account Model

This is designed to run on the **agent's macOS account** — a separate user with its own Apple ID. Not the user's personal account.

- **iMessage**: The agent has its own phone number. You text the agent like a contact.
- **Calendar**: The agent has its own iCloud calendar, shared with the user. Events the agent creates appear on the user's devices. The user shares their calendar with the agent (read-only) so the agent knows what's scheduled.

### Calendar Sharing Setup

1. On the agent's Mac account: create a calendar (e.g., "Mac") in Calendar.app
2. Right-click the calendar > Share > invite the user's Apple ID
3. On the user's devices: accept the shared calendar invitation
4. On the user's account: share their primary calendar with the agent's Apple ID (read-only)

## Requirements

- macOS 13+ (Ventura)
- Messages app signed in to iMessage
- Full Disk Access for Terminal (System Settings > Privacy & Security > Full Disk Access)
- Accessibility permission for Terminal (System Settings > Privacy & Security > Accessibility) — required for typing indicator
- Calendar access permission — granted on first run of `mac-calendar`
- `sqlite3`, `osascript`, `sips`, `bc` (all ship with macOS)

## How It Works

- **iMessage reading**: SQLite queries against `~/Library/Messages/chat.db` (preferred), with AppleScript as a fallback
- **iMessage sending**: AppleScript controlling Messages.app — tries iMessage first, falls back to SMS
- **Daemon mode**: Polls the database for new messages, spawns autonomous Claude Code sessions to handle them
- **Typing indicator**: Types into the Messages input field to show the native typing bubble while the agent works
- **Calendar**: Swift EventKit CLI tool called by bash scripts, outputs JSON

## Project Structure

```
.claude-plugin/          # Plugin manifests
commands/                # Slash commands (/imessage-daemon)
skills/
  imessage/              # Shell scripts for iMessage operations
    daemon/              # Auto-reply daemon + FDA launcher
  calendar/              # EventKit calendar operations
    mac-calendar.swift   # Swift CLI (build locally)
    *.sh                 # Bash wrapper scripts
examples/                # Example configuration files
tests/                   # Test suite
```

## Configuration

For daemon mode, create `~/.claude-imessage.env`:

```bash
export IMESSAGE_CONTACT_PHONE="4155551234"  # Required
export IMESSAGE_CONTACT_NAME="John Doe"     # Required
# export IMESSAGE_CONTACT_EMAIL="john@example.com"  # Optional
# export IMESSAGE_CHECK_INTERVAL="1"                 # Optional (seconds)
```

## License

MIT
