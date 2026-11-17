#!/usr/bin/env ash
# AGENT_MAX_TURNS / -t: default 0 (unlimited) and a positive cap.
# Verifies: with 0 (or no -t) the loop runs until the model answers in plain
# text (turns logged without a denominator); with a positive cap the loop
# stops after that many turns without a final answer (error + non-zero exit).
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
LOG="$WORK/log.jsonl"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- a scripted conversation: 3 tool calls, then a final plain-text answer ---
# (same shape as test_integration.sh)
cat > "$WORK/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"echo hello > out.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c2","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c3","type":"function","function":{"name":"shell","arguments":"{\"command\":\"cat out.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"Created and read back out.txt."},"finish_reason":"stop"}]}
EOF

# --- unlimited (explicit -t 0): runs to the final answer ---
PORT=18997
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/script.json" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 0 -w "$WORK" \
	"create a file, list it, read it back" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'unlimited: agent exit 0' 0 "$RC"
assert_eq 'unlimited: final answer' 'Created and read back out.txt.' "$ANSWER"
assert_true 'unlimited: turn 1 logged' grep -q 'turn 1' "$WORK/stderr.txt"
assert_true 'unlimited: turn 4 logged' grep -q 'turn 4' "$WORK/stderr.txt"
# no denominator when unlimited (the capped form is "turn 1/2", not "turn 1")
assert_false 'unlimited: no denominator' grep -q 'turn 1/' "$WORK/stderr.txt"

kill "$MOCK_PID" 2>/dev/null
MOCK_PID=""

# --- capped (-t 2): stops after 2 tool-call turns, no final answer ---
PORT=18998
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/script.json" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 2 -w "$WORK" \
	"create a file, list it, read it back" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'capped: agent exit 1' 1 "$RC"
assert_true 'capped: max-turns error' grep -q 'reached max-turns' "$WORK/stderr.txt"
assert_true 'capped: turn 1/2 logged' grep -q 'turn 1/2' "$WORK/stderr.txt"
assert_true 'capped: turn 2/2 logged' grep -q 'turn 2/2' "$WORK/stderr.txt"
assert_false 'capped: no turn 3' grep -q 'turn 3' "$WORK/stderr.txt"


kill "$MOCK_PID" 2>/dev/null
MOCK_PID=""

# --- leading zeros (-t 02 -O 0099): read as decimal, not a bad octal ---
PORT=18999
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/script.json" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 02 -O 0099 -w "$WORK" \
	"create a file, list it, read it back" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'leading zeros: exit 1 (capped)' 1 "$RC"
assert_true 'leading zeros: cap read as 2' grep -q 'turn 2/2' "$WORK/stderr.txt"
assert_false 'leading zeros: no arithmetic error' grep -q 'arithmetic' "$WORK/stderr.txt"

summary
