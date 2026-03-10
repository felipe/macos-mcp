#!/bin/bash

# Send a file via iMessage
# Usage: ./send-file.sh <recipient> <file_path>
#
# NOTE: macOS Messages can only send files from within its own directory
# (~/Library/Messages/Attachments/). Files from other locations fail silently
# with error 25. This script stages files there before sending.

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <recipient> <file_path>"
    echo "Example: $0 '+1234567890' '/path/to/image.jpg'"
    exit 1
fi

RECIPIENT="$1"
FILE_PATH="$2"

# Verify file exists
if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found: $FILE_PATH"
    exit 1
fi

# Get absolute path
ABS_PATH=$(cd "$(dirname "$FILE_PATH")" && pwd)/$(basename "$FILE_PATH")

# Copy file into Messages' attachments directory so it can access it
# Messages sandboxes file access — files outside its directory fail with error 25
STAGING_DIR="$HOME/Library/Messages/Attachments/_outgoing"
mkdir -p "$STAGING_DIR"

# Use a unique filename to avoid collisions from concurrent sends or duplicate basenames
BASENAME="$(basename "$ABS_PATH")"
EXT=""
if [[ "$BASENAME" == *.* ]]; then
    EXT=".${BASENAME##*.}"
fi
TMPFILE="$(mktemp "$STAGING_DIR/staged-XXXXXXXX")"
STAGED_FILE="${TMPFILE}${EXT}"
# Rename mktemp's file to include the original extension (needed for preview behavior)
if [ -n "$EXT" ]; then
    mv "$TMPFILE" "$STAGED_FILE"
fi

# Copy file into staging; abort if copy fails
if ! cp "$ABS_PATH" "$STAGED_FILE"; then
    echo "Error: Failed to stage file for sending"
    rm -f "$STAGED_FILE" 2>/dev/null
    exit 1
fi

# Escape quotes and backslashes for AppleScript (same approach as send-message.sh)
RECIPIENT_ESCAPED=$(printf '%s' "$RECIPIENT" | sed 's/\\!/!/g' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
STAGED_FILE_ESCAPED=$(printf '%s' "$STAGED_FILE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

# Send file via AppleScript
osascript <<EOF
set fileToSend to POSIX file "$STAGED_FILE_ESCAPED"
tell application "Messages"
    set targetService to 1st account whose service type = iMessage
    set targetBuddy to participant "$RECIPIENT_ESCAPED" of targetService
    send fileToSend to targetBuddy
end tell
EOF

if [ $? -eq 0 ]; then
    echo "File sent successfully: $ABS_PATH"
else
    # Clean up staged file on failure
    rm -f "$STAGED_FILE" 2>/dev/null
    echo "Error: Failed to send file"
    exit 1
fi
