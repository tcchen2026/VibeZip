# VibeZip

A 7-Zip fork with a native macOS archive manager. Based on 7-Zip 26.03.

- [macOS app and build instructions](macOS/README.md)
- [Design documents](design_docs/README.md)
- [Source map](AGENTS.md)
- [Upstream documentation](DOC/readme.txt)
- [License and third-party terms](DOC/License.txt)

The macOS app calls the archive library in-process and supports nested archives,
folder authorization, local previews and automatic legacy ZIP filename decoding.
Engine sources remain in the upstream directory layout; the Swift/AppKit app is in
`macOS/`.

Build on macOS with Xcode command-line tools and Swift 5.9 or later:

```sh
cd macOS
bash build.sh
open dist/VibeZip.app
```

Run the core and native integration tests with `bash Scripts/test-core.sh` from
`macOS/`.

Most code is LGPL-2.1-or-later. Preserve the BSD, public-domain and unRAR terms of
the relevant upstream files. The macOS additions are distributed under
LGPL-2.1-or-later; retained MIT notices are in `macOS/Resources/Licenses/`.
