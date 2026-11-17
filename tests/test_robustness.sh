#!/usr/bin/env ash
# CLI validation, unknown tool names, and delegate with a script path that
# contains a space.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- CLI validation (fails fast, exit 2, clear message) ---
err=$(busybox ash "$AGENT" -t abc "task" 2>&1 </dev/null); rc=$?
assert_rc 'non-integer -t rc' 2 "$rc"
assert_contains 'non-integer -t msg' 'must be a non-negative integer' "$err"
err=$(AGENT_TIMEOUT=-5 busybox ash "$AGENT" "task" 2>&1 </dev/null); rc=$?
assert_rc 'bad AGENT_TIMEOUT rc' 2 "$rc"
err=$(busybox ash "$AGENT" "task" -t 2>&1 </dev/null); rc=$?
assert_rc 'missing value rc' 2 "$rc"
assert_contains 'missing value msg' 'requires a value' "$err"
err=$(busybox ash "$AGENT" -H x "task" 2>&1 </dev/null); rc=$?
assert_rc 'non-integer -H rc' 2 "$rc"
err=$(AGENT_HTTP_TIMEOUT=-1 busybox ash "$AGENT" "task" 2>&1 </dev/null); rc=$?
assert_rc 'bad AGENT_HTTP_TIMEOUT rc' 2 "$rc"

# --- -H: a server that accepts but never answers is cut off ---
busybox timeout 20 busybox nc -l -p 19050 >/dev/null 2>&1 &
MOCK_PID=$!
sleep 1
start=$(date +%s)
err=$(busybox ash "$AGENT" -e http://127.0.0.1:19050/v1 -H 2 -w "$WORK" "task" 2>&1 </dev/null); rc=$?
elapsed=$(( $(date +%s) - start ))
assert_rc 'silent server: -H timeout rc' 1 "$rc"
assert_contains 'silent server: msg' 'HTTP POST failed' "$err"
assert_true 'silent server: cut off well before 20s' test "$elapsed" -lt 15
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=

# --- unknown tool name: reported, never run as a shell command ---
PORT=19000
cat > "$WORK/s1.json" <<'EOT'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"u1","type":"function","function":{"name":"frobnicate","arguments":"{\"command\":\"echo pwned > pwned.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
EOT
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/s1.json" "$WORK/log1.jsonl" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }
ANSWER=$(cd "$WORK" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m m -t 5 -w "$WORK" "go" 2>/dev/null)
assert_eq 'unknown tool answer' 'ok' "$ANSWER"
assert_true 'unknown tool not executed' test ! -e "$WORK/pwned.txt"
assert_true 'unknown tool reported' grep -q 'unknown tool: frobnicate' "$WORK/log1.jsonl"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null

# --- delegate: AGENT_SELF path containing a space ---
PORT=19001
mkdir -p "$WORK/my dir"
cp "$AGENT" "$WORK/my dir/agent.sh"
cat > "$WORK/s2.json" <<'EOT'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"p1","type":"function","function":{"name":"delegate","arguments":"{\"task\":\"say hi\",\"timeout\":30}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"CHILD-ANSWER"},"finish_reason":"stop"}]}
{"choices":[{"message":{"role":"assistant","content":"parent done"},"finish_reason":"stop"}]}
EOT
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/s2.json" "$WORK/log2.jsonl" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }
ANSWER=$(cd "$WORK" && AGENT_SELF="$WORK/my dir/agent.sh" busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m m -t 5 -w "$WORK" -d 1 "delegate" 2>/dev/null)
assert_eq 'delegate (space path) answer' 'parent done' "$ANSWER"
assert_true 'child answer fed back' grep -q 'CHILD-ANSWER' "$WORK/log2.jsonl"

kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null

# --- delegate timeout:0 means "no timeout" (busybox `timeout 0` kills at once) ---
# Force busybox's timeout first on PATH: the host's coreutils timeout treats 0
# as unlimited and would hide the bug.
PORT=19002
mkdir -p "$WORK/bin"
printf '#!/bin/busybox ash\nexec busybox timeout "$@"\n' > "$WORK/bin/timeout"
chmod +x "$WORK/bin/timeout"
cat > "$WORK/s3.json" <<'EOT'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"p1","type":"function","function":{"name":"delegate","arguments":"{\"task\":\"say hi\",\"timeout\":0}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"CHILD-ZERO"},"finish_reason":"stop"}]}
{"choices":[{"message":{"role":"assistant","content":"parent done"},"finish_reason":"stop"}]}
EOT
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/s3.json" "$WORK/log3.jsonl" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }
ANSWER=$(cd "$WORK" && PATH="$WORK/bin:$PATH" AGENT_SELF="$AGENT" busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m m -t 5 -w "$WORK" -d 1 "delegate" 2>/dev/null)
assert_eq 'delegate timeout:0 answer' 'parent done' "$ANSWER"
assert_true 'child ran (not killed)' grep -q 'CHILD-ZERO' "$WORK/log3.jsonl"

kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null

# --- tool call without an id still runs; an API error body is reported ---
PORT=19003
cat > "$WORK/s4.json" <<'EOT'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"type":"function","function":{"name":"shell","arguments":"{\"command\":\"echo noid > noid.txt\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
{"error":{"message":"quota exceeded"}}
EOT
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/s4.json" "$WORK/log4.jsonl" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }
ANSWER=$(cd "$WORK" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m m -t 5 -w "$WORK" "go" 2>/dev/null)
assert_eq 'id-less tool call answer' 'ok' "$ANSWER"
assert_true 'id-less tool call ran' test -e "$WORK/noid.txt"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null

PORT=19004
printf '{"error":{"message":"quota exceeded"}}\n' > "$WORK/s5.json"
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK/s5.json" "$WORK/log5.jsonl" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }
err=$(cd "$WORK" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m m -t 5 -w "$WORK" "go" 2>&1 >/dev/null); rc=$?
assert_rc 'API error rc' 1 "$rc"
assert_contains 'API error msg' 'API error: quota exceeded' "$err"

summary
