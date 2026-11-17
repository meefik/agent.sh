# run_command (env scrub, timeout incl. 0=unlimited), truncate_output
# (0=unlimited / positive cap), load_skill (validation, no max-output
# truncation), ask_prompt (y/n/q), extract_command, parse_response,
# build_tools, build_request.
. "$(dirname "$0")/lib.sh"

load_fn run_command truncate_output load_skill ask_prompt extract_command flat_val parse_response get_tc_id get_tc_name get_tc_args get_tc_args_obj build_tools build_request add_msg json_escape json_unescape build_params param_value_json is_json_number
load_json
# Globals normally set at agent.sh top level (run_command / load_skill rely on them).
CMD_TIMEOUT=60
MAX_OUTPUT=8000
EXEC_SHELL=sh

# --- run_command: basic execution (stdout+stderr combined) ---
out=$(run_command 'echo hello')
assert_eq 'stdout' 'hello' "$out"
out=$(run_command 'echo out; echo err >&2')
assert_contains 'stderr combined' 'err' "$out"
assert_contains 'stdout combined' 'out' "$out"

# --- run_command: env scrub (AGENT_* removed from the child) ---
out=$(AGENT_KEY=SECRET AGENT_TASK=TOPSECRET AGENT_ENDPOINT=http://x \
  run_command 'echo KEY=${AGENT_KEY:-none} TASK=${AGENT_TASK:-none} EP=${AGENT_ENDPOINT:-none}')
assert_eq 'scrubbed' 'KEY=none TASK=none EP=none' "$out"

# --- run_command: timeout kills a long sleep (exit 124) ---
CMD_TIMEOUT=1
out=$(run_command 'sleep 10')
rc=$?
assert_rc 'timeout rc' 124 "$rc"

# --- run_command: CMD_TIMEOUT=0 is unlimited (no timeout wrapper) ---
# A short sleep must complete (not be killed) when the timeout is 0.
CMD_TIMEOUT=0
out=$(run_command 'sleep 1; echo done')
rc=$?
assert_rc 'unlimited rc' 0 "$rc"
assert_eq 'unlimited ran' 'done' "$out"

# --- run_command: stdin is /dev/null (a command can't eat the script/answers) ---
CMD_TIMEOUT=0
out=$(printf 'stolen' | run_command 'cat; echo end')
assert_eq 'stdin isolated' 'end' "$out"

# --- run_command: timeout kills the whole process group, not just the shell ---
CMD_TIMEOUT=1 MAX_OUTPUT=0
s=$(date +%s); out=$(run_command 'sleep 30; echo x'); rc=$?
assert_rc 'timeout kills child: rc' 124 "$rc"
assert_true 'timeout kills child: fast' test "$(( $(date +%s) - s ))" -lt 10
# A background job that keeps the output pipe open must not hang the agent.
s=$(date +%s); out=$(run_command 'sleep 30 &'); rc=$?
assert_true 'bg pipe holder cut off at timeout' test "$(( $(date +%s) - s ))" -lt 10
# ...but a backgrounded job with its output redirected survives the command.
out=$(run_command 'sleep 31 >/dev/null 2>&1 & echo started')
assert_eq 'bg job (redirected) returns at once' 'started' "$out"
pkill -x -f 'sleep 31' 2>/dev/null

# --- run_command: the exit status survives output truncation ---
CMD_TIMEOUT=0 MAX_OUTPUT=5
out=$(run_command 'echo 0123456789; exit 3'); rc=$?
assert_rc 'truncated: rc' 3 "$rc"
assert_contains 'truncated: status kept' '[exit status: 3]' "$out"
assert_contains 'truncated: output capped' '01234' "$out"
MAX_OUTPUT=8000

# --- truncate_output: 0 = unlimited (full output) ---
MAX_OUTPUT=0
out=$(printf 'hello world' | truncate_output)
assert_eq 'truncate unlimited' 'hello world' "$out"

# The marker truncate_output appends when it cuts.
M="
[output truncated]"

# --- truncate_output: never cuts a UTF-8 character in half ---
MAX_OUTPUT=3
out=$(printf 'ab\303\251' | truncate_output)
assert_eq 'utf8 cut mid-char dropped' "ab$M" "$out"
MAX_OUTPUT=4
out=$(printf 'ab\303\251' | truncate_output)
assert_eq 'utf8 exact fit kept' "$(printf 'ab\303\251')" "$out"
MAX_OUTPUT=3
out=$(printf 'a\344\270\255b' | truncate_output)
assert_eq 'utf8 3-byte partial dropped' "a$M" "$out"
MAX_OUTPUT=2
out=$(printf 'ab\303\251' | truncate_output)
assert_eq 'utf8 ascii cut clean' "ab$M" "$out"

# --- truncate_output: positive value caps to N bytes ---
MAX_OUTPUT=5
out=$(printf 'hello world' | truncate_output)
assert_eq 'truncate 5' "hello$M" "$out"
MAX_OUTPUT=8000
out=$(printf 'short' | truncate_output)
assert_eq 'truncate no-op under cap' 'short' "$out"
# A writer producing more than the cap must not be killed by SIGPIPE.
MAX_OUTPUT=10 CMD_TIMEOUT=0
run_command 'seq 1 20000; exit $?' >/dev/null; assert_rc 'big output: writer not SIGPIPEd' 0 "$?"
MAX_OUTPUT=8000

# --- load_skill: validation (rejects traversal / bad names) ---
WORKDIR=$(pwd)
SKILL_LIST='- alpha — the alpha skill'
out=$(load_skill ''); assert_rc 'empty name' 1 "$?"; assert_contains 'empty name msg' 'invalid skill name' "$out"
out=$(load_skill '..'); assert_rc 'dotdot' 1 "$?"; assert_contains 'dotdot msg' 'invalid skill name' "$out"
out=$(load_skill 'a/b'); assert_rc 'slash' 1 "$?"; assert_contains 'slash msg' 'invalid skill name' "$out"
out=$(load_skill 'a b'); assert_rc 'space' 1 "$?"; assert_contains 'space msg' 'invalid skill name' "$out"
# Valid name but missing file.
out=$(load_skill 'alpha'); assert_rc 'missing file' 1 "$?"; assert_contains 'missing file msg' 'skill not found' "$out"
assert_contains 'lists available' 'alpha' "$out"

# --- load_skill: success (reads SKILL.md in full, no max-output cap) ---
mkdir -p "$WORKDIR/.agents/skills/alpha"
printf 'alpha skill body\nline two\n' > "$WORKDIR/.agents/skills/alpha/SKILL.md"
out=$(load_skill 'alpha')
assert_rc 'load ok' 0 "$?"
assert_eq 'full content' 'alpha skill body
line two' "$out"
# A skill is the user's own file (not model output), so MAX_OUTPUT does not
# truncate it: even a small cap leaves the content intact.
MAX_OUTPUT=5
out=$(load_skill 'alpha')
assert_eq 'not truncated by MAX_OUTPUT' 'alpha skill body
line two' "$out"
rm -rf "$WORKDIR/.agents"

# --- ask_prompt: y/n/q (reads stdin) ---
out=$(echo 'y' | ask_prompt 'rm -rf /' 2>&1); assert_rc 'ask y' 0 "$?"
out=$(echo 'n' | ask_prompt 'rm -rf /' 2>&1); assert_rc 'ask n' 1 "$?"
out=$(echo 'q' | ask_prompt 'rm -rf /' 2>&1); assert_rc 'ask q' 2 "$?"
out=$(echo 'yes' | ask_prompt 'x' 2>&1); assert_rc 'ask yes' 0 "$?"
out=$(echo 'no' | ask_prompt 'x' 2>&1); assert_rc 'ask no' 1 "$?"
out=$(echo 'quit' | ask_prompt 'x' 2>&1); assert_rc 'ask quit' 2 "$?"
out=$(echo 'junk' | ask_prompt 'x' 2>&1); assert_rc 'ask junk' 1 "$?"  # falls through to n
# EOF (no input) -> n.
out=$(ask_prompt 'x' </dev/null 2>&1); assert_rc 'ask eof' 1 "$?"

# --- extract_command: pull .command from a tool-call arguments JSON string ---
# String-form arguments (double-encoded: outer + inner).
args='{"command":"echo hello"}'
assert_eq 'extract plain' 'echo hello' "$(extract_command "$args")"
args='{"command":"echo \"quoted\""}'
assert_eq 'extract quoted' 'echo "quoted"' "$(extract_command "$args")"
# args holds a JSON-escaped string; single backslash = the JSON escape.
args='{"command":"echo a\nb"}'
assert_eq 'extract newline' "$(printf 'echo a\nb')" "$(extract_command "$args")"
args='{"command":"echo \u00e9"}'
assert_eq 'extract unicode' "$(printf 'echo \xc3\xa9')" "$(extract_command "$args")"

# --- flat_val: value of the first flat line at a path (optionally typed) ---
flat='/a string hello world
/a number 5
/b number 42
/c null null'
assert_eq 'flat_val first match' 'hello world' "$(printf '%s\n' "$flat" | flat_val /a)"
assert_eq 'flat_val typed'       '5'           "$(printf '%s\n' "$flat" | flat_val /a number)"
assert_eq 'flat_val number'      '42'          "$(printf '%s\n' "$flat" | flat_val /b)"
assert_eq 'flat_val type filter' ''            "$(printf '%s\n' "$flat" | flat_val /b string)"
assert_eq 'flat_val no prefix match' ''        "$(printf '%s\n' "$flat" | flat_val /)"
assert_eq 'flat_val absent'      ''            "$(printf '%s\n' "$flat" | flat_val /zz)"

# --- parse_response: content / finish_reason / tool_calls / reasoning ---
# Plain content.
FLAT='/choices/0/finish_reason string stop
/choices/0/message/content string done'
parse_response
assert_eq 'finish stop' 'stop' "$FINISH_REASON"
assert_eq 'content' 'done' "$CONTENT"
assert_eq 'content not null' '0' "$CONTENT_IS_NULL"
assert_eq 'no tool calls' '0' "$TC_COUNT"
assert_eq 'no reasoning' '' "$REASONING"

# Null content.
FLAT='/choices/0/finish_reason string tool_calls
/choices/0/message/content null null'
parse_response
assert_eq 'content null' '' "$CONTENT"
assert_eq 'content is null' '1' "$CONTENT_IS_NULL"

# Tool calls.
FLAT='/choices/0/finish_reason string tool_calls
/choices/0/message/content null null
/choices/0/message/tool_calls/0/id string call_1
/choices/0/message/tool_calls/0/function/name string shell
/choices/0/message/tool_calls/0/function/arguments string {"command":"echo hi"}
/choices/0/message/tool_calls/1/id string call_2
/choices/0/message/tool_calls/1/function/name string skill
/choices/0/message/tool_calls/1/function/arguments string {"name":"alpha"}'
parse_response
assert_eq 'tc count' '2' "$TC_COUNT"
assert_eq 'tc0 id' 'call_1' "$(get_tc_id 0)"
assert_eq 'tc0 name' 'shell' "$(get_tc_name 0)"
assert_eq 'tc0 args' '{"command":"echo hi"}' "$(get_tc_args 0)"
assert_eq 'tc1 id' 'call_2' "$(get_tc_id 1)"
assert_eq 'tc1 name' 'skill' "$(get_tc_name 1)"
assert_eq 'tc1 args' '{"name":"alpha"}' "$(get_tc_args 1)"

# Reasoning echo.
FLAT='/choices/0/finish_reason string stop
/choices/0/message/content string answer
/choices/0/message/reasoning string thought'
parse_response
assert_eq 'reasoning present' 'thought' "$REASONING"
FLAT='/choices/0/finish_reason string stop
/choices/0/message/content string answer
/choices/0/message/reasoning null null'
parse_response
assert_eq 'reasoning null' '' "$REASONING"

# reasoning_content (DeepSeek/vLLM/llama.cpp) is read and remembered.
FLAT='/choices/0/finish_reason string stop
/choices/0/message/content string answer
/choices/0/message/reasoning_content string pondered'
parse_response
assert_eq 'reasoning_content present' 'pondered' "$REASONING"
assert_eq 'reasoning_content key' 'reasoning_content' "$REASONING_KEY"
FLAT='/choices/0/finish_reason string stop
/choices/0/message/content string answer
/choices/0/message/reasoning string thought'
parse_response
assert_eq 'reasoning key default' 'reasoning' "$REASONING_KEY"

# --- build_tools ---
SKILLS_ENABLED=0
SELF=''
DEPTH=1
MCP_COUNT=0
tools=$(build_tools)
assert_contains 'shell tool' '"name":"shell"' "$tools"
assert_not_contains 'no skill tool' '"name":"skill"' "$tools"
assert_not_contains 'no delegate tool' '"name":"delegate"' "$tools"
# With skills.
SKILLS_ENABLED=1
tools=$(build_tools)
assert_contains 'skill tool' '"name":"skill"' "$tools"
# With delegate (SELF set + depth>0).
SKILLS_ENABLED=0
SELF=/path/to/agent.sh
tools=$(build_tools)
assert_contains 'delegate tool' '"name":"delegate"' "$tools"
# Delegate suppressed when depth 0.
SELF=/path/to/agent.sh
DEPTH=0
tools=$(build_tools)
assert_not_contains 'no delegate at depth 0' '"name":"delegate"' "$tools"

# --- build_request: full body shape ---
MSGS=''
add_msg '{"role":"system","content":"sys"}'
add_msg '{"role":"user","content":"do it"}'
PARAMS='temperature=0.7'
SKILLS_ENABLED=0
SELF=''
DEPTH=1
MCP_COUNT=0
MODEL=mymodel
req=$(build_request)
assert_contains 'model' '"model": "mymodel"' "$req"
assert_contains 'messages' '"messages": [' "$req"
assert_contains 'system msg' '"role":"system"' "$req"
assert_contains 'user msg' '"role":"user"' "$req"
assert_contains 'tools' '"tools": [' "$req"
assert_contains 'tool_choice' '"tool_choice": "auto"' "$req"
assert_contains 'params' '"temperature":0.7' "$req"

# --- utf8_clean: valid UTF-8 kept, invalid bytes -> '?' ---
load_fn utf8_clean
out=$(printf 'a\303\251 \360\237\230\200 \377b \303( \001z' | utf8_clean | od -An -c | tr -s ' ' | tr -d '\n')
assert_eq 'utf8_clean' ' a 303 251 360 237 230 200 ? b ? ( z' "$out"
out=$(printf 'tail\200' | utf8_clean)
assert_eq 'utf8_clean trailing byte' 'tail?' "$out"


summary
