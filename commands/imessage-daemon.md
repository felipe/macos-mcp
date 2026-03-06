---
description: "Manage the iMessage auto-reply daemon. Usage: /imessage-daemon [start|stop|status] (defaults to status)"
---

# iMessage Daemon Management

Manage the iMessage auto-reply daemon that monitors incoming messages and responds autonomously.

## User Request

The user wants to: {{command}}

Default to "status" if no command specified.

## Available Commands

- **start**: Start the daemon (requires configuration)
- **stop**: Stop the running daemon
- **status**: Check if daemon is running and show logs

## Your Task

1. **Determine the command**: Extract the action from the user's request (start|stop|status)

2. **Locate the daemon script**: The plugin installation includes the daemon at:
   - Find plugin installation path (typically in Claude Code's plugin directory)
   - Daemon script is at: `skills/imessage/daemon/imessage-auto-reply-daemon.sh`

3. **Execute the appropriate action**:

   ### For START:
   - Check if environment variables are configured:
     - `IMESSAGE_CONTACT_PHONE` (required)
     - `IMESSAGE_CONTACT_NAME` (required)
     - `IMESSAGE_CONTACT_EMAIL` (optional)
   - If not configured, guide user to set them:
     ```bash
     export IMESSAGE_CONTACT_PHONE="4155551234"
     export IMESSAGE_CONTACT_NAME="John Doe"
     export IMESSAGE_CONTACT_EMAIL="john@example.com"  # optional
     ```
   - Create tmp directory if needed: `mkdir -p ~/tmp/imessage`
   - Start the daemon in background:
     ```bash
     nohup /path/to/plugin/skills/imessage/daemon/imessage-auto-reply-daemon.sh > /dev/null 2>&1 &
     ```
   - Confirm it started and show the PID
   - Show how to view logs

   ### For STOP:
   - Find the daemon process: `ps aux | grep imessage-auto-reply-daemon | grep -v grep`
   - Kill it: `pkill -f imessage-auto-reply-daemon`
   - Confirm it was stopped
   - Show any final log messages

   ### For STATUS:
   - Check if daemon is running: `ps aux | grep imessage-auto-reply-daemon | grep -v grep`
   - If running:
     - Show PID and how long it's been running
     - Show last 10 lines of daemon log: `tail -10 ~/tmp/imessage/imessage-auto-reply.log`
     - Show last 10 lines of agent log: `tail -10 ~/tmp/imessage/imessage-agent.log`
     - Show configuration (contact phone/name)
   - If not running:
     - Confirm it's not running
     - Show how to start it with `/imessage-daemon start`

## Important Notes

- The daemon requires environment variables to be set before starting
- Logs are stored in `~/tmp/imessage/`
- The daemon maintains conversation continuity via conversation ID file
- Only one daemon instance should run per contact
