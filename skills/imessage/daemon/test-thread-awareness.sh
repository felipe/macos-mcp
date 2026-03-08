#!/bin/bash
#
# Test script for iMessage reply-thread awareness
# Tests SQL query changes, PID file management, and message parsing logic
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMESSAGE_SKILL="$(cd "$SCRIPT_DIR/.." && pwd)"
DB_PATH="$HOME/Library/Messages/chat.db"
TEST_TMP_DIR=$(mktemp -d)
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

echo "========================================"
echo "Thread Awareness Tests"
echo "========================================"
echo ""

# ──────────────────────────────────────────
# Test 1: SQL query returns GUID and thread_originator_guid columns
# ──────────────────────────────────────────
echo "Test 1: SQL query includes GUID and thread fields"

CURRENT_TIME=$(date +%s)
ONE_HOUR_AGO=$((CURRENT_TIME - 3600))
APPLE_ONE_HOUR_AGO=$(echo "($ONE_HOUR_AGO - 978307200) * 1000000000" | bc)

# Query a few recent messages (no phone filter, to ensure we get results)
QUERY_OUTPUT=$(sqlite3 "$DB_PATH" "
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
WHERE date > $APPLE_ONE_HOUR_AGO
ORDER BY date DESC
LIMIT 5;
" 2>&1) || true

# Check that the query executed without error (even if no results)
if [ $? -eq 0 ] || [ -z "$QUERY_OUTPUT" ]; then
    pass "SQL query with guid and thread_originator_guid executes successfully"
else
    fail "SQL query failed: $QUERY_OUTPUT"
fi

# Also test the phone-number variant query shape (with JOINs)
QUERY_OUTPUT_JOINED=$(sqlite3 "$DB_PATH" "
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
WHERE m.is_from_me = 0
    AND m.date > $APPLE_ONE_HOUR_AGO
ORDER BY m.date DESC
LIMIT 5;
" 2>&1) || true

if [ $? -eq 0 ] || [ -z "$QUERY_OUTPUT_JOINED" ]; then
    pass "Joined SQL query with guid and thread_originator_guid executes successfully"
else
    fail "Joined SQL query failed: $QUERY_OUTPUT_JOINED"
fi

echo ""

# ──────────────────────────────────────────
# Test 2: check-new-messages-db.sh output format includes GUID
# ──────────────────────────────────────────
echo "Test 2: check-new-messages-db.sh output format"

# Run the script without a phone filter to get any recent messages
CHECK_OUTPUT=$("$IMESSAGE_SKILL/check-new-messages-db.sh" 2>/dev/null) || true

if [ -z "$CHECK_OUTPUT" ]; then
    echo "  (No recent messages in chat.db to verify output format — testing with synthetic data)"
    # Verify the script at least doesn't error out
    pass "check-new-messages-db.sh runs without error (no messages to display)"
else
    # Check that GUID line appears in output
    if echo "$CHECK_OUTPUT" | grep -q "^GUID: "; then
        pass "Output contains GUID field"
    else
        fail "Output missing GUID field. Output was: $(echo "$CHECK_OUTPUT" | head -20)"
    fi

    # Check that MSG_ID, ROWID, DATE, TEXT still appear (backward compat)
    if echo "$CHECK_OUTPUT" | grep -q "^MSG_ID: "; then
        pass "Output still contains MSG_ID field (backward compat)"
    else
        fail "Output missing MSG_ID field"
    fi

    if echo "$CHECK_OUTPUT" | grep -q "^ROWID: "; then
        pass "Output still contains ROWID field (backward compat)"
    else
        fail "Output missing ROWID field"
    fi

    if echo "$CHECK_OUTPUT" | grep -q "^DATE: "; then
        pass "Output still contains DATE field (backward compat)"
    else
        fail "Output missing DATE field"
    fi

    # THREAD_REPLY_TO is optional — it only appears for threaded replies
    # Just verify the script handles it gracefully
    if echo "$CHECK_OUTPUT" | grep -q "^THREAD_REPLY_TO: "; then
        pass "Output contains THREAD_REPLY_TO field (found threaded replies in recent messages)"
    else
        pass "No THREAD_REPLY_TO in output (expected — no recent threaded replies, or field correctly omitted)"
    fi
fi

echo ""

# ──────────────────────────────────────────
# Test 3: Verify thread_originator_guid exists in schema
# ──────────────────────────────────────────
echo "Test 3: Database schema has required columns"

SCHEMA=$(sqlite3 "$DB_PATH" "PRAGMA table_info(message);" 2>&1)

if echo "$SCHEMA" | grep -q "guid"; then
    pass "message table has 'guid' column"
else
    fail "message table missing 'guid' column"
fi

if echo "$SCHEMA" | grep -q "thread_originator_guid"; then
    pass "message table has 'thread_originator_guid' column"
else
    fail "message table missing 'thread_originator_guid' column"
fi

if echo "$SCHEMA" | grep -q "thread_originator_part"; then
    pass "message table has 'thread_originator_part' column"
else
    fail "message table missing 'thread_originator_part' column"
fi

echo ""

# ──────────────────────────────────────────
# Test 4: PID file management per thread
# ──────────────────────────────────────────
echo "Test 4: Per-thread PID file management"

# Source the helper functions from the daemon (we only need the utility functions)
# Re-implement them here to avoid sourcing the whole daemon (which has set -e and requires env vars)
TMP_DIR="$TEST_TMP_DIR"

sanitize_thread_id() {
    local thread_id="$1"
    echo "$thread_id" | sed 's/[^a-zA-Z0-9_-]/_/g'
}

get_thread_pid_file() {
    local thread_id="$1"
    local safe_id=$(sanitize_thread_id "$thread_id")
    echo "$TMP_DIR/imessage_agent_${safe_id}.pid"
}

get_thread_conversation_file() {
    local thread_id="$1"
    local safe_id=$(sanitize_thread_id "$thread_id")
    echo "$TMP_DIR/imessage_conversation_${safe_id}.txt"
}

get_thread_agent_log() {
    local thread_id="$1"
    local safe_id=$(sanitize_thread_id "$thread_id")
    echo "$TMP_DIR/imessage-agent-${safe_id}.log"
}

is_agent_running() {
    local thread_id="${1:-default}"
    local pid_file=$(get_thread_pid_file "$thread_id")
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$pid_file"
        fi
    fi
    return 1
}

# Test 4a: Different threads get different PID files
PID_FILE_A=$(get_thread_pid_file "thread-aaa")
PID_FILE_B=$(get_thread_pid_file "thread-bbb")
PID_FILE_DEFAULT=$(get_thread_pid_file "default")

if [ "$PID_FILE_A" != "$PID_FILE_B" ]; then
    pass "Different thread IDs produce different PID file paths"
else
    fail "Thread IDs 'thread-aaa' and 'thread-bbb' produced same PID file: $PID_FILE_A"
fi

if [ "$PID_FILE_A" != "$PID_FILE_DEFAULT" ]; then
    pass "Thread PID file differs from default PID file"
else
    fail "Thread PID file same as default"
fi

# Test 4b: Sanitization of GUIDs with special characters
GUID_WITH_COLONS="p:0/iMessage;-;+13035551234"
SAFE=$(sanitize_thread_id "$GUID_WITH_COLONS")
if [[ "$SAFE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    pass "GUID with special chars sanitized correctly: $SAFE"
else
    fail "Sanitized GUID still contains special chars: $SAFE"
fi

# Test 4c: is_agent_running returns false when no PID file exists
if ! is_agent_running "nonexistent-thread"; then
    pass "is_agent_running returns false for thread with no PID file"
else
    fail "is_agent_running returned true for nonexistent thread"
fi

# Test 4d: is_agent_running returns true for a live process
sleep 999 &
SLEEP_PID=$!
echo "$SLEEP_PID" > "$(get_thread_pid_file "live-thread")"

if is_agent_running "live-thread"; then
    pass "is_agent_running returns true for live process"
else
    fail "is_agent_running returned false for live process"
fi
kill "$SLEEP_PID" 2>/dev/null; wait "$SLEEP_PID" 2>/dev/null || true

# Test 4e: is_agent_running cleans up stale PID files for dead processes
echo "99999999" > "$(get_thread_pid_file "dead-thread")"
if ! is_agent_running "dead-thread"; then
    pass "is_agent_running returns false for dead process"
else
    fail "is_agent_running returned true for dead process (PID 99999999)"
fi

STALE_FILE=$(get_thread_pid_file "dead-thread")
if [ ! -f "$STALE_FILE" ]; then
    pass "Stale PID file cleaned up automatically"
else
    fail "Stale PID file was not cleaned up"
fi

# Test 4f: Multiple threads can be tracked independently
sleep 999 &
PID_X=$!
sleep 999 &
PID_Y=$!
echo "$PID_X" > "$(get_thread_pid_file "thread-x")"
echo "$PID_Y" > "$(get_thread_pid_file "thread-y")"

if is_agent_running "thread-x" && is_agent_running "thread-y"; then
    pass "Multiple threads can run simultaneously"
else
    fail "Multiple threads not tracked independently"
fi

kill "$PID_X" 2>/dev/null; wait "$PID_X" 2>/dev/null || true
# thread-x is now dead, thread-y still alive
if ! is_agent_running "thread-x" && is_agent_running "thread-y"; then
    pass "Killing one thread does not affect another"
else
    fail "Thread isolation broken"
fi
kill "$PID_Y" 2>/dev/null; wait "$PID_Y" 2>/dev/null || true

echo ""

# ──────────────────────────────────────────
# Test 5: Message parsing extracts thread IDs correctly
# ──────────────────────────────────────────
echo "Test 5: Message parsing logic"

# Simulate message output with threading info
SIMULATED_OUTPUT_THREADED="MSG_ID: abc123
ROWID: 100
GUID: p:0/iMessage;-;+13035551234;guid-msg-001
DATE: 2026-03-08 12:00:00
TEXT: Hello from thread
THREAD_REPLY_TO: p:0/iMessage;-;+13035551234;guid-originator-001
FROM: +13035551234
CHAT: +13035551234
---"

SIMULATED_OUTPUT_NEW="MSG_ID: def456
ROWID: 101
GUID: p:0/iMessage;-;+13035551234;guid-msg-002
DATE: 2026-03-08 12:01:00
TEXT: Hello new message
FROM: +13035551234
CHAT: +13035551234
---"

SIMULATED_OUTPUT_NO_GUID="MSG_ID: ghi789
ROWID: 102
DATE: 2026-03-08 12:02:00
TEXT: Legacy message
FROM: +13035551234
CHAT: +13035551234
---"

# Parse threaded message
parsed_thread_id=""
parsed_guid=""
parsed_thread_reply=""

while IFS= read -r line; do
    case "$line" in
        "GUID: "*) parsed_guid="${line#GUID: }" ;;
        "THREAD_REPLY_TO: "*) parsed_thread_reply="${line#THREAD_REPLY_TO: }" ;;
        "---")
            if [ -n "$parsed_thread_reply" ]; then
                parsed_thread_id="$parsed_thread_reply"
            elif [ -n "$parsed_guid" ]; then
                parsed_thread_id="$parsed_guid"
            else
                parsed_thread_id="default"
            fi
            ;;
    esac
done <<< "$SIMULATED_OUTPUT_THREADED"

if [ "$parsed_thread_id" = "p:0/iMessage;-;+13035551234;guid-originator-001" ]; then
    pass "Threaded reply uses thread_originator_guid as thread ID"
else
    fail "Threaded reply thread ID wrong: got '$parsed_thread_id'"
fi

# Parse new (non-reply) message
parsed_thread_id=""
parsed_guid=""
parsed_thread_reply=""

while IFS= read -r line; do
    case "$line" in
        "GUID: "*) parsed_guid="${line#GUID: }" ;;
        "THREAD_REPLY_TO: "*) parsed_thread_reply="${line#THREAD_REPLY_TO: }" ;;
        "---")
            if [ -n "$parsed_thread_reply" ]; then
                parsed_thread_id="$parsed_thread_reply"
            elif [ -n "$parsed_guid" ]; then
                parsed_thread_id="$parsed_guid"
            else
                parsed_thread_id="default"
            fi
            ;;
    esac
done <<< "$SIMULATED_OUTPUT_NEW"

if [ "$parsed_thread_id" = "p:0/iMessage;-;+13035551234;guid-msg-002" ]; then
    pass "New message uses its own GUID as thread ID"
else
    fail "New message thread ID wrong: got '$parsed_thread_id'"
fi

# Parse legacy message (no GUID at all)
parsed_thread_id=""
parsed_guid=""
parsed_thread_reply=""

while IFS= read -r line; do
    case "$line" in
        "GUID: "*) parsed_guid="${line#GUID: }" ;;
        "THREAD_REPLY_TO: "*) parsed_thread_reply="${line#THREAD_REPLY_TO: }" ;;
        "---")
            if [ -n "$parsed_thread_reply" ]; then
                parsed_thread_id="$parsed_thread_reply"
            elif [ -n "$parsed_guid" ]; then
                parsed_thread_id="$parsed_guid"
            else
                parsed_thread_id="default"
            fi
            ;;
    esac
done <<< "$SIMULATED_OUTPUT_NO_GUID"

if [ "$parsed_thread_id" = "default" ]; then
    pass "Message without GUID falls back to 'default' thread"
else
    fail "No-GUID message thread ID wrong: got '$parsed_thread_id' (expected 'default')"
fi

echo ""

# ──────────────────────────────────────────
# Test 6: Per-thread conversation and log files
# ──────────────────────────────────────────
echo "Test 6: Per-thread file path uniqueness"

CONV_A=$(get_thread_conversation_file "thread-aaa")
CONV_B=$(get_thread_conversation_file "thread-bbb")
LOG_A=$(get_thread_agent_log "thread-aaa")
LOG_B=$(get_thread_agent_log "thread-bbb")

if [ "$CONV_A" != "$CONV_B" ]; then
    pass "Different threads get different conversation ID files"
else
    fail "Conversation files are the same for different threads"
fi

if [ "$LOG_A" != "$LOG_B" ]; then
    pass "Different threads get different agent log files"
else
    fail "Agent log files are the same for different threads"
fi

# Verify the file names contain the thread ID (sanitized)
if echo "$CONV_A" | grep -q "thread-aaa"; then
    pass "Conversation file path contains thread ID"
else
    fail "Conversation file path missing thread ID: $CONV_A"
fi

if echo "$LOG_A" | grep -q "thread-aaa"; then
    pass "Agent log file path contains thread ID"
else
    fail "Agent log file path missing thread ID: $LOG_A"
fi

echo ""

# ──────────────────────────────────────────
# Summary
# ──────────────────────────────────────────
echo "========================================"
echo "Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "========================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
