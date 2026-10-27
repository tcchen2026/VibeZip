# VibeZip

Build a native macOS archive manager in this 7-Zip fork, with the familiar
workflow of 7-Zip File Manager and the supplied Sevenfold design. The goal is reliable browsing and
editing of large, complex and nested archives, distributed through the Mac App
Store. App Sandbox and explicit file access are part of the architecture;
store signing and submission remain release work.

## Design philosophy

- Follow the complete Sevenfold layout in `design_reference/Sevenfold`: one or
  two file panes, Icons/List/Details, sidebar, editable breadcrumbs, toolbar
  filter and Info inspector. The user approved macOS 26 as the minimum. Keep
  real operations and sandbox permissions behind every shipped control; do not
  substitute the prototype's sample library or simulated results.
- Use the 7-Zip library in-process through persistent sessions and typed APIs.
  Stream contents; preserve native item identity; verify staged archive changes
  before committing them. Avoid command-line wrappers.
- Respect user control: restore only authorized locations, manage saved folder
  access in Settings, and keep processing and previews local. Never execute
  archive contents or hand files to external viewers.
- Keep exploration quiet. Use dialogs for decisions, passwords and Test results;
  show cancellable progress for operations lasting more than one second.
- Search existing metadata synchronously: the current filesystem directory or
  the entire current archive's file list. Do not search file contents or descend
  into nested archives.
- Keep changes focused and document limitations honestly. Preserve upstream and
  third-party notices. Use targeted core tests; visual UI review is manual.

## Design documents

Start with [design_docs/README.md](design_docs/README.md). It links the architecture,
archive transactions, sandbox and privacy model, interaction rules, ZIP filename
decoding, and build/release notes. Update the relevant document when changing a
design contract; distinguish implemented behavior from proposed work.

## Source map

- `C/`, `Asm/`: codecs and optimized primitives.
- `CPP/7zip/Archive/`: archive handlers; ZIP raw filename access is in `Zip/ZipHandler.{h,cpp}`.
- `CPP/7zip/Bundles/Format7zF/`: shared archive library build.
- `DOC/License.txt`, `DOC/copying.txt`: upstream licensing; retain per-file notices.
- `macOS/README.md`: app usage, build and tests.
- `macOS/Sources/VibeZip/`: AppKit UI; `MainWindowController.swift` coordinates actions, `PaneController.swift` lists files, `AboutWindow.swift` draws the GitHub badge.
- `macOS/Sources/VibeZipCore/`: archive sessions, safe file operations, folder bookmarks and ZIP encoding detection.
- `macOS/Sources/CVibeZip/`: C++/Swift bridge and stream callbacks.
- `macOS/Tests/VibeZipCoreTests/`: core and native integration tests.
- `macOS/Resources/Info.plist`: app metadata and `VibeZipRepositoryURL`.
- `macOS/Scripts/`, `macOS/build.sh`: engine build, tests, packaging and source rebuild.

Build: `cd macOS && bash build.sh`. Test: `cd macOS && bash Scripts/test-core.sh`.
