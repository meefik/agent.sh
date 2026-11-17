#!/usr/bin/env ash
# Skills, AGENTS.md, and output truncation.
#
# Skills: a .agents/skills/ dir in the workdir adds a skill(name) tool and a skill
# list in the system prompt. The model can load a skill; an unknown name
# returns an error listing the available skills.
#
# AGENTS.md: if present in the workdir, its content is appended to the
# system prompt.
#
# Truncation: command output is truncated to -O / AGENT_MAX_OUTPUT bytes.
. "$(dirname "$0")/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent.sh"
WORK="$(mktemp -d)"
PORT=18996
LOG="$WORK/log.jsonl"
SCRIPT="$WORK/script.json"

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- set up a skill ---
mkdir -p "$WORK/.agents/skills/protocol"
printf 'name: protocol\ndescription: Answer in the PROTOCOL format.\n\nAlways start your answer with "PROTOCOL OK".\n' \
	> "$WORK/.agents/skills/protocol/SKILL.md"

# --- AGENTS.md ---
printf 'CERTIFIED: every answer must start with the word CERTIFIED.\n' > "$WORK/AGENTS.md"

# step 0: load the skill. step 1: final answer.
# One scripted response per line (the ash mock reads line N as response N).
cat > "$SCRIPT" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"skill","arguments":"{\"name\":\"protocol\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"PROTOCOL OK"},"finish_reason":"stop"}]}
EOF

busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$SCRIPT" "$LOG" &
MOCK_PID=$!
wait_port "$PORT" || { printf 'mock server did not start\n'; exit 1; }

ANSWER=$(cd "$WORK" && busybox ash "$AGENT" \
	-e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK" \
	"answer the question" 2>"$WORK/stderr.txt")
RC=$?
assert_rc 'agent exit 0' 0 "$RC"
assert_eq 'final answer' 'PROTOCOL OK' "$ANSWER"

# --- the skill tool was advertised (skills present) ---
assert_true 'skill tool advertised' grep -q '"name":"skill"' "$LOG"
# --- the skill list went into the system prompt ---
assert_true 'skill list in prompt' grep -q 'Available skills' "$LOG"
assert_true 'protocol listed' grep -q 'protocol' "$LOG"
# --- the skill content was loaded (tool result) ---
assert_true 'skill content loaded' grep -q 'PROTOCOL format' "$LOG"
# --- AGENTS.md was loaded into the system prompt ---
assert_true 'AGENTS.md loaded' grep -q 'CERTIFIED' "$LOG"
assert_true 'AGENTS.md logged' grep -q 'loaded AGENTS.md' "$WORK/stderr.txt"

# --- skill validation: unknown name -> error listing available skills ---
# (unit-level: load_skill is tested in test_command.sh; here we check the
#  harness advertises the tool only when skills are present)
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

# --- no skills dir -> no skill tool ---
WORK2="$(mktemp -d)"
LOG2="$WORK2/log.jsonl"
cat > "$WORK2/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
EOF
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK2/script.json" "$LOG2" &
MOCK_PID=$!
wait_port "$PORT"
cd "$WORK2" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK2" "hi" >/dev/null 2>&1
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
assert_false 'no skill tool without skills' grep -q '"name":"skill"' "$LOG2"
rm -rf "$WORK2"

# --- output truncation: -O limits command output ---
WORK3="$(mktemp -d)"
LOG3="$WORK3/log.jsonl"
cat > "$WORK3/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"printf 'AAAAAAAAAAAAAAAAAAAA'\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
EOF
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK3/script.json" "$LOG3" &
MOCK_PID=$!
wait_port "$PORT"
cd "$WORK3" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK3" -O 5 "hi" >/dev/null 2>&1
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
# The tool result in the log should be truncated to 5 bytes.
trunc=$(grep -o '"content":"AAAA[^"]*"' "$LOG3" | head -n1 | sed 's|"content":"||; s|"$||')
assert_eq 'truncated to 5 bytes' 'AAAAA\n[output truncated]' "$trunc"
rm -rf "$WORK3"

# --- default cap is 16384 bytes; -O 0 is unlimited ---
for OPT in "" "-O 0"; do
WORK4="$(mktemp -d)"
LOG4="$WORK4/log.jsonl"
cat > "$WORK4/script.json" <<'EOT'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"head -c 20000 /dev/zero | tr '\\0' A\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
EOT
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK4/script.json" "$LOG4" &
MOCK_PID=$!
wait_port "$PORT"
cd "$WORK4" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK4" $OPT "hi" >/dev/null 2>&1
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
full=$(grep -o '"content":"A[A]*[^"]*"' "$LOG4" | head -n1 | sed 's|"content":"||; s|"$||')
if [ -z "$OPT" ]; then
	assert_eq 'default cap: 16384 bytes + marker' "$(printf '%016384d' 0 | tr 0 A)"'\n[output truncated]' "$full"
else
	assert_eq '-O 0 unlimited: 20000 bytes' 20000 "${#full}"
fi
rm -rf "$WORK4"
done

# --- -w: commands run in the workdir, not the launch directory ---
WORK7="$(mktemp -d)"; LAUNCH7="$(mktemp -d)"
LOG7="$WORK7/log.jsonl"
cat > "$WORK7/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"pwd\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
EOF
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK7/script.json" "$LOG7" &
MOCK_PID=$!
wait_port "$PORT"
cd "$LAUNCH7" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK7" "hi" >/dev/null 2>&1
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
real7=$(cd "$WORK7" && pwd)
assert_true 'pwd is the workdir' grep -qF "\"content\":\"$real7\"" "$LOG7"
rm -rf "$WORK7" "$LAUNCH7"
cd "$HERE"

# --- a custom prompt without the $SKILL_LIST token gets no skills section ---
WORK5="$(mktemp -d)"
LOG5="$WORK5/log.jsonl"
mkdir -p "$WORK5/.agents/skills/protocol"
printf 'name: protocol\ndescription: unique-skill-desc\n' > "$WORK5/.agents/skills/protocol/SKILL.md"
cat > "$WORK5/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
EOF
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK5/script.json" "$LOG5" &
MOCK_PID=$!
wait_port "$PORT"
cd "$WORK5" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK5" -p 'custom prompt' "hi" >/dev/null 2>&1
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
assert_false 'custom prompt: no skill list' grep -q 'unique-skill-desc' "$LOG5"
assert_true 'custom prompt: skill tool still present' grep -q '"name":"skill"' "$LOG5"
rm -rf "$WORK5"

# --- a failing command reports its exit status; a >128 KiB request body
#     (past the argv limit) still goes through ---
WORK6="$(mktemp -d)"
LOG6="$WORK6/log.jsonl"
cat > "$WORK6/script.json" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"head -c 200000 /dev/zero | tr '\\0' A; exit 3\"}"}}]},"finish_reason":"tool_calls"}]}
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
EOF
busybox ash "$HERE/mock/mock_server.sh" "$PORT" "$WORK6/script.json" "$LOG6" &
MOCK_PID=$!
wait_port "$PORT"
ANSWER=$(cd "$WORK6" && busybox ash "$AGENT" -e "http://127.0.0.1:$PORT/v1" -m testmodel -t 5 -w "$WORK6" "hi" 2>/dev/null)
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
assert_eq 'large body: final answer' 'done' "$ANSWER"
assert_true 'exit status reported' grep -q 'exit status: 3' "$LOG6"
rm -rf "$WORK6"

summary
