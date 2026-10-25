#!/bin/bash
# The accuracy gate (spec 11, step 2) for the installed Pith on this Mac. Ten times, it runs
# `Pith --snapshot-json` (two open readings 1 s apart) beside `top -l 2 -s 1`, whose second sample
# covers the same second; then it runs `--snapshot-json` alone, up to 100 snapshots. It checks:
# - memory: each app of 50 MB or more in the first snapshot is within 3% of the sum of top's MEM
#   over the app's PIDs, in each of the 10;
# - CPU: each such app is within 2 points of the sum of top's %CPU over its PIDs, over the 10 s
#   of the 10 readings, both as a share of the whole Mac, as Pith shows it;
# - residual: none of the 100 snapshots has a negative residual (spec 6.6).
# It prints one line per app, then PASS or FAIL, and exits 1 on FAIL. The lines name this Mac's
# apps, so they are never committed. Pith need not be running.
#
# Usage: scripts/accuracy.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PITH=/Applications/Pith.app/Contents/MacOS/Pith
[[ $# == 0 ]] || { echo "usage: scripts/accuracy.sh" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for i in {1..10}; do
    "$PITH" --snapshot-json >"$TMP/snapshot-$i.json" &
    top -l 2 -s 1 -stats pid,mem,cpu >"$TMP/top-$i.txt"
    wait $!
done
for i in {11..100}; do "$PITH" --snapshot-json >"$TMP/snapshot-$i.json"; done

# The apps of 50 MB or more in the first snapshot, then one line for each of them in each of the
# 10: run, id, name, bytes, CPU share or -, PIDs.
jq -r '.apps[] | select(.memory >= 52428800) | .id' "$TMP/snapshot-1.json" >"$TMP/ids.txt"
for i in {1..10}; do
    jq -r --arg run "$i" --rawfile ids "$TMP/ids.txt" '($ids | split("\n")) as $set | .apps[]
        | select(.id | IN($set[]))
        | [$run, .id, .name, .memory, (.cpu.value // "-"), (.pids | map(tostring) | join(","))]
        | @tsv' "$TMP/snapshot-$i.json"
done >"$TMP/apps.tsv"
# top's second sample of each run: run, PID, MEM in MiB, %CPU of one core.
for i in {1..10}; do
    awk -f "$ROOT/scripts/top-rows.awk" "$TMP/top-$i.txt" |
        awk -v run="$i" -v OFS='\t' '$1 == 2 { print run, $3, $4, $5 }'
done >"$TMP/top.tsv"

failed=0
awk -F '\t' -v cpus="$(sysctl -n hw.activecpu)" '
    FNR == NR { mem[$1, $2] = $3; cpu[$1, $2] = $4; next }
    {
        n = split($6, pids, ",")
        topMem = 0; topCPU = 0; missing = 0
        for (i = 1; i <= n; i++) {
            if (!(($1, pids[i]) in mem)) { missing++; continue }
            topMem += mem[$1, pids[i]]; topCPU += cpu[$1, pids[i]]
        }
        id = $2
        if (!(id in name)) { name[id] = $3; order[++apps] = id }
        pith = $4 / 1048576
        diff = (pith - topMem) / topMem * 100
        if (!(id in worst) || (diff < 0 ? -diff : diff) > (worst[id] < 0 ? -worst[id] : worst[id])) {
            worst[id] = diff; worstPith[id] = pith; worstTop[id] = topMem
        }
        runs[id]++; gone[id] += missing
        # Pith gives a share of the Mac; top gives % of one core.
        if ($5 != "-") { readings[id]++; pithCPU[id] += $5 * 100; macCPU[id] += topCPU / cpus }
    }
    END {
        for (a = 1; a <= apps; a++) {
            id = order[a]
            ok = (worst[id] < 0 ? -worst[id] : worst[id]) <= 3
            line = sprintf("%s: memory %.1f MB vs top %.1f MB (%+.2f%%, the worst of %d)", name[id],
                worstPith[id], worstTop[id], worst[id], runs[id])
            if (readings[id]) {
                p = pithCPU[id] / readings[id]; t = macCPU[id] / readings[id]
                ok = ok && (p - t < 0 ? t - p : p - t) <= 2
                line = line sprintf("; CPU %.2f%% vs top %.2f%% of the Mac (%+.2f points, %d s)", p, t,
                    p - t, readings[id])
            } else {
                ok = 0
                line = line "; no CPU reading"
            }
            if (gone[id]) line = line sprintf("; %d PIDs not in top", gone[id])
            print (ok ? "PASS " : "FAIL ") line
            failed += !ok
        }
        exit failed > 0
    }' "$TMP/top.tsv" "$TMP/apps.tsv" || failed=1

# A negative memory residual makes the whole residual a mismatch; a negative CPU one only its CPU.
read -r memory cpu < <(jq -rs '[
    ([.[] | select(.system.unavailable == "accounting mismatch")] | length),
    ([.[] | select(.system.value.cpu.unavailable == "accounting mismatch")] | length)
    ] | @tsv' "$TMP"/snapshot-*.json)
if [[ "$memory" == 0 && "$cpu" == 0 ]]; then
    echo "PASS residual: no negative residual in 100 snapshots"
else
    echo "FAIL residual: negative in $((memory + cpu)) of 100 snapshots ($memory memory, $cpu CPU)"
    failed=1
fi
if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
exit "$failed"
