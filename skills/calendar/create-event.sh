#!/usr/bin/env bash
set -euo pipefail

# Create a calendar event
# Usage: create-event.sh --cal CALENDAR_ID --title "Meeting" --start 2026-03-24T14:00:00Z --end 2026-03-24T15:00:00Z [--notes "..."] [--location "..."] [--all-day]
# Output: JSON with created event ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_CALENDAR="${SCRIPT_DIR}/mac-calendar"

if [[ ! -x "${MAC_CALENDAR}" ]]; then
  printf '{"error":"missing_binary","message":"mac-calendar not found","build":"cd %s && swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit"}\n' "${SCRIPT_DIR}" >&2
  exit 1
fi

"${MAC_CALENDAR}" create "$@"
