# iMessage-Claude-Bridge

Claude Code plugin for iMessage on macOS. Read, send, and auto-reply to iMessages using shell scripts, SQLite, and AppleScript.

## Install

```bash
/plugin marketplace add felipe/iMessage-Claude-Bridge
/plugin install imessage@imessage-claude-bridge
```

## Requirements

- macOS with Messages app signed in to iMessage
- Full Disk Access for Terminal (System Settings > Privacy & Security > Full Disk Access)
- Accessibility permission for Terminal (System Settings > Privacy & Security > Accessibility) — required for typing indicator
- `sqlite3`, `osascript`, `sips`, `bc` (all ship with macOS)

## What It Does

Two modes of operation:

### 1. Direct Skills

Individual iMessage commands available as Claude Code skills:

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

### 2. Autonomous Daemon

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

## How It Works

- **Reading messages**: SQLite queries against `~/Library/Messages/chat.db` (preferred), with AppleScript as a fallback
- **Sending messages**: AppleScript controlling Messages.app — tries iMessage first, falls back to SMS
- **Daemon mode**: Polls the database for new messages, spawns autonomous Claude Code sessions to handle them
- **Typing indicator**: Types into the Messages input field to show the native typing bubble while the agent works

## Project Structure

```
.claude-plugin/          # Plugin manifests
commands/                # Slash commands (/imessage-daemon)
skills/imessage/         # Shell scripts for iMessage operations
  daemon/                # Auto-reply daemon
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
