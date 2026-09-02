#!/bin/bash
# Rebuild-and-relaunch loop: polls Sources/ and Package.swift once a second
# and restarts the app when anything changes. Zero dependencies. If you want
# an FSEvents-based watcher instead: `brew install watchexec`, then
#   watchexec -r -e swift -- swift run Sill
# Extra arguments are passed to the app (e.g. ./Scripts/dev.sh --settings).
set -uo pipefail
cd "$(dirname "$0")/.."

APP_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

fingerprint() {
    find Sources Package.swift -type f -name "*.swift" -exec stat -f "%m %N" {} + | sort | md5
}

while true; do
    SNAPSHOT=$(fingerprint)
    if swift build; then
        [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
        .build/debug/Sill "$@" &
        APP_PID=$!
        echo "▶ launched (pid $APP_PID) — watching for changes"
    else
        echo "✗ build failed — fix and save to retry"
    fi
    while [[ "$(fingerprint)" == "$SNAPSHOT" ]]; do
        sleep 1
    done
    echo "↻ change detected, rebuilding…"
done
