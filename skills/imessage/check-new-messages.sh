#!/bin/bash

# Check for unread messages via AppleScript
# Usage: ./check-new-messages.sh [--count]

COUNT_ONLY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            COUNT_ONLY="yes"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$COUNT_ONLY" = "yes" ]; then
osascript <<'EOF'
tell application "Messages"
    set totalUnread to 0

    repeat with aChat in (every chat)
        try
            set unreadCount to unread message count of aChat
            set totalUnread to totalUnread + unreadCount
        end try
    end repeat

    return "Total unread messages: " & totalUnread
end tell
EOF
else
osascript <<'EOF'
tell application "Messages"
    set totalUnread to 0
    set output to ""

    repeat with aChat in (every chat)
        try
            set unreadCount to unread message count of aChat

            if unreadCount > 0 then
                set chatName to name of aChat
                set chatMessages to messages of aChat
                if (count of chatMessages) > 0 then
                    set lastMsg to item -1 of chatMessages
                    set lastText to text of lastMsg
                    set lastDate to date received of lastMsg

                    -- Truncate long messages
                    if length of lastText > 100 then
                        set lastText to text 1 thru 100 of lastText & "..."
                    end if

                    set output to output & chatName & " (" & unreadCount & " unread)" & return
                    set output to output & "  Last: " & (lastDate as string) & return
                    set output to output & "  \"" & lastText & "\"" & return
                    set output to output & "---" & return

                    set totalUnread to totalUnread + unreadCount
                end if
            end if
        end try
    end repeat

    if totalUnread is 0 then
        return "No unread messages"
    end if

    return "Unread Messages (" & totalUnread & " total):" & return & return & output
end tell
EOF
fi
