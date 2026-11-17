#!/bin/busybox ash
# Handler for mock_sse_server.sh: stream one /chat/completions response as SSE.
#
# nc -e runs this with the socket on stdin/stdout. It reads the request,
# determines the turn (the number of requests so far), and writes the SSE
# body (data: lines) to stdout with a text/event-stream response.
#
# Env (set by mock_sse_server.sh): MOCK_LOG.
. "$(dirname "$0")/mock_common.sh"

read_http_request

case "$REQ_LINE" in
	HEAD*)
		reply_empty
		exit 0;;
esac

# Log the request body (one line per request); agent.sh's body has newlines.
printf '%s\n' "${BODY//$'\n'/ }" >> "$MOCK_LOG"
n=$(grep -c . "$MOCK_LOG" 2>/dev/null)

# Build the SSE body for this turn.
if [ "$n" -eq 1 ]; then
	# Turn 1: a tool call, arguments split across two chunks.
	body="data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Let me run a command.\"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"${MOCK_TOOL:-shell}\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"command\\\":\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"echo streamed > s.txt\\\"}\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"c2\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"{\\\"command\\\":\\\"echo second > s2.txt\\\"}\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}

data: [DONE]

"
else
	# Turn 2: final plain-text answer.
	body="data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Streamed\"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\n\\n\"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"answer.\"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}

data: [DONE]

"
fi

# Content-Length must be in bytes: ${#body} counts characters in a UTF-8
# locale (the same wc -c convention as reply_json / reply_sse).
cl=$(printf '%s' "$body" | wc -c)
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %s\r\n\r\n%s' "$cl" "$body"
exit 0
