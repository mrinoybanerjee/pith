#!/bin/bash
# The speed gate (spec 10) for the installed Pith on this Mac. It relaunches Pith with
# --debug-hooks (R128) and samples it with `top` every 10 s: <minutes> closed, then <minutes> with
# the panel open, opened and closed through the hook's notification. It opens the panel 9 more
# times, samples 2 more minutes closed, runs one sweep benchmark, and reads the launch and open
# timings and the closes of the panel from the unified log: none during its open minutes (R145),
# and the 10 that it makes after them, which prove the close line is logged (N4). The first open
# after the launch is gated on its own line, beside the slowest of the other opens, and each open
# is listed with the 1-minute load average at its moment (R173). It refuses to run while the
# screen is locked, and it wakes the display, as a user's click would find them. Once it has quit
# the running Pith, on any exit it relaunches Pith without the hooks. It prints one line per budget, then PASS or FAIL,
# and exits 1 if any budget fails. The logs are kept; their path is printed first.
# --evaluate checks one `top -l ... -stats pid,cpu,mem,idlew` log against the closed or open
# budgets, and exits 2 if the log cannot be read. --evaluate-run checks the recorded files of a
# run, for the script test.
#
# Usage: scripts/perf.sh [--minutes <minutes, default 10>]
#        scripts/perf.sh --evaluate <closed | open> <log>
#        scripts/perf.sh --evaluate-run <dir with closed.log, open.log, after.log, children.txt,
#                        closes.txt, closes-after.txt, sweep.txt, timing.txt, loads.txt>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE="usage: scripts/perf.sh [--minutes <minutes>] | --evaluate <closed | open> <log> | --evaluate-run <dir>"
APP=/Applications/Pith.app

usage() {
    echo "$USAGE" >&2
    exit 2
}

# gate <name> <value> <budget> <printf format of the value>: one budget line, PASS or FAIL. A value
# that is not a number fails, so a changed format can never read as 0 (R142).
gate() {
    if [[ ! "$2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "FAIL $1: no number ('$2')"
        return 1
    fi
    awk -v name="$1" -v value="$2" -v budget="$3" -v format="$4" 'BEGIN {
        ok = value + 0 <= budget + 0
        printf "%s %s " format " %s %s\n", ok ? "PASS" : "FAIL", name, value, ok ? "<=" : ">", budget
        exit !ok
    }'
}

# evaluate <closed | open> <log>: the budgets of spec 10 that a top log measures. The first sample
# covers no interval, so its CPU is dropped; memory is read at the moment, so mem_max counts every
# sample. A 60 s window is 6 samples of 10 s. IDLEW is a count
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
            for (i = 2; i <= n; i++) sum += cpu[i]
            for (i = 1; i <= n; i++) if (mem[i] > most) most = mem[i]
            for (i = 2; i + 5 <= n; i++) {
                w = 0
                for (j = i; j < i + 6; j++) w += cpu[j]
                if (w > window) window = w
            }
            printf "%.6f %.6f %.6f %.6f\n", sum / (n - 1), window / 6, most, (idle[n] - idle[1]) / (t[n] - t[1])
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

# evaluate_run <dir>: every budget line of a run from its recorded files; returns 1 on any FAIL.
evaluate_run() {
    local dir="$1" failed=0 launches opens control
    echo "closed:"
    evaluate closed "$dir/closed.log" || failed=1
    echo "open:"
    evaluate open "$dir/open.log" || failed=1
    echo "closed after the open minutes:"
    evaluate closed "$dir/after.log" || failed=1
    echo "always:"
    gate children "$(sort -u "$dir/children.txt" | grep -c . || true)" 0 %d || failed=1
    gate panel_closes_while_open "$(grep -c 'panel closed' "$dir/closes.txt" || true)" 0 %d ||
        failed=1
    control="$(grep -c 'panel closed' "$dir/closes-after.txt" || true)"
    if [[ "$control" == 10 ]]; then
        echo "PASS panel_closes_after_open 10, the control"
    else
        echo "FAIL panel_closes_after_open $control, want 10: the close line may not be logged"
        failed=1
    fi
    cat "$dir/sweep.txt"
    gate sweep_mean_ms "$(grep -oE 'mean_ms=[0-9.]+' "$dir/sweep.txt" | cut -d= -f2 || true)" \
        3.00 %.2f || failed=1
    launches="$(grep -oE 'launch_to_first_reading_ms=[0-9.]+' "$dir/timing.txt" | cut -d= -f2 || true)"
    opens="$(grep -oE 'open_to_visible_ms=[0-9.]+' "$dir/timing.txt" | cut -d= -f2 || true)"
    if [[ "$(grep -c . <<<"$launches" || true)" == 1 && "$(grep -c . <<<"$opens" || true)" == 10 &&
        "$(grep -c . "$dir/loads.txt" || true)" == 10 ]]; then
        echo "opens in ms, with the 1-minute load: $(paste -d @ <(cat <<<"$opens") \
            <(awk '{ print $2 }' "$dir/loads.txt") | paste -sd ' ' -)"
        gate launch_to_first_reading_ms "$launches" 300 %.1f || failed=1
        gate first_open_to_visible_ms "$(head -1 <<<"$opens")" 100 %.1f || failed=1
        gate open_to_visible_ms_max "$(tail -n +2 <<<"$opens" | sort -n | tail -1)" 100 %.1f ||
            failed=1
    else
        echo "FAIL timings: want 1 launch, 10 opens and 10 loads in $dir"
        failed=1
    fi
    echo "footprint growth over 24 h: scripts/soak.sh"
    if [[ "$failed" == 0 ]]; then echo PASS; else echo FAIL; fi
    return "$failed"
}

if [[ "${1:-}" == --evaluate ]]; then
    [[ $# == 3 ]] || usage
    evaluate "$2" "$3"
    exit
fi
if [[ "${1:-}" == --evaluate-run ]]; then
    [[ $# == 2 ]] || usage
    evaluate_run "$2"
    exit
fi
MINUTES=10
if [[ "${1:-}" == --minutes ]]; then
    [[ $# == 2 && "$2" =~ ^[1-9][0-9]*$ ]] || usage
    MINUTES="$2"
elif [[ $# != 0 ]]; then
    usage
fi

# Quits Pith as scripts/install.sh does: SIGTERM, then up to 5 s for it to exit. Returns 1 if it
# still runs.
quit_pith() {
    pkill -x Pith || true
    local n=0
    while pgrep -xq Pith && ((n < 50)); do
        sleep 0.1
        n=$((n + 1))
    done
    ! pgrep -xq Pith
}

# post <open | close>: the panel notification of --debug-hooks. Pith is never the active app, so
# the notification is sent for immediate delivery. `$()` is nil; JavaScript's null is NSNull. Each
# open logs the load average of its moment (R173).
post() {
    [[ "$1" != open ]] || sysctl -n vm.loadavg >>"$LOGS/loads.txt"
    osascript -l JavaScript -e "ObjC.import('Foundation')
\$.NSDistributedNotificationCenter.defaultCenter
  .postNotificationNameObjectUserInfoDeliverImmediately(
    'com.mrinoy.pith.panel', \$(), \$({action: '$1'}), true)" >/dev/null
}

# sample <minutes> <log>: top every 10 s for <minutes>, after the first sample, which has no
# interval.
sample() {
    top -l $(($1 * 6 + 1)) -s 10 -pid "$PID" -stats pid,cpu,mem,idlew >"$2"
}

# pith_log <category> <start> [<end>]: the unified log of this Pith in a category.
pith_log() {
    local range=(--start "$2")
    [[ -z "${3:-}" ]] || range+=(--end "$3")
    /usr/bin/log show --style compact "${range[@]}" --predicate \
        "subsystem == \"com.mrinoy.pith\" AND category == \"$1\" AND processID == $PID"
}

# On any exit after the running Pith quit, even after a failed step or with the helpers gone, the
# helpers stop and Pith runs again without the hooks. Launch Services can still list the copy that
# just quit and send it the open (error -600), so `-n`.
relaunch() {
    set +e
    kill "${awake:-}" "${watcher:-}" 2>/dev/null
    quit_pith || echo "error: Pith did not quit; opening it anyway" >&2
    open -n "$APP"
}

# A locked screen is not what a click finds (R173).
if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "error: the screen is locked; unlock it and run again" >&2
    exit 2
fi
LOGS="$(mktemp -d)"
echo "logs: $LOGS"
# A display that sleeps or locks pauses Pith's clock (spec 9), so it stays awake for the run.
caffeinate -d -i -w $$ >/dev/null 2>&1 &
awake=$!
disown
# A dark display slows the first open, and a click always finds it lit (R173).
caffeinate -u -t 2
# A Pith that does not quit is left as it is: relaunching would start a second copy (N3).
quit_pith || { echo "error: Pith did not quit" >&2; exit 2; }
trap relaunch EXIT
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
sample "$MINUTES" "$LOGS/closed.log"
echo "open for $MINUTES min..."
open_start="$(date '+%Y-%m-%d %H:%M:%S')"
post open
sample "$MINUTES" "$LOGS/open.log"
open_end="$(date '+%Y-%m-%d %H:%M:%S')"
post close
for _ in {1..9}; do
    sleep 2
    post open
    sleep 2
    post close
done
echo "closed for 2 min after the opens..."
sample 2 "$LOGS/after.log"
kill "$watcher"
"$APP/Contents/MacOS/Pith" --benchmark-sweep 200 >"$LOGS/sweep.txt"
pith_log timing "$since" >"$LOGS/timing.txt"
pith_log debug-hooks "$open_start" "$open_end" >"$LOGS/closes.txt"
pith_log debug-hooks "$open_end" >"$LOGS/closes-after.txt"
evaluate_run "$LOGS"
