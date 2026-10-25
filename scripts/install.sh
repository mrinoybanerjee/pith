#!/bin/bash
# Installs Pith.app in /Applications on each target and opens it. A target is "local" (this Mac)
# or an SSH host with key-based login and a logged-in desktop session. Without --app, it first
# builds dist/Pith.app on this Mac. --dry-run prints each command instead of running it.
# A failed target does not stop the others; the script ends with a summary and exits 1 if any
# target failed. It exits 2, before it changes anything, on bad arguments or a broken app.
#
# Usage: scripts/install.sh [--dry-run] [--app <path to Pith.app>] <local | host>...

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE="usage: scripts/install.sh [--dry-run] [--app <path to Pith.app>] <local | host>..."
DRY_RUN=0
APP=""
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --app)
            [[ -n "${2:-}" ]] || { echo "$USAGE" >&2; exit 2; }
            APP="$2"
            shift
            ;;
        *)
            printf 'error: unknown option %s\n%s\n' "$1" "$USAGE" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ $# -eq 0 ]]; then
    echo "$USAGE" >&2
    exit 2
fi
# ssh would read a target such as -oProxyCommand=... as an option.
for target in "$@"; do
    if [[ "$target" == -* ]]; then
        printf 'error: target %s starts with "-"\n%s\n' "$target" "$USAGE" >&2
        exit 2
    fi
done
# With a trailing slash, rsync --delete would make /Applications match the app's contents.
if [[ -n "$APP" && "${APP##*/}" != Pith.app ]]; then
    echo "error: --app must name Pith.app itself, without a trailing slash" >&2
    exit 2
fi

# A host that is down or asks for a password fails in seconds instead of hanging.
SSH=(ssh -o ConnectTimeout=5 -o BatchMode=yes)
# Quits Pith (SIGTERM; no Automation consent needed) and waits up to 5 s for it to exit. It fails
# only if Pith still runs; finding no Pith is fine.
QUIT='pkill -x Pith; n=0; while pgrep -xq Pith && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; ! pgrep -xq Pith'

# on <target> <command line>: runs the command line on the target, or prints it under --dry-run.
on() {
    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ "$1" == local ]]; then echo "$2"; else echo "${SSH[*]} $(printf %q "$1") $2"; fi
    elif [[ "$1" == local ]]; then
        eval "$2"
    else
        "${SSH[@]}" "$1" "$2"
    fi
}

# install_on <target>: quits Pith, copies the app and opens it.
install_on() {
    local destination=/Applications/ rsh=""
    if [[ "$1" != local ]]; then
        destination="$(printf %q "$1"):/Applications/"
        rsh="-e '${SSH[*]}' "
    fi
    if ! on "$1" "$QUIT"; then
        echo "error: Pith did not quit on $1" >&2
        return 1
    fi
    on local "rsync -a --delete $rsh$(printf %q "$APP") $destination" &&
        on "$1" "open /Applications/Pith.app"
}

BUILD=0
if [[ -z "$APP" ]]; then
    BUILD=1
    APP="$ROOT/dist/Pith.app"
    on local "$(printf %q "$ROOT")/scripts/build-app.sh"
fi
# No target changes unless the app is whole. A dry run builds nothing, so it checks only --app.
if [[ "$DRY_RUN" == 0 || "$BUILD" == 0 ]] && ! codesign --verify --deep --strict "$APP"; then
    echo "error: $APP is missing or fails codesign --verify; nothing was changed" >&2
    exit 2
fi

installed=""
failed=""
for target in "$@"; do
    if install_on "$target"; then installed+=" $target"; else failed+=" $target"; fi
done
if [[ "$DRY_RUN" == 0 ]]; then
    printf 'installed:%s\nfailed:%s\n' "$installed" "$failed"
fi
if [[ -n "$failed" ]]; then
    exit 1
fi
