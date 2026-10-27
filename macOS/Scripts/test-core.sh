#!/bin/bash
set -euo pipefail
VIBEZIP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$VIBEZIP_ROOT"
if [ "$(uname -s)" = Darwin ] && [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
bash "$VIBEZIP_ROOT/Scripts/build-native.sh"
export CLANG_MODULE_CACHE_PATH="$VIBEZIP_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$VIBEZIP_ROOT/.build/swift-module-cache"
VIBEZIP_FLAGS=(--disable-sandbox --package-path "$VIBEZIP_ROOT" --scratch-path "$VIBEZIP_ROOT/.build/swift-sandbox"
    --cache-path "$VIBEZIP_ROOT/.build/swiftpm-cache" --config-path "$VIBEZIP_ROOT/.build/swiftpm-config"
    --security-path "$VIBEZIP_ROOT/.build/swiftpm-security" --configuration release)
if [ "$(uname -s)" = Darwin ]; then
    export VIBEZIP_LIBRARY="$VIBEZIP_ROOT/.build/native/$(uname -m)/libVibeZip7z.dylib"
    xcrun swift test "${VIBEZIP_FLAGS[@]}" --build-system native -debug-info-format none --arch "$(uname -m)" "$@"
else
    export VIBEZIP_LIBRARY="$VIBEZIP_ROOT/.build/native/$(uname -m)/libVibeZip7z.so"
    swift test "${VIBEZIP_FLAGS[@]}" "$@"
fi
