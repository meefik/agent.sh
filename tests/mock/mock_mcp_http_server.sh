#!/bin/busybox ash
# Mock MCP Streamable HTTP server: accept connections on <port> and run
# mock_mcp_http_handler.sh for each. Pure busybox applets (no python).
#
# Usage: mock_mcp_http_server.sh <port>
. "$(cd "$(dirname "$0")" && pwd)/mock_common.sh"
mock_server_loop "$1" "$(cd "$(dirname "$0")" && pwd)/mock_mcp_http_handler.sh"
