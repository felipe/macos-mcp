#!/bin/bash

# Send a file via iMessage
# Usage: ./send-file.sh <recipient> <file_path>

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

# Send file via AppleScript
osascript <<EOF
set fileToSend to POSIX file "$ABS_PATH"
tell application "Messages"
    set targetService to 1st account whose service type = iMessage
    set targetBuddy to participant "$RECIPIENT" of targetService
    send fileToSend to targetBuddy
end tell
EOF

if [ $? -eq 0 ]; then
    echo "File sent successfully: $ABS_PATH"
else
    echo "Error: Failed to send file"
    exit 1
fi
