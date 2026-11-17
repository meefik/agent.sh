#!/usr/bin/env ash
# MCP integration over an SSE (text/event-stream) server: the mock MCP
# server answers every request with a text/event-stream body (a single
# `data:` line) instead of application/json. Verifies that mcp_http_post
# strips the SSE framing before parsing the JSON-RPC body — the branch the
# application/json mock (test_mcp_integration.sh) never exercises.
#
# The scripted conversation is identical to test_mcp_integration.sh (same
# tools, same results), so the assertions are the same: discovery,
# advertised tool schemas, and a real tools/call round-trip.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18991
MCP_PORT=18992
LOG="$WORK/log.jsonl"
SCRIPT="$WORK/script.json"
MCP_URL="http://127.0.0.1:$MCP_PORT/mcp"

cleanup() {
	[ -n "${OPENAI_PID:-}" ] && kill "$OPENAI_PID" 2>/dev/null
	[ -n "${MCP_PID:-}" ] && kill "$MCP_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# step 0: call mcp_sse_greet. step 1: call mcp_sse_add. step 2: final answer.
# One scripted response per line (the ash mock reads line N as response N).
cat > "$SCRIPT" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"mcp_sse_greet","arguments":"{\"name\":\"World\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c2","type":"function","function":{"name":"mcp_sse_add","arguments":"{\"a\":17,\"b\":25}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"Greeted and added."},"finish_reason":"stop"}]}
EOF

busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$LOG" &
OPENAI_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

busybox ash "$HERE/mock/mock_mcp_sse_server.sh" "$MCP_PORT" &
MCP_PID=$!
wait_port "$MCP_PORT" || { printf 'mcp sse mock did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 10 -w "$WORK" \
	-M "sse=$MCP_URL" \
	"greet the world, then add 17 and 25" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'agent exit 0' 0 "$RC"
assert_eq 'final answer' 'Greeted and added.' "$ANSWER"

# --- discovery happened at startup (over the SSE server) ---
assert_true 'discovery logged' grep -q 'mcp: sse — 2 tool(s)' "$WORK/stderr.txt"

# --- the MCP tools were advertised in the request ---
assert_true 'greet advertised' grep -q '"name":"mcp_sse_greet"' "$LOG"
assert_true 'add advertised'   grep -q '"name":"mcp_sse_add"'   "$LOG"

# --- the tool results (from the SSE data: line) were fed back to the model ---
assert_true 'greet result' grep -q 'hello World' "$LOG"
assert_true 'add result'   grep -q '"content":"42"' "$LOG"

summary
