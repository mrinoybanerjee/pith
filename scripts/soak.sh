#!/bin/bash
# The soak (spec 11, step 4) of the running Pith on this Mac. It samples Pith's footprint with
# `top` every 10 minutes for <hours>, after it prints the steps to do by hand. Then it prints PASS
# or FAIL: the same Pith ran throughout, its footprint grew by 2 MB at most from the first sample
# to the last, and it left no new crash report (~/Library/Logs/DiagnosticReports/Pith*). It exits
# 1 on FAIL.
#
# Usage: scripts/soak.sh [--hours <hours, default 24>]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
cat <<EOF
Soak of Pith (pid $PID) for $HOURS h; the samples go to $LOG. By hand:
  1. During the run, sleep the Mac and wake it, twice.
  2. During the run, open and close the panel now and then, as in daily use.
  3. After the run, restart the Mac. Check that Pith runs again (pgrep -x Pith) and that
     ~/Library/Logs/DiagnosticReports has no Pith* file.
EOF
top -l $((HOURS * 6 + 1)) -s 600 -pid "$PID" -stats pid,mem >"$LOG"

failed=0
awk -f "$ROOT/scripts/top-rows.awk" "$LOG" | awk -v samples="$(grep -c '^Processes:' "$LOG")" '
    NR == 1 { first = $4 }
    { last = $4 }
    END {
        ok = NR == samples && last - first <= 2
        printf "%s footprint growth %.1f MB, from %.1f to %.1f MB, Pith in %d of %d samples\n",
            ok ? "PASS" : "FAIL", last - first, first, last, NR, samples
        exit !ok
    }' || failed=1
crashes="$(comm -13 <(echo "$before") <(reports) | grep -c . || true)"
if [[ "$crashes" == 0 ]]; then echo "PASS no new crash report"; else
    echo "FAIL $crashes new crash reports in ~/Library/Logs/DiagnosticReports"
    failed=1
fi
if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
exit "$failed"
