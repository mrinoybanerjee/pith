#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Without Xcode, SwiftPM 6.2 finds Testing.framework in the Command Line Tools but passes
# -I instead of -F (UserToolchain.deriveSwiftTestingPath), so `import Testing` fails and
# the test bundle cannot load the framework. Add both paths there; Xcode needs neither.
build=(swift build --build-tests)
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    build+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi
"${build[@]}"

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# A test run passes only when Swift Testing reports its own completion summary.
# Swift Testing drives AppKit from the Swift async main loop. AppKit's nested run loops
# (for example NSButtonCell.performClick or a window animation) can call CFRunLoopStop,
# which ends that loop and exits the process with status 0 before later tests run. The
# app itself uses NSApplication's loop and is unaffected. Only such an incomplete run is
# retried; any recorded issue or failure fails immediately.
run_tests() {
    local name="$1"
    shift
    local attempt log
    for attempt in 1 2 3; do
        log="$LOG_DIR/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')-$attempt.log"
        if ! swift test --skip-build "$@" >"$log" 2>&1 </dev/null; then
            cat "$log"
            return 1
        fi
        if grep -Eq '✘ (Test|Suite) .*(failed|recorded an issue)' "$log"; then
            cat "$log"
            return 1
        fi
        # Swift 6.2 adds "in N suites" to the summary; Swift 6.0 and 6.1 do not.
        if grep -Eq '^✔ Test run with [0-9]+ tests? (in [0-9]+ suites? )?passed' "$log"; then
            printf '%s: %s\n' "$name" "$(grep -E '^✔ Test run with' "$log")"
            return 0
        fi
        printf 'warning: %s ended before Swift Testing reported completion (attempt %s)\n' \
            "$name" "$attempt" >&2
    done
    cat "$log"
    printf 'error: %s never completed; tests after the interruption did not run\n' "$name" >&2
    return 1
}

run_tests "core and app" --parallel --skip NativeInteractionTests

# Native window tests run one per process so an interrupted run affects only that test.
# grep exits 1 when there are no native tests yet; any other failure stops the script.
swift test list --skip-build 2>/dev/null \
    | { grep 'NativeInteractionTests/' || (($? == 1)); } >"$LOG_DIR/native.txt"
native_count=0
while IFS= read -r test_id; do
    pattern="^$(printf '%s' "$test_id" | sed -E 's/[][().*+?^$|\\]/\\&/g')\$"
    run_tests "$test_id" --filter "$pattern" >/dev/null
    native_count=$((native_count + 1))
done <"$LOG_DIR/native.txt"
printf 'native windows: %s tests completed, one process each\n' "$native_count"
