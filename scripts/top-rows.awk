# Reads `top -l` output and prints one line per process row: the sample's number (from 1), its time
# in seconds since the first sample, then the row's columns in the order of `-stats`. MEM is in
# MiB. The + or - that top adds to a value that changed, and the * after a Rosetta PID, are
# dropped. A column of text with spaces, such as COMMAND, would split: use none.
# Used by scripts/perf.sh, accuracy.sh and soak.sh.

function mib(value,   unit, n) {
    unit = substr(value, length(value))
    n = substr(value, 1, length(value) - 1)
    if (unit == "B") return n / 1048576
    if (unit == "K") return n / 1024
    if (unit == "M") return n
    if (unit == "G") return n * 1024
    printf "error: top MEM value %s has no known unit\n", value >"/dev/stderr"
    exit 2
}

/^Processes:/ { sample++; inRows = 0; next }

# The time of the sample, as YYYY/MM/DD HH:MM:SS. A run past midnight adds a day.
/^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
    split($2, hms, ":")
    now = hms[1] * 3600 + hms[2] * 60 + hms[3]
    if (sample == 1) start = now
    if (now < last) day += 86400
    last = now
    elapsed = now + day - start
    next
}

/^PID / {
    mem = 0
    for (i = 1; i <= NF; i++) if ($i == "MEM") mem = i
    inRows = 1
    next
}

inRows && $1 ~ /^[0-9]+\*?$/ {
    line = sample " " elapsed
    for (i = 1; i <= NF; i++) {
        value = $i
        sub(/[-+*]$/, "", value)
        line = line " " (i == mem ? mib(value) : value)
    }
    print line
}
