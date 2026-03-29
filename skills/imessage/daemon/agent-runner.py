#!/usr/bin/env python3
"""
Agent runner for iMessage daemon.
Replaces `claude -p` with the Claude Agent SDK for structured tool control,
session management, and retry logic.

Called by the daemon script instead of `claude -p`:
    python3 agent-runner.py --thread-id X --message "text" ...

Output contract:
    stdout (last line): JSON {"sent": bool, "task_status": str|null, "session_id": str|null, "error": str|null}
    stderr: TYPING:start / TYPING:stop control messages + log lines
"""

import argparse
import asyncio
import json
import os
import re
import signal
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolUseBlock,
    create_sdk_mcp_server,
    query,
    tool,
)


# ─── Control messages (stderr) ─────────────────────────


def control(msg: str):
    """Print control message to stderr for daemon to parse."""
    print(msg, file=sys.stderr, flush=True)


def log(msg: str):
    """Print timestamped log to stderr."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


# ─── Task file management ──────────���───────────────────


def sanitize_thread_id(thread_id: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "_", thread_id)


def get_task_file(tmp_dir: str, thread_id: str) -> Path:
    safe = sanitize_thread_id(thread_id)
    return Path(tmp_dir) / "active_tasks" / f"{safe}.task"


def read_task_field(task_file: Path, field: str) -> str | None:
    if not task_file.exists():
        return None
    for line in task_file.read_text().splitlines():
        if line.startswith(f"{field}:"):
            return line.split(":", 1)[1].strip()
    return None


# ─── Agent spec loading ───────────────��────────────────


def load_agent_spec(spec_path: str) -> str:
    if not spec_path or not os.path.isdir(spec_path):
        return ""
    parts = []
    for md_file in sorted(Path(spec_path).glob("*.md")):
        parts.append(f"--- {md_file.name} ---")
        parts.append(md_file.read_text())
    if parts:
        return "\nAGENT PERSONA:\n" + "\n".join(parts)
    return ""


# ─── Tool definitions ────────────────��─────────────────


def make_tools(mcp_path: str, phone: str, chat_id: str):
    """Create SDK MCP tools that shell out to the macos-mcp binary."""

    @tool(
        "send_imessage",
        "Send an iMessage to the contact. Use this to reply to messages.",
        {"text": {"type": "string", "description": "Message text to send"}},
    )
    async def send_imessage(args: dict):
        result = subprocess.run(
            [mcp_path, "send", "message", phone, args["text"]],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return {"content": [{"type": "text", "text": result.stdout or result.stderr}]}

    @tool(
        "send_to_chat",
        "Send a message to a group chat",
        {
            "chat_id": {"type": "string", "description": "Chat identifier"},
            "text": {"type": "string", "description": "Message text"},
        },
    )
    async def send_to_chat(args: dict):
        result = subprocess.run(
            [mcp_path, "send", "chat", args["chat_id"], args["text"]],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return {"content": [{"type": "text", "text": result.stdout or result.stderr}]}

    @tool(
        "send_file",
        "Send a file attachment via iMessage (images, PDFs, etc.)",
        {"file_path": {"type": "string", "description": "Absolute path to file"}},
    )
    async def send_file(args: dict):
        result = subprocess.run(
            [mcp_path, "send", "file", phone, args["file_path"]],
            capture_output=True,
            text=True,
            timeout=60,
        )
        return {"content": [{"type": "text", "text": result.stdout or result.stderr}]}

    @tool(
        "check_messages",
        "Check for new messages from the contact in the last hour",
        {},
    )
    async def check_messages(args: dict):
        result = subprocess.run(
            [mcp_path, "messages", "check", "--phone", phone, "--since", "60"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        return {"content": [{"type": "text", "text": result.stdout or result.stderr}]}

    @tool(
        "read_conversation",
        "Read recent conversation history",
        {
            "limit": {
                "type": "integer",
                "description": "Number of messages to read (default 10)",
            }
        },
    )
    async def read_conversation(args: dict):
        limit = str(args.get("limit", 10))
        result = subprocess.run(
            [mcp_path, "messages", "read", "--phone", phone, "--limit", limit],
            capture_output=True,
            text=True,
            timeout=15,
        )
        return {"content": [{"type": "text", "text": result.stdout or result.stderr}]}

    @tool(
        "view_attachment",
        "Get attachment info for a message by rowid. Use when you see the replacement character in message text.",
        {
            "rowid": {"type": "integer", "description": "Message ROWID"},
            "convert_heic": {
                "type": "boolean",
                "description": "Convert HEIC to JPEG",
            },
        },
    )
    async def view_attachment(args: dict):
        cmd = [mcp_path, "messages", "attachments", "--rowid", str(args["rowid"])]
        if args.get("convert_heic"):
            cmd.append("--convert-heic")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return {"content": [{"type": "text", "text": result.stdout or result.stderr}]}

    @tool(
        "read_file",
        "Read a file from disk (for viewing images, logs, configs, etc.)",
        {"path": {"type": "string", "description": "Absolute path to file"}},
    )
    async def read_file(args: dict):
        path = os.path.expanduser(args["path"])
        try:
            with open(path, "r") as f:
                content = f.read(100_000)
            return {"content": [{"type": "text", "text": content}]}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error reading {path}: {e}"}]}

    @tool(
        "run_command",
        "Run a shell command and return output. Use for git, ssh, docker, etc.",
        {"command": {"type": "string", "description": "Shell command to execute"}},
    )
    async def run_command(args: dict):
        try:
            result = subprocess.run(
                args["command"],
                shell=True,
                capture_output=True,
                text=True,
                timeout=120,
            )
            output = (result.stdout + result.stderr)[:50_000]
            return {"content": [{"type": "text", "text": output or "(no output)"}]}
        except subprocess.TimeoutExpired:
            return {
                "content": [{"type": "text", "text": "Command timed out after 120s"}]
            }

    return [
        send_imessage,
        send_to_chat,
        send_file,
        check_messages,
        read_conversation,
        view_attachment,
        read_file,
        run_command,
    ]


# ─── Prompt builder ──────────���─────────────────────────


def build_prompt(
    args,
    conversation_json: str,
    agent_spec: str,
    is_continuation: bool = False,
    prev_desc: str = "",
    prev_reason: str = "",
    attempt: int = 0,
    max_retries: int = 3,
) -> str:
    tmp_dir = args.tmp_dir
    contact = args.contact_name
    phone = args.contact_phone
    chat_id = args.chat_identifier
    thread_id = args.thread_id
    message = args.message

    conv_type = "group chat" if chat_id.startswith("chat") else "1-on-1"

    thread_context = ""
    if thread_id != "default" and not thread_id.startswith("+"):
        thread_context = f"""
- THREAD CONTEXT: This message is part of an iMessage reply thread (thread ID: {thread_id})
- Stay focused on the topic of this thread
- Your response will appear in this specific reply thread"""

    continuation_header = ""
    if is_continuation:
        continuation_header = f"""
YOU ARE CONTINUING AN UNFINISHED TASK.
TASK: {prev_desc}
PREVIOUS ATTEMPT: {prev_reason} (attempt {attempt} of {max_retries})
Continue where you left off and finish it.
"""

    safe_thread = sanitize_thread_id(thread_id)

    return f"""{agent_spec}
{continuation_header}
You are {contact}'s personal iMessage assistant running in an autonomous agent session.

IMPORTANT CONTEXT:
- You are in a {conv_type} conversation
- Chat identifier: {chat_id}{thread_context}
- {contact} just sent: "{message}"

RECENT CONVERSATION (JSON):
{conversation_json}

YOUR AUTONOMOUS AGENT WORKFLOW:

FIRST: Send a brief, natural acknowledgment via send_imessage IMMEDIATELY.
Keep it short (1-4 words), casual, and varied. Examples: "On it", "Checking",
"One sec", "Let me look", "Hmm let me check". Match your persona's voice.
This is critical — the human needs to know you received the message right away.

THEN: Triage the request.

1a. IF QUICK (simple questions, lookups, brief answers):
   - Work on it immediately
   - Send your response via send_imessage
   - Do NOT send multiple messages beyond the ack + answer

1b. IF TASK (research, building, multi-step work, anything over ~1 minute):
   - Register the task: write a task file to track it (see TASK REGISTRY below)
   - Do the work
   - When finished, update the task file status to "done"
   - Send the final result via send_imessage

3. IF STATUS REQUEST:
   - Check the active tasks directory: {tmp_dir}/active_tasks/
   - Read any .task files there and report what's running, what's done
   - Clean up any .task files marked "done" that are older than 1 hour

TASK REGISTRY:
- Directory: {tmp_dir}/active_tasks/
- Sanitize the thread_id for filenames: replace every character that is NOT [a-zA-Z0-9_-] with _
- To register a task, create a file: {tmp_dir}/active_tasks/{safe_thread}.task
- File format (plain text):
  DESCRIPTION: <one-line summary of the task>
  STATUS: working
  STARTED: <timestamp>
  THREAD: {thread_id}
- When done, update the file:
  DESCRIPTION: <one-line summary>
  STATUS: done
  STARTED: <original timestamp>
  FINISHED: <timestamp>
  THREAD: {thread_id}
  RESULT: <one-line summary of outcome>

IMPORTANT RULES:
- Always use the send_imessage tool to reply (don't just return text)
- Keep messages concise and natural (this is iMessage, not email)
- If you're stuck or need clarification, ask via send_imessage
- Don't apologize excessively - be helpful and direct
- If the request is dangerous or inappropriate, politely decline
- When you see \ufffc (object replacement character) in message text, there's an attachment — use view_attachment to check it
- Expand ~ to $HOME in attachment paths before reading them"""


# ─── Main agent loop ───────────��───────────────────────


async def run_agent(args) -> dict:
    """Run the agent with retry loop and task-status awareness."""
    mcp_path = args.macos_mcp_path
    phone = args.contact_phone
    tmp_dir = args.tmp_dir
    thread_id = args.thread_id
    max_retries = args.max_retries
    timeout_secs = args.agent_timeout

    # Fetch recent conversation context
    try:
        conv_result = subprocess.run(
            [mcp_path, "messages", "read", "--phone", phone, "--limit", "10"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        conversation_json = conv_result.stdout
    except Exception as e:
        conversation_json = f'{{"error": "{e}"}}'

    # Load agent spec
    agent_spec = load_agent_spec(args.agent_spec_path)

    # Create tools and MCP server
    tools = make_tools(mcp_path, phone, args.chat_identifier)
    server = create_sdk_mcp_server("imessage", "1.0.0", tools)

    # Allowed tools list
    allowed_tools = [
        "mcp__imessage__send_imessage",
        "mcp__imessage__send_to_chat",
        "mcp__imessage__send_file",
        "mcp__imessage__check_messages",
        "mcp__imessage__read_conversation",
        "mcp__imessage__view_attachment",
        "mcp__imessage__read_file",
        "mcp__imessage__run_command",
    ]

    task_file = get_task_file(tmp_dir, thread_id)
    session_id = args.conversation_id or None
    result = {"sent": False, "task_status": None, "session_id": None, "error": None}
    prev_reason = ""

    for attempt in range(1, max_retries + 1):
        log(f"Agent attempt {attempt}/{max_retries} (thread: {thread_id})")
        control("TYPING:start")

        # Build prompt
        if attempt == 1:
            prompt = build_prompt(args, conversation_json, agent_spec)
        else:
            task_desc = read_task_field(task_file, "DESCRIPTION") or "unknown"
            prompt = build_prompt(
                args,
                conversation_json,
                agent_spec,
                is_continuation=True,
                prev_desc=task_desc,
                prev_reason=prev_reason,
                attempt=attempt,
                max_retries=max_retries,
            )

        options = ClaudeAgentOptions(
            mcp_servers={"imessage": server},
            allowed_tools=allowed_tools,
            permission_mode="bypassPermissions",
            max_turns=20,
            cwd=os.getcwd(),
        )
        if session_id:
            options.resume = session_id

        prev_reason = "completed without finishing"
        timed_out = False

        # Thread-based watchdog: asyncio.timeout doesn't work because the SDK
        # blocks in a subprocess. Kill child claude processes but NOT ourselves
        # so the retry loop can continue.
        watchdog_cancelled = threading.Event()
        watchdog_fired = threading.Event()

        def watchdog():
            if watchdog_cancelled.wait(timeout_secs):
                return  # Cancelled, agent finished in time
            log(f"Watchdog: timeout after {timeout_secs}s, killing child processes (attempt {attempt})")
            watchdog_fired.set()
            # Kill child processes (the SDK's bundled claude) but not ourselves
            my_pid = os.getpid()
            try:
                # Get all descendant PIDs
                result = subprocess.run(
                    ["pgrep", "-P", str(my_pid)],
                    capture_output=True, text=True, timeout=5,
                )
                for pid_str in result.stdout.strip().split("\n"):
                    pid_str = pid_str.strip()
                    if pid_str and pid_str != str(my_pid):
                        try:
                            os.kill(int(pid_str), signal.SIGKILL)
                        except (ProcessLookupError, ValueError):
                            pass
            except Exception as e:
                log(f"Watchdog kill error: {e}")

        watchdog_thread = threading.Thread(target=watchdog, daemon=True)
        watchdog_thread.start()

        try:
            async for message in query(prompt=prompt, options=options):
                # Capture session ID from result
                if isinstance(message, ResultMessage):
                    if message.session_id:
                        session_id = message.session_id
                        result["session_id"] = session_id
                    if message.is_error:
                        log(f"  Agent error: {message.result}")
                        result["error"] = message.result

                # Detect tool use to track if we sent a message
                elif isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, ToolUseBlock):
                            if block.name in (
                                "mcp__imessage__send_imessage",
                                "mcp__imessage__send_to_chat",
                            ):
                                result["sent"] = True
                                log(f"  Message sent via {block.name}")

        except Exception as e:
            log(f"Agent exception: {e}")
            if not watchdog_fired.is_set():
                result["error"] = str(e)
        finally:
            watchdog_cancelled.set()  # Cancel watchdog if agent finished in time

        # Check if watchdog killed us
        if watchdog_fired.is_set():
            log(f"Agent timed out after {timeout_secs}s (attempt {attempt})")
            prev_reason = f"timed out after {timeout_secs}s"
            timed_out = True

        control("TYPING:stop")

        # Check task status
        task_status = read_task_field(task_file, "STATUS")
        result["task_status"] = task_status

        if task_status == "done" or task_status is None:
            log(
                f"Agent finished, task_status='{task_status or 'none'}' sent={result['sent']} (attempt {attempt})"
            )
            break

        # Task still working — retry if we have attempts left
        if attempt < max_retries:
            task_desc = read_task_field(task_file, "DESCRIPTION") or "unknown"
            log(f"Task still working ('{task_desc}'), retrying attempt {attempt + 1}")
        else:
            # Max retries reached — notify user
            log(f"Task incomplete after {max_retries} attempts, giving up")
            task_desc = read_task_field(task_file, "DESCRIPTION") or "unknown"
            try:
                subprocess.run(
                    [
                        mcp_path,
                        "send",
                        "message",
                        phone,
                        f"I wasn't able to finish that task after {max_retries} attempts. "
                        f"The goal was: {task_desc}. Can you help me break it down?",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                result["sent"] = True
            except Exception:
                pass

    # If agent completed but never sent a message, warn
    if not result["sent"] and not result["error"]:
        log("WARNING: Agent completed without sending a message")

    return result


# ─── Entry point ──────────────��─────────────────────────


def main():
    parser = argparse.ArgumentParser(description="iMessage Agent Runner (Claude Agent SDK)")
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--contact-phone", required=True)
    parser.add_argument("--contact-name", required=True)
    parser.add_argument("--chat-identifier", required=True)
    parser.add_argument("--macos-mcp-path", required=True)
    parser.add_argument("--tmp-dir", required=True)
    parser.add_argument("--agent-spec-path", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--agent-timeout", type=int, default=600)
    parser.add_argument("--max-retries", type=int, default=3)
    args = parser.parse_args()

    result = asyncio.run(run_agent(args))
    # Print result JSON as the last line on stdout
    print(json.dumps(result))


if __name__ == "__main__":
    main()
