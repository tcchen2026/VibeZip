#!/bin/bash
# Build a Mac App Store / TestFlight package. Upload remains a separate action.
set -euo pipefail
VIBEZIP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$VIBEZIP_ROOT"
VIBEZIP_UNSIGNED=0
VIBEZIP_SKIP_BUILD=0
for VIBEZIP_ARG in "$@"; do
    case "$VIBEZIP_ARG" in
        --unsigned) VIBEZIP_UNSIGNED=1 ;;
        --skip-build) VIBEZIP_SKIP_BUILD=1 ;;
        --help|-h)
            echo 'Usage: Scripts/package-mas.sh [--unsigned] [--skip-build]'
            echo 'Signed packages require VIBEZIP_MAS_PROFILE and VIBEZIP_MAS_BUILD_NUMBER.'
            echo 'Matching Apple Distribution and Mac Installer Distribution identities must be in the keychain.'
            echo 'Optional: VIBEZIP_MAS_KEYCHAIN, VIBEZIP_MAS_APP_IDENTITY, VIBEZIP_MAS_INSTALLER_IDENTITY.'
            echo '--unsigned creates a local packaging-check artifact, unsuitable for upload.'
            exit 0 ;;
        *) echo "Unknown argument: $VIBEZIP_ARG" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { echo 'Mac App Store packaging requires macOS.' >&2; exit 1; }
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    : "${VIBEZIP_MAS_PROFILE:?Set the path to a Mac App Store Connect provisioning profile}"
    : "${VIBEZIP_MAS_BUILD_NUMBER:?Set a build number greater than the last App Store Connect upload}"
    [ -f "$VIBEZIP_MAS_PROFILE" ] || { echo 'The provisioning profile is missing.' >&2; exit 1; }
fi
if [ "$VIBEZIP_SKIP_BUILD" -eq 0 ]; then bash build.sh --universal; fi
VIBEZIP_APP="$VIBEZIP_ROOT/dist/VibeZip.app"
[ -d "$VIBEZIP_APP" ] || { echo 'Build dist/VibeZip.app first.' >&2; exit 1; }
for VIBEZIP_BINARY in "$VIBEZIP_APP/Contents/MacOS/VibeZip" "$VIBEZIP_APP/Contents/Frameworks/libVibeZip7z.dylib"; do
    xcrun lipo "$VIBEZIP_BINARY" -verify_arch arm64
    xcrun lipo "$VIBEZIP_BINARY" -verify_arch x86_64
done
umask 077
mkdir -p "$VIBEZIP_ROOT/.build" "$VIBEZIP_ROOT/dist"
VIBEZIP_STAGE="$(mktemp -d "$VIBEZIP_ROOT/.build/mas.XXXXXX")"
cleanup() {
    VIBEZIP_EXIT_STATUS=$?
    trap - EXIT
    rm -rf "$VIBEZIP_STAGE"
    exit "$VIBEZIP_EXIT_STATUS"
}
trap cleanup EXIT
VIBEZIP_STAGED_APP="$VIBEZIP_STAGE/VibeZip.app"
ditto "$VIBEZIP_APP" "$VIBEZIP_STAGED_APP"
VIBEZIP_PREPARE_ARGS=(--app "$VIBEZIP_STAGED_APP" --output "$VIBEZIP_STAGE")
if [ "$VIBEZIP_UNSIGNED" -eq 1 ]; then VIBEZIP_PREPARE_ARGS+=(--unsigned); fi
xcrun python3 Scripts/prepare-mas.py "${VIBEZIP_PREPARE_ARGS[@]}"

VIBEZIP_NAME=VibeZip-MAS-unsigned.pkg
VIBEZIP_SIGN_FLAGS=(--force --sign - --timestamp=none)
VIBEZIP_PACKAGE_FLAGS=(--product "$VIBEZIP_STAGE/requirements.plist")
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    VIBEZIP_NAME=VibeZip-MAS.pkg
    VIBEZIP_APP_IDENTITY="$(cat "$VIBEZIP_STAGE/application-identity.txt")"
    VIBEZIP_INSTALLER_IDENTITY="$(cat "$VIBEZIP_STAGE/installer-identity.txt")"
    VIBEZIP_SIGN_FLAGS=(--force --sign "$VIBEZIP_APP_IDENTITY" --timestamp --options runtime)
    VIBEZIP_PACKAGE_FLAGS+=(--sign "$VIBEZIP_INSTALLER_IDENTITY" --timestamp)
    if [ -n "${VIBEZIP_MAS_KEYCHAIN:-}" ]; then
        VIBEZIP_SIGN_FLAGS+=(--keychain "$VIBEZIP_MAS_KEYCHAIN")
        VIBEZIP_PACKAGE_FLAGS+=(--keychain "$VIBEZIP_MAS_KEYCHAIN")
    fi
fi
# Sign inside out. The library has no process entitlements of its own.
codesign "${VIBEZIP_SIGN_FLAGS[@]}" "$VIBEZIP_STAGED_APP/Contents/Frameworks/libVibeZip7z.dylib"
codesign "${VIBEZIP_SIGN_FLAGS[@]}" --generate-entitlement-der \
    --entitlements "$VIBEZIP_STAGE/mas.entitlements" "$VIBEZIP_STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$VIBEZIP_STAGED_APP"
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    VIBEZIP_TEAM="$(cat "$VIBEZIP_STAGE/team-identifier.txt")"
    codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$VIBEZIP_TEAM\"" "$VIBEZIP_STAGED_APP"
fi
VIBEZIP_PACKAGE="$VIBEZIP_STAGE/$VIBEZIP_NAME"
# Apple's --component mode creates a single-app package without install scripts.
productbuild "${VIBEZIP_PACKAGE_FLAGS[@]}" --component "$VIBEZIP_STAGED_APP" /Applications "$VIBEZIP_PACKAGE"
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then pkgutil --check-signature "$VIBEZIP_PACKAGE"; fi
pkgutil --expand "$VIBEZIP_PACKAGE" "$VIBEZIP_STAGE/expanded"
(cd "$VIBEZIP_STAGE" && shasum -a 256 "$VIBEZIP_NAME" > "$VIBEZIP_NAME.sha256")
chmod 644 "$VIBEZIP_PACKAGE" "$VIBEZIP_PACKAGE.sha256"
mv "$VIBEZIP_PACKAGE" "$VIBEZIP_ROOT/dist/$VIBEZIP_NAME"
mv "$VIBEZIP_PACKAGE.sha256" "$VIBEZIP_ROOT/dist/$VIBEZIP_NAME.sha256"
printf '\nPackage: %s\n' "$VIBEZIP_ROOT/dist/$VIBEZIP_NAME"
if [ "$VIBEZIP_UNSIGNED" -eq 1 ]; then
    echo 'Unsigned packaging check only. App Store Connect and Transporter require the signed package.'
else
    echo 'Signed for App Store Connect. Upload validation and App Review have not been run.'
fi
