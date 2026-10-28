#!/bin/bash
# Universal, sandboxed DMG. Developer ID releases are notarized before promotion.
# Use --unsigned for a local ad-hoc-signed test image (never a public release).
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
            echo 'Usage: Scripts/package-dmg.sh [--unsigned] [--skip-build]'
            echo 'Signed builds require MACOS_DEVELOPER_ID, ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID.'
            exit 0 ;;
        *) echo "Unknown argument: $VIBEZIP_ARG" >&2; exit 2 ;;
    esac
done
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    : "${MACOS_DEVELOPER_ID:?Set a Developer ID Application identity, or pass --unsigned}"
    : "${ASC_KEY_PATH:?Set the App Store Connect API private key path}"
    : "${ASC_KEY_ID:?Set the API key ID}" "${ASC_ISSUER_ID:?Set the issuer ID}"
    [ -f "$ASC_KEY_PATH" ] || { echo 'The notarization key file is missing.' >&2; exit 1; }
fi
if [ "$VIBEZIP_SKIP_BUILD" -eq 0 ]; then bash build.sh --universal; fi
VIBEZIP_APP="$VIBEZIP_ROOT/dist/VibeZip.app"
[ -d "$VIBEZIP_APP" ] || { echo 'Build dist/VibeZip.app first.' >&2; exit 1; }
# A release must contain both architectures even when reusing a build.
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    for VIBEZIP_BINARY in "$VIBEZIP_APP/Contents/MacOS/VibeZip" "$VIBEZIP_APP/Contents/Frameworks/libVibeZip7z.dylib"; do
        xcrun lipo "$VIBEZIP_BINARY" -verify_arch arm64
        xcrun lipo "$VIBEZIP_BINARY" -verify_arch x86_64
    done
fi
mkdir -p "$VIBEZIP_ROOT/.build" "$VIBEZIP_ROOT/dist"
VIBEZIP_STAGE="$(mktemp -d "$VIBEZIP_ROOT/.build/dmg.XXXXXX")"
trap 'rm -rf "$VIBEZIP_STAGE"' EXIT
mkdir "$VIBEZIP_STAGE/content"
ditto "$VIBEZIP_APP" "$VIBEZIP_STAGE/content/VibeZip.app"
VIBEZIP_STAGED_APP="$VIBEZIP_STAGE/content/VibeZip.app"
ln -s /Applications "$VIBEZIP_STAGE/content/Applications"
VIBEZIP_SIGN_FLAGS=(--force --sign - --timestamp=none)
VIBEZIP_NAME=VibeZip-macOS-unsigned.dmg
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    VIBEZIP_NAME=VibeZip-macOS.dmg
    VIBEZIP_SIGN_FLAGS=(--force --sign "$MACOS_DEVELOPER_ID" --timestamp --options runtime)
    if [ -n "${MACOS_SIGNING_KEYCHAIN:-}" ]; then VIBEZIP_SIGN_FLAGS+=(--keychain "$MACOS_SIGNING_KEYCHAIN"); fi
fi
codesign "${VIBEZIP_SIGN_FLAGS[@]}" "$VIBEZIP_STAGED_APP/Contents/Frameworks/libVibeZip7z.dylib"
codesign "${VIBEZIP_SIGN_FLAGS[@]}" --entitlements Resources/VibeZip.entitlements "$VIBEZIP_STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$VIBEZIP_STAGED_APP"
VIBEZIP_DMG="$VIBEZIP_STAGE/$VIBEZIP_NAME"
VIBEZIP_ATTEMPT=0
until hdiutil create -volname VibeZip -srcfolder "$VIBEZIP_STAGE/content" -fs HFS+ -format UDZO -ov "$VIBEZIP_DMG"; do
    VIBEZIP_ATTEMPT=$((VIBEZIP_ATTEMPT + 1))
    [ "$VIBEZIP_ATTEMPT" -lt 5 ] || exit 1
    sleep 3
done
hdiutil verify "$VIBEZIP_DMG"
if [ "$VIBEZIP_UNSIGNED" -eq 0 ]; then
    VIBEZIP_DMG_SIGN_FLAGS=(--force --sign "$MACOS_DEVELOPER_ID" --timestamp)
    if [ -n "${MACOS_SIGNING_KEYCHAIN:-}" ]; then VIBEZIP_DMG_SIGN_FLAGS+=(--keychain "$MACOS_SIGNING_KEYCHAIN"); fi
    codesign "${VIBEZIP_DMG_SIGN_FLAGS[@]}" "$VIBEZIP_DMG"
    VIBEZIP_NOTARY_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
    VIBEZIP_NOTARY_RESULT="$VIBEZIP_ROOT/dist/notarization.json"
    VIBEZIP_NOTARY_EXIT=0
    xcrun notarytool submit "$VIBEZIP_DMG" "${VIBEZIP_NOTARY_ARGS[@]}" --wait --output-format json > "$VIBEZIP_NOTARY_RESULT" || VIBEZIP_NOTARY_EXIT=$?
    VIBEZIP_NOTARY_STATUS="$(plutil -extract status raw -o - "$VIBEZIP_NOTARY_RESULT" 2>/dev/null || true)"
    if [ "$VIBEZIP_NOTARY_EXIT" -ne 0 ] || [ "$VIBEZIP_NOTARY_STATUS" != Accepted ]; then
        VIBEZIP_SUBMISSION="$(plutil -extract id raw -o - "$VIBEZIP_NOTARY_RESULT" 2>/dev/null || true)"
        if [ -n "$VIBEZIP_SUBMISSION" ]; then
            xcrun notarytool log "$VIBEZIP_SUBMISSION" "${VIBEZIP_NOTARY_ARGS[@]}" "$VIBEZIP_ROOT/dist/notarization-log.json" || true
        fi
        echo "Notarization failed: ${VIBEZIP_NOTARY_STATUS:-no response}. See dist/notarization*.json." >&2
        exit 1
    fi
    xcrun stapler staple "$VIBEZIP_DMG"
    xcrun stapler validate "$VIBEZIP_DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$VIBEZIP_DMG"
fi
mv "$VIBEZIP_DMG" "$VIBEZIP_ROOT/dist/$VIBEZIP_NAME"
(cd "$VIBEZIP_ROOT/dist" && shasum -a 256 "$VIBEZIP_NAME" > "$VIBEZIP_NAME.sha256")
printf '\nDMG: %s\n' "$VIBEZIP_ROOT/dist/$VIBEZIP_NAME"
if [ "$VIBEZIP_UNSIGNED" -eq 1 ]; then echo 'Local test build: ad-hoc signed, sandboxed, not notarized.'; fi
