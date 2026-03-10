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
#

# Allow running from within a Claude Code session or standalone
unset CLAUDECODE 2>/dev/null || true

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="${IMESSAGE_TMP_DIR:-$HOME/tmp/imessage}"
PROCESSED_LOG="$TMP_DIR/processed_imessages.log"
IMESSAGE_SKILL="$PROJECT_ROOT/skills/imessage"
LOG_FILE="$TMP_DIR/imessage-auto-reply.log"

# Configuration from environment variables
CONTACT_EMAIL="${IMESSAGE_CONTACT_EMAIL:-}"
CONTACT_PHONE="${IMESSAGE_CONTACT_PHONE:?Error: IMESSAGE_CONTACT_PHONE environment variable is required}"
CONTACT_NAME="${IMESSAGE_CONTACT_NAME:?Error: IMESSAGE_CONTACT_NAME environment variable is required}"
CHECK_INTERVAL="${IMESSAGE_CHECK_INTERVAL:-1}"
DEBOUNCE_SECONDS="${IMESSAGE_DEBOUNCE:-3}"

# Load environment variables if .env exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
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

# Generate a unique ID for a message based on timestamp and text
generate_message_id() {
    local timestamp="$1"
    local text="$2"
    local sender="$3"
    echo -n "${sender}_${timestamp}_${text}" | md5
}

check_if_processed() {
    local message_id="$1"
    grep -q "^$message_id$" "$PROCESSED_LOG" 2>/dev/null
}

mark_as_processed() {
    local message_id="$1"
    echo "$message_id" >> "$PROCESSED_LOG"
}

is_monitored_chat() {
    local chat_name="$1"
    # Check if chat name contains contact identifiers
    if [ -n "$CONTACT_NAME" ] && echo "$chat_name" | grep -qi "$CONTACT_NAME"; then
        return 0
    elif [ -n "$CONTACT_PHONE" ] && echo "$chat_name" | grep -q "$CONTACT_PHONE"; then
        return 0
    elif [ -n "$CONTACT_EMAIL" ] && echo "$chat_name" | grep -q "$CONTACT_EMAIL"; then
        return 0
    fi
    return 1
}

is_group_chat() {
    local chat_identifier="$1"
    # Group chats start with "chat", 1-on-1 chats use phone numbers or email
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
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            # PID file exists but process is dead, clean up
            rm -f "$pid_file"
        fi
    fi
    return 1
}

start_autonomous_agent() {
    local initial_message="$1"
    local chat_identifier="$2"
    local thread_id="${3:-default}"

    # Get per-thread file paths
    local pid_file=$(get_thread_pid_file "$thread_id")
    local conversation_id_file=$(get_thread_conversation_file "$thread_id")
    local agent_log=$(get_thread_agent_log "$thread_id")

    # Determine conversation type
    local conv_type="1-on-1"
    if is_group_chat "$chat_identifier"; then
        conv_type="group chat"
    fi

    log "Starting autonomous agent session ($conv_type, thread: $thread_id)..."

    # Get recent conversation context
    local conversation=$("$IMESSAGE_SKILL/read-messages-db.sh" "$CONTACT_PHONE" --limit 10 2>&1)

    # Check if we have an existing conversation to resume
    local resume_flag=""
    if [ -f "$conversation_id_file" ]; then
        local conv_id=$(cat "$conversation_id_file")
        resume_flag="-r $conv_id"
        log "  Resuming conversation: $conv_id (thread: $thread_id)"
    else
        log "  Starting new conversation for thread: $thread_id"
    fi

    # Build thread context for the prompt
    local thread_context=""
    if [ "$thread_id" != "default" ]; then
        thread_context="
- THREAD CONTEXT: This message is part of an iMessage reply thread (thread ID: ${thread_id})
- Stay focused on the topic of this thread
- Your response will appear in this specific reply thread"
    fi

    # Create autonomous agent prompt
    local agent_prompt="You are $CONTACT_NAME's personal iMessage assistant running in an autonomous agent session.

IMPORTANT CONTEXT:
- You are in a ${conv_type} conversation
- Chat identifier: ${chat_identifier}${thread_context}
- $CONTACT_NAME just sent: \"${initial_message}\"

AVAILABLE SKILLS:
1. send-imessage: Send messages to $CONTACT_NAME at any time
   - Usage: echo \"message\" | $IMESSAGE_SKILL/send-message.sh \"$CONTACT_PHONE\"
   - For group chats: echo \"message\" | $IMESSAGE_SKILL/send-to-chat.sh \"${chat_identifier}\"

2. check-new-imessages: Check if $CONTACT_NAME sent new messages
   - Usage: $IMESSAGE_SKILL/check-new-messages-db.sh \"$CONTACT_PHONE\"
   - Returns new messages from last hour, or empty if none

3. view-attachment: When a message has attachments (shown as ATTACHMENT: lines or ￼ character in text)
   - Use the Read tool to view image files directly (PNG, JPG, HEIC, etc.)
   - The file path will be in the ATTACHMENT line from check-new-messages output
   - You can also query attachments manually: sqlite3 ~/Library/Messages/chat.db \"SELECT a.filename, a.mime_type FROM attachment a JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id WHERE maj.message_id = <ROWID>;\"

4. send-file: Send images or files via iMessage
   - Usage: $IMESSAGE_SKILL/send-file.sh \"$CONTACT_PHONE\" \"/path/to/image.png\"
   - Supports any file type (images, PDFs, etc.)
   - Use this when you need to share screenshots, generated images, or any file

5. All other skills available in your Claude Code environment

RECENT CONVERSATION:
${conversation}

YOUR AUTONOMOUS AGENT WORKFLOW:

1. TRIAGE THE REQUEST:
   Quickly assess: is this a QUICK question (answerable in under a minute) or a TASK that needs work (research, building, multi-step)?

2a. IF QUICK (simple questions, lookups, brief answers):
   - Work on it immediately
   - Send ONE response via iMessage with your complete answer
   - Do NOT send multiple messages

2b. IF TASK (research, building, multi-step work, anything over ~1 minute):
   - Send a brief acknowledgment like \"On it\" or \"Working on that\" (1 sentence max, be natural)
   - Register the task: write a task file to track it (see TASK REGISTRY below)
   - Do the work
   - When finished, update the task file status to \"done\"
   - Send the final result via iMessage

3. IF STATUS REQUEST:
   - If the user is asking about status of background work, check the active tasks directory: ${TMP_DIR}/active_tasks/
   - Read any .task files there and report what's running, what's done
   - Clean up any .task files marked \"done\" that are older than 1 hour

TASK REGISTRY:
- Directory: ${TMP_DIR}/active_tasks/
- Sanitize the thread_id for filenames: replace every character that is NOT [a-zA-Z0-9_-] with _
- To register a task, create a file: ${TMP_DIR}/active_tasks/<sanitized_thread_id>.task
- File format (plain text):
  DESCRIPTION: <one-line summary of the task>
  STATUS: working
  STARTED: <timestamp>
  THREAD: <thread_id>
- When done, update the file:
  DESCRIPTION: <one-line summary>
  STATUS: done
  STARTED: <original timestamp>
  FINISHED: <timestamp>
  THREAD: <thread_id>
  RESULT: <one-line summary of outcome>

IMPORTANT RULES:
- Always use the send-message skill to reply (don't just print to stdout)
- Keep messages concise and natural (this is iMessage, not email)
- If you're stuck or need clarification, ask via iMessage
- Don't apologize excessively - be helpful and direct
- If the request is dangerous or inappropriate, politely decline
- When you see ￼ (object replacement character) in message text, it means there's an attachment — check for ATTACHMENT lines in the message data and use Read to view image files
- Expand ~ to \$HOME in attachment paths before reading them"

    # Run the agent and cleanup in a background subshell so the main loop can continue
    # processing messages for other threads concurrently
    log "  Launching Claude Code agent (thread: $thread_id)..."
    (
        # Start Claude Code agent inside the subshell so we can wait on it
        claude -p "$agent_prompt" $resume_flag --dangerously-skip-permissions > "$agent_log" 2>&1 &
        local agent_pid=$!
        echo "$agent_pid" > "$pid_file"

        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Agent started with PID: $agent_pid (thread: $thread_id)" >> "$LOG_FILE"

        # Keep typing indicator alive while agent works (~60s timeout on recipient side)
        (
            while kill -0 "$agent_pid" 2>/dev/null; do
                sleep 30
                "$IMESSAGE_SKILL/typing-indicator.sh" "$CONTACT_PHONE" keepalive > /dev/null 2>&1 || true
            done
        ) &
        local keepalive_pid=$!

        # Wait for agent to finish
        wait "$agent_pid" 2>/dev/null || true

        # Stop keepalive loop and clear typing indicator
        kill "$keepalive_pid" 2>/dev/null; wait "$keepalive_pid" 2>/dev/null || true
        "$IMESSAGE_SKILL/typing-indicator.sh" "$CONTACT_PHONE" stop > /dev/null 2>&1 || true

        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Typing indicator cleared (thread: $thread_id)" >> "$LOG_FILE"

        # Try to extract conversation ID from agent output for future resumes
        local new_conv_id=$(grep -o 'conversation_id: [a-zA-Z0-9_-]*' "$agent_log" 2>/dev/null | tail -1 | awk '{print $2}')
        if [ -n "$new_conv_id" ]; then
            echo "$new_conv_id" > "$conversation_id_file"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Saved conversation ID: $new_conv_id (thread: $thread_id)" >> "$LOG_FILE"
        fi

        # Clean up PID file
        rm -f "$pid_file"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Agent session completed (thread: $thread_id)" >> "$LOG_FILE"
    ) &
}

# Main daemon loop
log "=========================================="
log "iMessage Auto-Reply Daemon Starting"
log "=========================================="
log "Contact: $CONTACT_NAME ($CONTACT_PHONE)"
log "Check interval: ${CHECK_INTERVAL}s"
log "Tmp directory: $TMP_DIR"
log "Log file: $LOG_FILE"
log ""

while true; do
    # Check for new messages
    new_messages=$("$IMESSAGE_SKILL/check-new-messages-db.sh" "$CONTACT_PHONE" 2>/dev/null)

    if [ -n "$new_messages" ]; then
        # Parse and collect unprocessed messages
        # Each entry: thread_id|chat|is_reply|text
        collected=()
        while IFS= read -r line; do
            case "$line" in
                "MSG_ID: "*) current_msg_id="${line#MSG_ID: }" ;;
                "GUID: "*) current_guid="${line#GUID: }" ;;
                "TEXT: "*) current_text="${line#TEXT: }" ;;
                "THREAD_REPLY_TO: "*) current_thread_reply_to="${line#THREAD_REPLY_TO: }" ;;
                "CHAT: "*) current_chat="${line#CHAT: }" ;;
                "---")
                    if [ -n "$current_msg_id" ] && [ -n "$current_text" ]; then
                        if ! check_if_processed "$current_msg_id"; then
                            thread_id="default"
                            msg_is_reply=0
                            if [ -n "$current_thread_reply_to" ]; then
                                thread_id="$current_thread_reply_to"
                                msg_is_reply=1
                            elif [ -n "$current_guid" ]; then
                                thread_id="$current_guid"
                            fi
                            log "New message (thread: $thread_id): \"$current_text\""
                            mark_as_processed "$current_msg_id"
                            collected+=("${thread_id}|${current_chat:-$CONTACT_PHONE}|${msg_is_reply}|${current_text}")
                        fi
                    fi
                    current_msg_id=""; current_guid=""; current_text=""; current_thread_reply_to=""; current_chat=""
                    ;;
            esac
        done <<< "$new_messages"

        # If we collected new messages, debounce to catch rapid follow-ups
        if [ ${#collected[@]} -gt 0 ]; then
            log "Debouncing ${DEBOUNCE_SECONDS}s..."
            sleep "$DEBOUNCE_SECONDS"

            # Check for more messages that arrived during debounce
            more_messages=$("$IMESSAGE_SKILL/check-new-messages-db.sh" "$CONTACT_PHONE" 2>/dev/null)
            if [ -n "$more_messages" ]; then
                while IFS= read -r line; do
                    case "$line" in
                        "MSG_ID: "*) current_msg_id="${line#MSG_ID: }" ;;
                        "GUID: "*) current_guid="${line#GUID: }" ;;
                        "TEXT: "*) current_text="${line#TEXT: }" ;;
                        "THREAD_REPLY_TO: "*) current_thread_reply_to="${line#THREAD_REPLY_TO: }" ;;
                        "CHAT: "*) current_chat="${line#CHAT: }" ;;
                        "---")
                            if [ -n "$current_msg_id" ] && [ -n "$current_text" ]; then
                                if ! check_if_processed "$current_msg_id"; then
                                    thread_id="default"
                                    msg_is_reply=0
                                    if [ -n "$current_thread_reply_to" ]; then
                                        thread_id="$current_thread_reply_to"
                                        msg_is_reply=1
                                    elif [ -n "$current_guid" ]; then
                                        thread_id="$current_guid"
                                    fi
                                    log "Additional message during debounce (thread: $thread_id): \"$current_text\""
                                    mark_as_processed "$current_msg_id"
                                    collected+=("${thread_id}|${current_chat:-$CONTACT_PHONE}|${msg_is_reply}|${current_text}")
                                fi
                            fi
                            current_msg_id=""; current_guid=""; current_text=""; current_thread_reply_to=""; current_chat=""
                            ;;
                    esac
                done <<< "$more_messages"
            fi

            # Group collected messages by thread and launch agents
            # Reply-thread messages keep their own thread ID; standalone messages
            # (each with a unique GUID) get merged under one "batch" thread.
            # Uses temp files instead of associative arrays for Bash 3.2 compatibility.
            batch_dir=$(mktemp -d "$TMP_DIR/batch.XXXXXX")
            batch_thread_id=""

            for entry in "${collected[@]}"; do
                t_id="${entry%%|*}"
                rest="${entry#*|}"
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
            done

            # Launch one agent per thread group
            for txt_file in "$batch_dir"/*.txt; do
                [ -f "$txt_file" ] || continue
                safe_use_id="$(basename "$txt_file" .txt)"
                t_id=$(cat "$batch_dir/${safe_use_id}.tid")
                t_chat=$(cat "$batch_dir/${safe_use_id}.chat")
                t_texts=$(cat "$txt_file")
                if ! is_agent_running "$t_id"; then
                    "$IMESSAGE_SKILL/typing-indicator.sh" "$CONTACT_PHONE" start > /dev/null 2>&1 || log "  Typing indicator failed, continuing"
                    start_autonomous_agent "$t_texts" "$t_chat" "$t_id"
                else
                    log "  Agent already running for thread $t_id, skipping"
                fi
            done

            rm -rf "$batch_dir"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
