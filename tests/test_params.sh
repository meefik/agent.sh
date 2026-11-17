# Model parameters: is_json_number / param_value_json / build_params.
# These decide how -P key=value / AGENT_PARAMS values are emitted into the
# request body. A wrong classification produces invalid JSON.
. "$(dirname "$0")/lib.sh"

load_fn json_escape is_json_number param_value_json build_params

# --- is_json_number: accept ---
for v in 0 1 9 123 1.5 0.5 100 1e3 1E3 1e+3 1e-3 1.5e2 1.5e-2 \
         -1 -0.5 -1.5 -1e-3 0.0 0e5 123.456e10; do
	assert_true "is_json_number accepts '$v'" is_json_number "$v"
done

# --- is_json_number: reject ---
# note: '.5' and '+1' are NOT valid JSON numbers (no leading zero / no sign)
for v in '' - 12a abc 0x10 00 001 1. 1e 1e+ 1e- 1.5e \
         1.2.3 --1 .5 . +1 1+ 1.5e2.5 '1 5' 123abc; do
	is_json_number "$v"
	rc=$?
	assert_rc "is_json_number rejects '$v'" 1 "$rc"
done

# --- param_value_json: classification ---
assert_eq 'number int'        '123'      "$(param_value_json '123')"
assert_eq 'number float'      '0.7'      "$(param_value_json '0.7')"
assert_eq 'number neg'        '-1.5'     "$(param_value_json '-1.5')"
assert_eq 'number sci'        '1e3'      "$(param_value_json '1e3')"
assert_eq 'number zero'       '0'        "$(param_value_json '0')"
assert_eq 'true'              'true'     "$(param_value_json 'true')"
assert_eq 'false'             'false'    "$(param_value_json 'false')"
assert_eq 'null'              'null'     "$(param_value_json 'null')"
assert_eq 'string plain'      '"hello"'  "$(param_value_json 'hello')"
assert_eq 'string with space' '"a b"'    "$(param_value_json 'a b')"
assert_eq 'string non-num'    '"0x10"'   "$(param_value_json '0x10')"
assert_eq 'string dash'       '"-foo"'   "$(param_value_json '-foo')"
assert_eq 'string 12abc'      '"12abc"'  "$(param_value_json '12abc')"
assert_eq 'raw json obj'      '{"a":1}'  "$(param_value_json '{"a":1}')"
assert_eq 'raw json arr'      '[1,2]'    "$(param_value_json '[1,2]')"
assert_eq 'string quote'      '"a\"b"'   "$(param_value_json 'a"b')"

# build_params intentionally emits a leading comma: it is spliced after
# "tool_choice": "auto" in the request body, so the fragment is ,"k":v.
# --- build_params: single values ---
PARAMS='temperature=0.7'
assert_eq 'single'           ',"temperature":0.7'   "$(build_params)"
PARAMS='we"ird=1'
assert_eq 'key escaped'      ',"we\"ird":1'      "$(build_params)"
PARAMS='enable_thinking=true'
assert_eq 'bool'             ',"enable_thinking":true' "$(build_params)"
PARAMS='max_tokens=2000'
assert_eq 'int'              ',"max_tokens":2000'     "$(build_params)"
PARAMS='reasoning_effort=high'
assert_eq 'string'           ',"reasoning_effort":"high"' "$(build_params)"

# --- build_params: multiple (semicolon-separated) ---
PARAMS='temperature=0.7;top_p=0.9'
assert_eq 'two' ',"temperature":0.7,"top_p":0.9' "$(build_params)"
PARAMS='a=1;b=2;c=3'
assert_eq 'three' ',"a":1,"b":2,"c":3' "$(build_params)"

# --- build_params: value with spaces (split on first = only) ---
PARAMS='prompt=hello world'
assert_eq 'value with space' ',"prompt":"hello world"' "$(build_params)"

# --- build_params: value with = inside raw JSON (split on first = only) ---
PARAMS='thinking={"type":"enabled","budget_tokens":100}'
assert_eq 'raw json with = and ;' \
  ',"thinking":{"type":"enabled","budget_tokens":100}' "$(build_params)"

# --- build_params: empty key ignored ---
PARAMS='=value'
assert_eq 'empty key' '' "$(build_params)"
PARAMS='a=1;=2;b=3'
assert_eq 'empty key in middle' ',"a":1,"b":3' "$(build_params)"

# --- build_params: no = ignored ---
PARAMS='justastring'
assert_eq 'no equals' '' "$(build_params)"
PARAMS='a=1;noequals;b=3'
assert_eq 'no equals in middle' ',"a":1,"b":3' "$(build_params)"

# --- build_params: empty ---
PARAMS=''
assert_eq 'empty' '' "$(build_params)"

# --- build_params: leading/trailing semicolons (empty entries skipped) ---
PARAMS=';a=1;'
assert_eq 'leading/trailing ;' ',"a":1' "$(build_params)"

summary
