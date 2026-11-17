#!/bin/busybox ash
# Mock streaming (SSE) OpenAI endpoint, in pure busybox applets (no python).
#
# Usage: mock_sse_server.sh <port>
#
# Emits a scripted SSE conversation: turn 1 is a tool-call whose id/name arrive
# in one chunk and whose arguments arrive in TWO chunks (to exercise the
# per-index fragment concatenation) plus a second call (index 1), then a finish_reason, then [DONE]. Turn 2
# is a final plain-text answer (also streamed). The turn is the request count.
. "$(cd "$(dirname "$0")" && pwd)/mock_common.sh"
export MOCK_LOG="$(mktemp)"
: > "$MOCK_LOG"
mock_server_loop "$1" "$(cd "$(dirname "$0")" && pwd)/mock_sse_handler.sh"
