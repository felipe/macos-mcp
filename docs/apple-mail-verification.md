# Apple Mail verification

The implementation was checked on 2026-09-20 and 2026-09-21 against synthetic fixtures and the local Mail cache. No test email was sent and no live message was moved, flagged, or edited.

## Evidence

- Docker Swift suite: 45 tests passed, zero failures, including existing access-control and scoped-file tests.

- Universal arm64/x86_64 binary compiled with the macOS 13 deployment target.
- Existing scoped-file MCP smoke test passed after rebasing onto current main.
- Synthetic Mail CLI/MCP smoke passed for search, reading, mailbox listing, all nine tool schemas, and invalid-action rejection.
- All six generated action scripts compiled against the installed Mail scripting dictionary. Script compilation does not verify Mail's runtime behavior or provider synchronization.
- A read-only probe of the local index counted 139,575 messages and verified the global-message join. It confirmed row-ID cache filenames and space-padded `.emlx` byte prefixes, correcting two assumptions in the original plan.
- One live latest-message search completed in 13 ms. Reading that cached body completed in 822 ms after scoping file discovery to its indexed mailbox. These are individual observations, not latency guarantees.

The initial Mail.app probe timed out. On 2026-09-21 it responded in 128 ms, and all six indexed IMAP account IDs matched Mail.app account IDs. Live lookup then exposed Gmail's omitted virtual folder root and a slow RFC Message-ID scan in All Mail. Both are addressed: account-scoped virtual-root fallback and direct numeric lookup with an RFC identity check.

The generated lookup resolved a real cached message in 1,432 ms and rejected a deliberately mismatched RFC Message-ID in 1,264 ms. The probe replaces the flag mutation with a return statement and rejects scripts containing action commands. Live mutations and delivery remain unverified; no message was changed or sent. Uncertain action results never trigger automatic retries.

## Reproduce

```sh
make test-logic-docker
make test-build
make test-mail
# Optional: live, read-only account/mailbox/message lookup; needs Mail access
python3 scripts/probe-mail-lookup.py
```

The Docker target installs SQLite development headers and runs the fixtures with Swift 6.0. The native `swift test` command could not run with this host's Command Line Tools installation because XCTest was unavailable. Native compilation and smoke checks ran separately.

The Mail smoke script creates and deletes its own synthetic index and cache. The action compilation script generates temporary AppleScript files and invokes `osacompile`, never `osascript`.
