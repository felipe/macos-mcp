#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "smoke-scoped-files.sh must run on macOS" >&2
  exit 1
fi

BINARY="${1:-.build/macos-mcp-unsigned}"
PORT="${PORT:-9320}"
SECRET="${MCP_SECRET:-test-secret}"
TMP_DIR="$(mktemp -d /tmp/macos-mcp-scoped-files.XXXXXX)"
TEST_ROOT="$TMP_DIR/files"
AUDIT_LOG="$TMP_DIR/audit.log"
SERVER_LOG="$TMP_DIR/server.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT"
export ALLOWED_PATHS_JSON="{\"test\":\"$TEST_ROOT\"}"
export ALLOWED_PATHS_AUDIT_LOG_PATH="$AUDIT_LOG"

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found or not executable: $BINARY" >&2
  exit 1
fi

"$BINARY" serve --host 127.0.0.1 --port "$PORT" --mcp-secret "$SECRET" > /dev/null 2>"$SERVER_LOG" &
SERVER_PID=$!

for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
  echo "Server did not become healthy" >&2
  cat "$SERVER_LOG" >&2 || true
  exit 1
fi

call_mcp() {
  local payload="$1"
  curl -fsS \
    -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "Authorization: Bearer $SECRET" \
    -H 'Accept: application/json, text/event-stream' \
    -H 'Content-Type: application/json' \
    -d "$payload" | python3 -c '
import sys
text = sys.stdin.read()
last = None
for line in text.splitlines():
    if line.startswith("data: "):
        last = line[6:]
if last is None:
    raise SystemExit("No SSE data in response")
print(last)
'
}

call_tool() {
  local name="$1"
  local arguments_json="$2"
  local payload
  payload=$(cat <<JSON
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"$name","arguments":$arguments_json}}
JSON
)
  call_mcp "$payload" | python3 -c '
import json, sys
outer = json.load(sys.stdin)
print(outer["result"]["content"][0]["text"])
'
}

TOOLS_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
call_mcp "$TOOLS_PAYLOAD" | python3 -c '
import json, sys
outer = json.load(sys.stdin)
names = {tool["name"] for tool in outer["result"]["tools"]}
required = {"scoped_read", "scoped_write"}
missing = required - names
if missing:
    raise SystemExit(f"Missing tools: {sorted(missing)}")
'

WRITE_RESULT="$(call_tool "scoped_write" '{"path_name":"test","path":"notes/hello.md","content":"Hello world","mode":"upsert"}')"
printf '%s' "$WRITE_RESULT" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["path_name"] == "test"
assert result["written_path"] == "notes/hello.md"
assert result["sha256"]
'

READ_RESULT="$(call_tool "scoped_read" '{"path_name":"test","path":"notes/hello.md"}')"
printf '%s' "$READ_RESULT" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["content"] == "Hello world"
'

call_tool "scoped_write" '{"path_name":"test","path":"notes/page.md","content":"# Title","mode":"upsert"}' > /dev/null
call_tool "scoped_write" '{"path_name":"test","path":"notes/page.md","content":"First body","mode":"append-section","section_anchor":"deploy-target","section_heading":"Deploy Target"}' > /dev/null
call_tool "scoped_write" '{"path_name":"test","path":"notes/page.md","content":"Second body","mode":"supersede","section_anchor":"deploy-target","operation_id":"smoke-1","actor":"smoke-test"}' > /dev/null

python3 - <<PY
from pathlib import Path
content = Path("$TEST_ROOT/notes/page.md").read_text()
audit = Path("$AUDIT_LOG").read_text()
assert "## Deploy Target" in content
assert "Second body" in content
assert "## Superseded" in content
assert "First body" in content
assert '"action":"scoped_write"' in audit
print("scoped file smoke test passed")
PY
