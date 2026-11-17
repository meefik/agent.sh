#!/bin/busybox ash
# Handler for mock_sse_thinking_server.sh: stream one /chat/completions
# response as SSE with reasoning (thinking) deltas interleaved with content.
#
# Exercises the [thinking] prefix logic: each turn has a contiguous run of
# reasoning chunks (the prefix must be printed once per run, not per chunk),
# then a content chunk (which ends the run), then a tool call (turn 1) or a
# final answer (turn 2).
#
# Env (set by mock_sse_thinking_server.sh): MOCK_LOG.
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
	# Turn 1: two reasoning chunks (one thinking block), a content chunk,
	# then a tool call whose arguments arrive in two chunks.
	body="data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning\":\"Let me think. \"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"I need to check the file. \"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Let me check the file.\"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"shell\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"command\\\":\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"echo streamed > s.txt\\\"}\"}}]}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}

data: [DONE]

"
else
	# Turn 2: two reasoning chunks, then the final plain-text answer.
	body="data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"The result is \"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"streamed. \"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Streamed answer.\"}}]}

data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}

data: [DONE]

"
fi

# Content-Length must be in bytes: ${#body} counts characters in a UTF-8
# locale (the same wc -c convention as reply_json / reply_sse).
cl=$(printf '%s' "$body" | wc -c)
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %s\r\n\r\n%s' "$cl" "$body"
exit 0
