#!/bin/bash

# Send a message to a contact
# Usage: ./send-message.sh "Contact Name or Phone Number" "Message Text"
# Or: echo "Message Text" | ./send-message.sh "Contact Name"

if [ -z "$1" ]; then
    echo "Usage: $0 \"Contact Name or Phone Number\" [\"Message Text\"]"
    echo "Or pipe message: echo \"text\" | $0 \"Contact Name\""
    exit 1
fi

CONTACT="$1"
MESSAGE="${2:-}"

# If no message provided as argument, read from stdin if available
if [ -z "$MESSAGE" ] && [ ! -t 0 ]; then
    MESSAGE=$(cat)
fi

if [ -z "$MESSAGE" ]; then
    echo "Error: No message text provided"
    exit 1
fi

# Escape quotes and backslashes for AppleScript
# Also remove any stray backslashes before exclamation marks (from bash history expansion)
CONTACT_ESCAPED=$(printf '%s' "$CONTACT" | sed 's/\\!/!/g' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
MESSAGE_ESCAPED=$(printf '%s' "$MESSAGE" | sed 's/\\!/!/g' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

osascript <<EOF
tell application "Messages"
    try
        set targetService to 1st account whose service type = iMessage
        set targetBuddy to participant "$CONTACT_ESCAPED" of targetService

        send "$MESSAGE_ESCAPED" to targetBuddy

        return "Message sent to: $CONTACT_ESCAPED"

    on error errMsg
        -- If iMessage fails, it might be an SMS contact
        try
            set targetService to 1st account whose service type = SMS
            set targetBuddy to participant "$CONTACT_ESCAPED" of targetService

            send "$MESSAGE_ESCAPED" to targetBuddy

            return "SMS sent to: $CONTACT_ESCAPED"

        on error errMsg2
            return "Error: Could not send message. " & errMsg2
        end try
    end try
end tell
EOF
