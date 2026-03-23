#!/usr/bin/env bash
set -euo pipefail

# Search calendar events by title, notes, or location
# Usage: search-events.sh "query" [--days 30] [--cal CALENDAR_ID]
# Output: JSON array of matching event objects

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_CALENDAR="${SCRIPT_DIR}/mac-calendar"

if [[ ! -x "${MAC_CALENDAR}" ]]; then
  printf '{"error":"missing_binary","message":"mac-calendar not found","build":"cd %s && swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit"}\n' "${SCRIPT_DIR}" >&2
  exit 1
fi

"${MAC_CALENDAR}" search "$@"
