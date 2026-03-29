#!/bin/bash
#
# iMessage Auto Reply Daemon - Autonomous Agent Version
# Monitors for new messages from a specific contact and starts autonomous Claude Code sessions
# The agent can send multiple messages, check for new messages, and work autonomously
#
# Configuration via environment variables:
# - IMESSAGE_CONTACT_EMAIL: Email address of the contact to monitor (optional)
# - IMESSAGE_CONTACT_PHONE: Phone number of the contact to monitor (required)
# - IMESSAGE_CONTACT_NAME: Display name of the contact (required)
# - IMESSAGE_CHECK_INTERVAL: How often to check for new messages in seconds (default: 1)
# - IMESSAGE_DEBOUNCE: Seconds to wait for rapid follow-up messages before launching agent (default: 3)
# - IMESSAGE_AGENT_TIMEOUT: Max seconds an agent can run before being killed (default: 600)
#

# Allow running from within a Claude Code session or standalone
unset CLAUDECODE 2>/dev/null || true

# Note: not using set -e — the daemon loop must survive transient errors
# from message checks, agent launches, and typing indicator calls.

# Clean exit on signals so launchd can restart us properly.
# With execv in Launch.swift, launchd owns this bash process directly.
trap 'exit 0' TERM INT HUP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MACOS_MCP="$PROJECT_ROOT/macos-mcp"
TMP_DIR="${IMESSAGE_TMP_DIR:-$HOME/tmp/imessage}"
PROCESSED_LOG="$TMP_DIR/processed_imessages.log"
LOG_FILE="$TMP_DIR/imessage-auto-reply.log"

# Configuration from environment variables
CONTACT_EMAIL="${IMESSAGE_CONTACT_EMAIL:-}"
CONTACT_PHONE="${IMESSAGE_CONTACT_PHONE:?Error: IMESSAGE_CONTACT_PHONE environment variable is required}"
CONTACT_NAME="${IMESSAGE_CONTACT_NAME:?Error: IMESSAGE_CONTACT_NAME environment variable is required}"
CHECK_INTERVAL="${IMESSAGE_CHECK_INTERVAL:-1}"
DEBOUNCE_SECONDS="${IMESSAGE_DEBOUNCE:-3}"
AGENT_TIMEOUT="${IMESSAGE_AGENT_TIMEOUT:-1800}"
AGENT_SPEC_PATH="${MACOS_MCP_AGENT_PATH:-}"
AGENT_RUNNER="$SCRIPT_DIR/agent-runner.py"
AGENT_PYTHON="$SCRIPT_DIR/.venv/bin/python3"

# Load environment variables if .env exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

# Verify binary exists
if [ ! -x "$MACOS_MCP" ]; then
    echo "Error: macos-mcp binary not found at $MACOS_MCP" >&2
    echo "Build it with: cd $PROJECT_ROOT && make" >&2
    exit 1
fi

# Create tmp directory if it doesn't exist
mkdir -p "$TMP_DIR"
mkdir -p "$TMP_DIR/active_tasks"

# Create log file if it doesn't exist
touch "$PROCESSED_LOG"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Agent spec loading moved to agent-runner.py

# Generate a unique ID for a message based on rowid, date, and text
generate_message_id() {
    local rowid="$1"
    local date="$2"
    local text="$3"
    echo -n "${rowid}_${date}_${text}" | md5
}

check_if_processed() {
    local message_id="$1"
    grep -q "^$message_id$" "$PROCESSED_LOG" 2>/dev/null
}

mark_as_processed() {
    local message_id="$1"
    echo "$message_id" >> "$PROCESSED_LOG"
}

is_group_chat() {
    local chat_identifier="$1"
    if [[ "$chat_identifier" =~ ^chat ]]; then
        return 0
    fi
    return 1
}

# Sanitize thread ID for use in filenames (replace non-alphanumeric chars with underscore)
sanitize_thread_id() {
    local thread_id="$1"
    echo "$thread_id" | sed 's/[^a-zA-Z0-9_-]/_/g'
}

# Get per-thread file paths
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
        # Verify PID is alive AND is actually a claude/python process (guards against PID reuse)
        if ps -p "$pid" -o comm= 2>/dev/null | grep -qE 'claude|python'; then
            return 0
        else
            # PID file is stale — process dead or PID reused by unrelated process
            rm -f "$pid_file"
        fi
    fi
    return 1
}

# Parse JSON messages output into tab-separated lines for bash processing
# Output: one line per message: msg_id\tguid\ttext\tthread_reply_to\tchat
parse_messages_json() {
    python3 -c '
import json, sys, hashlib
try:
    data = json.load(sys.stdin)
except:
    sys.exit(0)
for msg in data.get("messages", []):
    rowid = str(msg.get("rowid", ""))
    date = msg.get("date", "")
    text = msg.get("text", "").replace("\t", " ").replace("\n", " ")
    guid = msg.get("guid", "")
    thread = msg.get("thread_reply_to", "")
    chat = msg.get("chat", "")
    msg_id = hashlib.md5(f"{rowid}_{date}_{text}".encode()).hexdigest()
    print(f"{msg_id}\t{guid}\t{text}\t{thread}\t{chat}")
'
}

# Collect unprocessed messages from JSON check output
collect_messages() {
    local json_output="$1"
    echo "$json_output" | parse_messages_json | while IFS=$'\t' read -r msg_id guid text thread_reply_to chat; do
        [ -z "$msg_id" ] && continue
        [ -z "$text" ] && continue
        if ! check_if_processed "$msg_id"; then
            thread_id="default"
            msg_is_reply=0
            if [ -n "$thread_reply_to" ]; then
                thread_id="$thread_reply_to"
                msg_is_reply=1
            elif [ -n "$guid" ]; then
                thread_id="$guid"
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] New message (thread: $thread_id): \"$text\"" >> "$LOG_FILE"
            # Don't mark as processed here — only mark after successfully dispatching
            # to an agent, so messages aren't lost when an agent is already running.
            echo "${msg_id}|${thread_id}|${chat:-$CONTACT_PHONE}|${msg_is_reply}|${text}"
        fi
    done
}

start_autonomous_agent() {
    local initial_message="$1"
    local chat_identifier="$2"
    local thread_id="${3:-default}"

    local pid_file=$(get_thread_pid_file "$thread_id")
    local conversation_id_file=$(get_thread_conversation_file "$thread_id")
    local agent_log=$(get_thread_agent_log "$thread_id")

    local conv_type="1-on-1"
    if is_group_chat "$chat_identifier"; then
        conv_type="group chat"
    fi

    log "Starting autonomous agent session ($conv_type, thread: $thread_id)..."

    # Build conversation-id flag for resume
    local conv_id_flag=""
    if [ -f "$conversation_id_file" ]; then
        conv_id_flag="--conversation-id $(cat "$conversation_id_file")"
        log "  Resuming conversation (thread: $thread_id)"
    else
        log "  Starting new conversation for thread: $thread_id"
    fi

    # Build agent spec flag
    local spec_flag=""
    [ -n "$AGENT_SPEC_PATH" ] && spec_flag="--agent-spec-path $AGENT_SPEC_PATH"

    local safe_thread=$(sanitize_thread_id "$thread_id")

    log "  Launching Agent SDK runner (thread: $thread_id)..."
    (
        # Use a FIFO to read stderr control messages from agent-runner
        local stderr_fifo="$TMP_DIR/agent_stderr_${safe_thread}"
        rm -f "$stderr_fifo"
        mkfifo "$stderr_fifo"

        # Background reader that processes control messages from stderr
        (
            while IFS= read -r line; do
                if [ "$line" = "TYPING:start" ]; then
                    "$MACOS_MCP" typing "$CONTACT_PHONE" start > /dev/null 2>&1 || true
                elif [ "$line" = "TYPING:stop" ]; then
                    "$MACOS_MCP" typing "$CONTACT_PHONE" stop > /dev/null 2>&1 || true
                else
                    echo "$line" >> "$agent_log"
                fi
            done < "$stderr_fifo"
        ) &
        local reader_pid=$!

        # Run agent-runner.py
        "$AGENT_PYTHON" "$AGENT_RUNNER" \
            --thread-id "$thread_id" \
            --message "$initial_message" \
            --contact-phone "$CONTACT_PHONE" \
            --contact-name "$CONTACT_NAME" \
            --chat-identifier "$chat_identifier" \
            --macos-mcp-path "$MACOS_MCP" \
            --tmp-dir "$TMP_DIR" \
            --agent-timeout "$AGENT_TIMEOUT" \
            --max-retries 3 \
            $conv_id_flag \
            $spec_flag \
            > "$agent_log.stdout" 2> "$stderr_fifo" &
        local runner_pid=$!
        echo "$runner_pid" > "$pid_file"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Agent runner PID: $runner_pid (thread: $thread_id)" >> "$LOG_FILE"

        # Typing keepalive while runner is alive
        (
            while kill -0 "$runner_pid" 2>/dev/null; do
                sleep 30
                "$MACOS_MCP" typing "$CONTACT_PHONE" keepalive > /dev/null 2>&1 || true
            done
        ) &
        local keepalive_pid=$!

        wait "$runner_pid" 2>/dev/null || true
        kill "$keepalive_pid" 2>/dev/null; wait "$keepalive_pid" 2>/dev/null || true
        kill "$reader_pid" 2>/dev/null; wait "$reader_pid" 2>/dev/null || true
        "$MACOS_MCP" typing "$CONTACT_PHONE" stop > /dev/null 2>&1 || true
        rm -f "$stderr_fifo"

        # Parse result JSON from last line of stdout
        local result_json=""
        if [ -f "$agent_log.stdout" ]; then
            result_json=$(tail -1 "$agent_log.stdout")
        fi

        # Extract and save session ID for resume
        local new_session_id=$(echo "$result_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' 2>/dev/null)
        if [ -n "$new_session_id" ]; then
            echo "$new_session_id" > "$conversation_id_file"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Saved session: $new_session_id (thread: $thread_id)" >> "$LOG_FILE"
        fi

        # Log result summary
        local sent=$(echo "$result_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sent", False))' 2>/dev/null)
        local task_status=$(echo "$result_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("task_status") or "none")' 2>/dev/null)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Agent completed: sent=$sent task_status=$task_status (thread: $thread_id)" >> "$LOG_FILE"

        rm -f "$pid_file" "$agent_log.stdout"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Agent session completed (thread: $thread_id)" >> "$LOG_FILE"
    ) &
}

# Main daemon loop
log "=========================================="
log "iMessage Auto-Reply Daemon Starting"
log "=========================================="
log "Contact: $CONTACT_NAME ($CONTACT_PHONE)"
log "Check interval: ${CHECK_INTERVAL}s"
log "Binary: $MACOS_MCP"
log "Tmp directory: $TMP_DIR"
log "Log file: $LOG_FILE"
log ""

while true; do
    # Check for new messages (JSON output)
    new_messages=$("$MACOS_MCP" messages check --phone "$CONTACT_PHONE" --since 60 2>/dev/null)

    # Quick check: any messages at all?
    msg_count=$(echo "$new_messages" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("messages",[])))' 2>/dev/null || echo "0")

    if [ "$msg_count" -gt 0 ]; then
        # Parse JSON and collect unprocessed messages
        collected=()
        while IFS= read -r entry; do
            [ -n "$entry" ] && collected+=("$entry")
        done < <(collect_messages "$new_messages")

        # If we collected new messages, debounce to catch rapid follow-ups
        if [ ${#collected[@]} -gt 0 ]; then
            log "Debouncing ${DEBOUNCE_SECONDS}s..."
            sleep "$DEBOUNCE_SECONDS"

            # Check for more messages that arrived during debounce
            more_messages=$("$MACOS_MCP" messages check --phone "$CONTACT_PHONE" --since 60 2>/dev/null)
            while IFS= read -r entry; do
                [ -n "$entry" ] && collected+=("$entry")
            done < <(collect_messages "$more_messages")

            # Group collected messages by thread and launch agents
            # Reply-thread messages keep their own thread ID; standalone messages
            # (each with a unique GUID) get merged under one "batch" thread.
            # Uses temp files instead of associative arrays for Bash 3.2 compatibility.
            batch_dir=$(mktemp -d "$TMP_DIR/batch.XXXXXX")
            batch_thread_id=""

            for entry in "${collected[@]}"; do
                t_msg_id="${entry%%|*}"
                rest="${entry#*|}"
                t_id="${rest%%|*}"
                rest="${rest#*|}"
                t_chat="${rest%%|*}"
                rest="${rest#*|}"
                t_is_reply="${rest%%|*}"
                t_text="${rest#*|}"

                use_id="$t_id"

                # Reply-thread messages always keep their own thread ID.
                # Standalone messages (not replies, unique GUID) get batched together.
                if [ "$t_is_reply" -eq 0 ] && [ "$t_id" != "default" ] && [ ${#t_id} -gt 20 ]; then
                    if [ -z "$batch_thread_id" ]; then
                        batch_thread_id="$t_id"
                    fi
                    use_id="$batch_thread_id"
                fi

                safe_use_id=$(sanitize_thread_id "$use_id")
                if [ -f "$batch_dir/${safe_use_id}.txt" ]; then
                    printf '\n%s' "$t_text" >> "$batch_dir/${safe_use_id}.txt"
                else
                    printf '%s' "$t_text" > "$batch_dir/${safe_use_id}.txt"
                    printf '%s' "$t_chat" > "$batch_dir/${safe_use_id}.chat"
                    printf '%s' "$use_id" > "$batch_dir/${safe_use_id}.tid"
                fi
                # Track msg_ids so we can mark as processed after dispatch
                echo "$t_msg_id" >> "$batch_dir/${safe_use_id}.ids"
            done

            # Launch one agent per thread group
            for txt_file in "$batch_dir"/*.txt; do
                [ -f "$txt_file" ] || continue
                safe_use_id="$(basename "$txt_file" .txt)"
                t_id=$(cat "$batch_dir/${safe_use_id}.tid")
                t_chat=$(cat "$batch_dir/${safe_use_id}.chat")
                t_texts=$(cat "$txt_file")
                if ! is_agent_running "$t_id"; then
                    "$MACOS_MCP" typing "$CONTACT_PHONE" start > /dev/null 2>&1 || log "  Typing indicator failed, continuing"
                    start_autonomous_agent "$t_texts" "$t_chat" "$t_id"
                    # Mark messages as processed only after successful dispatch
                    while IFS= read -r mid; do
                        mark_as_processed "$mid"
                    done < "$batch_dir/${safe_use_id}.ids"
                else
                    log "  Agent already running for thread $t_id, messages will retry next cycle"
                fi
            done

            rm -rf "$batch_dir"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
