# Shared test library for the agent.sh suite.
# Sourced by every test file. Provides the function extractor (the tests
# run the real code from agent.sh, not a copy), the assertion helpers, and
# the pass/fail counters.

AGENT_SH="${AGENT_SH:-$(cd "$(dirname "$0")/.." && pwd)/agent.sh}"

[ -f "$AGENT_SH" ] || { printf 'agent.sh not found: %s\n' "$AGENT_SH"; exit 1; }

# Extract one top-level function definition from agent.sh. The functions are
# defined at column 0 (body indented, closing brace at column 0), so awk can
# slice them out exactly.
extract_fn() {
	awk -v fn="$1" '
		$0 == fn "() {" { in_fn = 1 }
		in_fn { print }
		in_fn && /^}$/{ in_fn = 0; exit }
	' "$AGENT_SH"
}

# Load named functions into the current shell.
load_fn() {
	local fn
	for fn in "$@"; do
		eval "$(extract_fn "$fn")"
	done
}

# Load the vendored json.sh parser (json + its recursive helpers). Needed by
# any function that flattens a JSON document (extract_command, mcp_parse_result,
# mcp_discover, ...).
load_json() {
	load_fn json _json _json_char _json_die
}

# The shared AGENT_* env-scrub list (top-level in agent.sh, not a function).
# Strip the value's surrounding double quotes (the assignment is quoted in
# agent.sh) so the list word-splits into -u NAME pairs.
AGENT_SCRUB=$(grep '^AGENT_SCRUB=' "$AGENT_SH" | sed 's|^AGENT_SCRUB=||; s|^\"||; s|\"$||')

# The vendored json.sh uses fd 3 (debug) and fd 4 (object keys); agent.sh
# opens them at the top level. Replicate for the extracted functions.
exec 3>/dev/null
exec 4>/dev/null

PASS=0
FAIL=0
SKIP=0

# assert_eq <desc> <expected> <actual>
assert_eq() {
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
	fi
}

# assert_contains <desc> <substring> <haystack>
assert_contains() {
	case "$3" in
		*$2*)
			PASS=$((PASS + 1));;
		*)
			FAIL=$((FAIL + 1))
			printf 'FAIL: %s\n  expected substring: %s\n  actual: %s\n' "$1" "$2" "$3" >&2;;
	esac
}

# assert_not_contains <desc> <substring> <haystack>
assert_not_contains() {
	case "$3" in
		*$2*)
			FAIL=$((FAIL + 1))
			printf 'FAIL: %s\n  unexpected substring: %s\n  actual: %s\n' "$1" "$2" "$3" >&2;;
		*)
			PASS=$((PASS + 1));;
	esac
}

# assert_rc <desc> <expected> <actual>
assert_rc() {
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s (exit code)\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
	fi
}

# assert_true <desc> <command...>
assert_true() {
	local desc="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n' "$desc" >&2
	fi
}

# assert_false <desc> <command...>
assert_false() {
	local desc="$1"
	shift
	if "$@"; then
		FAIL=$((FAIL + 1))
		printf 'FAIL (expected false): %s\n' "$desc" >&2
	else
		PASS=$((PASS + 1))
	fi
}

skip() {
	SKIP=$((SKIP + 1))
	printf 'SKIP: %s\n' "$1" >&2
}

# Wait until a local port answers (the mock server).
wait_port() {
	local i=0
	while [ "$i" -lt 50 ]; do
		wget -q --spider "http://127.0.0.1:$1/" >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 0.1
	done
	return 1
}

# Summary line for the current file; non-zero exit on failure.
summary() {
	printf '%s: %d passed, %d failed, %d skipped\n' "${0##*/}" "$PASS" "$FAIL" "$SKIP"
	[ "$FAIL" -eq 0 ]
}
