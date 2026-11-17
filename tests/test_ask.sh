#!/usr/bin/env ash
# --ask: confirm each command (y/n/q). Feeding 'n' must DENY the command
# (it is not run) and feed "DENIED by user" back as the tool result.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18998
LOG="$WORK/log.jsonl"
SCRIPT="$WORK/script.json"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# step 0: a tool call to create a file. step 1: final answer.
# One scripted response per line (the ash mock reads line N as response N).
cat > "$SCRIPT" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"echo secret > denied.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"Done."},"finish_reason":"stop"}]}
EOF

busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

# --- DENY: feed 'n' ---
ANSWER=$(cd "$WORK" && echo 'n' | busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK" --ask \
	"create a file" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'deny exit 0' 0 "$RC"
assert_eq 'final answer after deny' 'Done.' "$ANSWER"
# The command was NOT run.
assert_false 'file not created' test -f "$WORK/denied.txt"
# The tool result was DENIED (fed back to the model).
assert_true 'DENIED in log' grep -q 'DENIED by user' "$LOG"
assert_true 'ask prompt shown' grep -q 'run: echo secret' "$WORK/stderr.txt"

# --- CONFIRM: feed 'y' (restart the server on the same port) ---
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
LOG2="$WORK/log2.jsonl"
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$LOG2" &
MOCK_PID=$!
wait_port "$PORT"
ANSWER=$(cd "$WORK" && echo 'y' | busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK" --ask \
	"create a file" 2>/dev/null)
assert_true 'file created on confirm' test -f "$WORK/denied.txt"
assert_eq 'confirm answer' 'Done.' "$ANSWER"

# --- AGENT_ASK=true (any non-empty, non-0 value) must still prompt, not fail open ---
rm -f "$WORK/denied.txt"
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$WORK/log3.jsonl" &
MOCK_PID=$!
wait_port "$PORT"
(cd "$WORK" && echo 'n' | AGENT_ASK=true busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK" \
	"create a file" >/dev/null 2>"$WORK/stderr3.txt")
assert_true 'AGENT_ASK=true prompts' grep -q 'run: echo secret' "$WORK/stderr3.txt"
assert_false 'AGENT_ASK=true denies' test -f "$WORK/denied.txt"

summary
