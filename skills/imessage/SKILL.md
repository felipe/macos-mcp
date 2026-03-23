# iMessage Skills

Tools for reading, sending, and monitoring iMessages on macOS via the `macos-mcp` binary.

## Requirements

- macOS with Messages app signed in to iMessage
- Full Disk Access for the `macos-mcp` binary
- Accessibility permission for Terminal (typing indicator)

## Tools

### Reading Messages

```bash
# Read recent messages from a specific contact
macos-mcp messages read --phone 4155551234 --limit 20

# Read all recent messages
macos-mcp messages read --limit 10
```

### Checking for New Messages

```bash
# Check new messages from a specific number (last 60 minutes)
macos-mcp messages check --phone 4155551234 --since 60

# Check all new incoming messages
macos-mcp messages check --since 60
```

Output is JSON with message objects containing rowid, guid, date, text, from, chat, thread_reply_to, and attachments.

### Sending Messages

```bash
# Send to individual contact (iMessage first, SMS fallback)
macos-mcp send message 4155551234 "Hello!"

# Pipe message
echo "Hello!" | macos-mcp send message 4155551234

# Send to group chat
macos-mcp send chat "chat123456" "Hello group!"

# Send file attachment
macos-mcp send file 4155551234 /path/to/image.jpg
```

### Typing Indicator

```bash
# Start typing indicator (opens conversation, types a space)
macos-mcp typing +14155551234 start

# Refresh to prevent ~60s timeout
macos-mcp typing +14155551234 keepalive

# Clear the input field
macos-mcp typing +14155551234 stop
```

Requires Accessibility permissions for the calling process.

### Utilities

```bash
# List recent conversations
macos-mcp messages list-conversations --limit 10

# Get attachments from a specific message (with HEIC→JPEG conversion)
macos-mcp messages attachments --rowid 12345 --convert-heic
```

### Daemon

Background daemon that monitors incoming messages and spawns autonomous Claude Code agent sessions to respond.

```bash
# Start in background
source ~/.claude-imessage.env
nohup skills/imessage/daemon/imessage-auto-reply-daemon.sh > /dev/null 2>&1 &

# Or use the slash command
/imessage-daemon start
```

See `daemon/README.md` for full documentation.
