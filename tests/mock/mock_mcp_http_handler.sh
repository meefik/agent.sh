#!/bin/busybox ash
# Handler for mock_mcp_http_server.sh: answer one MCP Streamable HTTP request.
#
# nc -e runs this with the socket on stdin/stdout. It reads the request
# (request line, headers, body by Content-Length) and replies with a
# JSON-RPC 2.0 response.
#
# The server is stateless: each request is answered independently. It does
# not issue a Mcp-Session-Id (the agent handles both sessionful and
# stateless servers).
. "$(dirname "$0")/mock_common.sh"

read_http_request

# Decide which method was requested.
case "$REQ_LINE" in
	*POST*|*post*)
		# Parse the JSON-RPC body to find the method.
		method=$(printf '%s\n' "$BODY" | grep -o '"method":"[^"]*"' | head -n1 | sed 's|"method":"||; s|"$||')
		case "$method" in
			tools/list)
				reply_json '{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"greet","description":"Greet someone","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},{"name":"add","description":"Add two numbers","inputSchema":{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}}]}}'
				;;
			tools/call)
				name=$(printf '%s\n' "$BODY" | grep -o '"name":"[^"]*"' | head -n1 | sed 's|"name":"||; s|"$||')
				args=$(printf '%s\n' "$BODY" | grep -o '"arguments":{[^}]*}')
				case "$name" in
					greet)
						who=$(printf '%s\n' "$args" | grep -o '"name":"[^"]*"' | sed 's|"name":"||; s|"$||')
						reply_json "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello $who\"}]}}"
						;;
					add)
						a=$(printf '%s\n' "$args" | grep -o '"a":[0-9]*' | head -n1 | sed 's|"a":||')
						b=$(printf '%s\n' "$args" | grep -o '"b":[0-9]*' | head -n1 | sed 's|"b":||')
						sum=$((a + b))
						reply_json "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"$sum\"}]}}"
						;;
					*)
						reply_json '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"unknown tool"}}'
						;;
				esac
				;;
			initialize)
				reply_json '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"mock-mcp","version":"1.0"}}}'
				;;
			notifications/initialized)
				reply_json '{"jsonrpc":"2.0","result":{}}'
				;;
			*)
				reply_json '{"jsonrpc":"2.0","id":1,"result":{}}'
				;;
		esac
		;;
	HEAD*|GET*)
		reply_empty
		;;
	*)
		reply_empty
		;;
esac
exit 0
