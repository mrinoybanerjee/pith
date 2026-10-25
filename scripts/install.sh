#!/bin/bash
# Installs Pith.app in /Applications on each target and opens it. A target is "local" (this Mac)
# or an SSH host. Without --app, it first builds dist/Pith.app on this Mac. --dry-run prints each
# command instead of running it.
#
# Usage: scripts/install.sh [--dry-run] [--app <path to Pith.app>] <local | host>...

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
APP=""
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --app)
            APP="$2"
            shift
            ;;
        *)
            echo "error: unknown option $1" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ $# -eq 0 ]]; then
    echo "usage: scripts/install.sh [--dry-run] [--app <path to Pith.app>] <local | host>..." >&2
    exit 2
fi
# With a trailing slash, rsync --delete would make /Applications match the app's contents.
if [[ -n "$APP" && "${APP##*/}" != Pith.app ]]; then
    echo "error: --app must name Pith.app itself, without a trailing slash" >&2
    exit 2
fi

# Quits a running Pith and waits until it exits, so that `open` starts the new copy. A Mac
# without a running Pith skips the quit: osascript cannot name an app that was never installed.
QUIT="if pgrep -xq Pith; then osascript -e 'tell application id \"com.mrinoy.pith\" to quit' && while pgrep -xq Pith; do sleep 0.1; done; fi"

# on <target> <command line>: runs the command line on the target, or prints it under --dry-run.
on() {
    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ "$1" == local ]]; then echo "$2"; else echo "ssh $1 $2"; fi
    elif [[ "$1" == local ]]; then
        eval "$2"
    else
        ssh "$1" "$2"
    fi
}

if [[ -z "$APP" ]]; then
    APP="$ROOT/dist/Pith.app"
    on local "$(printf %q "$ROOT")/scripts/build-app.sh"
fi
for target in "$@"; do
    destination=/Applications/
    [[ "$target" == local ]] || destination="$target:/Applications/"
    on "$target" "$QUIT"
    on local "rsync -a --delete $(printf %q "$APP") $destination"
    on "$target" "open /Applications/Pith.app"
done
