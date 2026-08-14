#!/bin/zsh
# Build Fetch, run FetchKit's tests, and relaunch the app.
#
# For trialling spacing: every number the layout uses is in
# Fetch/DesignSystem/Dimension.swift. Edit one, run this, look at the window.
#
#   ./scripts/preview.sh          build, test, relaunch
#   ./scripts/preview.sh -q       skip the tests (spacing cannot break them)
#
# The build goes to a scratch derived-data path so it never fights whatever
# Xcode has open.

set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${TMPDIR:-/tmp}/fetch-preview-dd"
QUICK=0
[[ "${1:-}" == "-q" ]] && QUICK=1

if (( ! QUICK )); then
    print -P "%F{cyan}▸ FetchKit tests%f"
    ( cd FetchKit && swift test 2>&1 | tail -3 )
fi

print -P "%F{cyan}▸ building%f"
if ! xcodebuild -project Fetch.xcodeproj -scheme Fetch -configuration Debug \
        -derivedDataPath "$DD" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; then
    print -P "%F{red}build produced no result line%f" >&2
    exit 1
fi

APP="$DD/Build/Products/Debug/Fetch.app"
[[ -d "$APP" ]] || { print -P "%F{red}no app at $APP%f" >&2; exit 1 }

# Wait for it to actually go. `sleep 1` raced it often enough to matter:
# launchd refuses the new instance while the old one is still shutting down,
# and the failure is an error 163 that says nothing about why.
osascript -e 'tell application "Fetch" to quit' 2>/dev/null || true
for _ in {1..40}; do
    pgrep -x Fetch >/dev/null || break
    sleep 0.25
done
pgrep -x Fetch >/dev/null && { pkill -x Fetch; sleep 0.5 }

open "$APP"
print -P "%F{green}▸ running%f $APP"
