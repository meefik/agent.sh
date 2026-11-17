#!/bin/busybox ash
# Mock streaming (SSE) OpenAI endpoint that emits reasoning (thinking)
# deltas, in pure busybox applets (no python).
#
# Usage: mock_sse_thinking_server.sh <port> <log>
#
# Emits a scripted SSE conversation: turn 1 is a tool call preceded by two
# reasoning chunks (one contiguous thinking block); turn 2 is a final
# plain-text answer preceded by two reasoning chunks.
. "$(cd "$(dirname "$0")" && pwd)/mock_common.sh"
export MOCK_LOG="$2"
: > "$MOCK_LOG"
mock_server_loop "$1" "$(cd "$(dirname "$0")" && pwd)/mock_sse_thinking_handler.sh"
