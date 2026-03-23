# Calendar Skills

Read, create, and search macOS calendar events via the `macos-mcp` binary (EventKit).

## Requirements

- macOS 13+ (Ventura)
- Calendar access permission (granted on first run via TCC prompt)

## Two-Account Model

This tool is designed for the **agent's macOS account**, not the user's personal account.

- The agent reads all visible calendars (its own + shared from user)
- The agent writes only to calendars it owns
- The user shares their calendar with the agent's Apple ID (read-only)
- The agent shares its calendar with the user's Apple ID (read-write from agent, read-only for user)

Events the agent creates appear on the user's Calendar app because the calendar is shared via iCloud.

### Setup

1. On the agent's Mac account, open Calendar.app
2. Create a calendar called "Mac" (or any name)
3. Share it with the user's Apple ID (via iCloud calendar sharing)
4. On the user's devices, accept the shared calendar invitation
5. On the user's account, share their primary calendar with the agent's Apple ID

## Tools

### Reading

```bash
# List all calendars visible to this account
macos-mcp calendar list

# Get events in a date range
macos-mcp calendar events --from 2026-03-23 --to 2026-03-24
macos-mcp calendar events --from 2026-03-23 --to 2026-03-30 --cal CALENDAR_ID

# Get upcoming events (default: next 24 hours)
macos-mcp calendar upcoming
macos-mcp calendar upcoming --hours 48
macos-mcp calendar upcoming --hours 8 --cal CALENDAR_ID

# Search events by title, notes, or location
macos-mcp calendar search "Abbott"
macos-mcp calendar search "standup" --days 7
macos-mcp calendar search "dentist" --days 90 --cal CALENDAR_ID
```

### Writing

```bash
# Create an event
macos-mcp calendar create --cal CALENDAR_ID --title "Focus: InStock bugs" \
  --start 2026-03-24T09:00:00Z --end 2026-03-24T12:00:00Z \
  --notes "3 launch blockers remaining"

# All-day event
macos-mcp calendar create --cal CALENDAR_ID --title "Faro launch target" \
  --start 2026-04-01 --end 2026-04-02 --all-day
```

### Updating / Deleting

```bash
macos-mcp calendar update --id EVENT_ID --title "New title" --start 2026-03-24T10:00:00Z
macos-mcp calendar delete --id EVENT_ID
```

## Output Format

All commands output JSON to stdout. Errors output JSON to stderr:

```json
{"error": "Calendar access denied. Grant permission in System Settings > Privacy > Calendars."}
```
