#!/bin/bash
# Rebuild from a checkout or the corresponding source archive bundled with the app.
set -euo pipefail
VIBEZIP_HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$VIBEZIP_HERE/7zip-source.tar.gz" ]; then
    VIBEZIP_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/VibeZip-source.XXXXXX")"
    tar -xzf "$VIBEZIP_HERE/7zip-source.tar.gz" -C "$VIBEZIP_SOURCE"
else
    VIBEZIP_SOURCE="$(cd "$VIBEZIP_HERE/../.." && pwd)"
fi
bash "$VIBEZIP_SOURCE/macOS/Scripts/build-native.sh"
printf '\nSource directory: %s\n' "$VIBEZIP_SOURCE"
