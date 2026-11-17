# Shared helpers for the ash mock HTTP servers.
#
# The mock is a real (minimal) HTTP server built on `busybox nc -l -p PORT
# -e handler`: nc accepts one connection, runs the handler with the socket on
# its stdin/stdout, then exits; the server script loops to accept the next.
# The handler reads the request (request line, headers, body by Content-Length)
# and writes the response to stdout.
#
# read_http_request: read the request from stdin into REQ_LINE, CONTENT_LENGTH,
# and BODY. The header loop stops at the blank (CRLF) line; the body is then
# read by Content-Length (head -c), which is what avoids the wget-holds-the-
# socket-open deadlock (a naive `while read` waits for EOF, which never comes
# until the handler responds).
read_http_request() {
	REQ_LINE=""
	CONTENT_LENGTH=0
	while IFS= read -r line; do
		line="${line%$'\r'}"
		[ -z "$REQ_LINE" ] && REQ_LINE="$line"
		case "$line" in
			Content-Length:*)
				CONTENT_LENGTH="${line#Content-Length:}"
				CONTENT_LENGTH="${CONTENT_LENGTH// /}";;
		esac
		[ -z "$line" ] && break
	done
	[ -n "$CONTENT_LENGTH" ] || CONTENT_LENGTH=0
	BODY=$(head -c "$CONTENT_LENGTH" 2>/dev/null)
}

# reply_json <body>: send a 200 application/json response with the given body.
# Content-Length must be in bytes: ${#1} counts characters in a UTF-8 locale,
# so measure the body with wc -c instead.
reply_json() {
	local cl
	cl=$(printf '%s' "$1" | wc -c)
	printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$cl" "$1"
}

# reply_sse <body>: send a 200 text/event-stream (SSE) response with the given
# body as a single data: line (the JSON-RPC response). The body's Content-Length
# is measured in bytes (wc -c), not characters.
reply_sse() {
	local cl
	cl=$(printf 'data: %s\n\n' "$1" | wc -c)
	printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %s\r\n\r\ndata: %s\n\n' "$cl" "$1"
}

# reply_empty: send a 200 with no body (for port-check HEAD/GET requests).
reply_empty() {
	printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'
}

# mock_server_loop <port> <handler>: accept connections on <port> for as long
# as this process lives. Each connection runs <handler> with the socket on its
# stdin/stdout; nc accepts ONE connection then exits, so the loop re-arms for
# the next. A trap kills the current nc (and removes the wrapper) on
# SIGTERM/SIGINT so the port is freed immediately (the tests kill and restart
# the server on the same port).
#
# nc -e needs an executable program, but the handler is a source script (no
# execute bit — the same convention as agent.sh itself). So we wrap it in a
# tiny temp script (in /tmp, where chmod +x is allowed) that does
# `exec busybox ash <handler>`; the socket is inherited onto the handler's
# stdin/stdout.
#
# Uses `busybox nc` when busybox is present (the target; also what proves the
# applet-only constraint in a container), else bare `nc`.
mock_server_loop() {
	local port="$1" handler="$2"
	local nc_cmd="nc"
	command -v busybox >/dev/null 2>&1 && nc_cmd="busybox nc"
	local wrapper
	wrapper=$(mktemp "${TMPDIR:-/tmp}/agent_mock_wrap.XXXXXX")
	printf '#!/bin/busybox ash\nexec busybox ash "%s"\n' "$handler" > "$wrapper"
	chmod +x "$wrapper"
	local nc_pid=""
	trap 'kill "$nc_pid" 2>/dev/null; rm -f "$wrapper"; exit 1' TERM INT
	while :; do
		$nc_cmd -l -p "$port" -e "$wrapper" &
		nc_pid=$!
		wait "$nc_pid"
		nc_pid=""
	done
}
