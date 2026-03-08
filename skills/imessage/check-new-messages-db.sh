#!/bin/bash

# Check for recent messages from Messages SQLite database
# Usage: ./check-new-messages-db.sh [phone_number]

DB_PATH="$HOME/Library/Messages/chat.db"
PHONE_NUMBER="${1:-}"

# Convert Apple Core Data timestamp to Unix timestamp
convert_to_unix() {
    local nano_timestamp=$1
    echo "scale=0; $nano_timestamp / 1000000000 + 978307200" | bc
}

# Convert to readable date
convert_date() {
    local nano_timestamp=$1
    local unix_timestamp=$(convert_to_unix "$nano_timestamp")
    date -r "$unix_timestamp" "+%Y-%m-%d %H:%M:%S"
}

# Get messages from last hour (to avoid processing very old messages)
CURRENT_TIME=$(date +%s)
ONE_HOUR_AGO=$((CURRENT_TIME - 3600))
APPLE_ONE_HOUR_AGO=$(echo "($ONE_HOUR_AGO - 978307200) * 1000000000" | bc)

if [ -n "$PHONE_NUMBER" ]; then
    # Get recent messages from specific number (incoming only)
    QUERY="
    SELECT
        m.ROWID,
        COALESCE(m.text, '') as text,
        m.is_from_me,
        m.date,
        h.id as handle_id,
        c.chat_identifier,
        COALESCE(m.guid, '') as msg_guid,
        COALESCE(m.thread_originator_guid, '') as thread_originator_guid
    FROM message m
    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
    JOIN chat c ON cmj.chat_id = c.ROWID
    JOIN handle h ON c.ROWID IN (
        SELECT chat_id FROM chat_handle_join WHERE handle_id = h.ROWID
    )
    WHERE h.id LIKE '%$PHONE_NUMBER%'
        AND m.is_from_me = 0
        AND m.date > $APPLE_ONE_HOUR_AGO
    ORDER BY m.date DESC
    LIMIT 10;
    "
else
    # Get all recent incoming messages
    QUERY="
    SELECT
        ROWID,
        COALESCE(text, '') as text,
        is_from_me,
        date,
        '' as handle_id,
        '' as chat_identifier,
        COALESCE(guid, '') as msg_guid,
        COALESCE(thread_originator_guid, '') as thread_originator_guid
    FROM message
    WHERE is_from_me = 0
        AND date > $APPLE_ONE_HOUR_AGO
    ORDER BY date DESC
    LIMIT 10;
    "
fi

# Execute query and format output
sqlite3 "$DB_PATH" "$QUERY" | while IFS='|' read -r rowid text is_from_me date handle_id chat_identifier msg_guid thread_originator_guid; do
    readable_date=$(convert_date "$date")
    # Create a unique message ID for tracking
    message_id=$(echo -n "${rowid}_${date}_${text}" | md5)

    echo "MSG_ID: $message_id"
    echo "ROWID: $rowid"
    if [ -n "$msg_guid" ]; then
        echo "GUID: $msg_guid"
    fi
    echo "DATE: $readable_date"
    echo "TEXT: $text"
    if [ -n "$thread_originator_guid" ]; then
        echo "THREAD_REPLY_TO: $thread_originator_guid"
    fi
    if [ -n "$handle_id" ]; then
        echo "FROM: $handle_id"
    fi
    if [ -n "$chat_identifier" ]; then
        echo "CHAT: $chat_identifier"
    fi

    # Check for attachments on this message
    sqlite3 "$DB_PATH" "
    SELECT a.filename, a.mime_type, a.transfer_name
    FROM attachment a
    JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
    WHERE maj.message_id = $rowid;
    " | while IFS='|' read -r att_filename att_mime att_name; do
        att_filename="${att_filename/#\~/$HOME}"
        echo "ATTACHMENT: $att_filename|$att_mime|$att_name"
    done

    echo "---"
done
