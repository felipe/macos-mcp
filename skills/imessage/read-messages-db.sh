#!/bin/bash

# Read recent messages from Messages SQLite database
# Usage: ./read-messages-db.sh [phone_number] [--limit N]

DB_PATH="$HOME/Library/Messages/chat.db"
PHONE_NUMBER=""
LIMIT="10"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        *)
            if [ -z "$PHONE_NUMBER" ]; then
                PHONE_NUMBER="$1"
            fi
            shift
            ;;
    esac
done

# Convert Apple Core Data timestamp (nanoseconds since 2001-01-01) to readable date
# Apple epoch is 978307200 seconds after Unix epoch (2001-01-01 00:00:00 UTC)
convert_date() {
    local nano_timestamp=$1
    local unix_timestamp=$(echo "scale=0; $nano_timestamp / 1000000000 + 978307200" | bc)
    date -r "$unix_timestamp" "+%Y-%m-%d %H:%M:%S"
}

if [ -n "$PHONE_NUMBER" ]; then
    # Get messages for specific phone number
    sqlite3 "$DB_PATH" <<SQL
SELECT
    m.ROWID,
    COALESCE(m.text, '') as text,
    m.is_from_me,
    m.date,
    h.id as handle_id,
    COALESCE(hex(m.attributedBody), '') as attributed_body_hex
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
JOIN chat c ON cmj.chat_id = c.ROWID
JOIN handle h ON c.ROWID IN (
    SELECT chat_id FROM chat_handle_join WHERE handle_id = h.ROWID
)
WHERE h.id LIKE '%$PHONE_NUMBER%'
ORDER BY m.date DESC
LIMIT $LIMIT;
SQL
else
    # Get all recent messages
    sqlite3 "$DB_PATH" <<SQL
SELECT
    ROWID,
    COALESCE(text, '') as text,
    is_from_me,
    date,
    '' as handle_id,
    COALESCE(hex(attributedBody), '') as attributed_body_hex
FROM message
ORDER BY date DESC
LIMIT $LIMIT;
SQL
fi | while IFS='|' read -r rowid text is_from_me date handle_id attributed_body_hex; do
    # If text is empty and we have attributedBody, try to extract text from it
    if [ -z "$text" ] && [ -n "$attributed_body_hex" ]; then
        # Convert hex to binary and extract readable strings
        # AttributedBody contains NSAttributedString - extract printable text
        text=$(echo "$attributed_body_hex" | xxd -r -p | strings -n 4 | grep -v "^NS" | grep -v "streamtyped" | grep -v "^Apple" | head -1 || echo "[no text]")

        # Clean up artifacts from NSAttributedString serialization
        text=$(echo "$text" | sed -E 's/^[A-Z]([A-Z])/\1/' | sed 's/\\!/!/g' | sed 's/\\?/?/g' | sed 's/^[+*]//')
    fi

    if [ -z "$text" ]; then
        text="[no text]"
    fi

    # Convert date
    readable_date=$(convert_date "$date")

    # Determine direction
    if [ "$is_from_me" = "1" ]; then
        direction="[OUT]"
    else
        direction="[IN]"
    fi

    echo "[$readable_date] $direction $text"
done
