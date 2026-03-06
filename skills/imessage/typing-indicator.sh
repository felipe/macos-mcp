#!/bin/bash
#
# Trigger the native iMessage typing indicator
# Types a space into the Messages input field so the recipient sees "..."
#
# Usage:
#   ./typing-indicator.sh "+14155551234" start   # Begin typing indicator
#   ./typing-indicator.sh "+14155551234" stop    # Clear input field
#
# Requires: Accessibility permissions for the calling process

CONTACT="$1"
ACTION="${2:-start}"

if [ -z "$CONTACT" ]; then
    echo "Usage: $0 <phone_or_email> start|stop"
    exit 1
fi

if [ "$ACTION" = "start" ]; then
    # Open the conversation and type a space to trigger typing indicator
    osascript <<EOF
open location "imessage://" & "$CONTACT"
delay 0.5
tell application "System Events"
    tell process "Messages"
        keystroke " "
    end tell
end tell
EOF

elif [ "$ACTION" = "stop" ]; then
    # Select all text in the input field and delete it
    osascript <<EOF
tell application "System Events"
    tell process "Messages"
        keystroke "a" using command down
        delay 0.1
        key code 51
    end tell
end tell
EOF
fi
