#!/bin/bash
# The accuracy gate (spec 11, step 2) for the installed Pith on this Mac (R138, R141-R143). Each
# comparison counts only the PIDs that both Pith and `top` saw; the others are left out on both
# sides, and each line counts them. No process is exempted.
# - Each reading checks itself first: every app's memory and CPU must be the sums over its PIDs of
#   the per-process values that `--snapshot-json` prints, so the gate checks what the panel shows.
# - Memory, at the same moment: 10 times, `top` samples MEM just before and just after a
#   `Pith --snapshot-json 0` reading. A run is within 3% of the range of the two samples, outside
#   it, or beyond 10%; each line shows the range's width. A range wider than 6% does not count, and
#   an app needs 5 counted runs, or it is "not comparable". An app passes when at most one counted
#   run is outside 3% and none is beyond 10%; its line names each run outside 3% (R170).
# - CPU, over a 10 s window: 3 times, `Pith --snapshot-json 10` beside `top -l 2 -s 10`, started
#   together. An app passes within 2 points, as a share of the whole Mac (R135).
# - The apps are those of 50 MB or more in the first memory reading.
# - Residual: each of exactly 100 snapshots (`--snapshot-json 1`) has a memory and a CPU residual.
# A comparison of nothing is a FAIL, and a tool error stops the script. It prints one line per app
# and comparison, then PASS or FAIL, and exits 1 on FAIL. It takes about 3 minutes. The lines name
# this Mac's apps: never commit them. --evaluate checks the recorded files of a run, for the test.
#
# Usage: scripts/accuracy.sh
#        scripts/accuracy.sh --evaluate <dir with cpus, memory-N.json, before-N.txt, after-N.txt,
#                            cpu-N.json, cpu-N.txt, residual-N.json>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE="usage: scripts/accuracy.sh [--evaluate <dir>]"
PITH=/Applications/Pith.app/Contents/MacOS/Pith
MIN_BYTES=52428800  # 50 MB
RESIDUALS=100

# top_column <log> <sample> <out>: the PID and the first column after it of every row in one
# sample of a `top -l` log, tab-separated.
top_column() {
    awk -f "$ROOT/scripts/top-rows.awk" "$1" |
        awk -v sample="$2" -v OFS='\t' '$1 == sample { print $3, $4 }' >"$3"
}

# app_processes <reading.json> <field> <ids> <out>: for each app in <ids>, its id, its name, and
# "pid:value" for each of its processes, comma-separated; "-" when Pith has no value.
app_processes() {
    jq -r --arg field "$2" --rawfile ids "$3" '($ids | split("\n")) as $set
        | .processes as $p | .snapshot.apps[] | select(.id as $id | $set | index($id))
        | [.id, .name, ([.pids[] | tostring | "\(.):\($p[.][$field] // "-")"] | join(","))]
        | @tsv' "$1" >"$4"
}

# check_sums <reading.json>: a line for each app whose memory or CPU is not the sum over its PIDs
# (CPU within 1e-9, with the sum capped at 1 as Aggregator.usage caps the app; a row with no CPU
# fails when its PIDs have shares, and the reverse), or one line when the reading has no app.
check_sums() {
    jq -r '.processes as $p | .snapshot.apps | if length == 0 then "no app in the reading" else .[]
        | ([.pids[] | $p[tostring].footprint] | add) as $memory
        | ([.pids[] | $p[tostring].cpu | select(. != null)] | add | if . > 1 then 1 else . end) as $cpu
        | select($memory != .memory or ((.cpu.value == null) != ($cpu == null))
            or (.cpu.value != null and $cpu != null
                and (($cpu - .cpu.value) | if . < 0 then -. else . end) > 1e-9))
        | "\(.name): memory \(.memory) but the sum is \($memory), CPU \(.cpu.value) but the sum is \($cpu)"
        end' "$1"
}

# compare_memory <before> <after> <processes> <run>: one line per app, tab-separated: id, name,
# status (PASS within 3% of the range, OUT outside it, FAIL beyond 10% or with no PID to compare,
# WIDE when the range is over 6% and does not count), width, the run and its range, the line.
compare_memory() {
    awk -F '\t' -v before="$1" -v after="$2" -v run="$4" '
        FILENAME == before { low[$1] = $2; next }
        FILENAME == after { high[$1] = $2; next }
        {
            n = split($3, processes, ",")
            pith = 0; a = 0; b = 0; both = 0; out = 0
            for (i = 1; i <= n; i++) {
                split(processes[i], p, ":")
                if (!(p[1] in low) || !(p[1] in high)) { out++; continue }
                pith += p[2] / 1048576; a += low[p[1]]; b += high[p[1]]; both++
            }
            lo = a < b ? a : b; hi = a < b ? b : a
            width = lo > 0 ? (hi - lo) / lo * 100 : 0
            status = both == 0 || pith < lo * 0.90 || pith > hi * 1.10 ? "FAIL" \
                : pith < lo * 0.97 || pith > hi * 1.03 ? "OUT" : "PASS"
            if (both > 0 && width > 6) status = "WIDE"
            printf "%s\t%s\t%s\t%.2f\trun %d (memory %.1f MB, top %.1f to %.1f MB)\t%s %s, run %d: memory %.1f MB, top %.1f to %.1f MB (width %.2f%%%s), PIDs %d, left out %d\n",
                $1, $2, status, width, run, pith, lo, hi, status, $2, run, pith, lo, hi, width,
                (status == "WIDE" ? ", not counted" : ""), both, out
        }' "$1" "$2" "$3"
}

# compare_cpu <top> <processes> <cpus> <window>: one line per app: Pith's shares of the whole Mac
# against the same PIDs' %CPU of one core in `top`, divided by the CPU count.
compare_cpu() {
    awk -F '\t' -v top="$1" -v cpus="$3" -v window="$4" '
        FILENAME == top { core[$1] = $2; next }
        {
            n = split($3, processes, ",")
            pith = 0; mac = 0; both = 0; out = 0
            for (i = 1; i <= n; i++) {
                split(processes[i], p, ":")
                if (!(p[1] in core) || p[2] == "-") { out++; continue }
                pith += p[2] * 100; mac += core[p[1]] / cpus; both++
            }
            gap = pith - mac
            ok = both > 0 && (gap < 0 ? -gap : gap) <= 2
            printf "%s %s, window %d: CPU %.2f%% vs top %.2f%% of the Mac over 10 s (%+.2f points), PIDs %d, left out %d\n",
                ok ? "PASS" : "FAIL", $2, window, pith, mac, gap, both, out
            failed += !ok
        }
        END { exit failed > 0 }' "$1" "$2"
}

# evaluate <dir>: every check on the recorded files of a run; returns 1 on any FAIL.
evaluate() {
    local dir="$1" work="$WORK" failed=0 cpus readings=0 runs=0 windows=0 i problems
    cpus="$(cat "$dir/cpus")"
    [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || { echo "error: $dir/cpus holds no CPU count" >&2; exit 2; }
    for reading in "$dir"/*.json; do
        # jq reads an empty file as no input and says nothing (N1).
        if [[ -s "$reading" ]]; then problems="$(check_sums "$reading")"; else problems="empty reading"; fi
        readings=$((readings + 1))
        if [[ -n "$problems" ]]; then
            sed "s|^|FAIL sums, ${reading##*/}: |" <<<"$problems"
            failed=1
        fi
    done
    [[ "$failed" == 1 ]] || echo "PASS sums: in all $readings readings, each app is the sum of its PIDs"

    jq -r --argjson min "$MIN_BYTES" '.snapshot.apps[] | select(.memory >= $min) | .id' \
        "$dir/memory-1.json" >"$work/ids"
    for ((i = 1; ; i++)); do
        [[ -e "$dir/memory-$i.json" ]] || break
        top_column "$dir/before-$i.txt" 1 "$work/before"
        top_column "$dir/after-$i.txt" 1 "$work/after"
        app_processes "$dir/memory-$i.json" footprint "$work/ids" "$work/processes"
        compare_memory "$work/before" "$work/after" "$work/processes" "$i" >"$work/run"
        if [[ ! -s "$work/run" ]]; then
            echo "FAIL memory, run $i: no app of 50 MB or more to compare"
            failed=1
        fi
        cut -f6 "$work/run"
        cat "$work/run" >>"$work/runs"
        runs=$((runs + 1))
    done
    # Each app needs 5 counted runs, at most one of them outside 3%, and none beyond 10% (R170).
    awk -F '\t' '
        function add(list, item) { return list (list == "" ? "" : ", ") item }
        !($1 in name) { name[$1] = $2; order[++apps] = $1 }
        { widths[$1] = add(widths[$1], $4 "%") }
        $3 != "WIDE" { counted[$1]++ }
        $3 == "PASS" { within[$1]++ }
        $3 == "OUT" { outliers[$1]++; outside[$1] = add(outside[$1], $5) }
        $3 == "FAIL" { beyond[$1] = add(beyond[$1], $5) }
        END {
            for (a = 1; a <= apps; a++) {
                id = order[a]
                if (counted[id] < 5) {
                    printf "FAIL %s: not comparable, %d runs counted (widths %s)\n", name[id], counted[id], widths[id]
                    failed = 1
                } else if (beyond[id] != "") {
                    printf "FAIL %s: memory beyond 10%% in %s\n", name[id], beyond[id]
                    failed = 1
                } else if (outliers[id] > 1) {
                    printf "FAIL %s: memory outside 3%% in %d of %d counted runs: %s\n", name[id], outliers[id], counted[id], outside[id]
                    failed = 1
                } else {
                    printf "PASS %s: memory within 3%% in %d of %d counted runs%s\n", name[id], within[id], counted[id],
                        (outside[id] == "" ? "" : "; outside 3%: " outside[id])
                }
            }
            exit failed
        }' "$work/runs" || failed=1
    [[ "$runs" -gt 0 ]] || { echo "FAIL memory: no run"; failed=1; }

    for ((i = 1; ; i++)); do
        [[ -e "$dir/cpu-$i.json" ]] || break
        top_column "$dir/cpu-$i.txt" 2 "$work/top"
        app_processes "$dir/cpu-$i.json" cpu "$work/ids" "$work/processes"
        if [[ ! -s "$work/processes" ]]; then
            echo "FAIL CPU, window $i: no app of 50 MB or more to compare"
            failed=1
        fi
        compare_cpu "$work/top" "$work/processes" "$cpus" "$i" || failed=1
        windows=$((windows + 1))
    done
    [[ "$windows" -gt 0 ]] || { echo "FAIL CPU: no window"; failed=1; }

    # Exactly 100 snapshots, and each counts only with a memory and a CPU residual; any other
    # reason is printed (N1).
    local residuals=("$dir"/residual-*.json) total valid
    for reading in "${residuals[@]}"; do
        if [[ -s "$reading" ]]; then
            jq -r '.snapshot.system
                | if (.value.memory | type) == "number" and (.value.cpu.value | type) == "number"
                  then "ok" else (.unavailable // .value.cpu.unavailable // "no residual") end' \
                "$reading"
        else
            echo "empty reading"
        fi
    done >"$work/residuals"
    total="${#residuals[@]}"
    valid="$(grep -cx ok "$work/residuals" || true)"
    if [[ "$total" != "$RESIDUALS" ]]; then
        echo "FAIL residual: $total snapshots, want $RESIDUALS"
        failed=1
    elif [[ "$valid" == "$total" ]]; then
        echo "PASS residual: all $total snapshots have a memory and a CPU residual"
    else
        echo "FAIL residual: $valid of $total snapshots have a memory and a CPU residual"
        grep -vx ok "$work/residuals" | sort | uniq -c | sed 's/^ */  /'
        failed=1
    fi
    if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
    return "$failed"
}

WORK="$(mktemp -d)"
RUN="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RUN"' EXIT
if [[ "${1:-}" == --evaluate ]]; then
    [[ $# == 2 ]] || { echo "$USAGE" >&2; exit 2; }
    evaluate "$2"
    exit
fi
[[ $# == 0 ]] || { echo "$USAGE" >&2; exit 2; }
echo "reading for about 3 minutes..."
sysctl -n hw.activecpu >"$RUN/cpus"
for i in {1..10}; do
    top -l 1 -stats pid,mem >"$RUN/before-$i.txt"
    "$PITH" --snapshot-json 0 >"$RUN/memory-$i.json"
    top -l 1 -stats pid,mem >"$RUN/after-$i.txt"
done
for i in {1..3}; do
    "$PITH" --snapshot-json 10 >"$RUN/cpu-$i.json" &
    top -l 2 -s 10 -stats pid,cpu >"$RUN/cpu-$i.txt"
    wait $!
done
for ((i = 1; i <= RESIDUALS; i++)); do "$PITH" --snapshot-json 1 >"$RUN/residual-$i.json"; done
evaluate "$RUN"
