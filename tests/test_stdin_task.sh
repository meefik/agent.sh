#!/usr/bin/env ash
# Task from piped stdin: `cat task.md | busybox ash agent.sh`.
# Verifies: with no CLI task / AGENT_TASK the task is read from stdin and sent
# as the user message; a CLI task wins over stdin; an empty stdin is a usage error.
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

cat > "$WORK/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
EOF

PORT=19051
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/script.json" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

printf 'STDIN-TASK-MARKER line1\nline2\n' > "$WORK/task.md"
ANSWER=$(cat "$WORK/task.md" | busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -w "$WORK" 2>/dev/null)
RC=$?
assert_rc 'stdin task: exit 0' 0 "$RC"
assert_eq 'stdin task: answer' 'ok' "$ANSWER"
assert_true 'stdin task: sent as user message' grep -q 'STDIN-TASK-MARKER line1\\nline2' "$LOG"

# a CLI task wins; stdin is ignored
: > "$LOG"
cat "$WORK/task.md" | busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -w "$WORK" "CLI-TASK" >/dev/null 2>&1
assert_true 'cli task: used' grep -q 'CLI-TASK' "$LOG"
assert_false 'cli task: stdin ignored' grep -q 'STDIN-TASK-MARKER' "$LOG"

# empty stdin and no task: usage error
busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" </dev/null >/dev/null 2>&1
assert_rc 'empty stdin: exit 2' 2 "$?"

summary
