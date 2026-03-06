#!/bin/bash

# Read messages from a conversation via AppleScript
# Usage: ./read-messages.sh "Contact Name" [--limit N]

if [ -z "$1" ]; then
    echo "Usage: $0 \"Contact Name or Phone Number\" [--limit N]"
    exit 1
fi

CONTACT="$1"
LIMIT="20"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Escape quotes and backslashes for AppleScript
CONTACT_ESCAPED=$(echo "$CONTACT" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

osascript <<EOF
tell application "Messages"
    try
        set targetChat to missing value

        -- Try to find chat by matching name or ID
        repeat with aChat in (every chat)
            try
                if name of aChat contains "$CONTACT_ESCAPED" or id of aChat contains "$CONTACT_ESCAPED" then
                    set targetChat to aChat
                    exit repeat
                end if
            end try
        end repeat

        if targetChat is missing value then
            return "Error: Could not find conversation with '$CONTACT_ESCAPED'"
        end if

        set chatMessages to messages of targetChat
        set msgCount to count of chatMessages

        if msgCount is 0 then
            return "No messages found in this conversation"
        end if

        -- Get the last N messages
        set startIndex to msgCount - ${LIMIT} + 1
        if startIndex < 1 then
            set startIndex to 1
        end if

        set output to "Messages with: " & (name of targetChat) & linefeed
        set output to output & "Total messages: " & msgCount & linefeed
        set output to output & "Showing last " & (msgCount - startIndex + 1) & " messages:" & linefeed & linefeed

        repeat with i from startIndex to msgCount
            set msg to item i of chatMessages
            set msgText to text of msg
            set msgDate to date sent of msg
            set msgDirection to direction of msg

            if msgDirection is incoming then
                set sender to "Them"
            else
                set sender to "You"
            end if

            set output to output & "[" & (msgDate as string) & "]" & linefeed
            set output to output & sender & ": " & msgText & linefeed & linefeed
        end repeat

        return output

    on error errMsg
        return "Error: " & errMsg
    end try
end tell
EOF
