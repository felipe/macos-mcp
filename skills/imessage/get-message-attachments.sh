#!/bin/bash

# Get and process attachments from a message
# Usage: ./get-message-attachments.sh <message_rowid>

if [ -z "$1" ]; then
    echo "Usage: $0 <message_rowid>"
    exit 1
fi

MESSAGE_ROWID="$1"
DB_PATH="$HOME/Library/Messages/chat.db"
TMP_DIR="${TMP_DIR:-$HOME/tmp}"
MAX_SIZE="${MAX_SIZE:-1024}"  # Max dimension in pixels

mkdir -p "$TMP_DIR"

# Query for attachments
sqlite3 "$DB_PATH" "
SELECT
    a.ROWID,
    a.filename,
    a.mime_type,
    a.transfer_name
FROM message m
JOIN message_attachment_join maj ON m.ROWID = maj.message_id
JOIN attachment a ON maj.attachment_id = a.ROWID
WHERE m.ROWID = $MESSAGE_ROWID;
" | while IFS='|' read -r attachment_id filename mime_type transfer_name; do
    # Expand tilde in filename
    filename="${filename/#\~/$HOME}"

    if [ ! -f "$filename" ]; then
        echo "ERROR: File not found: $filename" >&2
        continue
    fi

    # Generate output filename
    output_file="$TMP_DIR/attachment_${MESSAGE_ROWID}_${attachment_id}.jpg"

    # Check if it's an image
    if [[ "$mime_type" == image/* ]]; then
        # Convert and downscale image
        if [[ "$mime_type" == "image/heic" ]] || [[ "$filename" == *.HEIC ]] || [[ "$filename" == *.heic ]]; then
            # Convert HEIC to JPEG and resize in one step
            sips -s format jpeg -Z "$MAX_SIZE" "$filename" --out "$output_file" >/dev/null 2>&1
        else
            # For other image formats, just resize
            sips -Z "$MAX_SIZE" "$filename" --out "$output_file" >/dev/null 2>&1
        fi

        if [ $? -eq 0 ]; then
            # Get dimensions
            dimensions=$(sips -g pixelWidth -g pixelHeight "$output_file" 2>/dev/null | grep -E "pixelWidth|pixelHeight" | awk '{print $2}' | paste -sd 'x' -)
            file_size=$(ls -lh "$output_file" | awk '{print $5}')

            echo "IMAGE|$output_file|$mime_type|$transfer_name|$dimensions|$file_size"
        else
            echo "ERROR: Failed to convert $filename" >&2
        fi
    else
        # For non-image files, just report the original path
        file_size=$(ls -lh "$filename" | awk '{print $5}')
        echo "FILE|$filename|$mime_type|$transfer_name||$file_size"
    fi
done
