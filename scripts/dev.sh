#!/bin/bash
# scripts/dev.sh — build the debug bundle, launch it, and stream its OSLog.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stream=true
for arg in "$@"; do
    case "$arg" in
        --no-stream) stream=false ;;
    esac
done

# Local debug uses an ad-hoc app because a certificate without a provisioning
# profile is rejected by LaunchServices. KeychainStore falls back to login Keychain.
"$ROOT/scripts/bundle.sh" debug --fast

if ! $stream; then
    open "$ROOT/.build/Voxella Studio.app"
    exit 0
fi

echo "Streaming OSLog (subsystem=com.voxella.studio). Ctrl-C to quit app and stop." >&2
echo >&2

cleanup() {
    pid=$(pgrep -f "Voxella Studio.app/Contents/MacOS/VoxellaStudio" | head -1 || true)
    if [ -n "$pid" ]; then
        osascript -e 'quit app "Voxella Studio"' 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

( sleep 0.5 && open "$ROOT/.build/Voxella Studio.app" ) &
log stream \
    --predicate 'subsystem == "com.voxella.studio"' \
    --level info \
    --style compact
