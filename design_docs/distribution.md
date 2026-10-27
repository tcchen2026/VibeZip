# macOS DMG distribution

The direct-download DMG contains the same sandboxed app as the local build.
App Sandbox is independent of Mac App Store distribution: it stays enabled for
ad-hoc builds and Developer ID releases. No network or temporary sandbox
exception is added for the new UI or DMG.

## Local builds

From `macOS/`:

```sh
bash build.sh --universal
bash Scripts/package-dmg.sh --skip-build --unsigned
```

The image is `dist/VibeZip-macOS-unsigned.dmg`, with a SHA-256 sidecar. It contains
VibeZip.app and an Applications link. This ad-hoc build is for local testing;
it is not notarized and must not be published as the signed release.

Omit `--skip-build` to build both architectures first. `--skip-build` accepts a
host-only unsigned build for development; signed distribution checks that both
the app and library contain arm64 and x86_64.

For a release, set `MACOS_DEVELOPER_ID` to a Developer ID Application identity
in your keychain, and `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` for an App Store
Connect API key. `MACOS_SIGNING_KEYCHAIN` can select a temporary keychain.

```sh
bash Scripts/package-dmg.sh
```

The script signs the library and app with hardened runtime and a timestamp,
uses the app's sandbox entitlement file, creates the image, signs
it, submits it to Apple, requires an Accepted result, staples the ticket, and
runs Gatekeeper assessment. Only then does it promote `dist/VibeZip-macOS.dmg`
and write its checksum. Notarization failures stop the build and leave diagnostic
JSON under `dist/`. Private keys are never bundled.

Both signing paths use `Resources/VibeZip.entitlements`, which enables App
Sandbox, user-selected read/write access and app-scoped bookmarks, and explicitly
disables incoming and outgoing network access. Standard
`codesign` verification remains part of packaging.

## Manual GitHub Actions workflow

[.github/workflows/macos.yml](../.github/workflows/macos.yml) follows the manual
build/sign/notarize/artifact pattern in
[VibeOffice's macOS workflow](https://github.com/tcchen2026/VibeOffice/blob/main/.github/workflows/macos.yml).
It has **only `workflow_dispatch`**. Pushes, pull requests and tags do not build.

On GitHub, select **Actions → macOS DMG → Run workflow**. The workflow uses a
macOS 26 runner to build both architectures and package the DMG. It does not
run test suites or UI automation. Every successful run uploads the DMG and checksum as an Actions artifact.
The optional **Publish release** input creates or updates a release using the
built app's `vYYYY.MM.DD-abcdef` version, matching VibeOffice's format with
VibeZip's own UTC commit date and six-character hash. It defaults to false;
unsigned builds cannot publish.
**Pre-release** controls the designation when creating a release.

Create a GitHub environment named `release` and configure these secrets there:

| Secret | Value |
| --- | --- |
| `MACOS_DEVELOPER_ID_P12` | Base64-encoded Developer ID Application certificate and private key export |
| `MACOS_DEVELOPER_ID_PASSWORD` | Password used when exporting the P12; may be empty |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | API issuer ID |
| `ASC_KEY_P8` | Raw PEM contents of the API private key |

Without the P12 secret, the workflow produces an unsigned test DMG artifact.
With it, all notarization secrets are required and signing/notarization failures
fail the workflow; they do not fall back to an unsigned public release. The
certificate is imported into a temporary keychain and signing material is removed
in an `always()` cleanup step. No App Store upload is included in this workflow.

The repository remote for this project is `git@github.com:tcchen2026/VibeZip.git`.
The previous fork remote remains `upstream`. Committing locally neither pushes
the code nor runs the manual workflow.

