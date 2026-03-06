# Study: dvdsgl/claude-imessage

Reference: https://github.com/dvdsgl/claude-imessage

## Overview

A **Claude Code plugin** (not a standalone app) written entirely in shell scripts. It gives Claude Code the ability to read, send, and auto-reply to iMessages on macOS by combining direct SQLite queries against the Messages database with AppleScript automation for sending.

## Architecture

### Two Modes of Operation

1. **Direct Skill Mode** — Individual iMessage commands invoked manually from Claude Code (e.g., read messages, send a reply, list conversations).
2. **Autonomous Daemon Mode** — A background process polls for new messages and spawns Claude agent sessions to handle them automatically.

### How iMessage Integration Works

| Capability | Method | Details |
|---|---|---|
| **Read messages** | SQLite (preferred) | Queries `~/Library/Messages/chat.db` directly via `sqlite3` |
| **Read messages** | AppleScript (fallback) | Uses `osascript` to talk to Messages.app |
| **Send messages** | AppleScript | Controls Messages.app via `osascript`; falls back from iMessage to SMS |
| **Send files** | AppleScript | Converts path to absolute, sends via Messages.app |
| **Attachments** | SQLite + `sips` | Reads attachment paths from DB, converts HEIC→JPEG, resizes |
| **Timestamp conversion** | `bc` | Apple Core Data nanoseconds since 2001 → Unix epoch: `ns / 1000000000 + 978307200` |

### Database Schema (chat.db)

Four main tables:
- `message` — message text, timestamps, flags (is_from_me, is_read), attributedBody (hex-encoded rich text fallback)
- `chat` — chat identifiers, display names
- `handle` — phone numbers / email addresses
- `attachment` — file paths, MIME types, sizes

Joined via `chat_message_join` and `chat_handle_join` junction tables.

## File Structure

```
.claude-plugin/
  plugin.json                        — Plugin metadata (name: "imessage", v1.0.0)

commands/
  imessage-daemon.md                 — Docs for the /imessage-daemon slash command

examples/
  .env.example                       — Config template

skills/imessage/
  SKILL.md                           — Skill descriptions for Claude Code

  # Reading
  read-messages-db.sh                — Query chat.db for messages (preferred)
  read-messages.sh                   — AppleScript fallback for reading

  # Checking for new/unread
  check-new-messages-db.sh           — Query chat.db for recent unread (preferred)
  check-new-messages.sh              — AppleScript fallback for unread counts

  # Sending
  send-message.sh                    — Send to individual contact (name or phone)
  send-to-chat.sh                    — Send to group chat by chat identifier
  send-file.sh                       — Send file attachment

  # Utilities
  list-conversations.sh              — List recent conversations with metadata
  get-message-attachments.sh         — Retrieve and process attachments

  # Daemon
  daemon/
    imessage-auto-reply-daemon.sh    — Auto-reply loop
    README.md                        — Daemon documentation
```

## Configuration

Environment variables stored in `~/.claude-imessage.env`:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `IMESSAGE_CONTACT_PHONE` | Yes | — | Target contact phone number |
| `IMESSAGE_CONTACT_NAME` | Yes | — | Target contact display name |
| `IMESSAGE_CONTACT_EMAIL` | No | — | Contact email (optional) |
| `IMESSAGE_CHECK_INTERVAL` | No | `1` | Daemon polling interval (seconds) |
| `IMESSAGE_TMP_DIR` | No | `~/tmp/imessage/` | Logs and state files |

## Daemon Workflow

```
┌─────────────────────────────────────────────────────┐
│                   Daemon Loop                       │
│                                                     │
│  1. Poll chat.db for new messages (every N sec)     │
│  2. Compare against ~/tmp/imessage/processed_ids    │
│  3. If new message found:                           │
│     a. Fetch last 10 messages for context           │
│     b. Spawn autonomous Claude agent session        │
│     c. Agent has access to all iMessage skills      │
│     d. Agent reads context, composes reply,         │
│        sends via send-message.sh                    │
│     e. Save conversation ID for continuity          │
│  4. Wait for agent to finish, then loop             │
└─────────────────────────────────────────────────────┘
```

State files:
- `~/tmp/imessage/processed_ids` — Prevents re-processing the same message
- `~/tmp/imessage/conversation_id` — Maintains Claude conversation continuity across daemon restarts

## Dependencies

All native macOS tools — no external packages:
- `sqlite3` — Database queries
- `osascript` — AppleScript execution
- `sips` — Image format conversion (HEIC→JPEG)
- `bc` — Timestamp arithmetic
- `nohup` — Background daemon execution
- Claude Code CLI — Agent execution environment

## Key Design Decisions

1. **Shell-only implementation** — No build step, no dependencies, works on any macOS with Claude Code installed.
2. **Database-first reading** — SQLite queries are faster and more reliable than AppleScript for reading messages. AppleScript is only used as a fallback.
3. **AppleScript-only sending** — There's no way to send iMessages without going through Messages.app (no direct DB writes).
4. **Single-contact daemon** — The daemon is configured for one contact at a time. Multiple contacts would need multiple daemon instances or modification.
5. **Conversation continuity** — Saves Claude conversation IDs so the agent retains context across daemon restarts.

## What's Reusable vs. Needs Adaptation

### Directly Reusable
- SQLite query patterns for chat.db (schema is stable across macOS versions)
- AppleScript templates for sending messages
- Timestamp conversion formula
- Daemon polling architecture
- Processed-message deduplication pattern

### Needs Adaptation
- **Plugin structure** — If we want a different project structure than the Claude Code plugin format
- **Single-contact limitation** — The daemon only watches one contact; multi-contact support would need changes
- **No group chat daemon support** — Daemon only handles 1:1 conversations
- **No message filtering** — No way to ignore certain messages or route to different agents
- **Error handling** — Minimal error handling in the shell scripts; production use would need more robustness
- **Security** — The reference repo itself warns about "considerable security risks"; we'd want to add safeguards

## Security Notes (from reference repo)

The reference repo explicitly warns:
- Full access to the iMessage database
- Agents can send messages on the user's behalf autonomously
- "Exposes your computer to considerable security risks"
- Users assume all liability
