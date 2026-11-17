#!/bin/busybox ash
# Stateful mock OpenAI /chat/completions endpoint (non-streaming), in pure
# busybox applets (no python).
#
# Usage: mock_server.sh <port> <script> <log>
#
# <script> holds one scripted response per line (each line a complete JSON
# object). The nth request is answered with the nth line; when the script is
# exhausted, a final plain-text "DONE" answer is returned. Each request body
# is logged to <log> (one line) so tests can inspect the wire protocol the
# harness actually sent.
. "$(cd "$(dirname "$0")" && pwd)/mock_common.sh"
export MOCK_SCRIPT="$2"
export MOCK_LOG="$3"
: > "$MOCK_LOG"
mock_server_loop "$1" "$(cd "$(dirname "$0")" && pwd)/mock_handler.sh"
