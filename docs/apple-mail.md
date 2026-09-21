# Apple Mail

`macos-mcp mail` reads Mail's local Envelope Index in read-only mode and parses cached `.emlx` messages. Actions use Mail.app's scripting interface so Mail handles provider synchronization. The binary has no additional runtime dependency beyond macOS.

## Usage

```sh
macos-mcp mail mailboxes
macos-mcp mail search invoice --sender billing@example.com --since 2026-09-01 --limit 20
macos-mcp mail read 42
macos-mcp mail read --message-id '<example@example.com>' --include-html
macos-mcp mail draft --to colleague@example.com --subject Review --body 'Please review.'
macos-mcp mail send --to colleague@example.com --subject Review --body 'Please review.' --attach /absolute/path/report.pdf
macos-mcp mail reply 42 --body 'Thanks.' --all
macos-mcp mail forward 42 --to colleague@example.com --body 'For your review.'
macos-mcp mail move 42 --target-mailbox Archive --account me@example.com
macos-mcp mail flag 42 --read --unflag
```

Output is JSON. Repeat `--to`, `--cc`, `--bcc`, and `--attach` for multiple values. `--account` selects a configured sender email address. Reply and forward send immediately. Draft saves without sending. Send success means Mail accepted the message for sending, not that the provider delivered it.

## MCP contract

| Tool | Inputs |
| --- | --- |
| `mail_search` | Optional `query`, `sender`, `recipient`, `subject`, `mailbox`, `since`, `limit` |
| `mail_read` | Exactly one of `rowid`, `message_id`; optional `include_html` |
| `mail_list_mailboxes` | None |
| `mail_send` | Required `to`, `subject`, `body`; optional `cc`, `bcc`, `attachments`, `account` |
| `mail_draft` | Required `subject`, `body`; optional `to`, `cc`, `bcc`, `attachments`, `account` |
| `mail_reply` | Identifier and `body`; optional `reply_all`, `account`, `mailbox` |
| `mail_forward` | Identifier, `to`, `body`; optional `account`, `mailbox` |
| `mail_move` | Identifier and `target_mailbox`; optional `account`, `mailbox` |
| `mail_flag` | Identifier and at least one of `read`, `flagged`; optional `account`, `mailbox` |

An action identifier is exactly one of `rowid` or `message_id`. Direct RFC Message-ID actions also require `mailbox`; row ID actions derive the mailbox path from the index. Recipient and attachment inputs are arrays of strings. Boolean inputs accept JSON booleans. `limit` is an integer from 1 through 200, default 20. Invalid Mail tool calls return MCP `isError: true`.

Search matches subject and sender metadata; it does not search bodies. `sender`, `recipient`, and `subject` are literal substring filters, not SQL patterns. `since` accepts ISO 8601 or a date. Search `mailbox` is an exact URL returned by mailbox discovery. Results sort by received date and row ID, newest first. Action mailbox selectors refer to Mail.app mailbox paths. For account-scoped Gmail lookups, an absent `[Gmail]` or `[Google Mail]` virtual root falls back to the child mailbox exposed directly by Mail.app.

## Identity and cached content

SQLite row IDs, document IDs, RFC Message-IDs, and AppleScript IDs are separate identifiers. A row ID action reads the cached RFC Message-ID, uses the row ID as a direct scripting lookup hint, and verifies the returned message's RFC identity before any mutation. A mismatch fails without acting. This avoids a full Message-ID scan in large mailboxes; prefer row IDs for actions on large caches. Duplicate matches fail instead of choosing a message. Supply account and mailbox selectors to disambiguate copies. Row ID actions try the index account UUID against Mail's account ID; if that mapping fails, supply the configured sender email with `--account`. A missing body cache is an error; this implementation does not download message bodies through AppleScript.

The reader discovers the highest available `V*` directory and validates required schema columns. Apple does not publish a stable Envelope Index schema, so unsupported layouts return an error. `MAIL_DATA_DIR` can select a fixture or alternate Mail data directory and is inherited by the MCP server's CLI subprocesses.

The MIME parser returns decoded headers, plain text with HTML fallback, optional HTML, and attachment metadata. It does not export attachments or fetch remote resources. Encrypted content, detached attachments, and partially downloaded messages are not decrypted or reconstructed. Parsing and file discovery have bounds to prevent unbounded work on corrupt data or very large caches.

## Permissions and validation

Reads need Full Disk Access for the invoking process. Actions need macOS Automation permission to control Mail and an account configured in Mail.app. Keep the existing signed installation identity when granting permissions. A timeout after an action starts has an uncertain outcome; inspect Mail before retrying to avoid duplicate sends.

```sh
make test-logic     # Mail fixtures plus existing logic tests; needs an XCTest-capable Swift toolchain
make test-logic-docker # Linux fixtures with Swift and SQLite development headers
make test-build     # Universal macOS compile and existing MCP smoke test
make test-mail      # Synthetic Mail CLI/MCP smoke test; never sends email
```

Automated action tests use an injected runner and compile generated scripts against the installed Mail dictionary. They do not prove provider delivery or live Mail mutations. Live sending requires an explicitly authorized test recipient; installation and service restart are separate from these checks.

See [verification evidence and remaining live checks](apple-mail-verification.md).
