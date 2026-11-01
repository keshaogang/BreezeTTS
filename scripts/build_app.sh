#!/bin/bash
# One shot: engine -> xcodeproj -> .app in dist/
#
#   scripts/build_app.sh            # Universal (arm64 + x86_64)
#   scripts/build_app.sh arm64      # current machine only (fast)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PYTHON_BIN="${PYTHON_BIN:-python3}"

if [ "$#" -gt 0 ]; then
  ./scripts/build_mac.sh "$@"
else
  ./scripts/build_mac.sh
fi

"$PYTHON_BIN" scripts/gen_project.py

DEST="generic/platform=macOS"
if [ "$#" -gt 0 ]; then
  DEST="platform=macOS,arch=$1"
fi

xcodebuild -project BreezeTTS.xcodeproj \
  -scheme BreezeTTS \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath build/xc \
  build

APP="build/xc/Build/Products/Release/BreezeTTS.app"
mkdir -p dist
rm -rf "dist/BreezeTTS.app"
cp -R "$APP" "dist/BreezeTTS.app"

echo
echo "==> dist/BreezeTTS.app"
lipo -info "dist/BreezeTTS.app/Contents/MacOS/BreezeTTS"
lipo -info "dist/BreezeTTS.app/Contents/Frameworks/libbreeze.dylib"
codesign -dv "dist/BreezeTTS.app" 2>&1 | grep -E "Identifier|Signature" || true
