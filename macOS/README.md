# VibeZip for macOS

VibeZip is a native archive manager with an English AppKit and SwiftUI interface.
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
Local app bundles use ad-hoc signing and enable App Sandbox. Store distribution
requires the publisher's signing and App Store configuration.

For a local test DMG, run `bash Scripts/package-dmg.sh --unsigned`. This builds
both architectures and writes `dist/VibeZip-macOS-unsigned.dmg` plus a checksum.
The GitHub **macOS DMG** workflow runs manually through **Actions → Run workflow**;
it never runs on push. With release credentials it signs and notarizes the DMG.
See [DMG distribution](../design_docs/distribution.md) for secrets and release options.

## Use

Choose a folder on first launch. Saved security-scoped bookmarks allow the app to
restore the last authorized directory. Manage access in Settings → Folder Access.

The Sevenfold-inspired layout has a sidebar of authorized folders, open archives
and recent folders, a shortcut strip, and an optional Info inspector. Use View
to toggle the sidebar or key tips, Command-I for Info, and Help → Shortcut Map
for keyboard shortcuts. Favorites contains your real saved folder grants.
Toggle **2 Panels** in the toolbar or press F9 for two independent browsers.
Tab changes the active pane; commands, filter and Info follow it. In two-pane
mode, Copy/Move suggests the other pane's filesystem folder. The sidebar offers
7-Zip and Mac keyboard modes.

The toolbar's view switcher selects Icons, List or Details while retaining the
same selection. Command-1, Command-2 and Command-3 select these views directly.

Double-click enters a folder or opens a file as an archive. Back and Forward
are at the left of the toolbar; Up and history are beside the rounded path bar.
Click the breadcrumb address or press Command-L
to edit it. The toolbar filter covers the active folder, or all entries in the active
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

The About window contains a GitHub badge. Its destination is configured by
`VibeZipRepositoryURL` in `Resources/Info.plist`.

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
