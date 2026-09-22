# Mail contract v1 and Himalaya compatibility

The Mail API now separates accounts, mailboxes, envelopes, message content, flags, and attachment metadata. Apple Mail remains the backend: SQLite and `.emlx` for reads, Mail.app for actions. The nine existing `mail_*` tools and their CLI commands retain their contracts.

## Shared contract

| Tools | Behavior |
| --- | --- |
| `mail_capabilities` | Contract version, supported tools, compatibility pin and limitations |
| `mail_account_list` | Indexed account IDs and configured aliases |
| `mail_mailbox_list` | Mailbox IDs and paths within one account |
| `mail_envelope_list`, `mail_envelope_search` | Metadata only; consistent envelope objects and pagination |
| `mail_message_read` | Cached body, headers, optional HTML and attachments; no Seen mutation |
| `mail_attachment_list` | Cached MIME attachment metadata; no file export |
| `mail_message_draft` | Save a new draft without sending |
| `mail_message_send`, `mail_message_reply`, `mail_message_forward` | Preview by default; `confirm: true` sends |
| `mail_message_move` | Move within the selected account |
| `mail_flag_add`, `mail_flag_remove` | Set/clear `Seen` and `Flagged` |

Use `account` consistently across reads and actions. It accepts an indexed account ID from discovery or an alias configured below. Omission works only when exactly one account is indexed. Mailbox selectors accept the full ID URL or the exact path returned by discovery. They default to `INBOX`; messages in other folders require that folder explicitly. Missing or ambiguous accounts/mailboxes fail instead of choosing a match.

Envelopes contain `id`, `account`, `mailbox`, `subject`, `from.addr`, `date`, and `flags`. `date` is the local received date. The opaque `am1.` ID includes an identity snapshot and is checked against the selected account/mailbox and current index. Clients must return it unchanged. It is neither an IMAP UID nor an RFC Message-ID. Moves, reindexing, or changed identity invalidate it; list again to obtain a new ID. It is not a secret or an authorization token.

Listings use `page` starting at 1 and `page_size` from 1 to 200, default 25. Pages sort by received date then row ID, descending, and return `has_more`. Page numbers are bounded at 1,000,000. Pagination reflects the current local index, not a frozen snapshot; concurrent mail arrivals or moves can shift pages.

Shared search accepts literal `sender`, `recipient`, `subject`, inclusive `since`, and boolean `read`/`flagged` filters. Filters combine with AND. It does not search bodies. Unsupported inputs fail rather than silently changing the search.

Send/reply/forward previews do not save drafts or invoke Mail.app. `confirm: true` is an explicit send instruction. A successful action reports `queued`, not delivery. An uncertain result must not be retried automatically. Reply/forward use Mail.app's native threading and quoting; their preview describes the supplied action and body, not the final MIME message. `mail_message_draft` saves a new draft, not a reply template.

## Account aliases and senders

Set this environment variable on the CLI or MCP server:

```sh
export MACOS_MAIL_ACCOUNTS_JSON='{"work":{"id":"INDEXED-ACCOUNT-ID","email":"me@example.com"}}'
```

Obtain the ID with `mail_account_list`. The alias is available to every new tool, including the compatibility adapter. `email` is the sender address Mail.app has configured for that account. New-message sending and drafting require a configured sender. Message actions use the configured email to resolve Mail.app's account, or the indexed account ID if no email is configured. An alias can be used to bridge storage IDs that differ from Mail.app account IDs. An alias colliding with another indexed ID fails.

These aliases do not load Himalaya's TOML configuration or credentials. Mail.app owns provider authentication and synchronization.

## Pinned MCP adapter

The compatibility target is [Data-Wise/himalaya-mcp 2.1.2](https://github.com/Data-Wise/himalaya-mcp/tree/cc6b9a7e9ed8eee2921d4ce0585a4b7c54852158), commit `cc6b9a7e9ed8eee2921d4ce0585a4b7c54852158`. This is a supported subset of its MCP input shapes and text responses, not a replacement for the Himalaya CLI or its entire MCP server.

| Compatibility tool | Inputs | Supported behavior |
| --- | --- | --- |
| `list_emails` | `folder`, `page_size`, `page`, `account` | Envelope lines with opaque IDs |
| `search_emails` | `query`, `folder`, `account` | Metadata grammar below; default page of 25 |
| `read_email` | `id`, `folder`, `account` | Cached plain text, without marking Seen |
| `read_email_html` | `id`, `folder`, `account` | Cached HTML or empty-body text |
| `list_folders` | `account` | Folder names |
| `flag_email` | `id`, `flags`, `action`, `folder`, `account` | `add`/`remove`, only `Seen`/`Flagged` |
| `move_email` | `id`, `target_folder`, `folder`, `account` | Move within the account |
| `compose_email` | `to`, `subject`, `body`, `cc`, `bcc`, `attachments`, `confirm`, `account` | Plain-text new email; preview before confirmation |

`id`, `query`, and action-specific fields are required as appropriate; scope and pagination fields are optional. `compose_email` accepts comma-separated bare addresses in recipient strings. Display-name address parsing and MML composition are not supported. Success text deliberately says queued, not delivered. Attachment paths appear in previews; Mail actions validate files before sending.

Supported query examples:

```text
invoice
from alice and subject quarterly\ report
subject "quarterly report" and flag Flagged order by date desc
```

Bare words search subjects. Supported clauses are `from`, `to`, `subject`, and `flag`, joined by explicit `and`. Only `Seen` and `Flagged` are supported. Backslash escapes and quoted values preserve spaces. Only `order by date desc` is supported. Repeated fields, body/date clauses, `or`, `not`, grouping, and other sorts fail. Use shared search's `since` for date filtering. This restricted grammar does not claim full Himalaya filter compatibility.

The adapter returns upstream-style MCP text for supported operations and `{ "error": { "code": "unknown", "message": "...", "recoverable": false } }` with `isError: true` on failure. Backend-specific error taxonomy, exact preview formatting, attachment indicators on envelopes, provider fetching, `send_email` MML templates, `draft_reply`, folder creation/deletion, attachment downloads, prompts/resources, and all other upstream tools are outside this subset. These tools are not advertised. Existing Himalaya IDs cannot be reused; discover IDs through this server.

## CLI access and permissions

The shared contract and adapter also have a JSON CLI entry point:

```sh
macos-mcp mail api mail_capabilities '{}'
macos-mcp mail api mail_account_list '{}'
macos-mcp mail api mail_envelope_list '{"account":"work","page_size":25}'
macos-mcp mail api search_emails '{"account":"work","query":"subject invoice"}'
```

CLI results are JSON. Compatibility responses wrap their text in `{ "text": "..." }`; the MCP endpoint unwraps that text into its content block.

Every MCP tool passes through the centralized permission gate before dispatch. Only reads are enabled by the missing-policy default. A configured policy must explicitly grant each tool, including aliases. Granting `mail_send` does not grant `compose_email` or `mail_message_send`. A preview-capable send tool remains classified as a mutation, so it requires a grant even for previews. No policy is changed automatically.

Run `make test-logic-docker`, `make test-mail`, and `make test-permissions`. Fixture tests cover pagination, account/folder scope, stale IDs, compatible text, unsupported search/flags, preview versus confirmed action dispatch, and permission isolation. They use injected action handlers and synthetic mail. They do not send live email or establish provider delivery.
