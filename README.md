# VibeZip

A 7-Zip fork with a native macOS archive manager. Based on 7-Zip 26.03.

- [macOS app and build instructions](macOS/README.md)
- [Support and contact](SUPPORT.md)
- [Privacy policy](PRIVACY.md)
- [Design documents](design_docs/README.md)
- [Manual DMG builds and signing](design_docs/distribution.md)
- [Complete supplied UI reference](design_reference/README.md)
- [Source map](AGENTS.md)
- [Upstream documentation](DOC/readme.txt)
- [License and third-party terms](DOC/License.txt)

The macOS app calls the archive library in-process and supports nested archives,
folder authorization, local previews and automatic legacy ZIP filename decoding.
Its macOS 26 interface includes one or two file panes, Icons/List/Details views,
a sidebar and a live Info inspector. App Sandbox is enabled for local builds and
DMG distribution.
Engine sources remain in the upstream directory layout; the Swift/AppKit/SwiftUI app is in
`macOS/`.

Build on macOS 26 or later with Xcode 26 and Swift 6.2 or later:

```sh
cd macOS
bash build.sh
open dist/VibeZip.app
```

GitHub Actions builds the DMG only when manually dispatched. Pushes do not start
a build. The workflow builds and packages; it does not run test suites.

Most code is LGPL-2.1-or-later. Preserve the BSD, public-domain and unRAR terms of
the relevant upstream files. The macOS additions are distributed under
LGPL-2.1-or-later; retained MIT notices are in `macOS/Resources/Licenses/`.
