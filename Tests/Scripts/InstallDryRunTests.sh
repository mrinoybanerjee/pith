#!/bin/bash
# Checks the commands that scripts/install.sh --dry-run prints: the build, the local and SSH
# targets, the --app form, and the refusals.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QUIT="if pgrep -xq Pith; then osascript -e 'tell application id \"com.mrinoy.pith\" to quit' && while pgrep -xq Pith; do sleep 0.1; done; fi"
passed=0

# expect <expected output> <install.sh arguments...>
expect() {
    local expected="$1" actual
    shift
    actual="$("$ROOT/scripts/install.sh" --dry-run "$@")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: install.sh --dry-run %s\n--- expected\n%s\n--- actual\n%s\n' \
            "$*" "$expected" "$actual" >&2
        exit 1
    fi
    passed=$((passed + 1))
}

# refuse <install.sh arguments...>: the script must exit non-zero before it runs anything.
refuse() {
    if "$ROOT/scripts/install.sh" --dry-run "$@" >/dev/null 2>&1; then
        printf 'FAIL: install.sh --dry-run %s did not refuse\n' "$*" >&2
        exit 1
    fi
    passed=$((passed + 1))
}

expect "$ROOT/scripts/build-app.sh
$QUIT
rsync -a --delete $ROOT/dist/Pith.app /Applications/
open /Applications/Pith.app" local

expect "$QUIT
rsync -a --delete /Volumes/Transfer/Pith.app /Applications/
open /Applications/Pith.app
ssh pro $QUIT
rsync -a --delete /Volumes/Transfer/Pith.app pro:/Applications/
ssh pro open /Applications/Pith.app" --app /Volumes/Transfer/Pith.app local pro

# A trailing slash would make rsync --delete empty /Applications into the app's contents.
refuse --app /Volumes/Transfer/Pith.app/ local
refuse --app /Volumes/Transfer/Other.app local
refuse --app /Volumes/Transfer/Pith.app

printf 'install dry run: %s passed\n' "$passed"
