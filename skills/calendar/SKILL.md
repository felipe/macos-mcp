# Calendar Skills

Read, create, and search macOS calendar events via EventKit.

## Requirements

- macOS 13+ (Ventura)
- Calendar access permission (granted on first run via TCC prompt)
- Build the Swift binary first:
  ```bash
  cd skills/calendar
  swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit
  ```

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

#### `list-calendars.sh`
List all calendars visible to this account (own + shared).

```bash
./list-calendars.sh
```

Output: JSON array of calendar objects with `id`, `title`, `type`, `source`, `allowsModify`.

#### `get-events.sh`
Get events in a date range.

```bash
./get-events.sh --from 2026-03-23 --to 2026-03-24
./get-events.sh --from 2026-03-23 --to 2026-03-30 --cal CALENDAR_ID
```

#### `upcoming.sh`
Get upcoming events (default: next 24 hours).

```bash
./upcoming.sh
./upcoming.sh --hours 48
./upcoming.sh --hours 8 --cal CALENDAR_ID
```

#### `search-events.sh`
Search events by title, notes, or location.

```bash
./search-events.sh "Abbott"
./search-events.sh "standup" --days 7
./search-events.sh "dentist" --days 90 --cal CALENDAR_ID
```

### Writing

#### `create-event.sh`
Create an event on a writable calendar.

```bash
./create-event.sh --cal CALENDAR_ID --title "Focus: InStock bugs" \
  --start 2026-03-24T09:00:00Z --end 2026-03-24T12:00:00Z \
  --notes "3 launch blockers remaining"

# All-day event
./create-event.sh --cal CALENDAR_ID --title "Faro launch target" \
  --start 2026-04-01 --end 2026-04-01 --all-day
```

### Updating / Deleting

Use `mac-calendar` directly:

```bash
./mac-calendar update --id EVENT_ID --title "New title" --start 2026-03-24T10:00:00Z
./mac-calendar delete --id EVENT_ID
```

## Output Format

All commands output JSON to stdout. Errors output JSON to stderr:

```json
{"error": "Calendar access denied. Grant permission in System Settings > Privacy > Calendars."}
```

## Binary

The `mac-calendar` binary is not committed to the repo — build it locally:

```bash
swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit
```

Add `mac-calendar` to `.gitignore` (it's a compiled binary).
