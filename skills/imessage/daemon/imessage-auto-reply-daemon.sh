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

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="${IMESSAGE_TMP_DIR:-$HOME/tmp/imessage}"
PROCESSED_LOG="$TMP_DIR/processed_imessages.log"
CONVERSATION_ID_FILE="$TMP_DIR/imessage_claude_conversation_id.txt"
AGENT_PID_FILE="$TMP_DIR/imessage_agent.pid"
IMESSAGE_SKILL="$PROJECT_ROOT/skills/imessage"
LOG_FILE="$TMP_DIR/imessage-auto-reply.log"
AGENT_LOG="$TMP_DIR/imessage-agent.log"

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

is_agent_running() {
    if [ -f "$AGENT_PID_FILE" ]; then
        local pid=$(cat "$AGENT_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            # PID file exists but process is dead, clean up
            rm "$AGENT_PID_FILE"
        fi
    fi
    return 1
}

start_autonomous_agent() {
    local initial_message="$1"
    local chat_identifier="$2"

    # Determine conversation type
    local conv_type="1-on-1"
    if is_group_chat "$chat_identifier"; then
        conv_type="group chat"
    fi

    log "Starting autonomous agent session ($conv_type)..."

    # Get recent conversation context
    local conversation=$("$IMESSAGE_SKILL/read-messages-db.sh" "$CONTACT_PHONE" --limit 10 2>&1)

    # Check if we have an existing conversation to resume
    local resume_flag=""
    if [ -f "$CONVERSATION_ID_FILE" ]; then
        local conv_id=$(cat "$CONVERSATION_ID_FILE")
        resume_flag="-r $conv_id"
        log "  Resuming conversation: $conv_id"
    else
        log "  Starting new conversation (will save ID for future resumes)"
    fi

    # Create autonomous agent prompt
    local agent_prompt="You are $CONTACT_NAME's personal iMessage assistant running in an autonomous agent session.

IMPORTANT CONTEXT:
- You are in a ${conv_type} conversation
- Chat identifier: ${chat_identifier}
- $CONTACT_NAME just sent: \"${initial_message}\"

AVAILABLE SKILLS:
1. send-imessage: Send messages to $CONTACT_NAME at any time
   - Usage: echo \"message\" | $IMESSAGE_SKILL/send-message.sh \"$CONTACT_PHONE\"
   - For group chats: echo \"message\" | $IMESSAGE_SKILL/send-to-chat.sh \"${chat_identifier}\"

2. check-new-imessages: Check if $CONTACT_NAME sent new messages
   - Usage: $IMESSAGE_SKILL/check-new-messages-db.sh \"$CONTACT_PHONE\"
   - Returns new messages from last hour, or empty if none

3. All other skills available in your Claude Code environment

RECENT CONVERSATION:
${conversation}

YOUR AUTONOMOUS AGENT WORKFLOW:

1. INITIAL ACKNOWLEDGMENT:
   - Send a quick confirmation that you received the message and are working on it
   - Only if the request requires work (don't confirm simple questions you can answer immediately)

2. UNDERSTAND THE REQUEST:
   - Look up relevant context using available skills
   - Determine what the user needs

3. WORK ON THE TASK:
   - Break down complex requests into steps
   - Send progress updates for long-running tasks
   - Use all available Claude Code skills and tools

4. CHECK FOR NEW MESSAGES:
   - Every 30-60 seconds, check if $CONTACT_NAME sent new messages
   - If they did, read them and adjust your work accordingly
   - This allows for a natural back-and-forth conversation

5. SEND FINAL RESPONSE:
   - When done, send the result via iMessage
   - For complex results, break into multiple messages

IMPORTANT RULES:
- Always use the send-message skill to reply (don't just print to stdout)
- Keep messages concise and natural (this is iMessage, not email)
- If you're stuck or need clarification, ask via iMessage
- Don't apologize excessively - be helpful and direct
- If the request is dangerous or inappropriate, politely decline"

    # Start Claude Code agent
    log "  Launching Claude Code agent..."
    claude -p "$agent_prompt" $resume_flag --dangerously-skip-permissions > "$AGENT_LOG" 2>&1 &
    local agent_pid=$!
    echo "$agent_pid" > "$AGENT_PID_FILE"

    log "  Agent started with PID: $agent_pid"

    # Wait for agent to finish and capture conversation ID
    wait "$agent_pid" 2>/dev/null || true

    # Try to extract conversation ID from agent output for future resumes
    local new_conv_id=$(grep -o 'conversation_id: [a-zA-Z0-9_-]*' "$AGENT_LOG" 2>/dev/null | tail -1 | awk '{print $2}')
    if [ -n "$new_conv_id" ]; then
        echo "$new_conv_id" > "$CONVERSATION_ID_FILE"
        log "  Saved conversation ID: $new_conv_id"
    fi

    # Clean up PID file
    rm -f "$AGENT_PID_FILE"
    log "  Agent session completed"
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
                "TEXT: "*)
                    current_text="${line#TEXT: }"
                    ;;
                "CHAT: "*)
                    current_chat="${line#CHAT: }"
                    ;;
                "---")
                    # Process this message
                    if [ -n "$current_msg_id" ] && [ -n "$current_text" ]; then
                        if ! check_if_processed "$current_msg_id"; then
                            log "New message: \"$current_text\""
                            mark_as_processed "$current_msg_id"

                            # Only start agent if one isn't already running
                            if ! is_agent_running; then
                                start_autonomous_agent "$current_text" "${current_chat:-$CONTACT_PHONE}"
                            else
                                log "  Agent already running, skipping (agent will check for new messages)"
                            fi
                        fi
                    fi
                    # Reset for next message
                    current_msg_id=""
                    current_text=""
                    current_chat=""
                    ;;
            esac
        done <<< "$new_messages"
    fi

    sleep "$CHECK_INTERVAL"
done
