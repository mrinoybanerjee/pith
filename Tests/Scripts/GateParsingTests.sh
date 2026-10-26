#!/bin/bash
# Checks the gate scripts on synthetic recordings, with made-up PIDs and "Example" names:
# - `perf.sh --evaluate` on recorded `top` logs (spec 10): each budget line for the closed and
#   open budgets, and the refusal (exit 2) of a log that is too short. The first sample of each
#   log has 9.9% CPU, which the evaluation must drop.
# - `perf.sh --evaluate-run` on a run's files: the children, close, sweep and timing lines, and a
#   value that is no number fails (R142, R145), and the first open is gated on its own line (R173).
# - `perf.sh` relaunches Pith without the hooks after a failed step, even when its helpers are
#   gone (R145), stops when Pith does not quit (N3), and refuses a locked screen (R173), with fake
#   tools on PATH, so no real Pith is touched.
# - `accuracy.sh --evaluate` on a run's files (R138, R141-R143): the same-PID comparisons with
#   left-out PIDs, the 3% bracket and its low edge, the 6% width rule, the one-outlier and 10% rules
#   (R170),
#   CPU units, the sums, the residual, and comparisons of nothing.

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

# check <exit status> <expected output> <command...>: the command's exit status and its whole
# output. A refusal (exit 2) prints nothing on stdout and an error on stderr.
check() {
    local status="$1" expected="$2" actual code=0
    shift 2
    actual="$("$@" 2>"$TMP/stderr")" || code=$?
    [[ "$code" == "$status" && "$actual" == "$expected" ]] || fail "$(printf \
        '%s: exit %s, want %s\n--- expected\n%s\n--- actual\n%s\n%s' \
        "${*##*/}" "$code" "$status" "$expected" "$actual" "$(cat "$TMP/stderr")")"
    [[ "$status" != 2 ]] || grep -q '^error: ' "$TMP/stderr" || fail "no error for: $*"
    passed=$((passed + 1))
}

# check_lines <exit status> <command...>, with the wanted lines on stdin: the command's exit
# status, and each wanted line somewhere in its output.
check_lines() {
    local status="$1" actual code=0 line
    shift
    actual="$("$@" 2>&1)" || code=$?
    [[ "$code" == "$status" ]] || fail "$(printf '%s: exit %s, want %s\n%s' "${*##*/}" "$code" "$status" "$actual")"
    while IFS= read -r line; do
        grep -qxF -- "$line" <<<"$actual" || fail "$(printf '%s: no line\n%s\n--- in\n%s' "${*##*/}" "$line" "$actual")"
    done
    passed=$((passed + 1))
}

# --- perf.sh --evaluate

check 0 "PASS cpu_mean 0.04 <= 0.10
PASS cpu_60s_max 0.05 <= 1.00
PASS mem_max 21.0 <= 30.0
PASS idlew_per_s 0.20 <= 0.50" "$PERF" --evaluate closed "$FIXTURES/pass.log"

# fail.log: pass.log with 0.3% CPU in every sample after the first.
check 1 "FAIL cpu_mean 0.30 > 0.10
PASS cpu_60s_max 0.30 <= 1.00
PASS mem_max 21.0 <= 30.0
PASS idlew_per_s 0.20 <= 0.50" "$PERF" --evaluate closed "$FIXTURES/fail.log"

check 0 "PASS cpu_mean 0.30 <= 1.50
PASS cpu_60s_max 0.30 <= 5.00
PASS mem_max 21.0 <= 45.0
PASS idlew_per_s 0.20 <= 2.00" "$PERF" --evaluate open "$FIXTURES/fail.log"

# Three samples (13 lines each) give no 60 s window.
head -n 39 "$FIXTURES/pass.log" >"$TMP/short.log"
check 2 "" "$PERF" --evaluate closed "$TMP/short.log"

# --- perf.sh --evaluate-run

# perf_run <dir>: a passing run: pass.log for each phase, no child, no close while open and the
# 10 closes after, one sweep line, one launch, 10 opens and the load at each.
perf_run() {
    mkdir -p "$1"
    for phase in closed open after; do cp "$FIXTURES/pass.log" "$1/$phase.log"; done
    : >"$1/children.txt"
    echo "Timestamp               Ty Process[PID:TID]" >"$1/closes.txt"
    {
        echo "Timestamp               Ty Process[PID:TID]"
        for _ in {1..10}; do
            echo "2026-10-25 09:20:01.000 Df Pith[4242:1] [com.mrinoy.pith:debug-hooks] panel closed"
        done
    } >"$1/closes-after.txt"
    echo "sweep n=200 processes=330 mean_ms=0.868 max_ms=1.299" >"$1/sweep.txt"
    {
        echo "2026-10-25 09:00:00.100 Df Pith[4242:1] [com.mrinoy.pith:timing] launch_to_first_reading_ms=125.4"
        for ms in 55.2 48.1 47.9 50.0 46.3 47.0 49.9 51.2 48.8 47.5; do
            echo "2026-10-25 09:20:00.100 Df Pith[4242:1] [com.mrinoy.pith:timing] open_to_visible_ms=$ms"
        done
    } >"$1/timing.txt"
    for load in 1.52 1.40 1.38 1.35 1.30 1.31 1.29 1.27 1.25 1.26; do
        echo "{ $load 1.20 1.10 }"
    done >"$1/loads.txt"
}

perf_run "$TMP/run"
check 0 "closed:
PASS cpu_mean 0.04 <= 0.10
PASS cpu_60s_max 0.05 <= 1.00
PASS mem_max 21.0 <= 30.0
PASS idlew_per_s 0.20 <= 0.50
open:
PASS cpu_mean 0.04 <= 1.50
PASS cpu_60s_max 0.05 <= 5.00
PASS mem_max 21.0 <= 45.0
PASS idlew_per_s 0.20 <= 2.00
closed after the open minutes:
PASS cpu_mean 0.04 <= 0.10
PASS cpu_60s_max 0.05 <= 1.00
PASS mem_max 21.0 <= 30.0
PASS idlew_per_s 0.20 <= 0.50
always:
PASS children 0 <= 0
PASS panel_closes_while_open 0 <= 0
PASS panel_closes_after_open 10, the control
sweep n=200 processes=330 mean_ms=0.868 max_ms=1.299
PASS sweep_mean_ms 0.87 <= 3.00
opens in ms, with the 1-minute load: 55.2@1.52 48.1@1.40 47.9@1.38 50.0@1.35 46.3@1.30 47.0@1.31 49.9@1.29 51.2@1.27 48.8@1.25 47.5@1.26
PASS launch_to_first_reading_ms 125.4 <= 300
PASS first_open_to_visible_ms 55.2 <= 100
PASS open_to_visible_ms_max 51.2 <= 100
footprint growth over 24 h: scripts/soak.sh
PASS" "$PERF" --evaluate-run "$TMP/run"

# R173: a slow first open fails on its own line, while the other opens pass.
perf_run "$TMP/first"
sed -i '' 's/open_to_visible_ms=55.2/open_to_visible_ms=120.4/' "$TMP/first/timing.txt"
check_lines 1 "$PERF" --evaluate-run "$TMP/first" <<<"FAIL first_open_to_visible_ms 120.4 > 100
PASS open_to_visible_ms_max 51.2 <= 100
FAIL"

# A sweep line in another format has no number to gate: it fails, never reads as 0 (R142).
perf_run "$TMP/sweep"
echo "sweep n=200 mean=0.868" >"$TMP/sweep/sweep.txt"
check_lines 1 "$PERF" --evaluate-run "$TMP/sweep" <<<"FAIL sweep_mean_ms: no number ('')
FAIL"

perf_run "$TMP/child"
echo 4321 >"$TMP/child/children.txt"
check_lines 1 "$PERF" --evaluate-run "$TMP/child" <<<"FAIL children 1 > 0"

perf_run "$TMP/closed"
echo "2026-10-25 09:15:00.000 Df Pith[4242:1] [com.mrinoy.pith:debug-hooks] panel closed" \
    >>"$TMP/closed/closes.txt"
check_lines 1 "$PERF" --evaluate-run "$TMP/closed" <<<"FAIL panel_closes_while_open 1 > 0"

# N4: the closes after the open minutes are the control that the close line is logged at all.
perf_run "$TMP/control"
sed -i '' '$d' "$TMP/control/closes-after.txt"
check_lines 1 "$PERF" --evaluate-run "$TMP/control" <<<"FAIL panel_closes_after_open 9, want 10: the close line may not be logged
FAIL"

perf_run "$TMP/opens"
sed -i '' '$d' "$TMP/opens/timing.txt"
check_lines 1 "$PERF" --evaluate-run "$TMP/opens" <<<"FAIL timings: want 1 launch, 10 opens and 10 loads in $TMP/opens"

# --- perf.sh's relaunch on exit (R145), with fakes: Pith never starts, and caffeinate is gone
# before the trap runs.
mkdir "$TMP/bin"
printf '#!/bin/bash\necho "IOConsoleUsers unlocked"\n' >"$TMP/bin/ioreg"
printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/caffeinate"
printf '#!/bin/bash\nexit 1\n' >"$TMP/bin/pkill"
printf '#!/bin/bash\nexit 1\n' >"$TMP/bin/pgrep"
printf '#!/bin/bash\necho "$*" >>%q\n' "$TMP/opened" >"$TMP/bin/open"
chmod +x "$TMP/bin"/*
code=0
PATH="$TMP/bin:$PATH" "$PERF" --minutes 1 >/dev/null 2>"$TMP/stderr" || code=$?
[[ "$code" == 2 && "$(cat "$TMP/opened")" == "-n -a /Applications/Pith.app --args --debug-hooks
-n /Applications/Pith.app" ]] || fail "$(printf 'perf.sh after a failed start: exit %s, opened\n%s\n%s' \
    "$code" "$(cat "$TMP/opened")" "$(cat "$TMP/stderr")")"
passed=$((passed + 1))

# N3: when the user's Pith does not quit, the script stops and opens no second copy.
mkdir "$TMP/stuck"
cp "$TMP/bin/ioreg" "$TMP/stuck/ioreg"
printf '#!/bin/bash\nexit 0\n' >"$TMP/stuck/caffeinate"
printf '#!/bin/bash\nexit 0\n' >"$TMP/stuck/pkill"
printf '#!/bin/bash\nexit 0\n' >"$TMP/stuck/pgrep"
printf '#!/bin/bash\necho "$*" >>%q\n' "$TMP/stuck-opened" >"$TMP/stuck/open"
chmod +x "$TMP/stuck"/*
code=0
PATH="$TMP/stuck:$PATH" "$PERF" --minutes 1 >/dev/null 2>"$TMP/stderr" || code=$?
[[ "$code" == 2 && ! -e "$TMP/stuck-opened" ]] || fail "$(printf 'perf.sh when Pith does not quit: exit %s, opened\n%s\n%s' \
    "$code" "$(cat "$TMP/stuck-opened" 2>/dev/null)" "$(cat "$TMP/stderr")")"
passed=$((passed + 1))

# R173: a locked screen stops the script before it starts a helper, quits Pith or opens anything.
mkdir "$TMP/locked"
printf '#!/bin/bash\necho %q\n' '"IOConsoleUsers" = ({"CGSSessionScreenIsLocked"=Yes})' \
    >"$TMP/locked/ioreg"
for tool in caffeinate pkill pgrep open; do
    printf '#!/bin/bash\necho "%s $*" >>%q\n' "$tool" "$TMP/locked-calls" >"$TMP/locked/$tool"
done
chmod +x "$TMP/locked"/*
code=0
PATH="$TMP/locked:$PATH" "$PERF" --minutes 1 >/dev/null 2>"$TMP/stderr" || code=$?
[[ "$code" == 2 && ! -e "$TMP/locked-calls" ]] && grep -q 'the screen is locked' "$TMP/stderr" ||
    fail "$(printf 'perf.sh on a locked screen: exit %s, calls\n%s\n%s' "$code" \
        "$(cat "$TMP/locked-calls" 2>/dev/null)" "$(cat "$TMP/stderr")")"
passed=$((passed + 1))

# --- accuracy.sh --evaluate

# top_sample <column> <pid:value>...: one synthetic `top -l` sample of PID and one column.
top_sample() {
    local column="$1"
    shift
    printf '%s\n' "Processes: 412 total, 2 running, 410 sleeping, 2301 threads" \
        "2026/10/25 09:00:00" "Load Avg: 1.10, 1.20, 1.30" \
        "CPU usage: 3.00% user, 4.00% sys, 93.00% idle" "" "PID    $column"
    for row in "$@"; do printf '%-6s %s\n' "${row%%:*}" "${row#*:}"; done
}

# reading <out> <apps>: a synthetic --snapshot-json reading. <apps> is a JSON array of
# {name, pids: [[pid, MiB, CPU share or null]]}; each app's memory and CPU are the sums of its
# processes, and the residual is a value.
reading() {
    jq -n --argjson apps "$2" '{
        snapshot: {
            apps: [$apps[] | {
                id: "/Applications/\(.name).app", name, pids: [.pids[][0]],
                memory: ([.pids[][1] * 1048576] | add),
                cpu: ([.pids[][2] | select(. != null)]
                    | if length > 0 then {value: add} else {unavailable: "first sample"} end)}],
            system: {value: {memory: 1048576, cpu: {value: 0.1}}}},
        processes: ([$apps[].pids[] | {key: (.[0] | tostring),
            value: ({footprint: (.[1] * 1048576)} + (if .[2] == null then {} else {cpu: .[2]} end))}]
            | from_entries)}' >"$1"
}

EDITOR='{"name": "Example Editor", "pids": [[4101, 206, null], [4102, 101, null], [4103, 80, null]]}'
NOTES='{"name": "Example Notes", "pids": [[4201, 70, null]]}'
TINY='{"name": "Example Tiny", "pids": [[4301, 1, null]]}'

# accuracy_run <dir>: a passing run of 10 memory runs, 1 CPU window and 100 residual snapshots on 10
# CPUs. Example Editor's PID 4103 is in Pith and in `top` before, but not after, so it is left out
# on both sides: 206 + 101 MB against 297 to 305 MB passes inside the 3% bracket. In the window,
# 4103 is new and has no share. Example Tiny, under 50 MB, is not compared.
accuracy_run() {
    mkdir -p "$1"
    echo 10 >"$1/cpus"
    for i in {1..10}; do
        reading "$1/memory-$i.json" "[$EDITOR, $NOTES, $TINY]"
        top_sample MEM 4101:198M 4102:99M 4103:80M 4201:69M 4301:1024K >"$1/before-$i.txt"
        top_sample MEM 4101:204M+ 4102:101M+ 4201:70M+ 4301:1024K >"$1/after-$i.txt"
    done
    reading "$1/cpu-1.json" '[{"name": "Example Editor", "pids": [[4101, 206, 0.04], [4102, 101, 0.01], [4103, 80, null]]},
        {"name": "Example Notes", "pids": [[4201, 70, 0.002]]}]'
    { top_sample %CPU 4101:0.0 4102:0.0 4201:0.0; top_sample %CPU 4101:40.0 4102:10.0 4201:2.0; } \
        >"$1/cpu-1.txt"
    reading "$1/residual-1.json" "[$EDITOR, $NOTES]"
    for i in {2..100}; do cp "$1/residual-1.json" "$1/residual-$i.json"; done
}

memory_lines() {
    for i in {1..10}; do
        echo "PASS Example Editor, run $i: memory 307.0 MB, top 297.0 to 305.0 MB (width 2.69%), PIDs 2, left out 1"
        echo "PASS Example Notes, run $i: memory 70.0 MB, top 69.0 to 70.0 MB (width 1.45%), PIDs 1, left out 0"
    done
}

accuracy_run "$TMP/accuracy"
# The CPU units: 4% + 1% of the Mac in Pith against (40% + 10%) of one core / 10 CPUs in top.
check 0 "PASS sums: in all 111 readings, each app is the sum of its PIDs
$(memory_lines)
PASS Example Editor: memory within 3% in 10 of 10 counted runs
PASS Example Notes: memory within 3% in 10 of 10 counted runs
PASS Example Editor, window 1: CPU 5.00% vs top 5.00% of the Mac over 10 s (+0.00 points), PIDs 2, left out 1
PASS Example Notes, window 1: CPU 0.20% vs top 0.20% of the Mac over 10 s (+0.00 points), PIDs 1, left out 0
PASS residual: all 100 snapshots have a memory and a CPU residual
PASS" "$ACCURACY" --evaluate "$TMP/accuracy"

# outlier <dir> <run> <MiB>: Example Notes' top samples in a memory run, before and after.
outlier() {
    top_sample MEM 4101:198M 4102:99M 4103:80M "4201:$3M" 4301:1024K >"$1/before-$2.txt"
    top_sample MEM 4101:204M+ 4102:101M+ "4201:$3M" 4301:1024K >"$1/after-$2.txt"
}

# A value under the bracket's low edge widened by 3% is outside it: 70 < 73 x 0.97. One outlier
# still passes, and the line names it (R170).
accuracy_run "$TMP/low"
top_sample MEM 4101:198M 4102:99M 4103:80M 4201:73M 4301:1024K >"$TMP/low/before-2.txt"
top_sample MEM 4101:204M+ 4102:101M+ 4201:74M+ 4301:1024K >"$TMP/low/after-2.txt"
check_lines 0 "$ACCURACY" --evaluate "$TMP/low" <<<"OUT Example Notes, run 2: memory 70.0 MB, top 73.0 to 74.0 MB (width 1.37%), PIDs 1, left out 0
PASS Example Notes: memory within 3% in 9 of 10 counted runs; outside 3%: run 2 (memory 70.0 MB, top 73.0 to 74.0 MB)
PASS"
# R170: one outlier at 6% among 8 counted runs (2 of 10 are too wide) passes.
accuracy_run "$TMP/six"
for i in 1 2; do top_sample MEM 4101:198M 4102:99M 4201:60M >"$TMP/six/before-$i.txt"; done
outlier "$TMP/six" 4 74.5
check_lines 0 "$ACCURACY" --evaluate "$TMP/six" <<<"PASS Example Notes: memory within 3% in 7 of 8 counted runs; outside 3%: run 4 (memory 70.0 MB, top 74.5 to 74.5 MB)
PASS"

# R170: two outliers fail, and so does one run beyond 10%: 70 < 79 x 0.90.
accuracy_run "$TMP/two"
outlier "$TMP/two" 4 74.5
outlier "$TMP/two" 7 74.5
check_lines 1 "$ACCURACY" --evaluate "$TMP/two" <<<"FAIL Example Notes: memory outside 3% in 2 of 10 counted runs: run 4 (memory 70.0 MB, top 74.5 to 74.5 MB), run 7 (memory 70.0 MB, top 74.5 to 74.5 MB)
FAIL"
accuracy_run "$TMP/far"
outlier "$TMP/far" 4 79
check_lines 1 "$ACCURACY" --evaluate "$TMP/far" <<<"FAIL Example Notes, run 4: memory 70.0 MB, top 79.0 to 79.0 MB (width 0.00%), PIDs 1, left out 0
FAIL Example Notes: memory beyond 10% in run 4 (memory 70.0 MB, top 79.0 to 79.0 MB)
FAIL"

# R141: a range wider than 6% does not count; with 4 counted runs of 10, the app is not comparable.
accuracy_run "$TMP/wide"
for i in {1..6}; do top_sample MEM 4101:198M 4102:99M 4201:60M >"$TMP/wide/before-$i.txt"; done
check_lines 1 "$ACCURACY" --evaluate "$TMP/wide" <<<"WIDE Example Notes, run 1: memory 70.0 MB, top 60.0 to 70.0 MB (width 16.67%, not counted), PIDs 1, left out 0
FAIL Example Notes: not comparable, 4 runs counted (widths 16.67%, 16.67%, 16.67%, 16.67%, 16.67%, 16.67%, 1.45%, 1.45%, 1.45%, 1.45%)
FAIL"

# The CPU units again: with top's %CPU of one core not divided by the CPU count, Pith would match.
accuracy_run "$TMP/cpu"
{ top_sample %CPU 4101:0.0 4102:0.0 4201:0.0; top_sample %CPU 4101:4.0 4102:1.0 4201:0.2; } \
    >"$TMP/cpu/cpu-1.txt"
check_lines 1 "$ACCURACY" --evaluate "$TMP/cpu" <<<"FAIL Example Editor, window 1: CPU 5.00% vs top 0.50% of the Mac over 10 s (+4.50 points), PIDs 2, left out 1"

# R143: an app whose memory or CPU is not the sum over its PIDs fails.
accuracy_run "$TMP/sums"
jq '.snapshot.apps[0].memory += 1048576' "$TMP/sums/memory-3.json" >"$TMP/sums/m.json"
mv "$TMP/sums/m.json" "$TMP/sums/memory-3.json"
jq '.snapshot.apps[1].cpu.value += 0.001' "$TMP/sums/cpu-1.json" >"$TMP/sums/c.json"
mv "$TMP/sums/c.json" "$TMP/sums/cpu-1.json"
check_lines 1 "$ACCURACY" --evaluate "$TMP/sums" <<<"FAIL sums, cpu-1.json: Example Notes: memory 73400320 but the sum is 73400320, CPU 0.003 but the sum is 0.002
FAIL sums, memory-3.json: Example Editor: memory 406847488 but the sum is 405798912, CPU null but the sum is null
FAIL"

# R142: a snapshot with no residual fails, with its reason.
accuracy_run "$TMP/residual"
jq '.snapshot.system = {unavailable: "accounting mismatch"}' "$TMP/residual/residual-2.json" \
    >"$TMP/residual/r.json"
mv "$TMP/residual/r.json" "$TMP/residual/residual-2.json"
check_lines 1 "$ACCURACY" --evaluate "$TMP/residual" <<<"FAIL residual: 99 of 100 snapshots have a memory and a CPU residual
  1 accounting mismatch
FAIL"

# N1: 100 snapshots, no fewer, and an empty reading fails in both checks.
accuracy_run "$TMP/fewer"
rm "$TMP/fewer/residual-100.json"
check_lines 1 "$ACCURACY" --evaluate "$TMP/fewer" <<<"FAIL residual: 99 snapshots, want 100
FAIL"
accuracy_run "$TMP/blank"
: >"$TMP/blank/residual-7.json"
check_lines 1 "$ACCURACY" --evaluate "$TMP/blank" <<<"FAIL sums, residual-7.json: empty reading
FAIL residual: 99 of 100 snapshots have a memory and a CPU residual
  1 empty reading
FAIL"

# N5: a row with no CPU value whose PIDs have shares fails the sums.
accuracy_run "$TMP/nocpu"
jq '.snapshot.apps[1].cpu = {unavailable: "first sample"}' "$TMP/nocpu/cpu-1.json" >"$TMP/nocpu/c.json"
mv "$TMP/nocpu/c.json" "$TMP/nocpu/cpu-1.json"
check_lines 1 "$ACCURACY" --evaluate "$TMP/nocpu" <<<"FAIL sums, cpu-1.json: Example Notes: memory 73400320 but the sum is 73400320, CPU null but the sum is 0.002
FAIL"

# R142: readings with no app of 50 MB or more compare nothing, which fails.
accuracy_run "$TMP/empty"
for f in "$TMP/empty"/memory-*.json "$TMP/empty/cpu-1.json"; do reading "$f" "[$TINY]"; done
check_lines 1 "$ACCURACY" --evaluate "$TMP/empty" <<<"FAIL memory, run 1: no app of 50 MB or more to compare
FAIL CPU, window 1: no app of 50 MB or more to compare
FAIL"

# R142: a reading that is not JSON stops the script with jq's error, and no verdict.
accuracy_run "$TMP/broken"
echo "{" >"$TMP/broken/memory-4.json"
code=0
"$ACCURACY" --evaluate "$TMP/broken" >"$TMP/out" 2>&1 || code=$?
[[ "$code" -ge 2 ]] && ! grep -qx PASS "$TMP/out" && grep -q '^jq: ' "$TMP/out" ||
    fail "$(printf 'accuracy.sh on a broken reading: exit %s\n%s' "$code" "$(cat "$TMP/out")")"
passed=$((passed + 1))

printf 'gate parsing: %s passed\n' "$passed"
