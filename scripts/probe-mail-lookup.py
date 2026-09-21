#!/usr/bin/env python3
"""Opt-in live read-only probe. Run from the repository root; requires Mail access."""
import argparse
import json
import pathlib
import subprocess
import tempfile
import time
from urllib.parse import unquote, urlparse


def run(args, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="./.build/macos-mcp-unsigned")
    args = parser.parse_args()
    messages = json.loads(run([args.binary, "mail", "search", "--limit", "10"]).stdout)["messages"]
    for summary in messages:
        try:
            message = json.loads(run([args.binary, "mail", "read", str(summary["rowid"])]).stdout)
            if message["headers"].get("message-id"):
                break
        except subprocess.CalledProcessError:
            continue
    else:
        raise RuntimeError("No recent cached message available")
    mailbox = urlparse(summary["mailbox"])
    if not mailbox.hostname:
        raise RuntimeError("Sample has no indexed account ID")
    with tempfile.TemporaryDirectory(prefix="mail-lookup-") as tmp:
        root = pathlib.Path(tmp)
        (root / "main.swift").write_text('''import Foundation
let script = try MailActions.buildScript(action: "flag", arguments: [
    "message_id": CommandLine.arguments[1], "mailbox": CommandLine.arguments[2],
    "account_id": CommandLine.arguments[3], "lookup_id": CommandLine.arguments[4], "flagged": "true"
])
let marker = "set flagged status of targetMessage to true"
guard script.components(separatedBy: marker).count == 2 else { fatalError("Unexpected script shape") }
print(script.replacingOccurrences(of: marker, with: "return \\"matched\\""))
''')
        run(["swiftc", "Sources/MailActions.swift", str(root / "main.swift"), "-o", str(root / "probe")])
        for mismatched in (False, True):
            message_id = "<mail-lookup-mismatch@example.invalid>" if mismatched else message["headers"]["message-id"]
            script = run([str(root / "probe"), message_id, unquote(mailbox.path).strip("/"), mailbox.hostname, str(summary["rowid"])]).stdout
            # Fail closed if the generator shape changes. Only the lookup may execute.
            if any(token in script for token in ("set flagged status", "set read status", "send ", "move targetMessage", "make new")):
                raise RuntimeError("Generated probe contains an unexpected action")
            started = time.monotonic()
            result = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=15)
            passed = (result.returncode != 0 and "Message identity mismatch" in result.stderr) if mismatched else (result.returncode == 0 and result.stdout.strip() == "matched")
            print(json.dumps({"probe": "reject_mismatched_identity" if mismatched else "resolve_cached_message", "passed": passed, "elapsed_ms": round((time.monotonic() - started) * 1000)}))
            if not passed:
                raise RuntimeError("Live lookup probe failed; no mutation was attempted")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit("Live lookup probe timed out; no mutation was attempted")
    except (subprocess.CalledProcessError, RuntimeError) as error:
        # Do not echo a subprocess's argv: generated scripts contain private message IDs.
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else "Probe subprocess failed")
