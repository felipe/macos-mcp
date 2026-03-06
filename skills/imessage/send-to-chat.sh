#!/bin/bash

# Send a message to a specific chat by chat_identifier
# Usage: ./send-to-chat.sh "chat_identifier" "Message Text"
# Or: echo "Message Text" | ./send-to-chat.sh "chat_identifier"

if [ -z "$1" ]; then
    echo "Usage: $0 \"chat_identifier\" [\"Message Text\"]"
    echo "Or pipe message: echo \"text\" | $0 \"chat_identifier\""
    exit 1
fi

CHAT_ID="$1"
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
CHAT_ID_ESCAPED=$(echo "$CHAT_ID" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
MESSAGE_ESCAPED=$(echo "$MESSAGE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

osascript <<EOF
tell application "Messages"
    try
        set targetService to 1st account whose service type = iMessage
        set targetChat to a reference to text chat id "$CHAT_ID_ESCAPED" of targetService

        send "$MESSAGE_ESCAPED" to targetChat

        return "Message sent to chat: $CHAT_ID_ESCAPED"

    on error errMsg
        return "Error: Could not send message to chat. " & errMsg
    end try
end tell
EOF
