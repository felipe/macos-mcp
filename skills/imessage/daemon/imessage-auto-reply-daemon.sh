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

    # Start Claude Code agent
    log "  Launching Claude Code agent (thread: $thread_id)..."
    claude -p "$agent_prompt" $resume_flag --dangerously-skip-permissions > "$agent_log" 2>&1 &
    local agent_pid=$!
    echo "$agent_pid" > "$pid_file"

    log "  Agent started with PID: $agent_pid (thread: $thread_id)"

    # Run the wait/cleanup in a background subshell so the main loop can continue
    # processing messages for other threads concurrently
    (
        # Keep typing indicator alive while agent works (~60s timeout on recipient side)
        (
            while kill -0 "$agent_pid" 2>/dev/null; do
                sleep 30
                "$IMESSAGE_SKILL/typing-indicator.sh" "$CONTACT_PHONE" keepalive > /dev/null 2>&1 || true
            done
        ) &
        local keepalive_pid=$!

        # Wait for agent to finish and capture conversation ID
        wait "$agent_pid" 2>/dev/null || true

        # Stop keepalive loop and clear typing indicator
        kill "$keepalive_pid" 2>/dev/null; wait "$keepalive_pid" 2>/dev/null || true
        "$IMESSAGE_SKILL/typing-indicator.sh" "$CONTACT_PHONE" stop > /dev/null 2>&1 || true

        # Log completion
        local completion_msg="[$(date '+%Y-%m-%d %H:%M:%S')]   Typing indicator cleared (thread: $thread_id)"
        echo "$completion_msg"
        echo "$completion_msg" >> "$LOG_FILE"

        # Try to extract conversation ID from agent output for future resumes
        local new_conv_id=$(grep -o 'conversation_id: [a-zA-Z0-9_-]*' "$agent_log" 2>/dev/null | tail -1 | awk '{print $2}')
        if [ -n "$new_conv_id" ]; then
            echo "$new_conv_id" > "$conversation_id_file"
            local conv_msg="[$(date '+%Y-%m-%d %H:%M:%S')]   Saved conversation ID: $new_conv_id (thread: $thread_id)"
            echo "$conv_msg"
            echo "$conv_msg" >> "$LOG_FILE"
        fi

        # Clean up PID file
        rm -f "$pid_file"
        local done_msg="[$(date '+%Y-%m-%d %H:%M:%S')]   Agent session completed (thread: $thread_id)"
        echo "$done_msg"
        echo "$done_msg" >> "$LOG_FILE"
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
        # Parse messages
        while IFS= read -r line; do
            case "$line" in
                "MSG_ID: "*)
                    current_msg_id="${line#MSG_ID: }"
                    ;;
                "GUID: "*)
                    current_guid="${line#GUID: }"
                    ;;
                "TEXT: "*)
                    current_text="${line#TEXT: }"
                    ;;
                "THREAD_REPLY_TO: "*)
                    current_thread_reply_to="${line#THREAD_REPLY_TO: }"
                    ;;
                "CHAT: "*)
                    current_chat="${line#CHAT: }"
                    ;;
                "---")
                    # Process this message
                    if [ -n "$current_msg_id" ] && [ -n "$current_text" ]; then
                        if ! check_if_processed "$current_msg_id"; then
                            # Determine thread ID:
                            # - If it's a reply, use the thread_originator_guid
                            # - If it's a new message with a GUID, use its own GUID (starts a new thread)
                            # - Otherwise fall back to "default" for backward compatibility
                            thread_id="default"
                            if [ -n "$current_thread_reply_to" ]; then
                                thread_id="$current_thread_reply_to"
                            elif [ -n "$current_guid" ]; then
                                thread_id="$current_guid"
                            fi

                            log "New message (thread: $thread_id): \"$current_text\""
                            mark_as_processed "$current_msg_id"

                            # Only start agent if one isn't already running for THIS thread
                            if ! is_agent_running "$thread_id"; then
                                # Trigger native typing indicator (best-effort, don't crash daemon)
                                "$IMESSAGE_SKILL/typing-indicator.sh" "$CONTACT_PHONE" start > /dev/null 2>&1 || log "  Typing indicator failed, continuing"
                                start_autonomous_agent "$current_text" "${current_chat:-$CONTACT_PHONE}" "$thread_id"
                            else
                                log "  Agent already running for thread $thread_id, skipping (agent will check for new messages)"
                            fi
                        fi
                    fi
                    # Reset for next message
                    current_msg_id=""
                    current_guid=""
                    current_text=""
                    current_thread_reply_to=""
                    current_chat=""
                    ;;
            esac
        done <<< "$new_messages"
    fi

    sleep "$CHECK_INTERVAL"
done
