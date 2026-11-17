#!/usr/bin/env ash
# MCP sessions: the server answers `initialize` with an Mcp-Session-Id header
# (read via wget -S) and rejects every later request that does not echo it
# back. Verifies discovery and tools/call work against such a server, and that
# header lines never leak into the JSON body. $BB is a fake busybox whose
# `wget` plays the server — no network.
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/bb" <<'EOF'
#!/bin/busybox ash
# fake busybox: only `wget` is used by mcp_http_post
shift
req=$(cat)
case "$*" in *"Mcp-Session-Id: sess42"*) ok=1;; *) ok=0;; esac
case "$req" in
	*'"method":"initialize"'*)
		printf '  HTTP/1.1 200 OK\r\n  Content-Type: application/json\r\n  Mcp-Session-Id: sess42\r\n  \r\n' >&2
		printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}';;
	*notifications*) [ "$ok" = 1 ] || exit 8; printf '  HTTP/1.1 202 Accepted\r\n  \r\n' >&2;;
	*'"method":"tools/list"'*)
		[ "$ok" = 1 ] || exit 8
		printf '  HTTP/1.1 200 OK\r\n  \r\n' >&2
		printf '{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"ping","description":"d","inputSchema":{"type":"object"}}]}}';;
	*'"method":"tools/call"'*)
		[ "$ok" = 1 ] || exit 8
		printf '  HTTP/1.1 200 OK\r\n  \r\n' >&2
		printf '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"pong"}]}}';;
esac
EOF
BB="busybox ash $WORK/bb"
# "$BB" is expanded unquoted-as-one-word in agent.sh; use a wrapper executable.
printf '#!/bin/busybox ash\nexec busybox ash "%s/bb" "$@"\n' "$WORK" > "$WORK/bbx"
chmod +x "$WORK/bbx"
BB="$WORK/bbx"

load_json
load_fn mcp_http_post mcp_discover mcp_call mcp_parse_result mcp_sanitize mcp_dedup \
	json_from_flat flat_parse flat_val json_unescape json_escape
MCP_COUNT=0 MCP_SID=""

mcp_discover "http://x/mcp" srv
assert_rc 'discovery with session id succeeds' 0 "$?"
assert_eq 'one tool found' 1 "$MCP_COUNT"
assert_eq 'advertised name' mcp_srv_ping "$MCP_ADV_0"
assert_eq 'session id stored per tool' sess42 "$MCP_SID_0"

OUT=$(mcp_call mcp_srv_ping '{}')
assert_eq 'tools/call carries the session id' pong "$OUT"

# Header lines are not part of the body.
MCP_SID=""
mcp_http_post "http://x/mcp" initialize '{}' 0
assert_eq 'session id read from header' sess42 "$MCP_RSID"
assert_eq 'body has no header lines' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}' "$MCP_HTTP_BODY"

summary
