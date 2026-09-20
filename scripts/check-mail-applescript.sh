#!/usr/bin/env bash
set -euo pipefail
# Compile generated scripts against the installed Mail dictionary. Never execute them.
TMP_DIR="$(mktemp -d /tmp/macos-mcp-mail-scripts.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let cases: [(String, [String: String])] = [
    ("send", ["to": "test@example.test", "cc": "other@example.test", "bcc": "hidden@example.test", "subject": "Quotes \" and slash \\", "body": "Line one\nLine two", "attachments": "/tmp/test attachment.pdf", "account": "sender@example.test"]),
    ("draft", ["subject": "Draft", "body": "Content"]),
    ("reply", ["message_id": "<test@example.test>", "mailbox": "INBOX", "account": "sender@example.test", "body": "Reply", "reply_all": "true"]),
    ("forward", ["message_id": "<test@example.test>", "mailbox": "Parent/Child", "account_id": "test-id", "to": "test@example.test", "body": "Forward"]),
    ("move", ["message_id": "<test@example.test>", "mailbox": "INBOX", "target_mailbox": "Parent/Archive"]),
    ("flag", ["message_id": "<test@example.test>", "mailbox": "INBOX", "read": "true", "flagged": "false"]),
]
for (action, arguments) in cases {
    let script = try MailActions.buildScript(action: action, arguments: arguments)
    try script.write(to: root.appendingPathComponent(action + ".applescript"), atomically: true, encoding: .utf8)
}
SWIFT
swiftc Sources/MailActions.swift "$TMP_DIR/main.swift" -o "$TMP_DIR/generate"
"$TMP_DIR/generate" "$TMP_DIR"
for script in "$TMP_DIR"/*.applescript; do
    /usr/bin/osacompile -o "$script.scpt" "$script"
done
echo 'PASS: all 6 Mail action scripts compile; no scripts executed'
