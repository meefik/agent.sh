#!/usr/bin/env ash
# delegate timeout: the whole sub-agent process group is killed, not just the
# direct child. The fake "agent.sh" starts a background sleep (its own
# grandchild, standing in for a running model command) and then blocks.
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'kill "$(cat "$WORK/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$WORK"' EXIT

cat > "$WORK/fake_agent.sh" <<EOF
sleep 300 &
echo \$! > "$WORK/pid"
wait
EOF
cat > "$WORK/ok_agent.sh" <<'EOF'
echo "child says $AGENT_TASK"
EOF

load_fn spawn_subagent
BB=$(command -v busybox)
KEY="" ENDPOINT="" MODEL="" CUSTOM_PROMPT="" BASE_PROMPT="" PARAMS="" EXEC_SHELL=sh
WORKDIR="$WORK" CMD_TIMEOUT=0 HTTP_TIMEOUT=0 MAX_OUTPUT=0 MAX_TURNS=0 DEPTH=1 STREAM=0 MCP=""

SELF="$WORK/ok_agent.sh"
OUT=$(spawn_subagent "hi" "")
assert_rc 'normal run succeeds' 0 "$?"
assert_eq 'child answer returned' 'child says hi' "$OUT"

SELF="$WORK/fake_agent.sh"
OUT=$(spawn_subagent "x" 1)
assert_rc 'timeout fails' 1 "$?"
assert_contains 'reports exit 124' 'exit 124' "$OUT"
sleep 1
assert_true 'grandchild was killed' sh -c "! kill -0 \$(cat '$WORK/pid') 2>/dev/null"

summary
