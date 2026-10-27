#!/bin/bash
# Compile this fork's editable engine sources as an in-process shared library.
set -euo pipefail
VIBEZIP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIBEZIP_SOURCE="$(cd "$VIBEZIP_ROOT/.." && pwd)"
VIBEZIP_ARCH="${1:-$(uname -m)}"
VIBEZIP_BUNDLE="$VIBEZIP_SOURCE/CPP/7zip/Bundles/Format7zF"
VIBEZIP_DEST="$VIBEZIP_ROOT/.build/native/$VIBEZIP_ARCH"
mkdir -p "$VIBEZIP_DEST"
# Upstream makefiles do not track all header dependencies.
VIBEZIP_HEADERS="$(find "$VIBEZIP_SOURCE/C" "$VIBEZIP_SOURCE/CPP" "$VIBEZIP_SOURCE/Asm" -type f \( -name '*.h' -o -name '*.mak' \) -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
VIBEZIP_MAKE_FLAGS=(-j 8)
if [ ! -f "$VIBEZIP_DEST/headers.sha256" ] || [ "$(cat "$VIBEZIP_DEST/headers.sha256")" != "$VIBEZIP_HEADERS" ]; then
    VIBEZIP_MAKE_FLAGS+=(-B)
fi
if [ "$(uname -s)" = Darwin ]; then
    case "$VIBEZIP_ARCH" in arm64) VIBEZIP_MAKE_ARCH=arm64;; x86_64) VIBEZIP_MAKE_ARCH=x64;; *) exit 2;; esac
    export MACOSX_DEPLOYMENT_TARGET=26.0
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    make -C "$VIBEZIP_BUNDLE" "${VIBEZIP_MAKE_FLAGS[@]}" -f "../../cmpl_mac_$VIBEZIP_MAKE_ARCH.mak"
    cp "$VIBEZIP_BUNDLE/b/m_$VIBEZIP_MAKE_ARCH/7z.so" "$VIBEZIP_DEST/libVibeZip7z.dylib"
    install_name_tool -id '@rpath/libVibeZip7z.dylib' "$VIBEZIP_DEST/libVibeZip7z.dylib"
    codesign --force --sign - --timestamp=none "$VIBEZIP_DEST/libVibeZip7z.dylib"
else
    VIBEZIP_MAKE_FLAGS[1]=4
    make -C "$VIBEZIP_BUNDLE" "${VIBEZIP_MAKE_FLAGS[@]}" -f ../../cmpl_gcc.mak
    cp "$VIBEZIP_BUNDLE/b/g/7z.so" "$VIBEZIP_DEST/libVibeZip7z.so"
fi
printf '%s\n' "$VIBEZIP_HEADERS" > "$VIBEZIP_DEST/headers.sha256"
printf '\nNative archive library: %s\n' "$VIBEZIP_DEST"
