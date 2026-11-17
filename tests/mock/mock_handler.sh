#!/bin/busybox ash
# Handler for mock_server.sh: answer one /chat/completions request.
#
# nc -e runs this with the socket on stdin/stdout. It reads the request
# (request line, headers, body by Content-Length), logs the body, picks the
# nth scripted response (n = number of requests so far), and replies.
#
# Env (set by mock_server.sh): MOCK_SCRIPT, MOCK_LOG.
. "$(dirname "$0")/mock_common.sh"

read_http_request

# HEAD (the test's port probe): answer 200 with no body.
case "$REQ_LINE" in
	HEAD*)
		reply_empty
		exit 0;;
esac

# Log the request body (one line per request). agent.sh's body has newlines
# (it's built with printf), so strip them to keep one line per request.
printf '%s\n' "${BODY//$'\n'/ }" >> "$MOCK_LOG"

# Pick the nth scripted response (n = number of requests so far, 1-based).
n=$(grep -c . "$MOCK_LOG" 2>/dev/null)
resp=$(sed -n "${n}p" "$MOCK_SCRIPT" 2>/dev/null)
# Script exhausted: a final plain-text answer.
[ -n "$resp" ] || resp='{"choices":[{"message":{"role":"assistant","content":"DONE"},"finish_reason":"stop"}]}'

reply_json "$resp"
exit 0
