#!/bin/bash
# Match VibeOffice's UTC commit date and six-character hash version format.
# --metadata also prints the numeric bundle version and build number.
set -euo pipefail
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --metadata ]; }; then
    echo 'Usage: current-tree-version.sh [--metadata]' >&2
    exit 2
fi
VIBEZIP_SOURCE="$(cd "$(dirname "$0")/../.." && pwd -P)"
VIBEZIP_GIT_ROOT="$(git -C "$VIBEZIP_SOURCE" rev-parse --show-toplevel 2>/dev/null || true)"
VIBEZIP_EXTRA=''
if [ "$VIBEZIP_GIT_ROOT" = "$VIBEZIP_SOURCE" ]; then
    VIBEZIP_COMMIT="$(git -C "$VIBEZIP_SOURCE" rev-parse --verify 'HEAD^{commit}')"
    VIBEZIP_DAY="$(TZ=UTC git -C "$VIBEZIP_SOURCE" show -s --format=%cd --date=format-local:%Y.%m.%d "$VIBEZIP_COMMIT")"
    VIBEZIP_VERSION="v$VIBEZIP_DAY-${VIBEZIP_COMMIT:0:6}"
    VIBEZIP_SHORT_VERSION="$(printf '%s\n' "$VIBEZIP_DAY" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 }')"
    VIBEZIP_BUILD_VERSION="$(TZ=UTC git -C "$VIBEZIP_SOURCE" show -s --format=%cd --date=format-local:'%Y %m%d %H%M' "$VIBEZIP_COMMIT" |
        awk '{ printf "%d.%d.%d", $1, $2, $3 }')"
elif [ -f "$VIBEZIP_SOURCE/.vibezip-version" ]; then
    # Corresponding-source archives carry the original build's version without Git.
    read -r VIBEZIP_VERSION VIBEZIP_SHORT_VERSION VIBEZIP_BUILD_VERSION VIBEZIP_EXTRA < "$VIBEZIP_SOURCE/.vibezip-version"
else
    echo 'Version unavailable: build from a Git checkout or the bundled corresponding-source archive.' >&2
    exit 1
fi
if [[ ! "$VIBEZIP_VERSION" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{6}$ ]] ||
   [[ ! "$VIBEZIP_SHORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   [[ ! "$VIBEZIP_BUILD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ -n "$VIBEZIP_EXTRA" ]; then
    echo 'Invalid VibeZip version metadata.' >&2
    exit 1
fi
if [ "${1:-}" = --metadata ]; then
    printf '%s %s %s\n' "$VIBEZIP_VERSION" "$VIBEZIP_SHORT_VERSION" "$VIBEZIP_BUILD_VERSION"
else
    printf '%s\n' "$VIBEZIP_VERSION"
fi
