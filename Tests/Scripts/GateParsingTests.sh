#!/bin/bash
# Checks `scripts/perf.sh --evaluate` on recorded synthetic `top` logs (spec 10): each budget
# line, PASS or FAIL, for the closed and open budgets; and the refusal (exit 2) of a log that is
# too short. The first sample of each log has 9.9% CPU, which the evaluation must drop.
# Then `scripts/accuracy.sh --evaluate-memory` on a synthetic reading between two `top` samples
# (R138): a PID missing from a sample is left out on both sides, and a value inside the bracket
# widened by 3% passes while one outside fails.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF="$ROOT/scripts/perf.sh"
ACCURACY="$ROOT/scripts/accuracy.sh"
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

# expect_memory <exit status> <expected output> <top after>: the reading against before.txt and
# <top after>.
expect_memory() {
    local status="$1" expected="$2" actual code=0 a="$FIXTURES/accuracy"
    actual="$("$ACCURACY" --evaluate-memory "$a/reading.json" "$a/before.txt" "$a/$3" 2>&1)" ||
        code=$?
    [[ "$code" == "$status" && "$actual" == "$expected" ]] || fail "$(printf \
        'accuracy.sh --evaluate-memory … %s: exit %s, want %s\n--- expected\n%s\n--- actual\n%s' \
        "$3" "$code" "$status" "$expected" "$actual")"
    passed=$((passed + 1))
}

# Example Editor: 206 + 101 MB in Pith, 297 MB before and 305 MB after: outside the range, inside
# it widened by 3%. Its PID 4103 (80 MB in Pith) is missing after, so it is left out. Example
# Notes: 70 MB against 60 to 62 MB fails, and against 60 to 68 MB passes. Example Tiny, under
# 50 MB, is not compared.
expect_memory 1 "PASS Example Editor: memory 307.0 MB, top 297.0 to 305.0 MB (width 2.69%), PIDs 2, left out 1
FAIL Example Notes: memory 70.0 MB, top 60.0 to 62.0 MB (width 3.33%), PIDs 1, left out 0" after.txt
expect_memory 0 "PASS Example Editor: memory 307.0 MB, top 297.0 to 305.0 MB (width 2.69%), PIDs 2, left out 1
PASS Example Notes: memory 70.0 MB, top 60.0 to 68.0 MB (width 13.33%), PIDs 1, left out 0" after-wide.txt

printf 'gate parsing: %s passed\n' "$passed"
