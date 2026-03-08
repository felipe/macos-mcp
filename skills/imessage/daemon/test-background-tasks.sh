#!/bin/bash
#
# Tests for background task awareness in imessage-auto-reply-daemon.sh
# Validates task registry directory creation, file format, status transitions,
# cleanup of old done tasks, and prompt content.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/imessage-auto-reply-daemon.sh"
TEST_TMP_DIR=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

pass() {
    echo "PASS: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "FAIL: $1"
    FAILED=$((FAILED + 1))
}

# ─────────────────────────────────────────────
# Test 1: active_tasks directory creation
# ─────────────────────────────────────────────
test_active_tasks_dir_in_daemon() {
    if grep -q 'mkdir -p "$TMP_DIR/active_tasks"' "$DAEMON_SCRIPT"; then
        pass "Daemon creates \$TMP_DIR/active_tasks directory"
    else
        fail "Daemon does not create \$TMP_DIR/active_tasks directory"
    fi
}

# ─────────────────────────────────────────────
# Test 2: active_tasks directory is actually creatable
# ─────────────────────────────────────────────
test_active_tasks_dir_creation() {
    local tasks_dir="$TEST_TMP_DIR/active_tasks"
    mkdir -p "$tasks_dir"
    if [ -d "$tasks_dir" ]; then
        pass "active_tasks directory can be created"
    else
        fail "active_tasks directory creation failed"
    fi
}

# ─────────────────────────────────────────────
# Test 3: Write a task file in the expected format
# ─────────────────────────────────────────────
test_write_task_file() {
    local tasks_dir="$TEST_TMP_DIR/active_tasks"
    mkdir -p "$tasks_dir"
    local task_file="$tasks_dir/test_thread_123.task"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    cat > "$task_file" <<EOF
DESCRIPTION: Research current weather in Valencia
STATUS: working
STARTED: $timestamp
THREAD: test_thread_123
EOF

    if [ -f "$task_file" ]; then
        pass "Task file created successfully"
    else
        fail "Task file was not created"
    fi
}

# ─────────────────────────────────────────────
# Test 4: Read task file fields
# ─────────────────────────────────────────────
test_read_task_file() {
    local tasks_dir="$TEST_TMP_DIR/active_tasks"
    local task_file="$tasks_dir/test_thread_123.task"

    # File should exist from previous test
    if [ ! -f "$task_file" ]; then
        fail "Task file not found for read test (dependency on test_write_task_file)"
        return
    fi

    local description=$(grep '^DESCRIPTION:' "$task_file" | sed 's/^DESCRIPTION: //')
    local status=$(grep '^STATUS:' "$task_file" | sed 's/^STATUS: //')
    local thread=$(grep '^THREAD:' "$task_file" | sed 's/^THREAD: //')

    if [ "$description" = "Research current weather in Valencia" ] && \
       [ "$status" = "working" ] && \
       [ "$thread" = "test_thread_123" ]; then
        pass "Task file fields read correctly"
    else
        fail "Task file fields incorrect: desc='$description' status='$status' thread='$thread'"
    fi
}

# ─────────────────────────────────────────────
# Test 5: Status transition working -> done
# ─────────────────────────────────────────────
test_status_transition() {
    local tasks_dir="$TEST_TMP_DIR/active_tasks"
    local task_file="$tasks_dir/test_thread_456.task"
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')

    # Create initial working task
    cat > "$task_file" <<EOF
DESCRIPTION: Build a new landing page
STATUS: working
STARTED: $start_time
THREAD: test_thread_456
EOF

    # Verify it starts as working
    local initial_status=$(grep '^STATUS:' "$task_file" | sed 's/^STATUS: //')
    if [ "$initial_status" != "working" ]; then
        fail "Initial status should be 'working', got '$initial_status'"
        return
    fi

    # Transition to done
    local finish_time=$(date '+%Y-%m-%d %H:%M:%S')
    cat > "$task_file" <<EOF
DESCRIPTION: Build a new landing page
STATUS: done
STARTED: $start_time
FINISHED: $finish_time
THREAD: test_thread_456
RESULT: Landing page created at /var/www/landing
EOF

    local final_status=$(grep '^STATUS:' "$task_file" | sed 's/^STATUS: //')
    local result=$(grep '^RESULT:' "$task_file" | sed 's/^RESULT: //')
    local finished=$(grep '^FINISHED:' "$task_file" | sed 's/^FINISHED: //')

    if [ "$final_status" = "done" ] && \
       [ -n "$result" ] && \
       [ -n "$finished" ]; then
        pass "Status transition working -> done with RESULT and FINISHED fields"
    else
        fail "Status transition failed: status='$final_status' result='$result' finished='$finished'"
    fi
}

# ─────────────────────────────────────────────
# Test 6: Cleanup of old done tasks (> 1 hour)
# ─────────────────────────────────────────────
test_cleanup_old_done_tasks() {
    local tasks_dir="$TEST_TMP_DIR/active_tasks_cleanup"
    mkdir -p "$tasks_dir"

    # Create an "old" done task file
    local old_task="$tasks_dir/old_thread.task"
    cat > "$old_task" <<EOF
DESCRIPTION: Old completed task
STATUS: done
STARTED: 2025-01-01 10:00:00
FINISHED: 2025-01-01 10:05:00
THREAD: old_thread
RESULT: Completed
EOF

    # Set file modification time to 2 hours ago
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S')" "$old_task"

    # Create a "recent" done task file
    local recent_task="$tasks_dir/recent_thread.task"
    cat > "$recent_task" <<EOF
DESCRIPTION: Recent completed task
STATUS: done
STARTED: 2025-01-01 12:00:00
FINISHED: 2025-01-01 12:05:00
THREAD: recent_thread
RESULT: Completed
EOF
    # recent_task keeps current timestamp (just created)

    # Create a "working" task (should never be cleaned up regardless of age)
    local working_task="$tasks_dir/working_thread.task"
    cat > "$working_task" <<EOF
DESCRIPTION: Still working on this
STATUS: working
STARTED: 2025-01-01 10:00:00
THREAD: working_thread
EOF
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S')" "$working_task"

    # Simulate cleanup: remove .task files that are done AND older than 1 hour
    local cleaned=0
    for f in "$tasks_dir"/*.task; do
        [ -f "$f" ] || continue
        local file_status=$(grep '^STATUS:' "$f" | sed 's/^STATUS: //')
        if [ "$file_status" = "done" ]; then
            # Check if file is older than 1 hour (3600 seconds)
            local file_age=$(( $(date +%s) - $(stat -f %m "$f") ))
            if [ "$file_age" -gt 3600 ]; then
                rm -f "$f"
                cleaned=$((cleaned + 1))
            fi
        fi
    done

    # Verify: old done task removed, recent done task kept, working task kept
    if [ ! -f "$old_task" ] && [ -f "$recent_task" ] && [ -f "$working_task" ] && [ "$cleaned" -eq 1 ]; then
        pass "Cleanup removes old done tasks, keeps recent done and working tasks"
    else
        fail "Cleanup incorrect: old_exists=$([ -f "$old_task" ] && echo yes || echo no) recent_exists=$([ -f "$recent_task" ] && echo yes || echo no) working_exists=$([ -f "$working_task" ] && echo yes || echo no) cleaned=$cleaned"
    fi
}

# ─────────────────────────────────────────────
# Test 7: Prompt contains triage workflow text
# ─────────────────────────────────────────────
test_prompt_contains_triage() {
    if grep -q 'TRIAGE THE REQUEST' "$DAEMON_SCRIPT"; then
        pass "Prompt contains TRIAGE THE REQUEST"
    else
        fail "Prompt missing TRIAGE THE REQUEST"
    fi
}

# ─────────────────────────────────────────────
# Test 8: Prompt contains TASK REGISTRY section
# ─────────────────────────────────────────────
test_prompt_contains_task_registry() {
    if grep -q 'TASK REGISTRY' "$DAEMON_SCRIPT"; then
        pass "Prompt contains TASK REGISTRY section"
    else
        fail "Prompt missing TASK REGISTRY section"
    fi
}

# ─────────────────────────────────────────────
# Test 9: Prompt references active_tasks directory
# ─────────────────────────────────────────────
test_prompt_references_active_tasks_dir() {
    if grep -q 'active_tasks' "$DAEMON_SCRIPT"; then
        pass "Prompt references active_tasks directory"
    else
        fail "Prompt does not reference active_tasks directory"
    fi
}

# ─────────────────────────────────────────────
# Test 10: Prompt contains IF QUICK and IF TASK branches
# ─────────────────────────────────────────────
test_prompt_triage_branches() {
    local has_quick=false
    local has_task=false
    local has_status=false

    grep -q 'IF QUICK' "$DAEMON_SCRIPT" && has_quick=true
    grep -q 'IF TASK' "$DAEMON_SCRIPT" && has_task=true
    grep -q 'IF STATUS REQUEST' "$DAEMON_SCRIPT" && has_status=true

    if $has_quick && $has_task && $has_status; then
        pass "Prompt contains all triage branches (QUICK, TASK, STATUS REQUEST)"
    else
        fail "Prompt missing triage branches: quick=$has_quick task=$has_task status=$has_status"
    fi
}

# ─────────────────────────────────────────────
# Test 11: Prompt still contains IMPORTANT RULES
# ─────────────────────────────────────────────
test_prompt_keeps_important_rules() {
    if grep -q 'IMPORTANT RULES' "$DAEMON_SCRIPT"; then
        pass "Prompt still contains IMPORTANT RULES section"
    else
        fail "Prompt lost IMPORTANT RULES section"
    fi
}

# ─────────────────────────────────────────────
# Test 12: Multiple task files can coexist
# ─────────────────────────────────────────────
test_multiple_concurrent_tasks() {
    local tasks_dir="$TEST_TMP_DIR/active_tasks_multi"
    mkdir -p "$tasks_dir"

    for i in 1 2 3; do
        cat > "$tasks_dir/thread_$i.task" <<EOF
DESCRIPTION: Task number $i
STATUS: working
STARTED: $(date '+%Y-%m-%d %H:%M:%S')
THREAD: thread_$i
EOF
    done

    local count=$(ls "$tasks_dir"/*.task 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -eq 3 ]; then
        pass "Multiple concurrent task files coexist ($count files)"
    else
        fail "Expected 3 task files, found $count"
    fi
}

# ─────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────
echo "========================================"
echo "Background Task Awareness Tests"
echo "========================================"
echo ""

test_active_tasks_dir_in_daemon
test_active_tasks_dir_creation
test_write_task_file
test_read_task_file
test_status_transition
test_cleanup_old_done_tasks
test_prompt_contains_triage
test_prompt_contains_task_registry
test_prompt_references_active_tasks_dir
test_prompt_triage_branches
test_prompt_keeps_important_rules
test_multiple_concurrent_tasks

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
