#!/bin/bash
# Build the Breeze-TTS C engine for macOS as a Universal (arm64 + x86_64) dylib.
#
# Usage:
#   scripts/build_mac.sh            # both architectures, output into Vendor/
#   scripts/build_mac.sh arm64      # single architecture (fast iteration)
#
# Requirements: cmake >= 3.19, ninja, Xcode command line tools.
# The upstream sources live in Breeze-TTS-2.Cpp/ with third_party/ggml and
# third_party/shine already populated (see docs/BUILD.md for the tarball route
# used when `git clone --recursive` is blocked).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$ROOT/Breeze-TTS-2.Cpp"
VENDOR="$ROOT/Vendor"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"

CMAKE_BIN="${CMAKE_BIN:-cmake}"
NINJA_BIN="${NINJA_BIN:-ninja}"

if [ ! -f "$REPO/CMakeLists.txt" ]; then
  echo "error: $REPO is missing the upstream sources" >&2
  exit 1
fi
if [ ! -f "$REPO/third_party/ggml/CMakeLists.txt" ]; then
  echo "error: third_party/ggml is empty. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  ARCHS=("$@")
else
  ARCHS=(arm64 x86_64)
fi

for arch in "${ARCHS[@]}"; do
  build="$BUILD_ROOT/$arch"
  echo "==> configuring $arch"
  "$CMAKE_BIN" -S "$REPO" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBREEZE_VULKAN=OFF \
    -DBREEZE_CUDA=OFF \
    -DBREEZE_BUILD_CLI=OFF \
    -DBREEZE_BUILD_SERVER=OFF \
    -DBREEZE_MP3=OFF \
    -DBREEZE_BUILD_TESTS=OFF \
    -DBREEZE_BUILD_SHARED=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_BLAS=OFF >/dev/null

  echo "==> building $arch"
  CMAKE_BUILD_PARALLEL_LEVEL="$(sysctl -n hw.ncpu)" "$CMAKE_BIN" --build "$build" --target breeze breeze_core -j "$(sysctl -n hw.ncpu)"
done

mkdir -p "$VENDOR/include/breeze" "$VENDOR"
cp "$REPO/include/breeze/breeze.h" "$VENDOR/include/breeze/"

if [ "${#ARCHS[@]}" -gt 1 ]; then
  echo "==> lipo"
  lipo -create "$BUILD_ROOT/arm64/libbreeze.dylib" "$BUILD_ROOT/x86_64/libbreeze.dylib" \
    -output "$VENDOR/libbreeze.dylib"
  lipo -create "$BUILD_ROOT/arm64/libbreeze_core.a" "$BUILD_ROOT/x86_64/libbreeze_core.a" \
    -output "$VENDOR/libbreeze_core.a"
else
  cp "$BUILD_ROOT/${ARCHS[0]}/libbreeze.dylib" "$VENDOR/libbreeze.dylib"
  cp "$BUILD_ROOT/${ARCHS[0]}/libbreeze_core.a" "$VENDOR/libbreeze_core.a"
fi

# The dylib is embedded in BreezeTTS.app/Contents/Frameworks, so its install name
# has to be relative to the executable.
install_name_tool -id "@rpath/libbreeze.dylib" "$VENDOR/libbreeze.dylib" 2>/dev/null || true

echo "==> done"
lipo -info "$VENDOR/libbreeze.dylib"
lipo -info "$VENDOR/libbreeze_core.a"
