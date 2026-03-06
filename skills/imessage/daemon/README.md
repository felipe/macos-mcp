# iMessage Auto-Reply Daemon

Autonomous agent daemon that monitors iMessages and automatically responds using Claude Code.

## Overview

This daemon monitors incoming iMessages from a specific contact and automatically starts autonomous Claude Code agent sessions to handle requests. The agent can:

- Send multiple messages as it works
- Check for follow-up messages every 30-60 seconds
- Use all available Claude Code skills and tools
- Maintain conversation continuity across sessions
- Work on complex multi-step tasks autonomously

## Requirements

- macOS with Messages app signed in to iMessage
- Claude Code installed and in PATH
- Full Disk Access permission for Terminal
- Accessibility permission for Terminal (for typing indicator)
- Environment variables configured (see Configuration below)

## Quick Start

### 1. Configure

```bash
cp examples/.env.example ~/.claude-imessage.env
nano ~/.claude-imessage.env
```

Required variables:
- `IMESSAGE_CONTACT_PHONE` - Phone number to monitor (e.g., "4155551234")
- `IMESSAGE_CONTACT_NAME` - Display name (e.g., "John Doe")

### 2. Run

```bash
source ~/.claude-imessage.env

# Start daemon in background
nohup ./imessage-auto-reply-daemon.sh > /dev/null 2>&1 &

# Or run in foreground for testing
./imessage-auto-reply-daemon.sh
```

### 3. Monitor

```bash
# Check if running
ps aux | grep imessage-auto-reply-daemon

# View logs
tail -f ~/tmp/imessage/imessage-auto-reply.log
tail -f ~/tmp/imessage/imessage-agent.log

# Stop daemon
pkill -f imessage-auto-reply-daemon
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `IMESSAGE_CONTACT_PHONE` | **Yes** | - | Phone number to monitor (digits only) |
| `IMESSAGE_CONTACT_NAME` | **Yes** | - | Display name of contact |
| `IMESSAGE_CONTACT_EMAIL` | No | - | Email if they use iMessage email |
| `IMESSAGE_CHECK_INTERVAL` | No | 1 | Check interval in seconds |
| `IMESSAGE_TMP_DIR` | No | `~/tmp/imessage` | Directory for logs and state files |

## How It Works

### Message Detection

1. **Polls database**: Checks `~/Library/Messages/chat.db` every N seconds
2. **Filters by contact**: Only processes messages from configured phone/email
3. **Tracks processed**: Uses MD5 hash to avoid re-processing messages
4. **Detects both**: Handles 1-on-1 and group chat messages

### Agent Lifecycle

When a new message arrives:

1. **Check for running agent**: If already running, skip (agent will check for new messages)
2. **Show typing indicator**: Types into Messages input field so recipient sees the native typing bubble
3. **Load context**: Get last 10 messages for conversation history
4. **Resume or start**: Resume existing conversation ID or start new one
5. **Launch agent**: Start Claude Code with autonomous agent prompt
6. **Keep indicator alive**: Refreshes the typing indicator every 30s while the agent works
7. **Track PID**: Save process ID to prevent duplicate agents
8. **Clear indicator**: Stops the typing bubble when the agent finishes (success or failure)

### File Structure

```
~/tmp/imessage/
├── processed_imessages.log              # Processed message IDs
├── imessage_claude_conversation_id.txt  # Conversation ID for resume
├── imessage_agent.pid                   # Current agent PID
├── imessage-auto-reply.log              # Daemon activity log
└── imessage-agent.log                   # Agent session output
```

## Multiple Contacts

Run separate daemon instances for each contact:

```bash
IMESSAGE_CONTACT_PHONE="4155551234" IMESSAGE_CONTACT_NAME="Alice" \
  IMESSAGE_TMP_DIR="$HOME/tmp/imessage-alice" \
  nohup ./imessage-auto-reply-daemon.sh > /dev/null 2>&1 &

IMESSAGE_CONTACT_PHONE="4155559876" IMESSAGE_CONTACT_NAME="Bob" \
  IMESSAGE_TMP_DIR="$HOME/tmp/imessage-bob" \
  nohup ./imessage-auto-reply-daemon.sh > /dev/null 2>&1 &
```
