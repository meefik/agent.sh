#!/bin/busybox ash
# agent.sh — a single-file LLM agent in pure ash (busybox POSIX shell).
#
# One executable, only busybox applets (no jq, no python, no curl). Native
# tool calling (OpenAI `tools` protocol): the tool `shell(command)` (commands
# run under the execution shell: -s, else $SHELL, else sh), when
# $WORKDIR/.agents/skills/ has skills `skill(name)` (loads .agents/skills/<name>/SKILL.md),
# and, when AGENT_SELF is set and depth > 0, `delegate(task, timeout?)`
# (spawns a nested agent.sh for a sub-task; the child's final answer is the
# tool result). With -M name=url / AGENT_MCP, MCP servers' tools are
# exposed as mcp_<name>_<tool> (Streamable HTTP transport).
#
# Usage:
#   agent.sh [-e endpoint] [-m model] [-k key] [-p system-prompt]
#            [-s shell] [-t max-turns] [-T cmd-timeout] [-O max-output]
#            [-a|--ask] [-S|--stream] [-w workdir] [-d depth] [-P key=value]
#            [-M name=url] <task...>
#
# Every CLI argument has an env default, so the script can run with no
# arguments at all — set the env vars and pipe the script in:
#   AGENT_TASK="..." AGENT_KEY="..." busybox wget -qO - https://.../agent.sh | busybox ash -s -
#
#   -e endpoint   <- AGENT_ENDPOINT   (default http://localhost:11434/v1)
#   -m model      <- AGENT_MODEL      (default qwen3)
#   -k key        <- AGENT_KEY        (default empty)
#   -p sys-prompt <- AGENT_SYSTEM_PROMPT
#   -s shell      <- AGENT_SHELL      (default $SHELL, else sh)
#   -t max-turns  <- AGENT_MAX_TURNS  (default 0; unlimited; a positive
#                                      value caps the tool loop)
#   -O max-output  <- AGENT_MAX_OUTPUT (default 16384; 0 = unlimited; a positive
#                                      value caps each tool result in bytes)
#   -T cmd-timeout <- AGENT_TIMEOUT   (default 300; 0 = unlimited; a positive
#                                      value is the per-command timeout in
#                                      seconds)
#   -H http-timeout <- AGENT_HTTP_TIMEOUT (default 300; seconds of silence
#                                      tolerated on a model request; 0 = the
#                                      busybox wget default)
#   -M name=url   <- AGENT_MCP        (repeatable; MCP servers, Streamable HTTP;
#                                      env form: semicolon-separated)
#   -a/--ask      <- AGENT_ASK        (default 0; ask before each command)
#   -S/--stream   <- AGENT_STREAM     (default 0; stream the model output
#                                      live to stderr while it works)
#   -w workdir    <- AGENT_WORKDIR    (default: the current directory)
#   -d depth      <- AGENT_DEPTH      (default 1; remaining delegation depth;
#                                      the child runs at depth - 1)
#   -P key=value  <- AGENT_PARAMS     (repeatable; model parameters, e.g.
#                                      temperature=0.7; env form: semicolon-
#                                      separated AGENT_PARAMS="a=1;b=2")
#   <task...>     <- AGENT_TASK       (default empty; required unless the task
#                                      is piped on stdin: cat task.md | ash agent.sh)
#
# Transport: busybox wget --post-file=/dev/stdin (the body is piped in).
# The request and response live in shell variables — nothing is written to
# disk (no temp files), so the script runs on a read-only root or a target
# without /tmp.
# No sandbox of its own: wrap the script in whatever sandbox you want
#   (podman, bwrap, unshare, firejail, ...). agent.sh runs each command as a
#   plain child, with env scrubbing (the full AGENT_* set removed), a
#   per-command timeout, and output truncation.
#
# JSON parsing: vendored json.sh (rcrowley, pure POSIX shell, BSD-licensed).
#   https://github.com/rcrowley/json.sh — see attribution at the bottom.

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
# Every CLI argument also has an env default, so the script can run with
# no arguments at all (e.g. `busybox wget -qO - https://.../agent.sh | busybox ash -s -`
# with AGENT_TASK set in the environment).
ENDPOINT="${AGENT_ENDPOINT:-http://localhost:11434/v1}"
MODEL="${AGENT_MODEL:-qwen3}"
KEY="${AGENT_KEY:-}"
SYSTEM_PROMPT="${AGENT_SYSTEM_PROMPT:-}"
EXEC_SHELL="${AGENT_SHELL:-${SHELL:-sh}}"
MAX_TURNS="${AGENT_MAX_TURNS:-0}"
MAX_OUTPUT="${AGENT_MAX_OUTPUT:-16384}"
CMD_TIMEOUT="${AGENT_TIMEOUT:-300}"
HTTP_TIMEOUT="${AGENT_HTTP_TIMEOUT:-300}"
ASK="${AGENT_ASK:-0}"
STREAM="${AGENT_STREAM:-0}"
WORKDIR="${AGENT_WORKDIR:-}"
# Delegation: AGENT_SELF (a path or URL to agent.sh) enables the
# delegate(task, timeout) tool; DEPTH is the remaining delegation depth
# (default 1 — one level of sub-agents; the child runs at depth - 1).
DEPTH="${AGENT_DEPTH:-1}"
SELF="${AGENT_SELF:-}"
# Model parameters: repeatable -P key=value on the CLI; semicolon-separated
# in AGENT_PARAMS. Values are classified: { or [ prefix = raw JSON,
# number/true/false/null as-is, anything else a JSON string. Merged into the
# request body by build_request.
PARAMS="${AGENT_PARAMS:-}"
# MCP servers: repeatable -M name=url on the CLI; semicolon-separated in
# AGENT_MCP. value is a http:// or https:// URL (Streamable HTTP
# transport). See the MCP section.
MCP="${AGENT_MCP:-}"
# Task: env default, overridden by a CLI task if one is given (tracked
# separately in CLI_TASK so the two don't concatenate).
TASK="${AGENT_TASK:-}"
CLI_TASK=""

usage() {
	printf 'usage: agent.sh [-e endpoint] [-m model] [-k key] [-p system-prompt]\n          [-s shell] [-t max-turns] [-T cmd-timeout] [-O max-output]\n          [-H http-timeout]\n          [-a|--ask] [-S|--stream] [-w workdir] [-d depth]\n          [-P key=value] [-M name=url] <task...>\n\n-P sets a model parameter (repeatable): temperature=0.7, top_p=0.9,\nenable_thinking=true, ... (value: number/true/false/null or raw JSON).\nEnv: AGENT_PARAMS="temperature=0.7;top_p=0.9".\n\n-M name=url (repeatable) adds an MCP server (Streamable HTTP transport):\nvalue is a http:// or https:// URL, e.g. "http://localhost:8080/mcp".\nThe server tools are exposed to the model as mcp_<name>_<tool>.\nEnv: AGENT_MCP="fs=http://host:port/mcp;git=...".\n\n-S/--stream streams the model output live to stderr as it works\n(SSE stream: true); the response is reassembled into a normal turn.\n\nSkills: if $WORKDIR/.agents/skills/ contains <name>/SKILL.md, a skill(name)\ntool is added and the skill list goes into the system prompt. A custom\n-p/AGENT_SYSTEM_PROMPT may embed the literal $SKILL_LIST token to place\nthe list anywhere (or omit it to drop the list).\n\nSub-agents: with AGENT_SELF set (a path or URL to agent.sh) and depth\n> 0, a delegate(task, timeout) tool is added. It spawns a nested\nagent.sh to work a sub-task and returns its final answer. -d/AGENT_DEPTH\nsets the depth (default 1); the child runs at depth - 1. No total\ntimeout by default; timeout (seconds) is an optional tool parameter.\n\nEvery option also has an AGENT_* env default (see the header), so the\nscript can run with no arguments: AGENT_TASK="..." agent.sh\n'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		-e|-m|-k|-p|-s|-t|-T|-O|-H|-w|-d|-P|-M)
			[ "$#" -ge 2 ] || { printf 'agent.sh: option %s requires a value\n' "$1" >&2; exit 2; };;
	esac
	case "$1" in
		-e) ENDPOINT="$2"; shift 2;;
		-m) MODEL="$2"; shift 2;;
		-k) KEY="$2"; shift 2;;
		-p) SYSTEM_PROMPT="$2"; shift 2;;
		-s) EXEC_SHELL="$2"; shift 2;;
		-t) MAX_TURNS="$2"; shift 2;;
		-O) MAX_OUTPUT="$2"; shift 2;;
		-T) CMD_TIMEOUT="$2"; shift 2;;
		-H) HTTP_TIMEOUT="$2"; shift 2;;
		-a|--ask) ASK=1; shift;;
		-S|--stream) STREAM=1; shift;;
		-w) WORKDIR="$2"; shift 2;;
		-d) DEPTH="$2"; shift 2;;
		-P) PARAMS="${PARAMS:+$PARAMS;}$2"; shift 2;;
		-M) MCP="${MCP:+$MCP;}$2"; shift 2;;
		-h|--help) usage; exit 0;;
		--) shift; while [ "$#" -gt 0 ]; do CLI_TASK="${CLI_TASK:+$CLI_TASK }$1"; shift; done;;
		-*) printf 'agent.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2;;
		*) CLI_TASK="${CLI_TASK:+$CLI_TASK }$1"; shift;;
	esac
done

# Numeric options must be non-negative integers (they feed [ -gt ] tests).
check_int() {
	case "$2" in
		''|*[!0-9]*) printf 'agent.sh: %s must be a non-negative integer: %s\n' "$1" "$2" >&2; exit 2;;
	esac
}
check_int -t "$MAX_TURNS"; check_int -T "$CMD_TIMEOUT"
check_int -O "$MAX_OUTPUT"; check_int -d "$DEPTH"; check_int -H "$HTTP_TIMEOUT"
# Drop leading zeros: $(( )) would read "08" as a bad octal number.
for _v in MAX_TURNS CMD_TIMEOUT MAX_OUTPUT DEPTH HTTP_TIMEOUT; do
	eval "while case \$$_v in 0?*) :;; *) false;; esac; do $_v=\${$_v#0}; done"
done

# Model-request wget timeout flag (0 = leave busybox's default).
WGET_TO=""; [ "$HTTP_TIMEOUT" -gt 0 ] && WGET_TO="--timeout=$HTTP_TIMEOUT"

# Flags: empty or 0 = off, anything else = on (so AGENT_ASK=true can't
# silently disable the confirmation prompt).
case "$ASK" in ''|0) ASK=0;; *) ASK=1;; esac
case "$STREAM" in ''|0) STREAM=0;; *) STREAM=1;; esac

# The busybox binary, for the applets that must be busybox's own (wget:
# GNU wget cannot read a request body from a pipe) and for child agents
# (ash). Found on PATH, else the running binary's real path (Linux; the
# binary must keep a name starting with "busybox").
BB=$(command -v busybox) || BB=$(readlink /proc/self/exe)

# A CLI task wins over the AGENT_TASK env default.
[ -n "$CLI_TASK" ] && TASK="$CLI_TASK"
# No task yet: read it from piped stdin (`cat task.md | busybox ash agent.sh`).
# Not when the script itself is on stdin ($0 not a file) or stdin is a tty.
STDIN_TASK=
if [ -z "$TASK" ] && [ -f "$0" ] && [ ! -t 0 ]; then
	TASK=$(cat) && STDIN_TASK=1
fi
[ -n "$TASK" ] || { usage >&2; exit 2; }


# ---------------------------------------------------------------------------
# JSON escaping (build side of the wire protocol)
# ---------------------------------------------------------------------------
# Escape arbitrary bytes into a JSON string body (without the surrounding
# double quotes). Backslash and quote first (so we don't double-escape),
# then all control characters 0x00-0x1f: \n \t \r \b \f use short escapes,
# the rest use \u00XX. Uses ${s//pat/rep} which (unlike case patterns in
# busybox ash) does interpret $'\xNN' hex escapes.
json_escape() {
	local s="$1"
	# $2 non-empty: escape control characters only (for a JSON *document*
	# whose backslashes and quotes are structural, not data).
	if [ -z "$2" ]; then
		s="${s//\\/\\\\}"
		s="${s//\"/\\\"}"
	fi
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\x08'/\\b}"
	s="${s//$'\x0c'/\\f}"
	s="${s//$'\x0b'/\\u000b}"
	s="${s//$'\x01'/\\u0001}"
	s="${s//$'\x02'/\\u0002}"
	s="${s//$'\x03'/\\u0003}"
	s="${s//$'\x04'/\\u0004}"
	s="${s//$'\x05'/\\u0005}"
	s="${s//$'\x06'/\\u0006}"
	s="${s//$'\x07'/\\u0007}"
	s="${s//$'\x0e'/\\u000e}"
	s="${s//$'\x0f'/\\u000f}"
	s="${s//$'\x10'/\\u0010}"
	s="${s//$'\x11'/\\u0011}"
	s="${s//$'\x12'/\\u0012}"
	s="${s//$'\x13'/\\u0013}"
	s="${s//$'\x14'/\\u0014}"
	s="${s//$'\x15'/\\u0015}"
	s="${s//$'\x16'/\\u0016}"
	s="${s//$'\x17'/\\u0017}"
	s="${s//$'\x18'/\\u0018}"
	s="${s//$'\x19'/\\u0019}"
	s="${s//$'\x1a'/\\u001a}"
	s="${s//$'\x1b'/\\u001b}"
	s="${s//$'\x1c'/\\u001c}"
	s="${s//$'\x1d'/\\u001d}"
	s="${s//$'\x1e'/\\u001e}"
	s="${s//$'\x1f'/\\u001f}"
	printf '%s' "$s"
}

# Replace bytes that are not valid UTF-8 with '?' (stdin -> stdout): a request
# body with invalid UTF-8 is rejected by most servers, which would end the run.
# C locale sed; \x01 is a cursor that walks the line: skip ASCII, keep a valid
# multibyte sequence, else replace one byte (\x01 is dropped from the input).
utf8_clean() {
	tr -d '\001' | LC_ALL=C sed "s/^/\x01/;:l;s/\x01\([^\x80-\xff\x01]\{1,\}\)/\1\x01/;t l;s/\x01\([\xc2-\xdf][\x80-\xbf]\|\xe0[\xa0-\xbf][\x80-\xbf]\|[\xe1-\xec\xee\xef][\x80-\xbf][\x80-\xbf]\|\xed[\x80-\x9f][\x80-\xbf]\|\xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf]\|[\xf1-\xf3][\x80-\xbf][\x80-\xbf][\x80-\xbf]\|\xf4[\x80-\x8f][\x80-\xbf][\x80-\xbf]\)/\1\x01/;t l;s/\x01[\x80-\xff]/?\x01/;t l;s/\x01//"
}

# ---------------------------------------------------------------------------
# Vendored json.sh (rcrowley) — pure-shell JSON parser, BSD-licensed.
# Flattens a JSON document on stdin to lines of:  /key/path <type> <value>
# Attribution: https://github.com/rcrowley/json.sh
# ---------------------------------------------------------------------------
[ -z "$JSON_DEBUG" ] && exec 3>/dev/null || exec 3>&2
exec 4>/dev/null

json() {
	[ -z "$JSON_SEPARATOR" ] && _J_S="/" || _J_S="$JSON_SEPARATOR"
	_J_FD=1
	_J_PATHNAME="$_J_S" _J_STATE="whitespace" _J_STATE_DEFAULT="whitespace"
	IFS='
'
	sed "
		s/./&$(printf "\036")/g
		s/\\\\/\\\\\\\\/g
	" | tr "\036" "\n" | _json
}

_json() {
	while read _J_C
	do
		_json_char
		_J_PREV_C="$_J_C"
	done
}

_json_char() {
	case "$_J_STATE" in
		"array-0"|"array-even"|"array-odd"|"whitespace")
			case "$_J_STATE" in
				"array-0")
					case "$_J_C" in
						# Empty array: leaves carry no marker, so emit one
						# (the path is "<array>/0" here).
						"]") echo "${_J_PATHNAME%/0} array" >&$_J_FD; exit;;
					esac;;
				"array-even")
					case "$_J_C" in
						",")
							_J_DIRNAME="${_J_PATHNAME%"$_J_S"*}"
							[ "$_J_DIRNAME" = "$_J_S" ] && _J_DIRNAME=""
							_J_BASENAME="${_J_PATHNAME##*"$_J_S"}"
							_J_BASENAME="$(($_J_BASENAME + 1))"
							_J_PATHNAME="$_J_DIRNAME$_J_S$_J_BASENAME"
							_J_STATE="array-odd"
							continue;;
						"]") exit;;
					esac;;
			esac
			case "$_J_C" in
				"\"") _J_STATE="string" _J_V="" _J_ESCAPED=0;;
				"-") _J_STATE="number-negative" _J_V="$_J_C";;
				0) _J_STATE="number-leading-zero" _J_V="$_J_C";;
				[1-9]) _J_STATE="number-leading-nonzero" _J_V="$_J_C";;
				"[")
					(
						[ "$_J_PATHNAME" = "/" ] && _J_PATHNAME=""
						_J_PATHNAME="$_J_PATHNAME/0"
						_J_STATE="array-0" _J_STATE_DEFAULT="array-even"
						_json
					)
					_J_STATE="$_J_STATE_DEFAULT" _J_V="";;
				"f"|"t") _J_STATE="boolean" _J_V="$_J_C";;
				"n") _J_STATE="null" _J_V="$_J_C";;
				"{")
					(
						_J_STATE="object-0" _J_STATE_DEFAULT="object-even"
						_json
					)
					_J_STATE="$_J_STATE_DEFAULT" _J_V="";;
				"	"|""|" ") ;;
				*) _json_die "syntax: $_J_PATHNAME";;
			esac;;
		"boolean")
			case "$_J_V$_J_C" in
				"f"|"fa"|"fal"|"fals"|"t"|"tr"|"tru") _J_V="$_J_V$_J_C";;
				"false"|"true")
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME boolean $_J_V$_J_C" >&$_J_FD;;
				*) _json_die "syntax: $_J_PATHNAME boolean $_J_V$_J_C";;
			esac;;
		"object-0")
			case "$_J_C" in
				"\"")
					_J_FD=4
					_J_STATE="string"
					_J_STATE_DEFAULT="object-value"
					_J_V="" _J_ESCAPED=0;;
				# Empty object (not the root): emit a marker line.
				"}") [ "$_J_PATHNAME" = "/" ] || echo "$_J_PATHNAME object" >&$_J_FD; exit;;
				"	"|""|" ") ;;
				*) _json_die "syntax: $_J_PATHNAME";;
			esac;;
		"object-even")
			case "$_J_C" in
				"\"")
					_J_FD=4
					_J_STATE="string"
					_J_STATE_DEFAULT="object-value"
					_J_V="" _J_ESCAPED=0;;
				",") _J_STATE="object-odd";;
				"}") exit;;
				"	"|""|" ") ;;
				*) _json_die "syntax: $_J_PATHNAME";;
			esac;;
		"object-exit")
			case "$_J_C" in
				",") exit 101;;
				"}") exit 102;;
				*) exit 0;;
			esac;;
		"object-odd")
			case "$_J_C" in
				"\"")
					_J_FD=4
					_J_STATE="string"
					_J_STATE_DEFAULT="object-value"
					_J_V="" _J_ESCAPED=0;;
				"	"|""|" ") ;;
				*) _json_die "syntax: $_J_PATHNAME";;
			esac;;
		"object-value")
			case "$_J_C" in
				":")
					_J_FD=1
					(
						[ "$_J_PATHNAME" = "/" ] && _J_PATHNAME=""
						_J_PATHNAME="$_J_PATHNAME/$_J_V"
						_J_STATE="whitespace"
						_J_STATE_DEFAULT="object-exit"
						_json
					) || case "$?" in
						101) _J_STATE="object-even" _J_C="," _json_char;;
						102) _J_STATE="object-even" _J_C="}" _json_char;;
					esac
					_J_STATE="object-even";;
				"	"|""|" ") ;;
				*) _json_die "syntax: $_J_PATHNAME";;
			esac;;
		"null")
			case "$_J_V$_J_C" in
				"n"|"nu"|"nul") _J_V="$_J_V$_J_C";;
				"null")
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME null null" >&$_J_FD;;
				*) _json_die "syntax: $_J_PATHNAME null $_J_V$_J_C";;
			esac;;
		"number-float")
			case "$_J_C" in
				[0-9]) _J_V="$_J_V$_J_C";;
				"E"|"e") _J_STATE="number-sci" _J_V="$_J_V$_J_C";;
				*)
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME number $_J_V" >&$_J_FD
					_json_char;;
			esac;;
		"number-leading-nonzero")
			case "$_J_C" in
				".") _J_STATE="number-float" _J_V="$_J_V$_J_C";;
				[0-9]) _J_V="$_J_V$_J_C";;
				"E"|"e") _J_STATE="number-sci" _J_V="$_J_V$_J_C";;
				*)
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME number $_J_V" >&$_J_FD
					_json_char;;
			esac;;
		"number-leading-zero")
			case "$_J_C" in
				".") _J_STATE="number-float" _J_V="$_J_V$_J_C";;
				[0-9]) _json_die "syntax: $_J_PATHNAME number $_J_V$_J_C";;
				"E"|"e") _J_STATE="number-sci" _J_V="$_J_V$_J_C";;
				*)
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME number $_J_V" >&$_J_FD
					_json_char;;
			esac;;
		"number-negative")
			case "$_J_C" in
				0) _J_STATE="number-leading-zero" _J_V="$_J_V$_J_C";;
				[1-9])
					_J_STATE="number-leading-nonzero"
					_J_V="$_J_V$_J_C";;
				*)
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME number $_J_V" >&$_J_FD
					_json_char;;
			esac;;
		"number-sci")
			case "$_J_C" in
				"+") _J_STATE="number-sci-pos" _J_V="$_J_V$_J_C";;
				"-") _J_STATE="number-sci-neg" _J_V="$_J_V$_J_C";;
				[0-9]) _J_STATE="number-sci-pos" _J_V="$_J_V$_J_C";;
				*) _json_die "syntax: $_J_PATHNAME number $_J_V$_J_C";;
			esac;;
		"number-sci-neg"|"number-sci-pos")
			case "$_J_C" in
				[0-9]) _J_V="$_J_V$_J_C";;
				*)
					_J_STATE="$_J_STATE_DEFAULT"
					echo "$_J_PATHNAME number $_J_V" >&$_J_FD
					_json_char;;
			esac;;
		"string")
			# Passthrough: accumulate the raw string bytes (including backslash
			# escapes) unchanged, so the flat output is a clean, invertible
			# encoding. _json_unescape decodes it. _J_ESCAPED tracks whether the
			# previous char was a backslash, so an escaped quote (\" ) does not
			# terminate the string. (Original vendored version was lossy and
			# inconsistent — some escapes gained a backslash, some lost one.)
			if [ "$_J_ESCAPED" = "1" ]; then
				_J_V="$_J_V$_J_C"
				_J_ESCAPED=0
			else
				case "$_J_C" in
					'\')
						_J_V="$_J_V$_J_C"
						_J_ESCAPED=1;;
					'"')
						_J_STATE="$_J_STATE_DEFAULT"
						echo "$_J_PATHNAME string $_J_V" >&$_J_FD;;
					*)
						_J_V="$_J_V$_J_C";;
				esac
			fi;;
	esac
}

_json_die() {
	echo "json.sh: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# HTTP transport
# ---------------------------------------------------------------------------
# POST $1 (url) with body $2; the response BODY (headers stripped) is
# returned in the global HTTP_BODY. In-memory: nothing is written to disk.
# busybox wget --post-file.
http_post() {
	local url="$1" body="$2"
	# wget (must set Content-Type explicitly; --post-data defaults to
	# application/x-www-form-urlencoded which servers reject). Exits 8 on a
	# 4xx/5xx (server error); wget's own stderr message ("server returned
	# error: HTTP/1.1 401 ...") is left visible. -O - writes the response
	# body (headers stripped) to stdout. The status is the assignment's.
	# The body goes in on stdin (--post-file), not as an argument: a single
	# argv string is capped at 128 KiB on Linux and is visible in ps.
	HTTP_BODY=$(printf '%s' "$body" | "$BB" wget -q $WGET_TO \
		${KEY:+--header="Authorization: Bearer $KEY"} \
		--header="Content-Type: application/json" \
		--post-file=/dev/stdin -O - "$url")
}


# POST $1 (url) with body $2, streaming the SSE response. Each data chunk's
# content and reasoning are printed live to stderr as they arrive; the full
# response is reassembled into a non-streamed chat-completion shape and
# returned in the global HTTP_BODY (so the rest of the pipeline is unchanged).
# The right side of the pipe runs in a subshell: it reads the stream line by
# line, accumulates, and emits the synthesized response on stdout (captured
# by $(...)); the live output goes to stderr (not captured).
http_post_stream() {
	local url="$1" body="$2"
	HTTP_BODY=$(
		printf '%s' "$body" | "$BB" wget -q $WGET_TO \
			${KEY:+--header="Authorization: Bearer $KEY"} \
			--header="Content-Type: application/json" \
			--post-file=/dev/stdin -O - "$url" |
		{
			S_CONTENT=""
			S_REASONING=""
			S_RKEY=reasoning
			S_THINKING=0
			S_FINISH=""
			S_TC_COUNT=0
			S_RECEIVED=0
			while IFS= read -r line; do
				line="${line%$'\r'}"
				case "$line" in
					"data: "*) data="${line#data: }";;
					"data:"*) data="${line#data:}"; data="${data# }";;
					*) continue;;
				esac
				[ "$data" = "[DONE]" ] && break
				S_RECEIVED=1
				flat=$(printf '%s' "$data" | json 2>/dev/null)
				[ -n "$flat" ] || continue
				# Walk the chunk's flat lines ("/path type value") with builtins
				# only. Content is printed live; reasoning too, with a [thinking]
				# prefix at the start of each contiguous block; tool-call
				# fragments are accumulated by index (id/name arrive first, the
				# arguments in pieces, possibly in chunks without an id).
				# A chunk's tool_calls array holds one entry whose real slot is its
				# "index" field (not its array position, which is always 0), so
				# map position -> index first; the field may follow id/name.
				tcmap=""
				case "$flat" in
					*/tool_calls/*/index\ number\ *)
						while IFS= read -r l; do
							case "$l" in
								/choices/0/delta/tool_calls/*/index\ number\ *)
									rest="${l#/choices/0/delta/tool_calls/}"
									tcmap="$tcmap ${rest%%/*}=${l##* }";;
							esac
						done <<EOF
$flat
EOF
						;;
				esac
				while IFS= read -r l; do
					case "$l" in
						"/choices/0/delta/content string "*)
							# Sentinel: $(...) would strip a chunk's trailing
							# newlines (a "\n" token would vanish).
							c=$(json_unescape "${l#* string }"; printf x); c="${c%x}"
							printf '%s' "$c" >&2
							S_CONTENT="$S_CONTENT$c"
							S_THINKING=0;;
						"/choices/0/delta/reasoning string "*|"/choices/0/delta/reasoning_content string "*)
							case "$l" in /choices/0/delta/reasoning_content*) S_RKEY=reasoning_content;; esac
							r=$(json_unescape "${l#* string }"; printf x); r="${r%x}"
							[ "$S_THINKING" -eq 0 ] && printf '[thinking] ' >&2
							printf '%s' "$r" >&2
							S_THINKING=1
							S_REASONING="$S_REASONING$r";;
						"/choices/0/finish_reason string "*) S_FINISH="${l#* string }";;
						/choices/0/delta/tool_calls/*)
							rest="${l#/choices/0/delta/tool_calls/}"
							idx="${rest%%/*}"; rest="${rest#*/}"
							case "$idx" in ''|*[!0-9]*) continue;; esac
							case "$tcmap" in
								*" $idx="*) idx="${tcmap#* $idx=}"; idx="${idx%% *}"; case "$idx" in ''|*[!0-9]*) continue;; esac;;
								# No "index" field (some servers): a new id opens the next
								# slot, anything else continues the latest one.
								*) new=$S_TC_COUNT
									case "$rest" in "id string "*) :;; *) [ "$new" -gt 0 ] && new=$((new - 1));; esac
									tcmap="$tcmap $idx=$new"; idx=$new;;
							esac
							v="${rest#* string }"
							case "$rest" in
								# eval sees only \$v, never its contents, so no escaping.
								"id string "*) eval "S_TC_ID_$idx=\$v";;
								"function/name string "*) eval "S_TC_NAME_$idx=\$v";;
								"function/arguments string "*)
									eval "S_TC_ARGS_$idx=\"\${S_TC_ARGS_$idx:-}\$v\"";;
								*) continue;;
							esac
							[ "$idx" -ge "$S_TC_COUNT" ] && S_TC_COUNT=$((idx + 1));;
					esac
				done <<EOF
$flat
EOF
			done
			# No data received (e.g. wget failed) — fail rather than synthesize.
			[ "$S_RECEIVED" -eq 1 ] || exit 1
			# Synthesize a non-streamed response from the accumulated stream.
			msg=""
			if [ -n "$S_CONTENT" ]; then
				msg="${msg}\"content\":\"$(json_escape "$S_CONTENT")\""
			else
				msg="${msg}\"content\":null"
			fi
			if [ -n "$S_REASONING" ]; then
				msg="${msg},\"$S_RKEY\":\"$(json_escape "$S_REASONING")\""
			fi
			if [ "$S_TC_COUNT" -gt 0 ]; then
				tc_json=""
				i=0
				while [ "$i" -lt "$S_TC_COUNT" ]; do
					eval 'tcid="${S_TC_ID_'$i':-}"'
					eval 'tcname="${S_TC_NAME_'$i':-}"'
					eval 'tcargs="${S_TC_ARGS_'$i':-}"'
					tcargs=$(json_unescape "$tcargs")
					[ -n "$tcname" ] || tcname="shell"
					tc_obj="{\"id\":\"$(json_escape "$tcid")\",\"type\":\"function\",\"function\":{\"name\":\"$(json_escape "$tcname")\",\"arguments\":\"$(json_escape "$tcargs")\"}}"
					if [ -n "$tc_json" ]; then
						tc_json="$tc_json, $tc_obj"
					else
						tc_json="$tc_obj"
					fi
					i=$((i + 1))
				done
				msg="${msg},\"tool_calls\":[$tc_json]"
			fi
			printf '{"choices":[{"message":{"role":"assistant",%s},"finish_reason":"%s"}]}' "$msg" "$(json_escape "$S_FINISH")"
		}
	)
	[ -n "$HTTP_BODY" ]
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------
# No sandbox of its own: the user wraps agent.sh in whatever sandbox they
# want (podman, bwrap, unshare, firejail, ...). agent.sh just runs each
# command as a plain child of the harness, with the defense-in-depth layers
# that don't depend on a sandbox:
#   - env scrub: the full AGENT_* set removed so a prompt-injected
#     command cannot read the API key or the task text.
#   - per-command timeout (-T / AGENT_TIMEOUT, default 300, 0 = unlimited): the
#     command runs in its own session (setsid) and a watchdog SIGKILLs the whole
#     process group, so children (and background jobs still holding the output
#     pipe) die too; `timeout` alone would kill only the shell.
#   - output truncation (head -c "$MAX_OUTPUT", default 16384, 0 = unlimited), with the
#     "[exit status: N]" line appended after it so it is never cut off.
# The -w workdir is a hint to the model (the one place it's told it can
# write); it is not enforced here.
run_command() {
	local cmd="$1" cap rc wd=""
	# fd 3 carries the watchdog pid and the exit status to the $(...) capture;
	# fd 4 is this function's stdout (the truncated output). Both are closed for
	# the command and the watchdog so they cannot keep the capture pipe open.
	# The AGENT_* config vars are scrubbed (incl. AGENT_TASK, which may hold
	# sensitive task text) so a prompt-injected command cannot read them.
	{ cap=$( { {
		env $AGENT_SCRUB setsid "$EXEC_SHELL" -c "$cmd" 2>&1 </dev/null 3>&- 4>&- &
		pid=$!
		if [ "$CMD_TIMEOUT" -gt 0 ]; then
			( trap 'kill $sp 2>/dev/null; exit' TERM
			sleep "$CMD_TIMEOUT" & sp=$!
			wait $sp && kill -KILL -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null 3>&- 4>&- &
			echo $! >&3
		fi
		wait $pid
		echo $? >&3
	} 2>/dev/null | truncate_output >&4; } 3>&1 ); } 4>&1
	rc="${cap##*$'\n'}"
	[ "$rc" = "$cap" ] || { wd="${cap%%$'\n'*}"; kill "$wd" 2>/dev/null; }
	# A watchdog kill (SIGKILL) reads as the timeout's usual exit status.
	[ "$rc" -eq 137 ] && [ "$CMD_TIMEOUT" -gt 0 ] && rc=124
	# Tell the model about a failure.
	[ "$rc" -eq 0 ] || printf '\n[exit status: %s]\n' "$rc"
	return "$rc"
}

# Truncate a tool result to MAX_OUTPUT bytes (0 = unlimited), never cutting a
# UTF-8 character in half. Reads one byte past the cap: if that byte is a
# continuation byte (0x80-0xBF) the cut fell mid-character, so the partial
# character is dropped. (`head -c 0` prints nothing, hence the > 0 guard.)
truncate_output() {
	if [ "$MAX_OUTPUT" -gt 0 ]; then
		local LC_ALL=C o lo hi cut
		lo=$(printf '\200') hi=$(printf '\277')
		o=$(head -c "$((MAX_OUTPUT + 1))"; printf x); o="${o%x}"
		# Drain the rest so the writer never gets SIGPIPE (it would die mid-run).
		cat >/dev/null
		if [ "${#o}" -gt "$MAX_OUTPUT" ]; then
			case "${o: -1}" in [$lo-$hi]) cut=1;; esac
			o="${o%?}"
			if [ -n "$cut" ]; then
				while case "${o: -1}" in [$lo-$hi]) :;; *) false;; esac; do o="${o%?}"; done
				o="${o%?}"
			fi
			o="$o"$'\n[output truncated]'
		fi
		printf '%s' "$o"
	else
		cat
	fi
}

# Load a skill by name: $WORKDIR/.agents/skills/<name>/SKILL.md. The name is
# validated to [A-Za-z0-9_-]+ so a model (or a prompt-injected skill body)
# cannot traverse out of the skills dir. The content is loaded in full (skills
# are the user's own files, not model output, so no max-output cap).
# On success, prints the skill content and returns 0; on failure, prints
# an error (with the available names so the model can self-correct) and
# returns 1.
load_skill() {
	local name="$1"
	case "$name" in
		''|.|..|*[!A-Za-z0-9_-]*)
			printf 'invalid skill name: %s\nAvailable skills:\n%s' "$name" "$SKILL_LIST"
			return 1;;
	esac
	local path="$WORKDIR/.agents/skills/$name/SKILL.md"
	if [ ! -f "$path" ]; then
		printf 'skill not found: %s\nAvailable skills:\n%s' "$name" "$SKILL_LIST"
		return 1
	fi
	printf '%s' "$(cat "$path")"
}

# ---------------------------------------------------------------------------
# Sub-agents (delegate)
# ---------------------------------------------------------------------------
# Spawn a nested agent.sh to work a sub-task; its final answer (stdout) is
# the tool result. The child gets the parent's resolved settings via
# explicit AGENT_* assignments (endpoint, model, key, base system prompt,
# params, shell, workdir, timeouts, max-output, max-turns, stream, MCP) plus
# AGENT_DEPTH = depth - 1
# and AGENT_ASK=0 (a child never prompts; in ask mode the spawn itself is
# confirmed by the parent). The base prompt is passed, not the resolved one
# — the child re-derives its own skills section and AGENTS.md from the same
# workdir, so nothing is duplicated. The full AGENT_* set is scrubbed from
# the inherited environment (like run_command) so the parent's task/key
# cannot leak.
# No total timeout by default (the main agent has none either); an optional
# timeout (seconds) arms a watchdog that SIGKILLs the child's process group.
# On success, prints the child's final answer (truncated) and returns 0;
# on failure, prints an error (so the model can self-correct) and returns 1.
spawn_subagent() {
	local task="$1" timeout_s="$2" script="" out rc pid wd="" sp
	# Only the child's stdout (its final answer) is captured as the tool
	# result; the child's stderr (turn diagnostics) passes through to the
	# parent's stderr, so the user sees the nested run's progress.
	# The command is built in "$@" (not a string) so paths with spaces work.
	case "$SELF" in
		http://*|https://*)
			# wget the script into a variable (no temp file), then pipe it
			# into busybox ash -s - (busybox ash reads the script from stdin).
			script=$("$BB" wget -q --timeout=60 -O - "$SELF" 2>/dev/null)
			[ -n "$script" ] || { printf 'delegate: could not fetch %s\n' "$SELF"; return 1; }
			set -- "$BB" ash -s -;;
		'')
			printf 'delegate: AGENT_SELF not set\n'
			return 1;;
		*)
			# Path form: run the script via busybox ash (no execute bit needed —
			# agent.sh is a source script, not an executable).
			[ -f "$SELF" ] || { printf 'delegate: script not found: %s\n' "$SELF"; return 1; }
			set -- "$BB" ash "$SELF";;
	esac
	# The child runs in its own session (setsid); a timeout watchdog SIGKILLs the
	# whole process group (like run_command), so its commands die with it.
	# The exit status is appended after the output on its own line.
	out=$(
	printf '%s' "$script" | env $AGENT_SCRUB \
		AGENT_TASK="$task" AGENT_KEY="$KEY" AGENT_ENDPOINT="$ENDPOINT" \
		AGENT_MODEL="$MODEL" AGENT_SYSTEM_PROMPT="${CUSTOM_PROMPT:+$BASE_PROMPT}" \
		AGENT_PARAMS="$PARAMS" AGENT_SHELL="$EXEC_SHELL" \
		AGENT_SELF="$SELF" \
		AGENT_WORKDIR="$WORKDIR" AGENT_TIMEOUT="$CMD_TIMEOUT" \
		AGENT_HTTP_TIMEOUT="$HTTP_TIMEOUT" AGENT_MAX_OUTPUT="$MAX_OUTPUT" AGENT_MAX_TURNS="$MAX_TURNS" \
		AGENT_DEPTH="$((DEPTH - 1))" AGENT_ASK=0 \
		AGENT_STREAM="$STREAM" AGENT_MCP="$MCP" \
		setsid "$@" &
	pid=$!
	if [ -n "$timeout_s" ]; then
		( trap 'kill $sp 2>/dev/null; exit' TERM
		sleep "$timeout_s" & sp=$!
		wait $sp && kill -KILL -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
		wd=$!
	fi
	wait $pid 2>/dev/null; rc=$?
	[ -z "$wd" ] || kill $wd 2>/dev/null
	printf '\n%s' "$rc"
	)
	rc="${out##*$'\n'}"; out="${out%$'\n'*}"
	[ "$rc" -eq 137 ] && [ -n "$timeout_s" ] && rc=124
	if [ "$rc" -ne 0 ]; then
		printf 'delegate: sub-agent failed (exit %s)\n%s\n' "$rc" "$out"
		return 1
	fi
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Ask prompt
# ---------------------------------------------------------------------------
# Prompt the user to confirm a command. Returns 0 = run, 1 = denied, 2 = quit.
# Reads from stdin so it works both interactively and when input is piped. When
# the script itself arrives on stdin (`busybox wget ... | ash -s -`, so $0 is not a
# file) stdin holds the script text, so the answer is read from /dev/tty instead.
ask_prompt() {
	local cmd="$1"
	local ans
	while :; do
		printf 'run: %s ? [y/n/q] ' "$cmd" >&2
		if [ -f "$0" ] && [ -z "$STDIN_TASK" ]; then read -r ans || ans="n"; else { read -r ans </dev/tty; } 2>/dev/null || ans="n"; fi
		case "$ans" in
			y|Y|yes) return 0;;
			n|N|no) return 1;;
			q|Q|quit) return 2;;
			*) printf '  (y/n/q) ' >&2;;
		esac
	done
}

# Run-or-deny gate for a tool call: always yes unless --ask; on "q" the whole
# agent aborts. Returns 0 = run, 1 = denied.
confirm() {
	[ "$ASK" = "1" ] || return 0
	ask_prompt "$1" && return 0
	[ "$?" -ne 2 ] || { printf '[agent] aborted\n' >&2; exit 1; }
	return 1
}

# ---------------------------------------------------------------------------
# Request building
# ---------------------------------------------------------------------------
# Messages are accumulated in $MSGS as the inner content of a JSON array
# (comma-separated message objects). add_msg appends one message object.
MSGS=""
add_msg() {
	local m="$1"
	if [ -n "$MSGS" ]; then
		MSGS="$MSGS, $m"
	else
		MSGS="$m"
	fi
}

# Is $1 a valid JSON number? Decides whether a -P/AGENT_PARAMS value is
# emitted as a bare number or a JSON string.
is_json_number() {
	printf '%s' "$1" | grep -qE '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
}

# Classify a -P/AGENT_PARAMS value into a JSON literal: { or [ prefix = raw
# JSON (e.g. Anthropic-style thinking objects), number/true/false/null as-is,
# anything else a JSON string.
param_value_json() {
	local v="$1"
	case "$v" in
		{*) printf '%s' "$v";;
		'['*) printf '%s' "$v";;
		true|false|null) printf '%s' "$v";;
		-*|[0-9]*) if is_json_number "$v"; then printf '%s' "$v"; else printf '"%s"' "$(json_escape "$v")"; fi;;
		*) printf '"%s"' "$(json_escape "$v")";;
	esac
}

# Build the model-parameters fragment: ,"k":v,"k":v (empty if none).
# Splits on ; manually (not word-splitting) so values may contain spaces.
build_params() {
	local rest="$PARAMS" p k v out=""
	while [ -n "$rest" ]; do
		p="${rest%%;*}"
		if [ "$p" = "$rest" ]; then rest=""; else rest="${rest#*;}"; fi
		[ -n "$p" ] || continue
		# Split on the first = only (the value may contain = inside raw JSON).
		k="${p%%=*}"
		v="${p#*=}"
		[ "$k" = "$p" ] && continue   # no '=': ignore
		[ -n "$k" ] || continue        # empty key: ignore
		out="$out,\"$(json_escape "$k")\":$(param_value_json "$v")"
	done
	printf '%s' "$out"
}

# The full AGENT_* env-scrub list, shared by every child we spawn
# (run_command, spawn_subagent). Removing the whole set keeps a
# prompt-injected command from reading the API key, the task text, or any
# other config.
AGENT_SCRUB="-u AGENT_KEY -u AGENT_ENDPOINT -u AGENT_TASK -u AGENT_WORKDIR -u AGENT_PARAMS -u AGENT_SELF -u AGENT_DEPTH -u AGENT_MODEL -u AGENT_SYSTEM_PROMPT -u AGENT_SHELL -u AGENT_MAX_TURNS -u AGENT_TIMEOUT -u AGENT_MAX_OUTPUT -u AGENT_HTTP_TIMEOUT -u AGENT_ASK -u AGENT_STREAM -u AGENT_MCP"

# Build the tools array (shell always; skill only when skills are present;
# delegate only when AGENT_SELF is set and depth > 0; MCP tools when servers
# are configured and discovered).
build_tools() {
	local tools="{\"type\":\"function\",\"function\":{\"name\":\"shell\",\"description\":\"Run a shell command. Returns combined stdout/stderr, truncated.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"The shell command to run.\"}},\"required\":[\"command\"]}}}"
	if [ "$SKILLS_ENABLED" = "1" ]; then
		tools="$tools,{\"type\":\"function\",\"function\":{\"name\":\"skill\",\"description\":\"Load the full text of a skill by name (see the skill list in the system prompt).\",\"parameters\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"The skill name to load.\"}},\"required\":[\"name\"]}}}"
	fi
	if [ -n "$SELF" ] && [ "$DEPTH" -gt 0 ]; then
		tools="$tools,{\"type\":\"function\",\"function\":{\"name\":\"delegate\",\"description\":\"Spawn a sub-agent (a nested agent.sh run) to work a sub-task. It blocks until the sub-agent finishes and returns its final answer. Use it for self-contained sub-tasks that would take several shell commands.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"The sub-task for the sub-agent.\"},\"timeout\":{\"type\":\"number\",\"description\":\"Optional total timeout for the sub-agent, in seconds.\"}},\"required\":[\"task\"]}}}"
	fi
	# MCP tools: one per discovered tool, with the server's inputSchema.
	# Nested parameter expansion is not supported by busybox ash, so the
	# indexed MCP_* variables are read via eval.
	if [ "$MCP_COUNT" -gt 0 ]; then
		local i=0
		while [ "$i" -lt "$MCP_COUNT" ]; do
			eval 'mcp_adv="${MCP_ADV_'"$i"':-}"'
			eval 'mcp_server="${MCP_SERVER_'"$i"':-}"'
			eval 'mcp_tool="${MCP_TOOL_'"$i"':-}"'
			eval 'mcp_desc="${MCP_DESC_'"$i"':-}"'
			eval 'mcp_schema="${MCP_SCHEMA_'"$i"':-}"'
			[ -n "$mcp_desc" ] || mcp_desc="(no description)"
			tools="$tools,{\"type\":\"function\",\"function\":{\"name\":\"$(json_escape "$mcp_adv")\",\"description\":\"$(json_escape "MCP $mcp_server.$mcp_tool: $mcp_desc")\",\"parameters\":$mcp_schema}}"
			i=$((i + 1))
		done
	fi
	printf '[%s]' "$tools"
}

# Build the full request body for the current message list.
build_request() {
	# $MSGS already holds the full message list (system + user + history).
	printf '{\n  "model": "%s",\n  "messages": [%s],\n  "tools": %s,\n  "tool_choice": "auto"%s\n}' \
		"$(json_escape "$MODEL")" "$MSGS" "$(build_tools)" "$(build_params)"
}

# ---------------------------------------------------------------------------
# JSON string unescaping (decode side of the wire protocol)
# ---------------------------------------------------------------------------
# Standard single-layer JSON string unescaping. The vendored json.sh's
# string state is a passthrough (raw JSON string bytes, backslash escapes
# intact), so one pass of this turns a JSON string body into real bytes.
# \uXXXX is decoded to UTF-8 (1-4 bytes, surrogate pairs combined, a lone
# surrogate becomes U+FFFD). \u0000 is dropped — a shell string cannot hold
# a NUL.
json_unescape() {
	local s="$1" b="" out="" e hex d dv
	# Force byte semantics so ${b#?} consumes one byte, not one character.
	local LC_ALL=C
	# Consume s through a small window b (refilled 512 bytes at a time, so
	# every pattern scan is bounded): copy the run up to the next backslash
	# in one step, then decode the escape. Scanning the whole of s per escape
	# is quadratic (minutes for a 50 KB string). An escape is at most 12
	# bytes (\uXXXX\uXXXX), so refill when fewer remain after a backslash.
	while :; do
		if [ "${#b}" -lt 12 ] && [ -n "$s" ]; then b="$b${s:0:512}"; s="${s:512}"; fi
		case "$b" in
			*\\*) ;;
			*) out="$out$b"; b=""; [ -n "$s" ] && continue; break;;
		esac
		out="$out${b%%\\*}"
		b="${b#*\\}"
		if [ "${#b}" -lt 11 ] && [ -n "$s" ]; then b="$b${s:0:512}"; s="${s:512}"; fi
		e="${b%"${b#?}"}"
		b="${b#?}"
		case "$e" in
			n) out="${out}"$'\n';;
			r) out="${out}"$'\r';;
			t) out="${out}"$'\t';;
			b) out="${out}"$'\x08';;
			f) out="${out}"$'\x0c';;
			'"') out="${out}\"";;
			/ ) out="${out}/";;
			'\') out="${out}\\";;
			u)
				hex="${b:0:4}"
				case "$hex" in
					????) case "$hex" in *[!0-9a-fA-F]*) d=0;; *) d=$((0x$hex));; esac; b="${b#????}";;
					*) d=0; b="";;   # malformed/short: treat as 0
				esac
				# A high surrogate followed by \uDC00-\uDFFF is one astral
				# code point; a lone surrogate becomes U+FFFD.
				if [ "$d" -ge 55296 ] && [ "$d" -le 57343 ]; then
					hex="${b:2:4}"
					dv=0
					if [ "$d" -le 56319 ] && [ "${b:0:2}" = '\u' ]; then
						case "$hex" in *[!0-9a-fA-F]*|'') ;; *) dv=$((0x$hex));; esac
					fi
					if [ "$dv" -ge 56320 ] && [ "$dv" -le 57343 ]; then
						d=$(( 65536 + ((d - 55296) << 10) + dv - 56320 ))
						b="${b#??????}"
					else
						d=65533
					fi
				fi
				if [ "$d" -lt 128 ]; then
					# NUL/LF/CR must not pass through command substitution
					# ($(...) drops NUL and strips a trailing newline).
					case "$d" in
						0) : ;;
						10) out="${out}"$'\n';;
						13) out="${out}"$'\r';;
						*) out="${out}$(printf "\\$(printf '%03o' "$d")")";;
					esac
				elif [ "$d" -lt 2048 ]; then
					out="${out}$(printf "$(printf '\\%03o\\%03o' $(( (d >> 6) | 0xC0 )) $(( (d & 63) | 0x80 )))")"
				elif [ "$d" -lt 65536 ]; then
					out="${out}$(printf "$(printf '\\%03o\\%03o\\%03o' $(( (d >> 12) | 0xE0 )) $(( ((d >> 6) & 63) | 0x80 )) $(( (d & 63) | 0x80 )))")"
				else
					out="${out}$(printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(( (d >> 18) | 0xF0 )) $(( ((d >> 12) & 63) | 0x80 )) $(( ((d >> 6) & 63) | 0x80 )) $(( (d & 63) | 0x80 )))")"
				fi
				;;
			*) out="${out}\\$e";;
		esac
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# MCP (Model Context Protocol) support
# ---------------------------------------------------------------------------
# Connect MCP servers and expose their tools to the model. Each server is
# configured with -M name=url / AGENT_MCP: value is a http:// or https://
# URL (Streamable HTTP transport, MCP spec 2025-06-18).
#
# One HTTP POST per request via busybox wget --post-file (the same tool
# the agent uses for the model endpoint). Streamable HTTP responses are
# typically chunked with Connection: keep-alive; busybox nc closes the
# socket on stdin EOF and captures only the headers, so wget is used.
# Responses are either application/json or text/event-stream (SSE); the
# JSON-RPC body is extracted from the first data: line when SSE.
# Sessions: wget -S exposes the response headers on stderr, so the
# Mcp-Session-Id of initialize is kept per server and sent on every later
# request. A broken server (bad URL, timeout, parse error) warns and is skipped — it never breaks the agent.
#
# Advertised tool names are mcp_<server>_<tool> (sanitized to the OpenAI
# name charset [a-zA-Z0-9_-]); the mapping to (server, original tool) is
# kept in indexed variables MCP_SERVER_i / MCP_TOOL_i / MCP_COUNT.

# Replace every char outside [a-zA-Z0-9_-] with _. Used to build the
# advertised mcp_<server>_<tool> name from an arbitrary MCP tool name.
mcp_sanitize() {
	local s="$1" LC_ALL=C
	printf '%s' "${s//[!a-zA-Z0-9_-]/_}"
}

# Parse one vendored-json flat line into FLAT_PATH / FLAT_TYPE / FLAT_VALUE.
# A flat line is "<path> <type> <value>" where type is one of
# string|number|boolean|null. The type is the LEFTMOST occurrence of
# " <kw> " (or " <kw>" at end of line) — this distinguishes a type keyword
# (preceded by a space) from a key that merely looks like one (preceded by /).
# The value is everything after "<type> ", so it may itself contain spaces
# (keys/values with spaces survive).
flat_parse() {
	# A trailing space is appended so every type keyword is followed by a
	# space (a valueless marker line ends right after it); builtins only.
	local l="$1 " best_off=-1 best_kw="" kw pre
	FLAT_PATH="" FLAT_TYPE="" FLAT_VALUE=""
	for kw in string number boolean null array object; do
		pre="${l%% $kw *}"
		[ "$pre" != "$l" ] || continue
		if [ "$best_off" -lt 0 ] || [ "${#pre}" -lt "$best_off" ]; then
			best_off=${#pre}
			best_kw=$kw
		fi
	done
	[ "$best_off" -ge 0 ] || return 1
	FLAT_PATH="${l:0:$best_off}"
	FLAT_TYPE="$best_kw"
	FLAT_VALUE="${l:$((best_off + ${#best_kw} + 2))}"
	FLAT_VALUE="${FLAT_VALUE% }"
	return 0
}

# Reconstruct a raw JSON node from the vendored json.sh flat output, at the
# given prefix ("" for the root). The flattener emits only leaf lines
# ("/path type value"), so object/array structure is inferred: a node whose
# children are integer-indexed (0,1,2,...) is an array, otherwise an object.
# Strings are decoded and re-escaped (the flat body carries the raw
# JSON-escaped body). Limitation: keys containing "/" are
# ambiguous in the flat encoding and are unsupported.
json_from_flat() {
	local flat="$1" prefix="$2" NL=$'\n' t="" v c ln sub="" children="" is_array=0
	# One in-process pass over the lines: find the leaf line (path == prefix)
	# or collect the subtree's lines and distinct child keys. Children get
	# only their subtree (so work shrinks with depth); no forks, and no
	# whole-document pattern matching (slow in ash: minutes for a tool list).
	while IFS= read -r ln; do
		case "$ln" in
			"$prefix"\ *)
				flat_parse "$ln" && [ "$FLAT_PATH" = "$prefix" ] && { t=$FLAT_TYPE; v=$FLAT_VALUE; break; };;
			"$prefix"/*)
				flat_parse "$ln" || continue
				sub="${sub:+$sub$NL}$ln"
				c="${FLAT_PATH#"$prefix"/}"; c="${c%%/*}"
				[ -n "$c" ] || continue
				case "$NL$children$NL" in *"$NL$c$NL"*) continue;; esac
				children="${children:+$children$NL}$c"
				case "$c" in *[!0-9]*) ;; *) is_array=1;; esac;;
		esac
	done <<EOF
$flat
EOF
	if [ -n "$t" ]; then
		case "$t" in
			string) printf '"%s"' "$(json_escape "$(json_unescape "$v")")";;
			number|boolean) printf '%s' "$v";;
			null) printf 'null';;
			array) printf '[]';;
			object) printf '{}';;
		esac
		return 0
	fi
	[ -n "$children" ] || { printf '{}'; return 0; }
	local out="" sep=""
	if [ "$is_array" = "1" ]; then
		local i=0
		while :; do
			case "$NL$children$NL" in *"$NL$i$NL"*) ;; *) break;; esac
			out="$out$sep$(json_from_flat "$sub" "$prefix/$i")"
			sep=", "
			i=$((i + 1))
		done
		printf '[%s]' "$out"
	else
		while IFS= read -r c; do
			out="$out$sep\"$(json_escape "$c")\":$(json_from_flat "$sub" "$prefix/$c")"
			sep=", "
		done <<EOF
$children
EOF
		printf '{%s}' "$out"
	fi
}

# POST a JSON-RPC request to an MCP Streamable HTTP server via busybox
# wget. $1 = URL, $2 = JSON-RPC method, $3 = JSON-RPC params (a JSON
# object string; empty for notifications), $4 = 1 for a notification
# (no id field), 0 otherwise. The response BODY (headers stripped) is
# stored in the global MCP_HTTP_BODY. Returns 0 on success, 1 on failure.
#
# wget (not nc): Streamable HTTP responses are typically chunked with
# Connection: keep-alive, and busybox nc closes the socket on stdin EOF,
# capturing only the headers before the body arrives. wget --post-file
# reads the full body and exits when the response is complete — the same
# tool the agent uses for the model endpoint. wget -S puts the response
# headers on stderr, which is how Mcp-Session-Id is read.
mcp_http_post() {
	local url="$1" method="$2" params="$3"
	local is_notification="${4:-0}"
	# Build the JSON-RPC body.
	local body
	if [ "$is_notification" = "1" ]; then
		body="{\"jsonrpc\":\"2.0\",\"method\":\"$method\"}"
	else
		body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
	fi
	# Accept both SSE and JSON (Streamable HTTP responses are usually SSE).
	# wget --post-data defaults to application/x-www-form-urlencoded, so
	# set Content-Type explicitly. -O - writes the body (headers stripped)
	# to stdout; exits 8 on a 4xx/5xx.
	# Fixed 120s timeout (unlike http_post / http_post_stream, not -H): this is a
	# harness HTTP-client operation, not a model command, so it does not use
	# CMD_TIMEOUT (the per-command timeout, which may be 0 = unlimited — an
	# unlimited MCP POST would hang the agent on a hung server).
	# The body goes in on stdin (--post-file), like http_post: no argv cap,
	# not visible in ps. MCP-Protocol-Version is required after initialize.
	# -S prints the response headers on stderr (merged into the capture): the
	# Mcp-Session-Id header is read into MCP_RSID, and the header lines are
	# dropped from the body. MCP_SID (if set) is sent back on every request.
	local raw
	raw=$(printf '%s' "$body" | "$BB" wget -q -S --timeout=120 \
		--header="Content-Type: application/json" \
		--header="Accept: application/json, text/event-stream" \
		--header="MCP-Protocol-Version: 2025-06-18" \
		${MCP_SID:+--header="Mcp-Session-Id: $MCP_SID"} \
		--post-file=/dev/stdin -O - "$url" 2>&1) || return 1
	raw="${raw//$'\r'/}"
	MCP_RSID=$(printf '%s\n' "$raw" | sed -n 's/^  [Mm][Cc][Pp]-[Ss][Ee][Ss][Ss][Ii][Oo][Nn]-[Ii][Dd]: *//p' | head -n1)
	MCP_HTTP_BODY=$(printf '%s\n' "$raw" | grep -vE '^  ($|HTTP/|[A-Za-z0-9-]+: )')
	[ -n "$MCP_HTTP_BODY" ] || return 1
	# CRLF line endings (legal in SSE and HTTP bodies) would break the JSON
	# parser; a raw CR cannot occur inside a JSON string, so drop them all.
	MCP_HTTP_BODY="${MCP_HTTP_BODY//$'\r'/}"
	# The body is either a text/event-stream (the JSON-RPC response is the
	# first data: line) or application/json (the body is the response).
	# Strip the SSE framing if present; a plain JSON body passes through.
	# The space after the colon is optional per the SSE spec (both `data:`
	# and `data: ` are valid), so strip both forms (like http_post_stream).
	# A server may send notifications first: prefer the data line carrying
	# the JSON-RPC result/error, else the first data line.
	local data first
	data=$(printf '%s' "$MCP_HTTP_BODY" | grep -E '^data: ?' | sed 's/^data://; s/^ //')
	first=$(printf '%s\n' "$data" | grep -m1 -E '"(result|error)"')
	[ -n "$first" ] || first=$(printf '%s\n' "$data" | head -n1)
	[ -n "$first" ] && MCP_HTTP_BODY="$first"
	return 0
}

# Parse a tools/call response line into a plain-text result. Handles
# result.content[] (concatenating type:text blocks), result.isError, a
# plain-string result, and JSON-RPC error. Prints the result.
mcp_parse_result() {
	local flat v
	flat=$(printf '%s' "$1" | json 2>/dev/null)
	[ -n "$flat" ] || { printf 'mcp: could not parse response'; return 1; }
	# JSON-RPC error?
	v=$(printf '%s\n' "$flat" | flat_val /error/message string)
	if [ -n "$v" ]; then
		printf 'mcp error: %s' "$(json_unescape "$v")"
		return 1
	fi
	# Plain-string result?
	v=$(printf '%s\n' "$flat" | flat_val /result string)
	if [ -n "$v" ]; then
		printf '%s' "$(json_unescape "$v")"
		return 0
	fi
	# isError: true flags the result; then one line per content[] block: the
	# text of type:text blocks, a note for any other type (image, ...).
	local errflag="" out="" p t
	printf '%s\n' "$flat" | grep -qE '^/result/isError boolean true$' && errflag="mcp tool error: "
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		t="${p##*/type string }"; p="${p%/type string *}"
		if [ "$t" = text ]; then
			v=$(json_unescape "$(printf '%s\n' "$flat" | flat_val "$p/text" string)")
		else
			v="[$t content omitted]"
		fi
		out="$out${out:+
}$v"
	done <<EOF
$(printf '%s\n' "$flat" | grep -E '^/result/content/[0-9]+/type string ')
EOF
	printf '%s%s' "$errflag" "$out"
}

# Discover the tools of one MCP server over Streamable HTTP. $1 = server URL,
# $2 = the server name. Populates the MCP_* mapping variables. The handshake
# is: initialize (id 1) -> notifications/initialized (notification) ->
# tools/list (id 1). Returns 0 on success, 1 on failure (the caller warns
# and skips).
mcp_discover() {
	local url="$1" name="$2"
	# 1. initialize (a fresh session: the server may answer with Mcp-Session-Id).
	MCP_SID=""
	if ! mcp_http_post "$url" "initialize" '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent.sh","version":"1.0"}}' 0; then
		return 1
	fi
	# A JSON-RPC error object means the server refused: skip it.
	printf '%s' "$MCP_HTTP_BODY" | json 2>/dev/null | grep -q '^/error/' && return 1
	MCP_SID="$MCP_RSID"
	# 2. notifications/initialized (a notification; the response is an ack,
	# 202 Accepted or 200 — its body is not needed).
	mcp_http_post "$url" "notifications/initialized" "" 1 || true
	# 3. tools/list, following nextCursor (capped at 20 pages). A failure on
	# the first page fails the server; later pages keep what was found.
	local flat count i cursor="" page=0 params='{}' tname tdesc schema adv
	while :; do
		if ! mcp_http_post "$url" "tools/list" "$params" 0; then
			[ "$page" -gt 0 ] && return 0
			return 1
		fi
		flat=$(printf '%s' "$MCP_HTTP_BODY" | json 2>/dev/null)
		[ -n "$flat" ] || { [ "$page" -gt 0 ] && return 0; return 1; }
		if printf '%s\n' "$flat" | grep -q '^/error/'; then
			[ "$page" -gt 0 ] && return 0
			return 1
		fi
		count=$(printf '%s\n' "$flat" | grep -cE '^/result/tools/[0-9]+/name ')
		[ -n "$count" ] || count=0
		i=0
		while [ "$i" -lt "$count" ]; do
			tname=$(json_unescape "$(printf '%s\n' "$flat" | flat_val "/result/tools/$i/name" string)")
			tdesc=$(json_unescape "$(printf '%s\n' "$flat" | flat_val "/result/tools/$i/description" string)")
			# inputSchema: reconstruct the raw JSON from the flat lines under this
			# tool's inputSchema prefix (the flattener emits only leaves, so the
			# structure is inferred). Missing/absent -> a permissive object schema.
			schema=$(json_from_flat "$flat" "/result/tools/$i/inputSchema")
			case "$schema" in ''|'{}') schema='{"type":"object"}';; esac
			# advertised name = mcp_<server>_<tool>, sanitized, collisions suffixed
			adv=$(mcp_sanitize "mcp_${name}_${tname}")
			adv=$(mcp_dedup "${adv:0:64}")
			# Indexed variables: the LHS of an assignment is not expanded in
			# POSIX shell, so use eval (like the streaming tool-call code).
			eval "MCP_ADV_$MCP_COUNT=\$adv"
			eval "MCP_SERVER_$MCP_COUNT=\$name"
			eval "MCP_TOOL_$MCP_COUNT=\$tname"
			eval "MCP_URL_$MCP_COUNT=\$url"
			eval "MCP_SID_$MCP_COUNT=\$MCP_SID"
			eval "MCP_DESC_$MCP_COUNT=\$tdesc"
			eval "MCP_SCHEMA_$MCP_COUNT=\$schema"
			MCP_COUNT=$((MCP_COUNT + 1))
			i=$((i + 1))
		done
		page=$((page + 1))
		cursor=$(printf '%s\n' "$flat" | flat_val /result/nextCursor string)
		{ [ -n "$cursor" ] && [ "$page" -lt 20 ]; } || break
		params="{\"cursor\":\"$cursor\"}"
	done
	return 0
}

# Call one MCP tool by its advertised name. $1 = advertised name, $2 = the
# tool-call arguments (a JSON object string, as the model sent it). Finds
# the mapping entry, runs tools/call against the server over HTTP, and
# prints the plain-text result (truncation happens in the main loop).
mcp_call() {
	local adv="$1" args="$2"
	local i=0 found="" tool url mcp_adv_i
	while [ "$i" -lt "$MCP_COUNT" ]; do
		eval 'mcp_adv_i="${MCP_ADV_'"$i"':-}"'
		if [ "$mcp_adv_i" = "$adv" ]; then
			found=$i
			break
		fi
		i=$((i + 1))
	done
	[ -n "$found" ] || { printf 'mcp: unknown tool: %s' "$adv"; return 1; }
	eval 'tool="${MCP_TOOL_'"$found"':-}"'
	eval 'url="${MCP_URL_'"$found"':-}"'
	eval 'MCP_SID="${MCP_SID_'"$found"':-}"'
	[ -n "$args" ] || args="{}"

	if ! mcp_http_post "$url" "tools/call" "{\"name\":\"$(json_escape "$tool")\",\"arguments\":$args}" 0; then
		printf 'mcp: call failed (no response)'; return 1
	fi
	mcp_parse_result "$MCP_HTTP_BODY"
}

# Deduplicate an advertised name against the existing MCP_ADV_i set; on a
# collision, append _2, _3, ... (capped so the total stays <= 64 chars).
mcp_dedup() {
	local name="$1" n=2
	while :; do
		local i=0 dup=0
		while [ "$i" -lt "$MCP_COUNT" ]; do
			eval 'mcp_adv_i="${MCP_ADV_'"$i"':-}"'
			[ "$mcp_adv_i" = "$name" ] && { dup=1; break; }
			i=$((i + 1))
		done
		[ "$dup" = "0" ] && break
		name="${name:0:58}_$n"
		n=$((n + 1))
	done
	printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# Response parsing helpers
# ---------------------------------------------------------------------------
# Value of the first flat line at path $1 (flat text on stdin); optional $2 is
# the type word (string|number|boolean|null), default any.
flat_val() {
	sed -n "s|^$1 ${2:-[a-z]*} ||p" | head -n1
}

# Parse the flattened response (the FLAT string) and extract fields into
# globals.
parse_response() {
	local line
	FINISH_REASON=$(printf '%s\n' "$FLAT" | flat_val /choices/0/finish_reason string)
	CONTENT="" CONTENT_IS_NULL=0
	line=$(printf '%s\n' "$FLAT" | grep -E '^/choices/0/message/content ' | head -n1)
	if [ "$line" = "/choices/0/message/content null null" ]; then
		CONTENT_IS_NULL=1
	else
		CONTENT=$(json_unescape "${line#/choices/0/message/content string }")
	fi
	# Count distinct call indexes by id or name (some servers omit the id).
	TC_COUNT=$(printf '%s\n' "$FLAT" | grep -E '^/choices/0/message/tool_calls/[0-9]+/(id|function/name) ' | sed 's|^/choices/0/message/tool_calls/\([0-9]*\)/.*|\1|' | uniq | grep -c .)
	[ -n "$TC_COUNT" ] || TC_COUNT=0
	# Reasoning models (Qwen3, DeepSeek, ...) return a `reasoning` field (or
	# `reasoning_content`: DeepSeek, vLLM, llama.cpp) on the assistant message.
	# Echo it back in history under the same key so the chain of thought
	# survives across turns; empty when absent or null.
	REASONING="" REASONING_KEY=reasoning
	line=$(printf '%s\n' "$FLAT" | grep -E '^/choices/0/message/reasoning(_content)? string ' | head -n1)
	if [ -n "$line" ]; then
		case "$line" in /choices/0/message/reasoning_content*) REASONING_KEY=reasoning_content;; esac
		REASONING=$(json_unescape "${line#* string }")
	fi
}

# Extract tool_call i's id, name, and arguments from the flattened string.
get_tc_id() {
	printf '%s\n' "$FLAT" | flat_val "/choices/0/message/tool_calls/$1/id"
}
get_tc_name() {
	printf '%s\n' "$FLAT" | flat_val "/choices/0/message/tool_calls/$1/function/name"
}
get_tc_args() {
	local raw
	raw=$(printf '%s\n' "$FLAT" | flat_val "/choices/0/message/tool_calls/$1/function/arguments")
	json_unescape "$raw"
}

# Extract .command from a tool-call arguments JSON string.
# The arguments value is double-JSON-encoded: the outer response layer
# (already decoded by the vendored json.sh's passthrough) and the inner
# tool-call JSON. json_unescape is applied once to the outer layer (in
# get_tc_args) and once here to the inner layer, yielding the raw command.
get_tc_args_obj() {
	# Some OpenAI-compatible servers return function.arguments as a JSON
	# object rather than a string; extract .command directly (single decode).
	printf '%s\n' "$FLAT" | flat_val "/choices/0/message/tool_calls/$1/function/arguments/command"
}

extract_command() {
	local out
	out=$(printf '%s' "$1" | json 2>/dev/null | flat_val /command)
	json_unescape "$out"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# Workdir: where the model's commands run and the one place it's told it can
# write (default: the launch directory). Not enforced — the user decides the
# sandbox, if any.
[ -n "$WORKDIR" ] || WORKDIR=$(pwd)
mkdir -p "$WORKDIR" 2>/dev/null || true
# Make a relative AGENT_SELF absolute (the cd below would break it), then
# run from the workdir so the model's commands start where it is told to write.
case "$SELF" in ''|/*|http://*|https://*) ;; *) SELF="$PWD/$SELF";; esac
cd "$WORKDIR" 2>/dev/null || { printf 'agent.sh: cannot cd to workdir: %s\n' "$WORKDIR" >&2; exit 1; }
WORKDIR=$PWD
printf '[agent] workdir: %s\n' "$WORKDIR" >&2

# ---------------------------------------------------------------------------
# Skills
# ---------------------------------------------------------------------------
# A skill is $WORKDIR/.agents/skills/<name>/SKILL.md (Agent Skills convention):
# markdown with a `name:`/`description:` frontmatter, optionally with bundled
# files (references/, scripts/) the model reads via the shell tool. We scan
# the skills dir at startup and build SKILL_LIST (the `name — description`
# list). SKILL_LIST is a first-class variable: the default system prompt
# interpolates it, and a custom prompt may place the literal token
# $SKILL_LIST anywhere (or omit it to drop the list entirely).
SKILL_LIST=""
if [ -d "$WORKDIR/.agents/skills" ]; then
	for skill_md in "$WORKDIR"/.agents/skills/*/SKILL.md; do
		[ -f "$skill_md" ] || continue
		skill_name="${skill_md%/SKILL.md}"; skill_name="${skill_name##*/}"
		# load_skill only accepts [A-Za-z0-9_-]; don't advertise the rest.
		case "$skill_name" in *[!A-Za-z0-9_-]*) continue;; esac
		# First description: line; a folded/literal marker (>, |) takes the next
		# line; surrounding quotes are dropped.
		skill_desc=$(sed -n '/^description:/{s/^description:[[:space:]]*//;/^[>|][+-]\{0,1\}$/{n;s/^[[:space:]]*//;};s/^"\(.*\)"$/\1/;s/^'\''\(.*\)'\''$/\1/;p;q;}' "$skill_md" 2>/dev/null)
		[ -n "$skill_desc" ] || skill_desc="(no description)"
		SKILL_LIST="${SKILL_LIST:+$SKILL_LIST
}- $skill_name — $skill_desc"
	done
fi
SKILLS_ENABLED=0
[ -n "$SKILL_LIST" ] && SKILLS_ENABLED=1
[ -n "$SKILL_LIST" ] && printf '[agent] skills: %s available\n' "$(printf '%s\n' "$SKILL_LIST" | grep -c '^- ')" >&2

# ---------------------------------------------------------------------------
# MCP servers
# ---------------------------------------------------------------------------
# -M name=url / AGENT_MCP (semicolon-separated; env entries first, then CLI;
# a duplicate name is discovered again and its tool names get _2, _3 ...
# suffixes) configures MCP servers. value is a http/https URL (Streamable
# HTTP transport).
# Each server is discovered at startup (tools/list); its tools are exposed
# to the model as mcp_<name>_<tool>. A broken server warns and is skipped.
MCP_COUNT=0
# Walk a copy: $MCP itself is passed on to delegate children.
mcp_rest="$MCP"
if [ -n "$mcp_rest" ]; then
	while [ -n "$mcp_rest" ]; do
		# Split on the first ; (values may contain spaces).
		entry="${mcp_rest%%;*}"
		if [ "$entry" = "$mcp_rest" ]; then mcp_rest=""; else mcp_rest="${mcp_rest#*;}"; fi
		[ -n "$entry" ] || continue
		# Split on the first = (the URL may contain =).
		mname="${entry%%=*}"; mvalue="${entry#*=}"
		[ "$mname" = "$entry" ] && continue   # no '=': ignore
		[ -n "$mname" ] || continue            # empty name: ignore
		# Validate the name (it becomes part of the advertised tool names).
		case "$mname" in
			*[!A-Za-z0-9_-]*)
				printf '[agent] mcp: invalid server name: %s (skipped)\n' "$mname" >&2
				continue;;
		esac
		# Discover this server's tools (populates the MCP_* mapping).
		MCP_BEFORE=$MCP_COUNT
		if mcp_discover "$mvalue" "$mname"; then
			printf '[agent] mcp: %s — %s tool(s)\n' "$mname" "$((MCP_COUNT - MCP_BEFORE))" >&2
		else
			printf '[agent] mcp: %s — discovery failed (skipped)\n' "$mname" >&2
		fi
	done
fi
[ "$MCP_COUNT" -gt 0 ] && printf '[agent] mcp: %s tools total\n' "$MCP_COUNT" >&2

# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------
# A user-supplied prompt is used as given: the skills / delegate / MCP
# sections below are added to the built-in prompt only (a custom prompt
# places the skill list itself via the $SKILL_LIST token).
CUSTOM_PROMPT="$SYSTEM_PROMPT"
[ -n "$SYSTEM_PROMPT" ] || SYSTEM_PROMPT="You are a helpful assistant. You have a tool, shell(command), that runs a shell command and returns its combined stdout/stderr (truncated). The workdir at $WORKDIR is the place to write files. Use the tool to accomplish the task, then give a concise final answer."

# Base prompt: the prompt the delegate child gets. Captured before the
# skills section, delegate paragraph, $SKILL_LIST token replacement, and
# AGENTS.md additions — the child re-derives all of those from the same
# workdir, so nothing is duplicated.
BASE_PROMPT="$SYSTEM_PROMPT"

# Skills: when present, the default prompt advertises the skill tool + list.
if [ -z "$CUSTOM_PROMPT" ] && [ "$SKILLS_ENABLED" = "1" ]; then
	SYSTEM_PROMPT="${SYSTEM_PROMPT}
You also have a tool, skill(name), that loads the full text of a skill by name. Available skills:
$SKILL_LIST
Load a skill with the skill tool before using it when the task matches one."
fi

# Delegate: when AGENT_SELF is set and depth > 0, the default prompt
# advertises the delegate tool.
if [ -z "$CUSTOM_PROMPT" ] && [ -n "$SELF" ] && [ "$DEPTH" -gt 0 ]; then
	SYSTEM_PROMPT="${SYSTEM_PROMPT}
You also have a tool, delegate(task, timeout), that spawns a sub-agent (a nested agent.sh run) to work a sub-task. It blocks until the sub-agent finishes and returns its final answer. Use it for self-contained sub-tasks that would take several shell commands. timeout (seconds) is optional."
fi

# MCP: when servers were configured and discovered, the default prompt
# advertises the MCP tools.
if [ -z "$CUSTOM_PROMPT" ] && [ "$MCP_COUNT" -gt 0 ]; then
	mcp_i=0
	mcp_list=""
	while [ "$mcp_i" -lt "$MCP_COUNT" ]; do
		# Nested parameter expansion is not supported by busybox ash, so
		# read the indexed variables via eval (like the streaming code).
		eval 'mcp_adv="${MCP_ADV_'"$mcp_i"':-}"'
		eval 'mcp_desc="${MCP_DESC_'"$mcp_i"':-}"'
		[ -n "$mcp_desc" ] || mcp_desc="(no description)"
		mcp_list="${mcp_list:+$mcp_list
}$((mcp_i + 1)). $mcp_adv — $mcp_desc"
		mcp_i=$((mcp_i + 1))
	done
	SYSTEM_PROMPT="${SYSTEM_PROMPT}

You also have MCP tools from external MCP servers. Call them by their advertised name (mcp_<server>_<tool>):
$mcp_list"
fi

# Custom prompt: a literal $SKILL_LIST token is replaced with the list (empty
# when there are no skills), so the user can place it anywhere or omit it to
# drop the list. (Quote the env value so the token survives the user's own
# shell: AGENT_SYSTEM_PROMPT='... $SKILL_LIST ...'.)
SYSTEM_PROMPT="${SYSTEM_PROMPT//\$SKILL_LIST/$SKILL_LIST}"

# Workspace instructions: if AGENTS.md exists in the workdir, append it to
# the system prompt so the model follows the workspace's conventions.
# Loaded in full (the file is the user's own instructions, not model output,
# so no max-output cap).
if [ -f "$WORKDIR/AGENTS.md" ]; then
	SYSTEM_PROMPT="${SYSTEM_PROMPT}

Workspace instructions (AGENTS.md in the workdir):
$(cat "$WORKDIR/AGENTS.md" 2>/dev/null)"
	printf '[agent] loaded AGENTS.md from %s\n' "$WORKDIR" >&2
fi

# Initial messages: system + user task.
add_msg "{\"role\":\"system\",\"content\":\"$(json_escape "$SYSTEM_PROMPT")\"}"
add_msg "{\"role\":\"user\",\"content\":\"$(json_escape "$TASK")\"}"

URL="$ENDPOINT/chat/completions"

HI_LO=$(printf '\200') HI_HI=$(printf '\377')
TURN=0
while :; do
	TURN=$((TURN + 1))
	# MAX_TURNS 0 = unlimited; a positive value caps the tool loop.
	if [ "$MAX_TURNS" -gt 0 ] && [ "$TURN" -gt "$MAX_TURNS" ]; then
		break
	fi
	if [ "$MAX_TURNS" -gt 0 ]; then
		printf '[agent] turn %s/%s\n' "$TURN" "$MAX_TURNS" >&2
	else
		printf '[agent] turn %s\n' "$TURN" >&2
	fi

	# Build and send the request (in memory — no temp files). Streaming
	# requests add "stream": true (SSE); the response is reassembled.
	REQ=$(build_request)
	if [ "$STREAM" = "1" ]; then
		# Append "stream": true before the closing brace. The body ends with a
		# newline + }; drop that last char, add the flag, then re-close.
		REQ="${REQ%?}"
		REQ="${REQ}, \"stream\": true$(printf '\n}')"
		http_post_stream "$URL" "$REQ" || { printf '[agent] error: HTTP POST (stream) failed\n' >&2; exit 1; }
	else
		http_post "$URL" "$REQ" || { printf '[agent] error: HTTP POST failed\n' >&2; exit 1; }
	fi
	[ -n "$HTTP_BODY" ] || { printf '[agent] error: empty response\n' >&2; exit 1; }

	# Flatten the response (in memory).
	FLAT=$(printf '%s' "$HTTP_BODY" | json 2>/dev/null)
	[ -n "$FLAT" ] || { printf '[agent] error: could not parse response as JSON\n' >&2; exit 1; }
	parse_response

	# Tool-call turn: run each call in order, building the assistant message
	# (with its tool_calls) and one tool message per call; both go into the
	# history afterwards (the assistant message first).
	if [ "$TC_COUNT" -gt 0 ]; then
		if [ "$CONTENT_IS_NULL" = "1" ]; then
			assistant_content="null"
		else
			assistant_content="\"$(json_escape "$CONTENT")\""
		fi
		assistant_reasoning=""
		[ -n "$REASONING" ] && assistant_reasoning=",\"$REASONING_KEY\":\"$(json_escape "$REASONING")\""
		tc_json="" tool_msgs="" i=0
		while [ "$i" -lt "$TC_COUNT" ]; do
			tcid=$(get_tc_id "$i")
			tcargs=$(get_tc_args "$i")
			tcname=$(get_tc_name "$i")
			# Object-form arguments (not a string): rebuild the JSON from the flat
			# lines so the history and the tools see a real arguments string.
			if [ -z "$tcargs" ]; then
				tcargs=$(json_from_flat "$FLAT" "/choices/0/message/tool_calls/$i/function/arguments")
				[ "$tcargs" = '""' ] && tcargs=""
			fi
			[ -n "$tcname" ] || tcname="shell"
			tc_json="${tc_json:+$tc_json, }{\"id\":\"$(json_escape "$tcid")\",\"type\":\"function\",\"function\":{\"name\":\"$(json_escape "$tcname")\",\"arguments\":\"$(json_escape "$tcargs")\"}}"
			result=""
			case "$tcname" in
				skill)
					# skill(name): load the named skill's SKILL.md.
					skill_name=$(json_unescape "$(printf '%s' "$tcargs" | json 2>/dev/null | flat_val /name string)")
					result=$(load_skill "$skill_name")
					printf '[agent] skill: %s\n' "$skill_name" >&2
					;;
				delegate)
					# delegate(task, timeout?): spawn a nested agent.sh for a
					# sub-task; its final answer is the tool result.
					delegate_flat=$(printf '%s' "$tcargs" | json 2>/dev/null)
					delegate_task=$(json_unescape "$(printf '%s\n' "$delegate_flat" | flat_val /task string)")
					# Only a positive integer is a valid timeout (busybox timeout
					# takes integers; `timeout 0` kills the child immediately);
					# anything else is ignored — no total timeout.
					delegate_timeout=$(printf '%s\n' "$delegate_flat" | flat_val /timeout number)
					case "$delegate_timeout" in
						''|*[!0-9]*|0*) delegate_timeout="";;
					esac
					if [ -z "$delegate_task" ]; then
						result="(no task in delegate call)"
					elif ! confirm "delegate: $delegate_task"; then
						result="DENIED by user"
					else
						result=$(spawn_subagent "$delegate_task" "$delegate_timeout" | truncate_output)
					fi
					printf '[agent] delegate: %s\n' "$(printf '%s' "$delegate_task" | head -c 120)" >&2
					;;
				mcp_*)
					# mcp_<server>_<tool>: tcargs is the arguments JSON object,
					# passed straight to tools/call.
					if ! confirm "mcp $tcname: $(printf '%s' "$tcargs" | head -c 120)"; then
						result="DENIED by user"
					else
						result=$(mcp_call "$tcname" "$tcargs" | truncate_output)
					fi
					printf '[agent] mcp: %s\n' "$tcname" >&2
					;;
				shell)
					cmd=$(extract_command "$tcargs")
					# Object-form arguments (not a string): the string-form
					# lookup found nothing, so try the direct path.
					[ -n "$cmd" ] || cmd=$(json_unescape "$(get_tc_args_obj "$i")")
					if [ -z "$cmd" ]; then
						result="(no command in tool call)"
					elif ! confirm "$cmd"; then
						result="DENIED by user"
					else
						result=$(run_command "$cmd")
					fi
					printf '[agent] tool %s: %s\n' "$tcname" "$(printf '%s' "$cmd" | head -c 120)" >&2
					;;
				*)
					result="unknown tool: $tcname"
					printf '[agent] unknown tool: %s\n' "$tcname" >&2
					;;
			esac
			case "$result" in *[$HI_LO-$HI_HI]*) result=$(printf '%s' "$result" | utf8_clean);; esac
			tool_msgs="${tool_msgs:+$tool_msgs, }{\"role\":\"tool\",\"tool_call_id\":\"$(json_escape "$tcid")\",\"content\":\"$(json_escape "$result")\"}"
			i=$((i + 1))
		done
		add_msg "{\"role\":\"assistant\",\"content\":$assistant_content$assistant_reasoning,\"tool_calls\":[$tc_json]}"
		add_msg "$tool_msgs"
		continue
	fi

	# Plain-text final answer.
	if [ -n "$CONTENT" ]; then
		printf '%s\n' "$CONTENT"
		exit 0
	fi

	# No content and no tool_calls.
	api_err=$(json_unescape "$(printf '%s\n' "$FLAT" | flat_val /error/message string)")
	if [ -n "$api_err" ]; then
		printf '[agent] error: API error: %s\n' "$api_err" >&2
	elif [ "$FINISH_REASON" = "length" ]; then
		printf '[agent] error: response truncated (finish_reason=length)\n' >&2
	else
		printf '[agent] error: no content or tool_calls (finish_reason=%s)\n' "$FINISH_REASON" >&2
	fi
	exit 1
done

printf '[agent] error: reached max-turns (%s) without a final answer\n' "$MAX_TURNS" >&2
exit 1
