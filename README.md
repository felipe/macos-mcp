# macos-mcp

Unified macOS system services for AI tools. Single binary, single Full Disk Access grant. Also works as a Claude Code plugin.

## Install

### Claude Code Plugin

```bash
/plugin marketplace add felipe/macos-mcp
/plugin install macos@macos-mcp
```

### Standalone

Pre-built universal binary (arm64 + x86_64) ships in the repo. Or build from source:

```bash
make  # Requires Xcode Command Line Tools
```

Grant Full Disk Access to the `macos-mcp` binary in System Settings > Privacy & Security > Full Disk Access.

## Usage

```bash
# iMessage
macos-mcp messages check --phone 4155551234 --since 60
macos-mcp messages read --phone 4155551234 --limit 10
macos-mcp messages list-conversations --limit 20
macos-mcp messages attachments --rowid 12345 --convert-heic
macos-mcp send message 4155551234 "Hello!"
macos-mcp send file 4155551234 /path/to/image.png
macos-mcp send chat "chat123456" "Hello group!"
macos-mcp typing 4155551234 start

# Calendar
macos-mcp calendar list
macos-mcp calendar events --from 2026-03-23 --to 2026-03-24
macos-mcp calendar upcoming --hours 24
macos-mcp calendar search "meeting" --days 30
macos-mcp calendar create --cal CAL_ID --title "Meeting" --start 2026-03-24T14:00:00Z --end 2026-03-24T15:00:00Z
macos-mcp calendar update --id EVENT_ID --title "New title"
macos-mcp calendar delete --id EVENT_ID

# iCloud file sync (for launchd agents)
macos-mcp icloud sync --source "My Vault" --cache ~/.local/share/myapp/cache --files "file1.md,file2.yml"
macos-mcp icloud sync --source "My Vault" --cache /tmp/cache --files "data.yml" -- /path/to/script.sh

# FDA process wrapper (for launchd agents)
macos-mcp launch /path/to/script.sh
```

All output is JSON to stdout. Errors are JSON to stderr.

## Autonomous Daemon

Background daemon that monitors incoming iMessages and spawns Claude Code agent sessions to respond.

```bash
# Configure via environment variables
export IMESSAGE_CONTACT_PHONE="4155551234"
export IMESSAGE_CONTACT_NAME="John Doe"

# Optional: agent persona (SoulSpec convention)
export MACOS_MCP_AGENT_PATH="/path/to/agent/spec"

# Start
skills/imessage/daemon/imessage-auto-reply-daemon.sh
```

Or manage via launchd — see [daemon/README.md](skills/imessage/daemon/README.md).

## Two-Account Model

Designed to run on the **agent's macOS account** — a separate user with its own Apple ID.

- **iMessage**: The agent has its own phone number. You text the agent like a contact.
- **Calendar**: The agent has its own iCloud calendar, shared with the user. The user shares their calendar with the agent (read-only).

## Requirements

- macOS 13+ (Ventura)
- Messages app signed in to iMessage
- Full Disk Access for the `macos-mcp` binary
- Accessibility permission for Terminal (typing indicator)
- Calendar access permission (TCC prompt on first run)

## Project Structure

```
macos-mcp              # Pre-built universal binary
Sources/               # Swift source files
  main.swift           # CLI router
  Shared.swift         # JSON output, date parsing, helpers
  Launch.swift         # FDA process wrapper
  ICloud.swift         # iCloud Drive file sync
  Calendar.swift       # EventKit operations
  Messages.swift       # SQLite message queries
  Attachments.swift    # Attachment processing + HEIC conversion
  Send.swift           # AppleScript wrappers (send, typing)
Makefile               # Build universal binary
.claude-plugin/        # Plugin manifests
commands/              # Slash commands (/imessage-daemon)
skills/
  imessage/
    daemon/            # Auto-reply daemon
    SKILL.md
  calendar/
    SKILL.md
```

## License

MIT
