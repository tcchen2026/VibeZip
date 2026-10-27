# Supplied Sevenfold design

`Sevenfold/` contains all 20 files from the supplied `Sevenfold-SwiftUI(1).zip`,
unchanged. `manifest.json` records the ZIP's SHA-256 and the checksum of every
extracted file. This is the complete designer reference, separate from the
shipping application under `macOS/`.

The reference package requires Swift 6.2 and macOS 26. Its sample library,
compression progress, benchmark and several utility results are simulated.
Running this package previews the design; it does not run VibeZip's archive
engine or establish App Sandbox permissions.

See [design integration](../design_docs/design-integration.md) for the production
mapping. Preserve the reference unchanged so future design reviews can compare
against the supplied package.
