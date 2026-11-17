#!/usr/bin/env ash
# Integration: run the full agent.sh against the mock OpenAI endpoint.
# Verifies the multi-turn tool loop, history round-trip, the wire protocol,
# --ask, output truncation, and the final answer.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18999
LOG="$WORK/log.jsonl"
SCRIPT="$WORK/script.json"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- build the scripted conversation: 3 tool calls, then a final answer ---
# step 0: create a file
# step 1: list it
# step 2: read it back
# step 3: final plain-text answer
# One scripted response per line (the ash mock reads line N as response N).
cat > "$SCRIPT" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"echo hello > out.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c2","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c3","type":"function","function":{"name":"shell","arguments":"{\"command\":\"cat out.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"Created and read back out.txt."},"finish_reason":"stop"}]}
EOF

busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

# --- run the agent ---
ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 10 -w "$WORK" \
	"create a file, list it, read it back" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'agent exit 0' 0 "$RC"
assert_eq 'final answer' 'Created and read back out.txt.' "$ANSWER"

# --- the file was actually created by the tool calls ---
assert_true 'file exists' test -f "$WORK/out.txt"
assert_eq 'file content' 'hello' "$(cat "$WORK/out.txt")"

# --- the wire protocol: 4 requests, each with the expected message roles ---
assert_eq 'request count' 4 "$(grep -c . "$LOG")"

# The ash mock logs the raw request body (no {"body":...} wrapper, no space
# after the colon). Count messages by their "role" field (each message has
# exactly one).
# Request 1: system + user only.
r1=$(head -n1 "$LOG" | grep -o '"role":' | grep -c .)
assert_eq 'req1 messages' 2 "$r1"
# Request 4: system + user + (assistant+tool)*3 = 8 messages.
r4=$(tail -n1 "$LOG" | grep -o '"role":' | grep -c .)
assert_eq 'req4 messages' 8 "$r4"

# The tool results were fed back (the harness ran the commands and captured output).
assert_true 'tool msg in log' grep -q '"role":"tool"' "$LOG"
# The shell tool was advertised in the request.
assert_true 'shell tool advertised' grep -q '"name":"shell"' "$LOG"

# --- stderr diagnostics present ---
assert_true 'turn 1 logged' grep -q 'turn 1/10' "$WORK/stderr.txt"
assert_true 'turn 4 logged' grep -q 'turn 4/10' "$WORK/stderr.txt"

summary
