# MCP helpers: mcp_sanitize, flat_parse, json_from_flat, mcp_parse_result, mcp_dedup.
. "$(dirname "$0")/lib.sh"

load_fn flat_val mcp_sanitize flat_parse json_from_flat mcp_parse_result mcp_dedup json_unescape json_escape
load_json

# --- mcp_sanitize: keep [a-zA-Z0-9_-], everything else -> _ ---
assert_eq 'plain'          'mcp_foo_bar'   "$(mcp_sanitize 'mcp_foo_bar')"
assert_eq 'dotted'         'mcp_foo_bar'   "$(mcp_sanitize 'mcp_foo.bar')"
assert_eq 'spaces'         'mcp_foo_bar'   "$(mcp_sanitize 'mcp foo bar')"
# In the C locale a multibyte char is seen byte-by-byte, so each byte -> _.
assert_eq 'unicode'        'mcp_fo___bar'  "$(mcp_sanitize 'mcp_foö_bar')"
assert_eq 'slash'          'mcp_foo_bar'   "$(mcp_sanitize 'mcp/foo/bar')"
assert_eq 'empty'          ''              "$(mcp_sanitize '')"
assert_eq 'all allowed'    'a-b_c9'        "$(mcp_sanitize 'a-b_c9')"

# --- flat_parse: "<path> <type> <value>" ---
flat_parse '/a string hello world'; assert_eq 'path' '/a' "$FLAT_PATH"; assert_eq 'type' 'string' "$FLAT_TYPE"; assert_eq 'value w/ spaces' 'hello world' "$FLAT_VALUE"
flat_parse '/b number 42'; assert_eq 'num type' 'number' "$FLAT_TYPE"; assert_eq 'num value' '42' "$FLAT_VALUE"
flat_parse '/c boolean true'; assert_eq 'bool type' 'boolean' "$FLAT_TYPE"; assert_eq 'bool value' 'true' "$FLAT_VALUE"
flat_parse '/d null null'; assert_eq 'null type' 'null' "$FLAT_TYPE"; assert_eq 'null value' 'null' "$FLAT_VALUE"
# A key that merely looks like a type keyword (preceded by /, not a space) is not a type.
flat_parse '/string string actual'; assert_eq 'key named string' '/string' "$FLAT_PATH"; assert_eq 'key named string type' 'string' "$FLAT_TYPE"; assert_eq 'key named string value' 'actual' "$FLAT_VALUE"
flat_parse '/number number 7'; assert_eq 'key named number' '/number' "$FLAT_PATH"
# No type keyword at all.
flat_parse '/x no type here'
assert_rc 'no type rc' 1 "$?"

# --- json_from_flat: reconstruct a raw JSON node from flat lines ---
# Object.
flat='/a string hello
/b number 42'
assert_eq 'object' '{"a":"hello", "b":42}' "$(json_from_flat "$flat" '')"
# Array of strings.
flat='/0 string a
/1 string b'
assert_eq 'array' '["a", "b"]' "$(json_from_flat "$flat" '')"
# Nested object.
flat='/outer/inner string x
/outer/num number 5'
assert_eq 'nested' '{"outer":{"inner":"x", "num":5}}' "$(json_from_flat "$flat" '')"
# Nested array of objects (prefix '' wraps the top-level node in an object).
flat='/arr/0/x string p
/arr/1/x string q'
assert_eq 'arr of obj' '{"arr":[{"x":"p"}, {"x":"q"}]}' "$(json_from_flat "$flat" '')"
# Direct array at a prefix (each element is an object with a name key).
flat='/result/tools/0/name string a
/result/tools/1/name string b'
assert_eq 'array at prefix' '[{"name":"a"}, {"name":"b"}]' "$(json_from_flat "$flat" '/result/tools')"
# Empty (no children under prefix).
assert_eq 'empty object' '{}' "$(json_from_flat '/x string y' '/other')"
# Double-decoded strings (flat body carries JSON-escaped body).
flat='/s string a\"b'
assert_eq 'double-decoded' '{"s":"a\"b"}' "$(json_from_flat "$flat" '')"

# --- empty containers survive the flatten -> rebuild round trip ---
flat_parse '/a/required array'
assert_eq 'marker path' '/a/required' "$FLAT_PATH"; assert_eq 'marker type' 'array' "$FLAT_TYPE"
flat=$(printf '%s' '{"type":"object","properties":{},"required":[],"x":[{}]}' | json)
assert_eq 'empty array/object' '{"type":"object", "properties":{}, "required":[], "x":[{}]}' "$(json_from_flat "$flat" '')"

# --- mcp_parse_result: content[] / isError / plain string / JSON-RPC error ---
# content[] with two text blocks (concatenated with newline).
assert_eq 'content two' "$(printf 'one\ntwo')" \
  "$(mcp_parse_result '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}}')"
# content[] with a non-text block (noted, not included).
assert_eq 'content non-text' "$(printf 'text-only\n[image content omitted]')" \
  "$(mcp_parse_result '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"text-only"},{"type":"image","data":"x"}]}}')"
# isError prefix.
assert_err=$(mcp_parse_result '{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"boom"}]}}')
assert_contains 'isError prefix' 'mcp tool error: ' "$assert_err"
assert_contains 'isError body' 'boom' "$assert_err"
# isError:false is NOT an error (no prefix).
assert_eq 'isError false' 'fine' \
  "$(mcp_parse_result '{"jsonrpc":"2.0","id":2,"result":{"isError":false,"content":[{"type":"text","text":"fine"}]}}')"
# Plain-string result.
assert_eq 'plain string' 'just text' \
  "$(mcp_parse_result '{"jsonrpc":"2.0","id":2,"result":"just text"}')"
# JSON-RPC error.
assert_err=$(mcp_parse_result '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"not found"}}')
assert_contains 'rpc error prefix' 'mcp error: ' "$assert_err"
assert_contains 'rpc error msg' 'not found' "$assert_err"

# --- mcp_dedup: collision suffixes _2, _3 ---
MCP_COUNT=0
MCP_ADV_0='mcp_foo_bar'
MCP_COUNT=1
assert_eq 'no collision' 'mcp_foo_baz' "$(mcp_dedup 'mcp_foo_baz')"
assert_eq 'collision _2'  'mcp_foo_bar_2' "$(mcp_dedup 'mcp_foo_bar')"
MCP_ADV_1='mcp_foo_bar_2'
MCP_COUNT=2
# The suffix is appended to the *current* name, so _2 then _3 -> _2_3.
assert_eq 'collision _3'  'mcp_foo_bar_2_3' "$(mcp_dedup 'mcp_foo_bar')"

# --- mcp_http_post: CRLF bodies (SSE or plain JSON) must still parse ---
load_fn mcp_http_post
BB=fakebb
fakebb() { cat >/dev/null; printf '%b' "$FAKE_RESP"; }
FAKE_RESP='event: message\r\ndata: {"a":1}\r\n\r\n'
mcp_http_post http://x m '{}' 0
assert_eq 'sse crlf' '{"a":1}' "$MCP_HTTP_BODY"
assert_eq 'sse crlf parses' '/a number 1' "$(printf '%s' "$MCP_HTTP_BODY" | json 2>/dev/null)"
FAKE_RESP='{\r\n"a":1\r\n}'
mcp_http_post http://x m '{}' 0
assert_eq 'json crlf parses' '/a number 1' "$(printf '%s' "$MCP_HTTP_BODY" | json 2>/dev/null)"

# --- mcp_http_post: a notification before the result in an SSE stream ---
FAKE_RESP='event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{"p":1}}\n\nevent: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"a":2}}\n\n'
mcp_http_post http://x m '{}' 0
assert_eq 'sse skips notification' '{"jsonrpc":"2.0","id":1,"result":{"a":2}}' "$MCP_HTTP_BODY"
FAKE_RESP='data: {"x":1}\n\ndata: {"x":2}\n\n'
mcp_http_post http://x m '{}' 0
assert_eq 'sse falls back to first data' '{"x":1}' "$MCP_HTTP_BODY"

# --- mcp_call: whitespace-formatted arguments are passed through unchanged ---
load_fn mcp_call
MCP_COUNT=1 MCP_ADV_0=mcp_s_t MCP_TOOL_0=t MCP_URL_0=http://x
mcp_http_post() { SENT="$3"; MCP_HTTP_BODY='{"result":"ok"}'; }
mcp_call mcp_s_t '{
  "x": 1
}' >/dev/null
assert_eq 'pretty args' '{"name":"t","arguments":{
  "x": 1
}}' "$SENT"

# --- mcp_discover: a tool without inputSchema gets {"type":"object"} ---
load_fn mcp_discover
MCP_COUNT=0
mcp_http_post() { MCP_HTTP_BODY='{"result":{"tools":[{"name":"bare","description":"d"},{"name":"empty","inputSchema":{}}]}}'; }
mcp_discover http://x srv
assert_eq 'no schema: count' '2' "$MCP_COUNT"
assert_eq 'no schema: default' '{"type":"object"}' "$MCP_SCHEMA_0"
assert_eq 'empty schema: default' '{"type":"object"}' "$MCP_SCHEMA_1"

summary
