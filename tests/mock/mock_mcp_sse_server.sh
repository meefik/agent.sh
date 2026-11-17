#!/bin/busybox ash
# Mock MCP Streamable HTTP server that answers with text/event-stream (SSE)
# instead of application/json. Accepts connections on <port> and runs
# mock_mcp_sse_handler.sh for each. Pure busybox applets (no python).
#
# Usage: mock_mcp_sse_server.sh <port>
. "$(cd "$(dirname "$0")" && pwd)/mock_common.sh"
mock_server_loop "$1" "$(cd "$(dirname "$0")" && pwd)/mock_mcp_sse_handler.sh"
