# iMessage Skills

Tools for reading, sending, and monitoring iMessages on macOS.

## Requirements

- macOS with Messages app signed in to iMessage
- Full Disk Access permission for Terminal (System Preferences > Security & Privacy > Privacy > Full Disk Access)

## Tools

### Reading Messages

#### `read-messages-db.sh` (Preferred)
Read message history directly from the Messages SQLite database. More reliable and faster than AppleScript.

```bash
# Read recent messages from a specific contact
./read-messages-db.sh "4155551234" --limit 20

# Read all recent messages
./read-messages-db.sh --limit 10
```

#### `read-messages.sh` (AppleScript Fallback)
Read messages using AppleScript. Use when database access is unavailable.

```bash
./read-messages.sh "Contact Name" --limit 20
```

### Checking for New Messages

#### `check-new-messages-db.sh` (Preferred)
Check for recent incoming messages from the last hour via SQLite. Used by the iMessage auto-reply daemon.

```bash
# Check new messages from a specific number
./check-new-messages-db.sh "4155551234"

# Check all new incoming messages
./check-new-messages-db.sh
```

Output includes MSG_ID, ROWID, DATE, TEXT, FROM, and CHAT fields for each message.

#### `check-new-messages.sh` (AppleScript Fallback)
Check unread message counts and preview latest messages.

```bash
# Get unread count only
./check-new-messages.sh --count

# Get unread messages with previews
./check-new-messages.sh
```

### Sending Messages

#### `send-message.sh`
Send a message to an individual contact by name or phone number. Tries iMessage first, falls back to SMS.

```bash
# Direct argument
./send-message.sh "4155551234" "Hello!"

# Pipe message
echo "Hello!" | ./send-message.sh "4155551234"
```

#### `send-to-chat.sh`
Send a message to a group chat by chat identifier.

```bash
# Direct argument
./send-to-chat.sh "chat123456" "Hello group!"

# Pipe message
echo "Hello group!" | ./send-to-chat.sh "chat123456"
```

#### `send-file.sh`
Send a file attachment via iMessage.

```bash
./send-file.sh "+14155551234" "/path/to/image.jpg"
```

### Utilities

#### `list-conversations.sh`
List recent conversations with message counts and last activity.

```bash
./list-conversations.sh --limit 10
```

#### `get-message-attachments.sh`
Retrieve and process attachments from a specific message. Automatically converts HEIC to JPEG and resizes images.

```bash
./get-message-attachments.sh <message_rowid>
```

Output format: `IMAGE|path|mime_type|name|dimensions|size` or `FILE|path|mime_type|name||size`

### Daemon

#### `daemon/imessage-auto-reply-daemon.sh`
Background daemon that monitors incoming messages and spawns autonomous Claude Code agent sessions to respond.

```bash
# Start in background
source ~/.claude-imessage.env
nohup ./daemon/imessage-auto-reply-daemon.sh > /dev/null 2>&1 &

# Or use the slash command
/imessage-daemon start
```

See `daemon/README.md` for full documentation.
