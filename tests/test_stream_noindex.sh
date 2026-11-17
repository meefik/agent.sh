#!/usr/bin/env ash
# Streaming tool calls from a server that omits "index" in the deltas: each
# parallel call arrives in its own chunk (new id), with argument fragments in
# later id-less chunks. Every call must get its own slot. $BB is a fake
# busybox whose `wget` emits the SSE stream — no network.
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/bb" <<'EOF'
#!/bin/busybox ash
cat >/dev/null
cat <<'SSE'
data: {"choices":[{"delta":{"tool_calls":[{"id":"a1","type":"function","function":{"name":"shell","arguments":""}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"command\":"}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"echo one\"}"}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"id":"b2","type":"function","function":{"name":"shell","arguments":"{\"command\":\"echo two\"}"}}]}}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

SSE
EOF
printf '#!/bin/busybox ash\nexec busybox ash "%s/bb" "$@"\n' "$WORK" > "$WORK/bbx"
chmod +x "$WORK/bbx"
BB="$WORK/bbx" KEY="" WGET_TO=""

load_json
load_fn http_post_stream json_unescape json_escape
http_post_stream "http://x/v1/chat/completions" '{}' 2>/dev/null
assert_rc 'stream ok' 0 "$?"

FLAT=$(printf '%s' "$HTTP_BODY" | json)
assert_eq 'call 0 id' a1 "$(printf '%s\n' "$FLAT" | sed -n 's|^/choices/0/message/tool_calls/0/id string ||p')"
assert_eq 'call 1 id' b2 "$(printf '%s\n' "$FLAT" | sed -n 's|^/choices/0/message/tool_calls/1/id string ||p')"
assert_eq 'call 0 args' '{\"command\":\"echo one\"}' "$(printf '%s\n' "$FLAT" | sed -n 's|^/choices/0/message/tool_calls/0/function/arguments string ||p')"
assert_eq 'call 1 args' '{\"command\":\"echo two\"}' "$(printf '%s\n' "$FLAT" | sed -n 's|^/choices/0/message/tool_calls/1/function/arguments string ||p')"
assert_eq 'no third call' '' "$(printf '%s\n' "$FLAT" | sed -n 's|^/choices/0/message/tool_calls/2/id string ||p')"

summary
