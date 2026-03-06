#!/bin/bash

# List recent conversations
# Usage: ./list-conversations.sh [--limit N]

LIMIT=""

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

osascript <<EOF
tell application "Messages"
    set conversationList to {}
    set chatList to every chat

    repeat with aChat in chatList
        try
            set chatID to id of aChat
            set chatName to name of aChat
            set chatMessages to messages of aChat
            set messageCount to count of chatMessages

            if messageCount > 0 then
                set lastMsg to item -1 of chatMessages
                set lastDate to date received of lastMsg

                set end of conversationList to {chatName:chatName, chatID:chatID, msgCount:messageCount, lastDate:lastDate}
            end if
        end try
    end repeat

    -- Sort by last message date (most recent first)
    set sortedList to my sortByDate(conversationList)

    -- Apply limit if specified
    ${LIMIT:+set maxItems to ${LIMIT}}
    ${LIMIT:+set totalItems to count of sortedList}
    ${LIMIT:+if maxItems < totalItems then}
    ${LIMIT:+    set sortedList to items 1 thru maxItems of sortedList}
    ${LIMIT:+end if}

    set output to "Recent Conversations:" & linefeed & linefeed

    repeat with conv in sortedList
        set chatName to chatName of conv
        set msgCount to msgCount of conv
        set lastDate to lastDate of conv

        set output to output & chatName & linefeed
        set output to output & "  Messages: " & msgCount & linefeed
        set output to output & "  Last: " & (lastDate as string) & linefeed
        set output to output & "---" & linefeed
    end repeat

    return output
end tell

on sortByDate(theList)
    set theIndexList to {}
    set theSortedList to {}

    repeat (length of theList) times
        set theLowItem to missing value
        repeat with i from 1 to (length of theList)
            if i is not in theIndexList then
                set theItem to item i of theList
                if theLowItem is missing value then
                    set theLowItem to theItem
                    set theLowItemIndex to i
                else
                    if lastDate of theItem > lastDate of theLowItem then
                        set theLowItem to theItem
                        set theLowItemIndex to i
                    end if
                end if
            end if
        end repeat
        set end of theSortedList to theLowItem
        set end of theIndexList to theLowItemIndex
    end repeat

    return theSortedList
end sortByDate

EOF
