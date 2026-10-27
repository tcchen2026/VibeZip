# VibeZip for macOS

VibeZip is a native, single-pane archive manager with an English AppKit interface.
It loads this repository's 7-Zip shared library directly, without a command-line
helper process.

## Build

Requires macOS 13 or later, Xcode command-line tools and Swift 5.9 or later.
From this directory:

```sh
bash build.sh
open dist/VibeZip.app
```

`--universal` builds arm64 and x86_64. `--debug` selects a debug Swift build.
`--library-only` builds the engine. `--test` runs the core test suite.
Local app bundles use ad-hoc signing and enable App Sandbox. Store distribution
requires the publisher's signing and App Store configuration.

## Use

Choose a folder on first launch. Saved security-scoped bookmarks allow the app to
restore the last authorized directory. Manage access in Settings → Folder Access.

Double-click enters a folder or opens a file as an archive. Back, Forward and Up
are at the left of the toolbar. Click the breadcrumb address or press Command-L
to edit it. Search covers the current folder, or all entries in the current
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
