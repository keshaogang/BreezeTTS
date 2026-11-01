#!/bin/bash
# deploy.sh — build (optional) → refresh dist → install to /Applications → relaunch.
# /Applications/BreezeTTS.app is the ONE canonical location: the iPhone-wake
# helper only ever opens that path, so every build must land there.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Optional rebuild: ./scripts/deploy.sh build
if [ "${1:-}" = "build" ]; then
    export PATH="$HOME/.workbuddy/binaries/python/envs/default/bin:$PATH"
    xcodebuild -project BreezeTTS.xcodeproj -scheme BreezeTTS -configuration Release \
        -destination "platform=macOS,arch=arm64" -derivedDataPath build/xc build \
        2>&1 | grep -E "error:|BUILD " | head -8 || true
fi

[ -d build/xc/Build/Products/Release/BreezeTTS.app ] || { echo "no build product"; exit 1; }

# 1. refresh dist (dev copy)
rm -rf dist/BreezeTTS.app.new
cp -R build/xc/Build/Products/Release/BreezeTTS.app dist/BreezeTTS.app.new

# 2. quit running instance, swap dist, install to /Applications
pkill -x BreezeTTS 2>/dev/null || true
sleep 1
rm -rf dist/BreezeTTS.app
mv dist/BreezeTTS.app.new dist/BreezeTTS.app
rm -rf /Applications/BreezeTTS.app
cp -R dist/BreezeTTS.app /Applications/BreezeTTS.app

# 3. relaunch from /Applications
open /Applications/BreezeTTS.app 2>/dev/null || { sleep 2; open /Applications/BreezeTTS.app; }
sleep 4
pgrep -lx BreezeTTS >/dev/null && echo "✅ deployed to /Applications and running" \
    || { echo "⚠️ not running yet (model loading), retry: open /Applications/BreezeTTS.app"; exit 0; }
