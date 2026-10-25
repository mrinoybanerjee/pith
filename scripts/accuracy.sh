#!/bin/bash
# The accuracy gate (spec 11, step 2) for the installed Pith on this Mac, as R138 reads it. Each
# check counts only the PIDs that both Pith and `top` saw, and leaves the others out on both sides.
# - Memory, at the same moment: 10 times, `top` samples MEM just before and just after a
#   `Pith --snapshot-json 0` reading. Each app of 50 MB or more passes within 3% of the range of
#   the two samples. Each line shows the range's width, so a loose comparison is visible.
# - CPU, over a 10 s window: 3 times, `Pith --snapshot-json 10` beside `top -l 2 -s 10`, started
#   together. Each app of 50 MB or more passes within 2 points, as a share of the whole Mac (R135).
# - Residual: no negative residual in 100 snapshots (`--snapshot-json 1`).
# No process is left out. It prints one line per app and comparison, then PASS or FAIL, and exits 1
# on FAIL. It takes about 3 minutes. The lines name this Mac's apps: never commit them.
# --evaluate-memory checks one recorded memory comparison, for the script test.
#
# Usage: scripts/accuracy.sh
#        scripts/accuracy.sh --evaluate-memory <reading.json> <top before> <top after>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE="usage: scripts/accuracy.sh [--evaluate-memory <reading.json> <top before> <top after>]"
PITH=/Applications/Pith.app/Contents/MacOS/Pith
MIN_BYTES=52428800  # 50 MB

# top_column <log> <sample> <column>: the PID and one column of every row in one sample of a
# `top -l` log, tab-separated. Column 4 is the first after the PID.
top_column() {
    awk -f "$ROOT/scripts/top-rows.awk" "$1" |
        awk -v sample="$2" -v column="$3" -v OFS='\t' '$1 == sample { print $3, $column }'
}

# app_processes <reading.json> <field>: for each app of 50 MB or more, its name, then
# "pid:value" for each of its processes, comma-separated; the value is "-" when Pith has none.
app_processes() {
    jq -r --arg field "$2" --argjson min "$MIN_BYTES" '.processes as $p | .snapshot.apps[]
        | select(.memory >= $min)
        | [.name, ([.pids[] | tostring | "\(.):\($p[.][$field] // "-")"] | join(","))]
        | @tsv' "$1"
}

# compare_memory <reading.json> <top before> <top after>: Pith's footprints in MiB against the
# range of the two `top` samples, over the PIDs in all three.
compare_memory() {
    awk -F '\t' '
        FILENAME == ARGV[1] { before[$1] = $2; next }
        FILENAME == ARGV[2] { after[$1] = $2; next }
        {
            n = split($2, processes, ",")
            pith = 0; low = 0; high = 0; both = 0; out = 0
            for (i = 1; i <= n; i++) {
                split(processes[i], p, ":")
                if (!(p[1] in before) || !(p[1] in after)) { out++; continue }
                pith += p[2] / 1048576; low += before[p[1]]; high += after[p[1]]; both++
            }
            if (low > high) { t = low; low = high; high = t }
            ok = both > 0 && pith >= low * 0.97 && pith <= high * 1.03
            width = low > 0 ? (high - low) / low * 100 : 0
            printf "%s %s: memory %.1f MB, top %.1f to %.1f MB (width %.2f%%), PIDs %d, left out %d\n",
                ok ? "PASS" : "FAIL", $1, pith, low, high, width, both, out
            failed += !ok
        }
        END { exit failed > 0 }' <(top_column "$2" 1 4) <(top_column "$3" 1 4) \
        <(app_processes "$1" footprint)
}

# compare_cpu <reading.json> <top -l 2 log>: Pith's CPU shares against the second sample's %CPU
# of one core over the same 10 s, both as a share of the whole Mac, over the PIDs in both. A
# process with no Pith share (new, or an exec) is left out on both sides.
compare_cpu() {
    awk -F '\t' -v cpus="$(sysctl -n hw.activecpu)" '
        FILENAME == ARGV[1] { top[$1] = $2; next }
        {
            n = split($2, processes, ",")
            pith = 0; mac = 0; both = 0; out = 0
            for (i = 1; i <= n; i++) {
                split(processes[i], p, ":")
                if (!(p[1] in top) || p[2] == "-") { out++; continue }
                pith += p[2] * 100; mac += top[p[1]] / cpus; both++
            }
            ok = both > 0 && (pith - mac < 0 ? mac - pith : pith - mac) <= 2
            printf "%s %s: CPU %.2f%% vs top %.2f%% of the Mac over 10 s (%+.2f points), PIDs %d, left out %d\n",
                ok ? "PASS" : "FAIL", $1, pith, mac, pith - mac, both, out
            failed += !ok
        }
        END { exit failed > 0 }' <(top_column "$2" 2 4) <(app_processes "$1" cpu)
}

if [[ "${1:-}" == --evaluate-memory ]]; then
    [[ $# == 4 ]] || { echo "$USAGE" >&2; exit 2; }
    compare_memory "$2" "$3" "$4"
    exit
fi
[[ $# == 0 ]] || { echo "$USAGE" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failed=0

for i in {1..10}; do
    echo "memory $i of 10:"
    top -l 1 -stats pid,mem >"$TMP/before-$i.txt"
    "$PITH" --snapshot-json 0 >"$TMP/memory-$i.json"
    top -l 1 -stats pid,mem >"$TMP/after-$i.txt"
    compare_memory "$TMP/memory-$i.json" "$TMP/before-$i.txt" "$TMP/after-$i.txt" || failed=1
done
for i in {1..3}; do
    echo "CPU window $i of 3:"
    "$PITH" --snapshot-json 10 >"$TMP/cpu-$i.json" &
    top -l 2 -s 10 -stats pid,cpu >"$TMP/cpu-$i.txt"
    wait $!
    compare_cpu "$TMP/cpu-$i.json" "$TMP/cpu-$i.txt" || failed=1
done
for i in {1..100}; do "$PITH" --snapshot-json 1 >"$TMP/residual-$i.json"; done
# A negative memory residual makes the whole residual a mismatch; a negative CPU one only its CPU.
read -r memory cpu < <(jq -rs '[
    ([.[] | select(.snapshot.system.unavailable == "accounting mismatch")] | length),
    ([.[] | select(.snapshot.system.value.cpu.unavailable == "accounting mismatch")] | length)
    ] | @tsv' "$TMP"/residual-*.json)
if [[ "$memory" == 0 && "$cpu" == 0 ]]; then
    echo "PASS residual: no negative residual in 100 snapshots"
else
    echo "FAIL residual: negative in $((memory + cpu)) of 100 snapshots ($memory memory, $cpu CPU)"
    failed=1
fi
if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
exit "$failed"
