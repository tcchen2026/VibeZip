# Mac App Store packaging

[package-mas.sh](../macOS/Scripts/package-mas.sh) builds a universal, sandboxed
app and packages it with Apple's `productbuild --component` mode. The output is
a single-app `.pkg` for App Store Connect, including TestFlight. It contains no
installer scripts or shared-location components. The existing
[DMG workflow](distribution.md) remains the direct-download route.

Packaging does not upload the app, start TestFlight distribution, submit it for
review, or publish a GitHub release. A successfully signed package still needs
App Store Connect validation and review. Store-signed apps are intended for
installation through TestFlight or the store; use the ordinary local build for
development launches.

## Local packaging

From `macOS/`, an unsigned inspection package needs no Apple credentials:

```sh
bash Scripts/package-mas.sh --unsigned
```

This writes `dist/VibeZip-MAS-unsigned.pkg` and a SHA-256 checksum. The app inside
is ad-hoc signed. **Do not upload this package to Transporter or App Store
Connect.** It is only useful for inspecting the layout and bundled resources.
Both architectures are required even in unsigned mode.

For a signed package, register the app's explicit bundle ID, currently
`org.vibezip.swift`, and create its App Store Connect app record. Install these
identities with their private keys in your keychain:

- **Apple Distribution** (or the older **Mac App Distribution** identity) for
  the app and its library.
- **Mac Installer Distribution** for the `.pkg`. Its certificate name normally
  starts with `3rd Party Mac Developer Installer`.

Download a **Mac App Store Connect provisioning profile** for that exact app ID
and application distribution certificate. A profile is required by this path
so the package can also be used for TestFlight. A Developer ID or development
profile is not suitable. Keep credentials outside the checkout; common signing
file extensions are also ignored by Git and excluded from bundled source.

```sh
export VIBEZIP_MAS_PROFILE=/path/to/VibeZip.provisionprofile
export VIBEZIP_MAS_BUILD_NUMBER=1
bash Scripts/package-mas.sh
```

The script selects a valid application identity authorized by the profile and
an installer identity from the same team. `VIBEZIP_MAS_KEYCHAIN` optionally
selects a keychain. If more than one installer identity matches, set
`VIBEZIP_MAS_INSTALLER_IDENTITY` to its full certificate name or SHA-1 fingerprint;
`VIBEZIP_MAS_APP_IDENTITY` supports the same override for the application.
Developer ID identities are not accepted for this path.

The result is `dist/VibeZip-MAS.pkg` and its SHA-256 checksum. `--skip-build`
reuses `dist/VibeZip.app` after checking both architectures and current build
metadata. Packaging works on a staged copy; the local app and DMG input retain
their original signing, entitlements and bundle version.

## Versions and checks

The marketing version (`CFBundleShortVersionString`) remains the numeric commit
date. The app's About version remains `vYYYY.MM.DD-abcdef`, matching the normal
VibeZip/VibeOffice scheme. The App Store Connect version must match the marketing
version in the package.

For store packages, `VIBEZIP_MAS_BUILD_NUMBER` replaces only `CFBundleVersion` in
the staged app. Use a number greater than the last uploaded macOS build, including
across marketing versions. Repackaging the same commit requires a new number
for another upload. The script validates syntax but cannot query the previous
number in App Store Connect.

Before signing, the script checks the profile's platform, expiration, explicit
app ID, team and authorized application certificate. It rejects development and
Developer ID profiles. It embeds `Contents/embedded.provisionprofile` and adds
the profile's application/team identifiers and, when present, its beta reporting
entitlement to the app's existing sandbox entitlements. Network access stays
disabled. The library is signed first without process entitlements, then the
app is signed with hardened runtime and DER entitlements.
The embedded profile has mode `0644`, so users can read it after the installer
assigns ownership to root. Private staging remains mode-restricted. The SwiftPM
resource bundle receives its own bundle identifier (`<app-id>.resources`), bundle
type and versions, with its store build number matching the app.

After embedding the profile and writing bundle metadata, preparation clears all
extended attributes recursively from the staged app before signing. This removes
download quarantine, Finder information and other inherited metadata; symlinks
are handled without following their targets. Source files and the original
downloaded profile are unchanged. See Apple's
[extended attribute cleanup guidance](https://developer.apple.com/library/archive/qa/qa1940/_index.html).

Packaging checks bundle metadata, both architectures, required resources,
localizations, privacy-manifest syntax and code signatures. It signs the package
with the installer identity, checks its signature, expands its structure, and
verifies the extracted app's code signatures, absence of extended attributes,
read permissions for every user, and resource bundle identifiers and versions.
Verification never clears attributes from the
extracted payload: unexpected metadata fails the build. The installer file's own
attributes are also cleared and checked. Only then does it promote the package
and checksum into `dist/`. These checks cover the packaging errors reported as
90255, 90276 and 91109. This does not replace Apple's upload validation or checks
of the running, store-signed app. Signing
timestamps may require network access on the build machine; the app itself still
has no network entitlement. Store packages do not use the Developer ID
notarization/stapling route.

## Manual GitHub Actions

Run **Actions → macOS App Store → Run workflow**. The
[workflow](../.github/workflows/macos-mas.yml) runs only on manual dispatch, on
`macos-26`, and checks for Xcode and SDK 26 or later. It shares the existing
compiler caches, builds both architectures, and saves the package and checksum
as artifacts. It does not run tests or UI automation.

In the repository's `release` environment, configure:

| Secret | Value |
| --- | --- |
| `MACOS_MAS_APP_P12` | Base64-encoded application distribution certificate and private key export |
| `MACOS_MAS_APP_PASSWORD` | Application P12 export password; may be empty |
| `MACOS_MAS_INSTALLER_P12` | Base64-encoded installer distribution certificate and private key export |
| `MACOS_MAS_INSTALLER_PASSWORD` | Installer P12 export password; may be empty |
| `MACOS_MAS_PROFILE` | Base64-encoded Mac App Store Connect provisioning profile |

Certificates are imported into a temporary keychain and removed, along with the
profile and P12 exports, in an `always()` cleanup step. Credentials and app bundles
are not cached. A signed run fails when credentials are missing or invalid; it
does not fall back to unsigned output. Select **unsigned** explicitly to produce
the inspection artifact without credentials.

The optional **build_number** input overrides the store build number. Otherwise
the workflow uses `<run_number>.<run_attempt>`, so a rerun gets a new number.
If a later-numbered run has already been uploaded, do not upload an older run's
rerun. When mixing local uploads and Actions, or after a custom override, choose
a build number greater than the last upload. These numbers are independent of
the DMG workflow's build numbers.

## Upload and remaining release work

Transporter.app is optional. The signed `.pkg` can be uploaded with Transporter
or Apple's supported command-line tools; neither is invoked by packaging. See
[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
Configure App Store Connect metadata, screenshots, support/privacy URLs, privacy
answers, and encryption declarations for the shipped archive encryption features.
Review the bundled source and notices against the final distributed binary.
Validate the exact TestFlight/store build's permission flows, archive changes,
cancellation and temporary cleanup before release.

Universal packaging and local application/installer signing have been verified
with store distribution certificates. App Store Connect acceptance and TestFlight
installation still require verification; local signature checks alone do not
establish upload acceptance.

Primary references: Apple's
[distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
[package construction](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution),
[profile creation](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/),
and [provisioning profile model](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
