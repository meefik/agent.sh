#!/usr/bin/env ash
# Sub-agents (delegate): the model spawns a nested agent.sh to work a
# sub-task; the child's final answer is the tool result.
#
# The parent and child both POST to the same mock endpoint (the child
# inherits AGENT_ENDPOINT), so the request log interleaves their turns:
#   n=1  parent: delegate call
#   n=2  child:  first tool call
#   n=3  child:  final answer
#   n=4  parent: final answer
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18995
LOG="$WORK/log.jsonl"
SCRIPT="$WORK/script.json"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	[ -n "${MCP_PID:-}" ] && kill "$MCP_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# One scripted response per line (the ash mock reads line N as response N).
# The parent and child both POST to the same mock, so the requests interleave:
#   1: parent delegate call, 2: child shell, 3: child final, 4: parent final.
cat > "$SCRIPT" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"p1","type":"function","function":{"name":"delegate","arguments":"{\"task\":\"create a file called sub.txt with the text sub and read it back\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"echo sub > sub.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"sub.txt contains sub"},"finish_reason":"stop"}]}
{"choices":[{"message":{"role":"assistant","content":"Sub-agent finished."},"finish_reason":"stop"}]}
EOF

busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

MCP_PORT=18994
busybox ash "$HERE/mock/mock_mcp_http_server.sh" "$MCP_PORT" &
MCP_PID=$!
wait_port "$MCP_PORT" || { printf 'mcp mock did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && AGENT_SELF="$AGENT" busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 10 -w "$WORK" -d 1 \
	-M "math=http://127.0.0.1:$MCP_PORT/mcp" \
	"delegate the sub-task" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'agent exit 0' 0 "$RC"
assert_eq 'final answer' 'Sub-agent finished.' "$ANSWER"

# --- the child actually ran its command (file created in the workdir) ---
assert_true 'child file created' test -f "$WORK/sub.txt"
assert_eq 'child file content' 'sub' "$(cat "$WORK/sub.txt")"

# --- the delegate tool was advertised (AGENT_SELF set + depth>0) ---
assert_true 'delegate advertised' grep -q '"name":"delegate"' "$LOG"

# --- the child's final answer was fed back as the tool result ---
assert_true 'child answer as tool result' grep -q 'sub.txt contains sub' "$LOG"

# --- the depth guard: a child at depth 0 cannot delegate further ---
# (the child ran with AGENT_DEPTH = parent_depth - 1 = 0, so its request
#  must NOT advertise the delegate tool)
# The child's request is the 2nd log line.
child_req=$(sed -n '2p' "$LOG")
if printf '%s\n' "$child_req" | grep -q '"name":"delegate"'; then
	FAIL=$((FAIL + 1)); printf 'FAIL (expected false): no delegate at depth 0\n' >&2
else
	PASS=$((PASS + 1))
fi

# --- the child inherited AGENT_MCP (re-discovered the parent's servers) ---
if printf '%s\n' "$child_req" | grep -q '"name":"mcp_math_add"'; then
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1)); printf 'FAIL: child has mcp tools\n' >&2
fi

summary
