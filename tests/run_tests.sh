#!/usr/bin/env ash
# Run the whole agent.sh test suite. Each test file is self-contained and
# exits non-zero on failure. Prints a per-file summary and a final total.
#
# The tests run under busybox ash — agent.sh's target shell (shebang
# #!/bin/busybox ash). Running them under the host shell (bash) would test
# the wrong interpreter: some of agent.sh's POSIX-ash constructs behave
# differently in bash, so the target shell is the only one that proves the
# code works where it will actually run.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# Prefer busybox ash (the target); fall back to the host shell if busybox is
# missing (e.g. a dev machine without busybox).
#
# IMPORTANT: this is TEST_SHELL, NOT the SHELL env var. agent.sh reads $SHELL
# to pick the execution shell for the model's commands (EXEC_SHELL), so
# exporting SHELL="busybox ash" would make every model command run under a
# program literally named "busybox ash" (one word) and fail. Keep the env
# var untouched.
if command -v busybox >/dev/null 2>&1; then
	TEST_SHELL="busybox ash"
else
	TEST_SHELL="${SHELL:-sh}"
	printf 'warning: busybox not found; running under %s (not the target shell)\n' "$TEST_SHELL" >&2
fi

total_pass=0
total_fail=0
total_skip=0
failed_files=0

for t in "$HERE"/test_*.sh; do
	name=$(basename "$t")
	out=$($TEST_SHELL "$t" 2>&1)
	rc=$?
	printf '%s: %s\n' "$name" "$(printf '%s\n' "$out" | tail -n1)"
	# On failure, show the FAIL lines (with expected/actual) so the cause is
	# visible.
	[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -A2 'FAIL:' | sed 's/^/    /'
	# Extract the pass/fail/skip counts from the summary line.
	pass=$(printf '%s\n' "$out" | tail -n1 | sed 's/.*: \([0-9]*\) passed.*/\1/')
	fail=$(printf '%s\n' "$out" | tail -n1 | sed 's/.*: [0-9]* passed, \([0-9]*\) failed.*/\1/')
	skip=$(printf '%s\n' "$out" | tail -n1 | sed 's/.*: [0-9]* passed, [0-9]* failed, \([0-9]*\) skipped.*/\1/')
	total_pass=$((total_pass + ${pass:-0}))
	total_fail=$((total_fail + ${fail:-0}))
	total_skip=$((total_skip + ${skip:-0}))
	[ "$rc" -ne 0 ] && failed_files=$((failed_files + 1))
done

printf 'TOTAL: %s passed, %s failed, %s skipped\n' "$total_pass" "$total_fail" "$total_skip"
[ "$total_fail" -eq 0 ]
