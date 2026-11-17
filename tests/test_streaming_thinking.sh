#!/usr/bin/env ash
# Streaming with reasoning (thinking) deltas: the model streams reasoning
# chunks interleaved with content. Verifies the [thinking] prefix is printed
# once per contiguous reasoning block (not per chunk), that the accumulated
# reasoning is carried back into history, and that the tool call and final
# answer are correct.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18994
LOG="$WORK/log.jsonl"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

busybox ash "$HERE/mock/mock_sse_thinking_server.sh" "$PORT" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'sse thinking mock server did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK" -S \
	"do the task" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'agent exit 0' 0 "$RC"
assert_eq 'final answer' 'Streamed answer.' "$ANSWER"

# --- the streamed tool call was reassembled and executed ---
assert_true 'tool ran (file created)' test -f "$WORK/s.txt"
assert_eq 'tool output' 'streamed' "$(cat "$WORK/s.txt")"

# --- the [thinking] prefix is printed once per reasoning block ---
# (two blocks, one per turn; two reasoning chunks each)
assert_eq 'one prefix per thinking block' 2 "$(grep -c '\[thinking\]' "$WORK/stderr.txt")"

# --- chunks within a block are not re-prefixed ---
assert_true 'first block contiguous' grep -q '\[thinking\] Let me think. I need to check the file.' "$WORK/stderr.txt"
assert_true 'second block contiguous' grep -q '\[thinking\] The result is streamed.' "$WORK/stderr.txt"

# --- the accumulated reasoning was carried back into history ---
assert_true 'reasoning in history' grep -q 'Let me think. I need to check the file.' "$LOG"

summary
