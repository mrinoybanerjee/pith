#!/bin/bash
# Checks scripts/install.sh: the commands that --dry-run prints for the build, local and SSH
# targets and --app; the refusals (exit 2, nothing printed); and that a failed target does not
# stop the next one. It works from a checkout path with spaces.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
R="$(printf %q "$ROOT")"
SSH="ssh -o ConnectTimeout=5 -o BatchMode=yes"
QUIT='pkill -x Pith; n=0; while pgrep -xq Pith && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; ! pgrep -xq Pith'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
passed=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# A signed stand-in for Pith.app, in a folder whose name has a space.
APP="$TMP/Transfer Disk/Pith.app"
mkdir -p "$APP/Contents/MacOS"
cp /usr/bin/true "$APP/Contents/MacOS/Pith"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Pith</string></dict></plist>' \
    >"$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
A="$(printf %q "$APP")"
# A copy whose seal is broken.
mkdir -p "$TMP/Broken"
cp -R "$APP" "$TMP/Broken/Pith.app"
echo "<!-- changed -->" >>"$TMP/Broken/Pith.app/Contents/Info.plist"

# expect <expected output> <install.sh arguments...>
expect() {
    local expected="$1" actual
    shift
    actual="$("$INSTALL" --dry-run "$@")"
    [[ "$actual" == "$expected" ]] || fail "$(printf \
        'install.sh --dry-run %s\n--- expected\n%s\n--- actual\n%s' "$*" "$expected" "$actual")"
    passed=$((passed + 1))
}

# refuse <install.sh arguments...>: the script exits 2 and prints no command.
refuse() {
    local status=0
    "$INSTALL" --dry-run "$@" >"$TMP/out" 2>/dev/null || status=$?
    [[ "$status" == 2 && ! -s "$TMP/out" ]] ||
        fail "install.sh --dry-run $*: exit $status, $(wc -c <"$TMP/out") bytes out; want 2, none"
    passed=$((passed + 1))
}

expect "$R/scripts/build-app.sh
$QUIT
rsync -a --delete $R/dist/Pith.app /Applications/
open /Applications/Pith.app" local

expect "$QUIT
rsync -a --delete $A /Applications/
open /Applications/Pith.app
$SSH air $QUIT
rsync -a --delete -e '$SSH' $A air:/Applications/
$SSH air open /Applications/Pith.app
$SSH pro $QUIT
rsync -a --delete -e '$SSH' $A pro:/Applications/
$SSH pro open /Applications/Pith.app" --app "$APP" local air pro

# A target is quoted, so it cannot split or run as shell code.
expect "$SSH a\\;b $QUIT
rsync -a --delete -e '$SSH' $A a\\;b:/Applications/
$SSH a\\;b open /Applications/Pith.app" --app "$APP" 'a;b'

refuse --app "$APP/" local # with a trailing slash, rsync --delete would empty /Applications
refuse --app "$TMP/Transfer Disk/Other.app" local
refuse --app "$TMP/Missing/Pith.app" local
refuse --app "$TMP/Broken/Pith.app" local
refuse --app "$APP"
refuse --app
refuse --force local

# Host "down" refuses ssh and host "up" accepts. Fake ssh and rsync stand in, so nothing is
# copied, quit or opened anywhere.
mkdir "$TMP/bin"
printf '#!/bin/bash\n[[ " $* " != *" down "* ]]\n' >"$TMP/bin/ssh"
printf '#!/bin/bash\n' >"$TMP/bin/rsync"
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync"
status=0
summary="$(PATH="$TMP/bin:$PATH" "$INSTALL" --app "$APP" down up 2>/dev/null)" || status=$?
[[ "$status" == 1 && "$summary" == $'installed: up\nfailed: down' ]] ||
    fail "a failed target: exit $status, summary '$summary'"
passed=$((passed + 1))

printf 'install script: %s passed\n' "$passed"
