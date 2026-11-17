#!/usr/bin/env ash
# Streaming (-S / --stream / AGENT_STREAM): the model's output is streamed
# live to stderr (SSE), and the response is reassembled into a normal turn.
# Verifies: live content to stderr, tool-call fragment reassembly (arguments
# split across two chunks), and the final answer.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18993

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

busybox ash "$HERE/mock/mock_sse_server.sh" "$PORT" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'sse mock server did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK" -S \
	"do the task" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'agent exit 0' 0 "$RC"
# A "\n\n" chunk must survive reassembly (not be stripped as trailing newlines).
assert_eq 'final answer' "$(printf 'Streamed\n\nanswer.')" "$ANSWER"

# --- live content was printed to stderr as it streamed ---
assert_true 'live content on stderr' grep -q 'Let me run a command.' "$WORK/stderr.txt"

# --- the streamed tool call was reassembled and executed ---
# (arguments were split across two SSE chunks; the file must exist)
assert_true 'tool ran (file created)' test -f "$WORK/s.txt"
assert_eq 'tool output' 'streamed' "$(cat "$WORK/s.txt")"
assert_eq 'second parallel call ran' 'second' "$(cat "$WORK/s2.txt" 2>/dev/null)"

# --- the harness logged the turn ---
assert_true 'turn 1 logged' grep -q 'turn 1/5' "$WORK/stderr.txt"
assert_true 'turn 2 logged' grep -q 'turn 2/5' "$WORK/stderr.txt"

summary
