#!/usr/bin/env bash
set -euo pipefail

# List all visible calendars (own + shared)
# Output: JSON array of calendar objects

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_CALENDAR="${SCRIPT_DIR}/mac-calendar"

if [[ ! -x "${MAC_CALENDAR}" ]]; then
  echo "mac-calendar binary not found. Build it first:" >&2
  echo "  cd ${SCRIPT_DIR} && swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit" >&2
  exit 1
fi

"${MAC_CALENDAR}" list-calendars
