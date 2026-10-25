#!/bin/bash
# The speed gate (spec 10) for the installed Pith on this Mac. It relaunches Pith with
# --debug-hooks (R128) and samples it with `top` every 10 s: <minutes> closed, then <minutes> with
# the panel open, opened and closed through the hook's notification. It opens the panel 9 more
# times, runs one sweep benchmark, reads the launch and open timings from the unified log, and
# relaunches Pith without the hooks, also when it fails or is stopped. It prints one line per
# budget, then PASS or FAIL, and exits 1 if any budget fails. The `top` logs are kept; their
# path is printed first.
# With --evaluate, it checks one `top -l ... -stats pid,cpu,mem,idlew` log against the closed or
# open budgets, and exits 2 if the log cannot be read.
#
# Usage: scripts/perf.sh [--minutes <minutes, default 10>]
#        scripts/perf.sh --evaluate <closed | open> <log>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE="usage: scripts/perf.sh [--minutes <minutes>] | --evaluate <closed | open> <log>"
APP=/Applications/Pith.app

usage() {
    echo "$USAGE" >&2
    exit 2
}

# gate <name> <value> <budget> <printf format of the value>: one budget line, PASS or FAIL.
gate() {
    awk -v name="$1" -v value="$2" -v budget="$3" -v format="$4" 'BEGIN {
        ok = value + 0 <= budget + 0
        printf "%s %s " format " %s %s\n", ok ? "PASS" : "FAIL", name, value, ok ? "<=" : ">", budget
        exit !ok
    }'
}

# evaluate <closed | open> <log>: the budgets of spec 10 that a top log measures. The first sample
# covers no interval, so its CPU is dropped. A 60 s window is 6 samples of 10 s. IDLEW is a count
# since Pith started (top's default event mode, "-c n"), so its rate is the change over the run.
evaluate() {
    local budgets measures failed=0
    case "$1" in
        closed) budgets=(0.10 1.00 30.0 0.50) ;;
        open) budgets=(1.50 5.00 45.0 2.00) ;;
        *) usage ;;
    esac
    measures="$(awk -f "$ROOT/scripts/top-rows.awk" "$2" | awk \
        -v samples="$(grep -c '^Processes:' "$2")" '
        { t[NR] = $2; cpu[NR] = $4; mem[NR] = $5; idle[NR] = $6 }
        END {
            n = NR
            if (n != samples) error(samples " samples but " n " rows of Pith: did it exit?")
            if (n < 7) error(n " samples, fewer than the 7 that one 60 s window needs")
            if ((t[n] - t[1]) / (n - 1) < 9 || (t[n] - t[1]) / (n - 1) > 11) error("samples are not 10 s apart")
            for (i = 2; i <= n; i++) {
                sum += cpu[i]
                if (mem[i] > most) most = mem[i]
            }
            for (i = 2; i + 5 <= n; i++) {
                w = 0
                for (j = i; j < i + 6; j++) w += cpu[j]
                if (w > window) window = w
            }
            print sum / (n - 1), window / 6, most, (idle[n] - idle[1]) / (t[n] - t[1])
        }
        function error(message) {
            print "error: " message > "/dev/stderr"
            exit 2
        }')" || return 2
    read -r cpu window mem rate <<<"$measures"
    gate cpu_mean "$cpu" "${budgets[0]}" %.2f || failed=1
    gate cpu_60s_max "$window" "${budgets[1]}" %.2f || failed=1
    gate mem_max "$mem" "${budgets[2]}" %.1f || failed=1
    gate idlew_per_s "$rate" "${budgets[3]}" %.2f || failed=1
    return "$failed"
}

if [[ "${1:-}" == --evaluate ]]; then
    [[ $# == 3 ]] || usage
    evaluate "$2" "$3"
    exit
fi
MINUTES=10
if [[ "${1:-}" == --minutes ]]; then
    [[ $# == 2 && "$2" =~ ^[1-9][0-9]*$ ]] || usage
    MINUTES="$2"
elif [[ $# != 0 ]]; then
    usage
fi

# Quits Pith as scripts/install.sh does: SIGTERM, then up to 5 s for it to exit.
quit_pith() {
    pkill -x Pith || true
    local n=0
    while pgrep -xq Pith && ((n < 50)); do
        sleep 0.1
        n=$((n + 1))
    done
    if pgrep -xq Pith; then
        echo "error: Pith did not quit" >&2
        exit 2
    fi
}

# post <open | close>: the panel notification of --debug-hooks. Pith is never the active app, so
# the notification is sent for immediate delivery. `$()` is nil; JavaScript's null is NSNull.
post() {
    osascript -l JavaScript -e "ObjC.import('Foundation')
\$.NSDistributedNotificationCenter.defaultCenter
  .postNotificationNameObjectUserInfoDeliverImmediately(
    'com.mrinoy.pith.panel', \$(), \$({action: '$1'}), true)" >/dev/null
}

# sample <log>: top every 10 s for MINUTES, after the first sample, which has no interval.
sample() {
    top -l $((MINUTES * 6 + 1)) -s 10 -pid "$PID" -stats pid,cpu,mem,idlew >"$1"
}

LOGS="$(mktemp -d)"
echo "logs: $LOGS"
# A display that sleeps or locks pauses Pith's clock (spec 9), so it stays awake for the run.
caffeinate -d -i -w $$ >/dev/null 2>&1 &
awake=$!
disown
quit_pith
# Also on a failure or Ctrl-C: the helpers stop, and Pith runs again without the hooks. Launch
# Services can still list the copy that just quit and send it the open (error -600), so `-n`.
trap 'kill "$awake" "${watcher:-}" 2>/dev/null; quit_pith; open -n "$APP"' EXIT
since="$(date '+%Y-%m-%d %H:%M:%S')"
open -n -a "$APP" --args --debug-hooks
for _ in {1..50}; do
    PID="$(pgrep -x Pith)" && break
    sleep 0.1
done
[[ -n "${PID:-}" ]] || { echo "error: Pith did not start" >&2; exit 2; }
sleep 5
# Pith's child processes, checked every second, so a child shorter than that can be missed.
while sleep 1; do pgrep -P "$PID" || true; done >"$LOGS/children.txt" 2>&1 &
watcher=$!
disown

echo "closed for $MINUTES min..."
sample "$LOGS/closed.log"
echo "open for $MINUTES min..."
post open
sample "$LOGS/open.log"
post close
for _ in {1..9}; do
    sleep 2
    post open
    sleep 2
    post close
done
kill "$watcher"
sweep="$("$APP/Contents/MacOS/Pith" --benchmark-sweep 200)"
log show --start "$since" --style compact --predicate \
    "subsystem == \"com.mrinoy.pith\" AND category == \"timing\" AND processID == $PID" \
    >"$LOGS/timing.txt"

failed=0
echo "closed:"
evaluate closed "$LOGS/closed.log" || failed=1
echo "open:"
evaluate open "$LOGS/open.log" || failed=1
echo "always:"
gate children "$(sort -u "$LOGS/children.txt" | grep -c . || true)" 0 %d || failed=1
echo "$sweep"
gate sweep_mean_ms "$(grep -oE 'mean_ms=[0-9.]+' <<<"$sweep" | cut -d= -f2)" 3.00 %.2f || failed=1
launches="$(grep -oE 'launch_to_first_reading_ms=[0-9.]+' "$LOGS/timing.txt" | cut -d= -f2)"
opens="$(grep -oE 'open_to_visible_ms=[0-9.]+' "$LOGS/timing.txt" | cut -d= -f2)"
if [[ "$(grep -c . <<<"$launches" || true)" == 1 && "$(grep -c . <<<"$opens" || true)" == 10 ]]; then
    gate launch_to_first_reading_ms "$launches" 300 %.1f || failed=1
    gate open_to_visible_ms_max "$(sort -n <<<"$opens" | tail -1)" 100 %.1f || failed=1
else
    echo "FAIL timings: want 1 launch and 10 opens in $LOGS/timing.txt"
    failed=1
fi
echo "footprint growth over 24 h: scripts/soak.sh"
if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
exit "$failed"
