# Development and release

The repository preserves the upstream 7-Zip source layout. The macOS application
is in `macOS/`; it builds the engine directly from the sibling `C/`, `CPP/` and
`Asm/` directories. Keep engine changes small, retain existing notices and
document interface changes at the Swift/C++ boundary.

## Build entry points

On macOS 26 or later with Xcode 26 and Swift 6.2 or later:

```sh
cd macOS
bash build.sh
open dist/VibeZip.app
```

| Command, from `macOS/` | Purpose |
| --- | --- |
| `bash build.sh` | Build the host architecture and package a sandboxed app |
| `bash build.sh --universal` | Build arm64 and x86_64 and combine the binaries |
| `bash build.sh --debug` | Use a debug Swift configuration |
| `bash build.sh --library-only` | Build just the native engine |
| `bash Scripts/package-dmg.sh --unsigned` | Build and package a universal local DMG |
| `bash Scripts/package-dmg.sh` | Build, sign and notarize a universal release DMG using configured credentials |
| `bash Scripts/test-core.sh` | Build the engine and run core/native tests |
| `bash Scripts/test-core.sh --filter ZIPFilenameEncodingTests` | Run a focused test suite |

[build-native.sh](../macOS/Scripts/build-native.sh) compiles
`CPP/7zip/Bundles/Format7zF` and copies the library into `macOS/.build/native/`.
It fingerprints upstream headers and makefiles to force a rebuild when needed,
because the upstream makefiles do not track every header dependency.
[Package.swift](../macOS/Package.swift) defines the C++ bridge, core library and
AppKit/SwiftUI executable targets.

Build scripts keep Swift caches under `macOS/.build/` and use SwiftPM's
`--disable-sandbox` flag. That flag concerns SwiftPM's build-time sandbox; it does
not disable the resulting application's App Sandbox. Runtime entitlements are
applied separately when the app is signed. Whether a development environment
allows a build to run is also separate from the app's file-access model.

The core test script has a Linux route. AppKit, security-scoped bookmark behavior
and Foundation's filename detector are macOS-specific, so Linux tests do not
validate those features.

## Verification proportional to the change

| Area | Relevant coverage |
| --- | --- |
| Paths, indexed listings, search, copy, split/combine and options | [CoreTests.swift](../macOS/Tests/VibeZipCoreTests/CoreTests.swift) |
| Real engine reads/writes, passwords, nested transactions, corruption and limits | [EngineIntegrationTests.swift](../macOS/Tests/VibeZipCoreTests/EngineIntegrationTests.swift) |
| Saved access, moved/offline roots, overlapping grants and restoration | [DirectoryAccessStoreTests.swift](../macOS/Tests/VibeZipCoreTests/DirectoryAccessStoreTests.swift) |
| Legacy filename bytes and consistent downstream behavior | [ZIPFilenameEncodingTests.swift](../macOS/Tests/VibeZipCoreTests/ZIPFilenameEncodingTests.swift) |

Use targeted tests for changed core behavior and integration tests for engine or
transaction changes. Fixtures should be generated in temporary directories.
Bookmark unit tests use an injected provider; they do not replace checking actual
system file panels in a signed sandboxed app when the access flow changes.

Review layout and interaction visually. Routine UI spacing changes do not need
new screenshot or exhaustive UI automation tests. Documentation changes need
link and consistency checks, not a repeated full application test run. Build or
packaging changes should check the affected scripts and produced resources.

## Packaging and licensing material

The [macOS DMG workflow](../.github/workflows/macos.yml) runs only when manually
dispatched. It builds and packages without running tests or UI automation. See
[DMG distribution](distribution.md) for the release environment, signing secrets
and optional publication. App Sandbox stays enabled for direct distribution.

[build.sh](../macOS/build.sh) creates the app in a staging directory and signs the
engine and app with an ad-hoc identity for local use. It packages the engine,
resources, privacy declaration, license notices, a corresponding-source archive
and [rebuild-engine.sh](../macOS/Scripts/rebuild-engine.sh). The source archive
includes the design documents and excludes generated builds and local metadata.

Retain the upstream terms in [DOC/License.txt](../DOC/License.txt),
[DOC/copying.txt](../DOC/copying.txt) and per-file notices. The macOS additions use
the terms in [macOS/LICENSE](../macOS/LICENSE); retained MIT notices are in
[Resources/Licenses/](../macOS/Resources/Licenses/). The engine contains components
with additional terms, including the unRAR restriction. Keep
[THIRD_PARTY_NOTICES.txt](../macOS/Resources/THIRD_PARTY_NOTICES.txt) and the bundled
source aligned with the actual shipped code. The About badge is not the license
documentation surface.

## Open release work

Direct DMG distribution is implemented by `Scripts/package-dmg.sh`; publishing
requires the configured Developer ID and notarization credentials. The regular
app build remains ad-hoc signed. Mac App Store provisioning, store metadata and
submission are separate future work; the DMG workflow does not upload to the store.

Before a release, validate the exact distributed build's folder authorization,
restore and revoke flows, access to multivolume siblings, destination writes and
temporary-file cleanup. Recheck that its privacy declarations, entitlements,
source package and notices match that build. These are release tasks; successful
core tests or a local sandboxed launch do not constitute store approval.

Current implementation limits are maintained alongside the relevant design:
[metadata scaling and process isolation](architecture.md),
[commit and extraction guarantees](archive-operations.md),
[preview and temporary data](sandbox-and-security.md), and
[ambiguous ZIP encodings](zip-filenames.md). They are not promises of additional
features or a release schedule.
