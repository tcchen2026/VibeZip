# VibeZip for macOS

VibeZip is a native archive manager with an AppKit and SwiftUI interface in
English, Simplified Chinese, Japanese and Korean.
It loads this repository's 7-Zip shared library directly, without a command-line
helper process.

## Build

Requires macOS 26 or later, Xcode 26 or later with Swift 6.2 or later.
From this directory:

```sh
bash build.sh
open dist/VibeZip.app
```

`--universal` builds arm64 and x86_64. `--debug` selects a debug Swift build.
`--library-only` builds the engine. `--test` runs the core test suite.
Local app bundles use ad-hoc signing and enable App Sandbox with incoming and
outgoing network access disabled. Store distribution
requires the publisher's signing and App Store configuration.

For a local test DMG, run `bash Scripts/package-dmg.sh --unsigned`. This builds
both architectures and writes `dist/VibeZip-macOS-unsigned.dmg` plus a checksum.
The GitHub **macOS DMG** workflow runs manually through **Actions → Run workflow**;
it never runs on push. With release credentials it signs and notarizes the DMG.
See [DMG distribution](../design_docs/distribution.md) for secrets and release options.

## Use

Choose a folder on first launch. Saved security-scoped bookmarks allow the app to
restore the last authorized directory. Manage access in Settings → Folder Access.

The app follows your macOS language preferences, with English as the fallback.
To choose a language specifically for VibeZip, use System Settings → General →
Language & Region, then reopen the app. Help and Privacy are translated too;
native engine diagnostics and license notices may remain in their original language.

The Sevenfold-inspired layout has a sidebar of authorized folders, open archives
and recent folders, and an optional Info inspector. Use View to toggle the sidebar
or Info. Favorites contains your real saved folder grants.
Toggle **2 Panels** in the toolbar for two independent browsers.
Tab changes the active pane; commands, filter and Info follow it. In two-pane
mode, Copy/Move suggests the other pane's filesystem folder.

The toolbar's view switcher selects Icons, List or Details while retaining the
same selection. Command-1, Command-2 and Command-3 select these views directly.

Double-click enters a folder or opens a file as an archive. Back and Forward
are at the left of the toolbar; Up and history are beside the rounded path bar.
Click an ancestor breadcrumb to go directly to that folder or archive. Click the
current location or empty space, or press Command-L, to edit the address.
The toolbar filter covers the active folder, or all entries in the active
archive. It does not enter nested archives.

Open nested archives directly. Supported changes are verified and written back
through their parents; multivolume archives are read only. Preview is local and
supports text, hex, images and PDF. Long operations report progress and can be
cancelled. Archive tests display their result in a dialog.

ZIP names with valid Unicode metadata retain it. Other names are checked for
UTF-8 and automatically detected legacy code pages, including GBK, Big5 and
Shift-JIS, with CP437 as the fallback. Detection is heuristic when a ZIP lacks
encoding metadata. Browsing, previews, extraction and archive updates share the
same decoded names. Opening an archive does not rewrite it.

The About window shows the app icon, name, version, a GitHub button and a short
LGPL 2.1-or-later license footer. The GitHub destination is configured by
`VibeZipRepositoryURL` in `Resources/Info.plist`.

Settings → General includes **Show Temporary Folder** and **Clean Temporary Files**.
A compact MB/GB total shows temporary file sizes, including files still in use,
and refreshes when Settings opens and after cleanup.
VibeZip keeps disposable copies in its own folder under the macOS app temporary
directory. Cleanup removes unused copies while preserving files held by open
archives and running operations. Archive backups and staging beside user files
are outside this cleanup.

**Set VibeZip as Default** in Settings → General starts with `.zip/.7z/.rar`
selected; clicking the button applies all three. Individual formats remain in the
combo box. macOS may request confirmation for each type, and declining stops the
remaining requests while keeping earlier confirmed changes. For a manual change, use Finder's
Get Info → Open with → VibeZip → Change All for a file of that format.
The address bar shortens paths under your home to `~`, such as `~/Downloads`.

## Development

Read the [design documents](../design_docs/README.md) for the architecture,
interaction rules, sandbox model and current limitations.

Edit engine code in `../C`, `../CPP` and `../Asm`. `Scripts/build-native.sh` builds
those sources directly. Swift targets are described in `Package.swift`.

```sh
bash Scripts/test-core.sh
bash Scripts/test-core.sh --filter ZIPFilenameEncodingTests
```

Tests use generated fixtures in temporary directories. The app bundles its
corresponding source, licenses and `rebuild-engine.sh` in
`Contents/Resources/Source` for rebuilding the engine.

## License

The macOS additions are distributed under LGPL-2.1-or-later. See `LICENSE`,
`../DOC/License.txt` and `Resources/THIRD_PARTY_NOTICES.txt`. Preserve retained
MIT notices and all upstream per-file terms.
