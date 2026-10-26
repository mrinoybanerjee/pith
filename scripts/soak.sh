#!/bin/bash
# The soak (spec 11, step 4) of the running Pith on this Mac. It reads Pith's footprint in bytes
# (`footprint -f bytes`, R145) every 10 minutes for <hours>, after it prints the steps to do by
# hand. Then it prints PASS or FAIL: the same Pith ran throughout, its footprint grew by 2 MB at
# most from the first reading to the last, and it left no new crash report
# (~/Library/Logs/DiagnosticReports/Pith*). It exits 1 on FAIL.
#
# Usage: scripts/soak.sh [--hours <hours, default 24>]

set -euo pipefail

USAGE="usage: scripts/soak.sh [--hours <hours>]"
HOURS=24
if [[ "${1:-}" == --hours ]]; then
    [[ $# == 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "$USAGE" >&2; exit 2; }
    HOURS="$2"
elif [[ $# != 0 ]]; then
    echo "$USAGE" >&2
    exit 2
fi
PID="$(pgrep -x Pith)" || { echo "error: Pith is not running" >&2; exit 2; }
reports() { find ~/Library/Logs/DiagnosticReports -maxdepth 1 -name 'Pith*' | sort; }
before="$(reports)"
LOG="$(mktemp)"
cat <<STEPS
Soak of Pith (pid $PID) for $HOURS h; the readings go to $LOG. By hand:
  1. During the run, sleep the Mac and wake it, twice.
  2. During the run, open and close the panel now and then, as in daily use.
  3. After the run, restart the Mac. Check that Pith runs again (pgrep -x Pith) and that
     ~/Library/Logs/DiagnosticReports has no Pith* file.
STEPS
readings=$((HOURS * 6 + 1))
for ((i = 0; i < readings; i++)); do
    ((i == 0)) || sleep 600
    # Fails, and ends the readings, once this Pith is gone.
    footprint -f bytes -p "$PID" 2>/dev/null | grep -oE 'Footprint: [0-9]+ B' | grep -oE '[0-9]+' \
        >>"$LOG" || break
done

failed=0
awk -v readings="$readings" '
    NR == 1 { first = $1 }
    { last = $1 }
    END {
        growth = (last - first) / 1048576
        ok = NR == readings && growth <= 2
        printf "%s footprint growth %.2f MB, from %.2f to %.2f MB, Pith in %d of %d readings\n",
            ok ? "PASS" : "FAIL", growth, first / 1048576, last / 1048576, NR, readings
        exit !ok
    }' "$LOG" || failed=1
crashes="$(comm -13 <(echo "$before") <(reports) | grep -c . || true)"
if [[ "$crashes" == 0 ]]; then echo "PASS no new crash report"; else
    echo "FAIL $crashes new crash reports in ~/Library/Logs/DiagnosticReports"
    failed=1
fi
if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
exit "$failed"
