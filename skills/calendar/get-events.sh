#!/usr/bin/env bash
set -euo pipefail

# Get calendar events for a date range
# Usage: get-events.sh --from 2026-03-23 --to 2026-03-24 [--cal CALENDAR_ID]
# Output: JSON array of event objects

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_CALENDAR="${SCRIPT_DIR}/mac-calendar"

if [[ ! -x "${MAC_CALENDAR}" ]]; then
  echo "mac-calendar binary not found. Build it first:" >&2
  echo "  cd ${SCRIPT_DIR} && swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit" >&2
  exit 1
fi

"${MAC_CALENDAR}" events "$@"
