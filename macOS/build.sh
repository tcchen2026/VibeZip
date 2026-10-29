#!/bin/bash
# Offline native-library and AppKit build; all build caches stay in the workspace.
set -euo pipefail
VIBEZIP_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$VIBEZIP_ROOT"
VIBEZIP_SOURCE="$(cd "$VIBEZIP_ROOT/.." && pwd)"
VIBEZIP_CONFIG=release
VIBEZIP_UNIVERSAL=0
VIBEZIP_TEST=0
VIBEZIP_INSTALL=0
VIBEZIP_OPEN=0
VIBEZIP_LIBRARY_ONLY=0
for argument in "$@"; do
    case "$argument" in
        --universal) VIBEZIP_UNIVERSAL=1 ;;
        --debug) VIBEZIP_CONFIG=debug ;;
        --test) VIBEZIP_TEST=1 ;;
        --install) VIBEZIP_INSTALL=1 ;;
        --open) VIBEZIP_OPEN=1 ;;
        --library-only|--engine-only) VIBEZIP_LIBRARY_ONLY=1 ;;
        --help|-h)
            printf '%s\n' 'Usage: ./build.sh [--universal] [--debug] [--test] [--install] [--open] [--library-only]'
            exit 0 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { echo 'Use Scripts/test-core.sh for Linux core tests.' >&2; exit 1; }
if [ "$VIBEZIP_LIBRARY_ONLY" -eq 0 ]; then
    VIBEZIP_VERSION_METADATA="$(bash "$VIBEZIP_ROOT/Scripts/current-tree-version.sh" --metadata)"
    read -r VIBEZIP_VERSION VIBEZIP_SHORT_VERSION VIBEZIP_BUILD_VERSION <<< "$VIBEZIP_VERSION_METADATA"
fi
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CLANG_MODULE_CACHE_PATH="$VIBEZIP_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$VIBEZIP_ROOT/.build/swift-module-cache"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
VIBEZIP_NATIVE="$(uname -m)"
VIBEZIP_ARCHES=("$VIBEZIP_NATIVE")
if [ "$VIBEZIP_UNIVERSAL" -eq 1 ]; then VIBEZIP_ARCHES=(arm64 x86_64); fi
VIBEZIP_SWIFT_FLAGS=(--disable-sandbox --build-system native -debug-info-format none
    --package-path "$VIBEZIP_ROOT" --scratch-path "$VIBEZIP_ROOT/.build/swift-sandbox"
    --cache-path "$VIBEZIP_ROOT/.build/swiftpm-cache" --config-path "$VIBEZIP_ROOT/.build/swiftpm-config"
    --security-path "$VIBEZIP_ROOT/.build/swiftpm-security" --configuration "$VIBEZIP_CONFIG")
VIBEZIP_LIBRARIES=()
VIBEZIP_EXECUTABLES=()
for VIBEZIP_ARCH in "${VIBEZIP_ARCHES[@]}"; do
    bash "$VIBEZIP_ROOT/Scripts/build-native.sh" "$VIBEZIP_ARCH"
    VIBEZIP_LIBRARIES+=("$VIBEZIP_ROOT/.build/native/$VIBEZIP_ARCH/libVibeZip7z.dylib")
    if [ "$VIBEZIP_LIBRARY_ONLY" -eq 0 ]; then
        xcrun swift build "${VIBEZIP_SWIFT_FLAGS[@]}" --arch "$VIBEZIP_ARCH" --product VibeZip
        VIBEZIP_BIN="$(xcrun swift build "${VIBEZIP_SWIFT_FLAGS[@]}" --arch "$VIBEZIP_ARCH" --show-bin-path)"
        VIBEZIP_EXECUTABLES+=("$VIBEZIP_BIN/VibeZip")
    fi
done
if [ "$VIBEZIP_LIBRARY_ONLY" -eq 1 ]; then exit 0; fi
if [ "$VIBEZIP_TEST" -eq 1 ]; then
    export VIBEZIP_LIBRARY="$VIBEZIP_ROOT/.build/native/$VIBEZIP_NATIVE/libVibeZip7z.dylib"
    xcrun swift test "${VIBEZIP_SWIFT_FLAGS[@]}" --arch "$VIBEZIP_NATIVE"
fi
VIBEZIP_STAGING="$(mktemp -d "$VIBEZIP_ROOT/.build/app-staging.XXXXXX")"
VIBEZIP_APP="$VIBEZIP_STAGING/VibeZip.app"
# On failure keep the staging directory available for diagnosis.
mkdir -p "$VIBEZIP_APP/Contents/MacOS" "$VIBEZIP_APP/Contents/Frameworks" \
    "$VIBEZIP_APP/Contents/Resources/Source" "$VIBEZIP_APP/Contents/Resources/Licenses"
if [ "$VIBEZIP_UNIVERSAL" -eq 1 ]; then
    xcrun lipo -create "${VIBEZIP_EXECUTABLES[@]}" -output "$VIBEZIP_APP/Contents/MacOS/VibeZip"
    xcrun lipo -create "${VIBEZIP_LIBRARIES[@]}" -output "$VIBEZIP_APP/Contents/Frameworks/libVibeZip7z.dylib"
else
    cp "${VIBEZIP_EXECUTABLES[0]}" "$VIBEZIP_APP/Contents/MacOS/VibeZip"
    cp "${VIBEZIP_LIBRARIES[0]}" "$VIBEZIP_APP/Contents/Frameworks/libVibeZip7z.dylib"
fi
cp "$VIBEZIP_ROOT/Resources/Info.plist" "$VIBEZIP_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VIBEZIP_SHORT_VERSION" \
    -c "Set :CFBundleVersion $VIBEZIP_BUILD_VERSION" \
    -c "Set :VibeZipVersion $VIBEZIP_VERSION" "$VIBEZIP_APP/Contents/Info.plist"
# Record the tools that actually built the app, including for App Store uploads.
VIBEZIP_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
VIBEZIP_SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
VIBEZIP_XCODE_INFO="$(xcodebuild -version)"
VIBEZIP_XCODE_BUILD="$(printf '%s\n' "$VIBEZIP_XCODE_INFO" | awk '/^Build version / { print $3 }')"
VIBEZIP_XCODE_NUMBER="$(printf '%s\n' "$VIBEZIP_XCODE_INFO" | awk '/^Xcode / { split($2, v, "."); printf "%02d%d%d", v[1], v[2], v[3] }')"
/usr/libexec/PlistBuddy \
    -c "Add :DTPlatformName string macosx" \
    -c "Add :DTPlatformVersion string $VIBEZIP_SDK_VERSION" \
    -c "Add :DTPlatformBuild string $VIBEZIP_SDK_BUILD" \
    -c "Add :DTSDKName string macosx$VIBEZIP_SDK_VERSION" \
    -c "Add :DTSDKBuild string $VIBEZIP_SDK_BUILD" \
    -c "Add :DTXcode string $VIBEZIP_XCODE_NUMBER" \
    -c "Add :DTXcodeBuild string $VIBEZIP_XCODE_BUILD" \
    -c "Add :BuildMachineOSBuild string $(sw_vers -buildVersion)" "$VIBEZIP_APP/Contents/Info.plist"
cp "$VIBEZIP_ROOT/Resources/PrivacyInfo.xcprivacy" "$VIBEZIP_ROOT/Resources/Privacy.txt" "$VIBEZIP_APP/Contents/Resources/"
cp "$VIBEZIP_ROOT/README.md" "$VIBEZIP_ROOT/Resources/GitHub.svg" "$VIBEZIP_APP/Contents/Resources/"
cp -R "$VIBEZIP_BIN/VibeZip_VibeZipCore.bundle" "$VIBEZIP_APP/Contents/Resources/"
# SwiftPM's resource-only bundle has no identifier/version metadata of its own.
VIBEZIP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$VIBEZIP_APP/Contents/Info.plist")"
VIBEZIP_RESOURCE_INFO="$VIBEZIP_APP/Contents/Resources/VibeZip_VibeZipCore.bundle/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string $VIBEZIP_BUNDLE_ID.resources" \
    -c 'Add :CFBundleName string VibeZipCoreResources' \
    -c 'Add :CFBundleInfoDictionaryVersion string 6.0' \
    -c 'Add :CFBundlePackageType string BNDL' \
    -c "Add :CFBundleShortVersionString string $VIBEZIP_SHORT_VERSION" \
    -c "Add :CFBundleVersion string $VIBEZIP_BUILD_VERSION" "$VIBEZIP_RESOURCE_INFO"
cp "$VIBEZIP_ROOT/LICENSE" "$VIBEZIP_APP/Contents/Resources/Licenses/VibeZip-LGPL.txt"
cp "$VIBEZIP_ROOT/Resources/Licenses/"*.txt "$VIBEZIP_APP/Contents/Resources/Licenses/"
cp "$VIBEZIP_ROOT/Resources/THIRD_PARTY_NOTICES.txt" "$VIBEZIP_APP/Contents/Resources/Licenses/"
cp "$VIBEZIP_SOURCE/DOC/License.txt" "$VIBEZIP_APP/Contents/Resources/Licenses/7-Zip-License.txt"
cp "$VIBEZIP_SOURCE/DOC/copying.txt" "$VIBEZIP_APP/Contents/Resources/Licenses/LGPL-2.1.txt"
cp "$VIBEZIP_SOURCE/DOC/unRarLicense.txt" "$VIBEZIP_APP/Contents/Resources/Licenses/"
cp "$VIBEZIP_ROOT/Scripts/rebuild-engine.sh" "$VIBEZIP_APP/Contents/Resources/Source/"
printf '%s\n' "$VIBEZIP_VERSION_METADATA" > "$VIBEZIP_STAGING/.vibezip-version"
COPYFILE_DISABLE=1 tar --exclude='*/.build' --exclude='*/.swiftpm' --exclude='*/dist' \
    --exclude='*/b' --exclude='*/.DS_Store' --exclude='*/._*' --exclude='*/.env*' \
    --exclude='*/.codex' --exclude='*/.agents' --exclude='*/xcuserdata' \
    --exclude='*.p12' --exclude='*.pfx' --exclude='*.p8' --exclude='*.pem' \
    --exclude='*.provisionprofile' --exclude='*.mobileprovision' --exclude='*.keychain*' \
    -czf "$VIBEZIP_APP/Contents/Resources/Source/7zip-source.tar.gz" \
    -C "$VIBEZIP_SOURCE" Asm C CPP DOC macOS design_docs README.md AGENTS.md .gitignore .gitattributes \
    -C "$VIBEZIP_STAGING" .vibezip-version
mkdir -p "$VIBEZIP_STAGING/AppIcon.iconset"
xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$VIBEZIP_ROOT/Scripts/MakeIcon.swift" "$VIBEZIP_STAGING/AppIcon.iconset"
cp "$VIBEZIP_STAGING/AppIcon.icns" "$VIBEZIP_APP/Contents/Resources/AppIcon.icns"
chmod 755 "$VIBEZIP_APP/Contents/MacOS/VibeZip" "$VIBEZIP_APP/Contents/Frameworks/libVibeZip7z.dylib"
plutil -lint "$VIBEZIP_APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$VIBEZIP_APP/Contents/Frameworks/libVibeZip7z.dylib"
codesign --force --sign - --timestamp=none --entitlements "$VIBEZIP_ROOT/Resources/VibeZip.entitlements" "$VIBEZIP_APP"
codesign --verify --deep --strict --verbose=2 "$VIBEZIP_APP"
mkdir -p "$VIBEZIP_ROOT/dist"
if [ -e "$VIBEZIP_ROOT/dist/VibeZip.app" ]; then
    mv "$VIBEZIP_ROOT/dist/VibeZip.app" "$VIBEZIP_STAGING/VibeZip.previous.app"
fi
mv "$VIBEZIP_APP" "$VIBEZIP_ROOT/dist/VibeZip.app"
VIBEZIP_APP="$VIBEZIP_ROOT/dist/VibeZip.app"
if [ "$VIBEZIP_INSTALL" -eq 1 ]; then
    mkdir -p "$HOME/Applications"
    if [ -e "$HOME/Applications/VibeZip.app" ]; then
        mv "$HOME/Applications/VibeZip.app" "$HOME/Applications/VibeZip.previous-$(date +%Y%m%d-%H%M%S)-$$.app"
    fi
    ditto "$VIBEZIP_APP" "$HOME/Applications/VibeZip.app"
    VIBEZIP_APP="$HOME/Applications/VibeZip.app"
fi
printf '\nBuilt: %s (%s)\n' "$VIBEZIP_APP" "$VIBEZIP_VERSION"
printf '%s\n' 'Includes the native 7-Zip library and corresponding source. No 7zz process or Homebrew dependency.'
if [ "$VIBEZIP_OPEN" -eq 1 ]; then open "$VIBEZIP_APP"; fi
