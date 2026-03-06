#!/bin/bash
#
# Trigger the native iMessage typing indicator
# Types a space into the Messages input field so the recipient sees "..."
#
# Usage:
#   ./typing-indicator.sh "+14155551234" start      # Begin typing indicator
#   ./typing-indicator.sh "+14155551234" stop       # Clear input field
#   ./typing-indicator.sh "+14155551234" keepalive  # Refresh (re-type to prevent timeout)
#
# Requires: Accessibility permissions for the calling process

CONTACT="$1"
ACTION="${2:-start}"

if [ -z "$CONTACT" ]; then
    echo "Usage: $0 <phone_or_email> start|stop|keepalive"
    exit 1
fi

case "$ACTION" in
    start)
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
        ;;

    stop)
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
        ;;

    keepalive)
        # Delete the space and re-type it to reset the typing timeout
        osascript <<EOF
tell application "System Events"
    tell process "Messages"
        key code 51
        delay 0.1
        keystroke " "
    end tell
end tell
EOF
        ;;

    *)
        echo "Unknown action: $ACTION (expected start|stop|keepalive)"
        exit 1
        ;;
esac
