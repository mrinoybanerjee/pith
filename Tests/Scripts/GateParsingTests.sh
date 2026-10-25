#!/bin/bash
# Checks `scripts/perf.sh --evaluate` on recorded synthetic `top` logs (spec 10): each budget
# line, PASS or FAIL, for the closed and open budgets; and the refusal (exit 2) of a log that is
# too short. The first sample of each log has 9.9% CPU, which the evaluation must drop.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF="$ROOT/scripts/perf.sh"
FIXTURES="$ROOT/Tests/Scripts/Fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
passed=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# expect <exit status> <expected output> <perf.sh --evaluate arguments...>. A refusal (exit 2)
# prints nothing on stdout and an error on stderr.
expect() {
    local status="$1" expected="$2" actual code=0
    shift 2
    actual="$("$PERF" --evaluate "$@" 2>"$TMP/stderr")" || code=$?
    [[ "$code" == "$status" && "$actual" == "$expected" ]] || fail "$(printf \
        'perf.sh --evaluate %s: exit %s, want %s\n--- expected\n%s\n--- actual\n%s\n%s' \
        "$*" "$code" "$status" "$expected" "$actual" "$(cat "$TMP/stderr")")"
    [[ "$status" != 2 ]] || grep -q '^error: ' "$TMP/stderr" || fail "no error for: $*"
    passed=$((passed + 1))
}

# pass.log: 0.04% CPU on average, 21 MB at most, idle wakeups from 100 to 120 in 100 s.
expect 0 "PASS cpu_mean 0.04 <= 0.10
PASS cpu_60s_max 0.05 <= 1.00
PASS mem_max 21.0 <= 30.0
PASS idlew_per_s 0.20 <= 0.50" closed "$FIXTURES/pass.log"

# fail.log: pass.log with 0.3% CPU in every sample after the first.
expect 1 "FAIL cpu_mean 0.30 > 0.10
PASS cpu_60s_max 0.30 <= 1.00
PASS mem_max 21.0 <= 30.0
PASS idlew_per_s 0.20 <= 0.50" closed "$FIXTURES/fail.log"

expect 0 "PASS cpu_mean 0.30 <= 1.50
PASS cpu_60s_max 0.30 <= 5.00
PASS mem_max 21.0 <= 45.0
PASS idlew_per_s 0.20 <= 2.00" open "$FIXTURES/fail.log"

# Three samples (13 lines each) give no 60 s window.
head -n 39 "$FIXTURES/pass.log" >"$TMP/short.log"
expect 2 "" closed "$TMP/short.log"

printf 'gate parsing: %s passed\n' "$passed"
