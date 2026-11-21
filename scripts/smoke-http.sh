#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary=${1:-dist/MailMCP.app/Contents/MacOS/MailMCP}
port=${MAILMCP_TEST_PORT:-18765}
url="http://127.0.0.1:$port/mcp"
token=$(openssl rand -hex 32)
work=$(mktemp -d)
mkdir -p "$work/state"
cat > "$work/state/moves.jsonl" <<'AUDIT_FIXTURE'
{"operationId":"12345678-1234-1234-1234-123456789012","at":"2020-01-01T00:00:00Z","status":"verified"}
AUDIT_FIXTURE
python3 - >> "$work/state/moves.jsonl" <<'BATCH_FIXTURE'
from datetime import datetime, timezone
import json
for message in (2, 3):
    print(json.dumps({
        "operationId": f"20000000-0000-4000-8000-{message:012d}",
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": "verified", "destinationId": message + 20,
        "source": {"accountId": None, "path": ["Source"]},
        "destination": {"accountId": "test-account", "path": ["Archive"]},
        "id": message, "messageId": f"message-{message}",
    }))
BATCH_FIXTURE
MAILMCP_PORT=$port MAILMCP_TOKEN=$token MAILMCP_STATE_DIR="$work/state" MAILMCP_TRACE_STDERR=1 \
    "$binary" >"$work/server.log" 2>&1 &
pid=$!
trap 'result=$?; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; if (( result != 0 )); then cat "$work/server.log"; fi; rm -rf "$work"' EXIT

for _ in {1..50}; do
    if grep -q 'listening' "$work/server.log"; then break; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$work/server.log"; exit 1; fi
    sleep 0.1
done

auth="Authorization: Bearer $token"
post() {
    curl -fsS --max-time 10 -H "$auth" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' "$@" "$url"
}
status() {
    curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$@" "$url"
}

[[ $(status) == 401 ]]
[[ $(status -H "$auth") == 405 ]]
[[ $(status -H "$auth" -H 'Origin: https://example.org') == 403 ]]
[[ $(status -H "$auth" -H "Host: example.org:$port") == 403 ]]
post --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}' |
    python3 -c 'import json,sys; result=json.load(sys.stdin)["result"]; assert result["protocolVersion"] == "2025-11-25" and result["serverInfo"]["version"] == "0.5.0"'
post --data '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' |
    python3 -c 'import json,sys; tools={t["name"]: t for t in json.load(sys.stdin)["result"]["tools"]}; assert set(tools) == {"list_mailboxes", "list_messages", "search_messages", "find_similar_messages", "move_message", "move_messages", "get_move_status"}; assert tools["move_messages"]["inputSchema"]["properties"]["moves"]["maxItems"] == 50 and {tuple(x["required"]) for x in tools["search_messages"]["inputSchema"]["anyOf"]} == {("query",), ("to",), ("cc",)}'
post -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
    --data '{"jsonrpc":"2.0","id":3,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' |
    python3 -c 'import json,sys; assert set(json.load(sys.stdin)["result"]["capabilities"]) == {"tools", "prompts"}'
post --data '{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"find_mail","arguments":{"query":"smoke test"}}}' |
    python3 -c 'import json,sys; assert "smoke test" in json.load(sys.stdin)["result"]["messages"][0]["content"]["text"]'
post --data '{"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name":"file_mail","arguments":{"request":"smoke test"}}}' |
    python3 -c 'import json,sys; prompt=json.load(sys.stdin)["result"]["messages"][0]["content"]["text"]; assert "get_move_status" in prompt and "operationId" in prompt and "unknown outcome" in prompt'
post --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_mailboxes","arguments":{"test":false}}}' |
    python3 -c 'import json,sys; lines=sys.stdin.read().splitlines(); assert lines[0]==": connected"; response=json.loads(next(line[6:] for line in lines if line.startswith("data: "))); assert response["id"]==4 and response["result"]["isError"]'
python3 - "$port" "$token" <<'PYTEST'
import json
import socket
import sys
import time
import urllib.error
import urllib.request

port, token = sys.argv[1:]
headers = {
    "Host": f"127.0.0.1:{port}",
    "Authorization": f"Bearer {token}",
    "Accept": "application/json, text/event-stream",
    "Content-Type": "application/json",
}
def call(name, arguments):
    return json.dumps({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments}}).encode()

def assert_rpc_rejection(message, expected_code, extra_headers=None):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=json.dumps(message).encode(),
                                    headers={**headers, **(extra_headers or {})})
    try:
        urllib.request.urlopen(request, timeout=5).close()
    except urllib.error.HTTPError as error:
        assert error.code == 400
        assert json.load(error)["error"]["code"] == expected_code
    else:
        raise AssertionError("Malformed MCP request was accepted")

modern_headers = {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "ping"}
ping = {"jsonrpc": "2.0", "id": 7, "method": "ping", "params": {"_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
}}}
assert_rpc_rejection(ping, -32020, {"Mcp-Method": "ping"})
assert_rpc_rejection({**ping, "id": None}, -32600, modern_headers)
assert_rpc_rejection({**ping, "params": {"_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
}}}, -32602, modern_headers)

with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as conn:
    body = call("list_mailboxes", {"unexpected": True})
    fields = {**headers, "Content-Length": str(len(body))}
    header = "POST /mcp HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in fields.items()) + "\r\n"
    conn.sendall(header.encode() + body)
    conn.shutdown(socket.SHUT_WR)
    with conn.makefile("rb") as reply:
        response = reply.read()
    assert b"X-MailMCP-Trace-ID:" in response
    message = next(json.loads(line[6:]) for line in response.splitlines() if line.startswith(b"data: "))
    assert message["result"]["isError"] and message["id"] == 7

request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
                                data=call("get_move_status", {"operationId": "invalid-uuid"}), headers=headers)
with urllib.request.urlopen(request, timeout=5) as response:
    assert response.headers.get_content_type() == "application/json"
    assert response.headers.get("X-MailMCP-Trace-ID")
    assert json.load(response)["result"]["isError"]

expired_id = "12345678-1234-1234-1234-123456789012"
request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
                                data=call("get_move_status", {"operationId": expired_id}), headers=headers)
for _ in range(30):
    with urllib.request.urlopen(request, timeout=5) as response:
        status = json.load(response)["result"].get("structuredContent", {})
    if status.get("status") == "expired":
        assert status == {"operationId": expired_id.upper(), "status": "expired", "safeToRetry": False}
        break
    time.sleep(0.1)
else:
    raise AssertionError("Startup journal maintenance did not expire a legacy operation")

batch = [{
    "operationId": f"20000000-0000-4000-8000-{message:012d}",
    "source": {"accountId": None, "path": ["Source"]},
    "destination": {"accountId": "test-account", "path": ["Archive"]},
    "id": message, "messageId": f"message-{message}",
} for message in (3, 2)]
request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
                                data=call("move_messages", {"moves": batch}), headers=headers)
with urllib.request.urlopen(request, timeout=5) as response:
    assert response.headers.get_content_type() == "application/json"
    operations = json.load(response)["result"]["structuredContent"]["operations"]
    assert [r["destinationId"] for r in operations] == [23, 22]
    assert [r["operationId"] for r in operations] == [r["operationId"] for r in batch]

invalid_batch = [batch[0], {key: value for key, value in batch[1].items() if key != "operationId"}]
request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
                                data=call("move_messages", {"moves": invalid_batch}), headers=headers)
with urllib.request.urlopen(request, timeout=5) as response:
    result = json.load(response)["result"]
    assert result["isError"] and "moves[1]" in result["content"][0]["text"]
PYTEST
printf 'HTTP smoke checks passed.\n'
