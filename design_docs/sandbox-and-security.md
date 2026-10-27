# Sandbox, file access and local data

VibeZip targets Mac App Store distribution with explicit user-selected file
access. The current app bundle enables App Sandbox, user-selected read/write
access and app-scoped bookmarks. It requests no network entitlement. See
[VibeZip.entitlements](../macOS/Resources/VibeZip.entitlements).

The archive engine and built-in preview run in the app process and share this
sandbox. The sandbox limits process access; it does not make malformed archives
safe to parse or grant access to every file displayed as a path.

## Authorization lifecycle

[DirectoryAccessStore.swift](../macOS/Sources/VibeZipCore/DirectoryAccessStore.swift)
owns security-scoped resources on the main thread. Folder scopes remain active
for the process lifetime or until removed. Workers use that process access.

| Situation | Behavior |
| --- | --- |
| No saved location | Show an empty browser with **Choose Folder…**; do not silently select Home or another directory |
| Authorized folder chosen | Create and resolve a security-scoped bookmark, start access, then save it locally |
| Restart | Resolve saved bookmarks and restore the last directory only if its authorized root and relative path are available |
| Folder moved or bookmark stale | Use the resolved root; renew the bookmark when possible |
| Folder offline or inaccessible | Keep its record visible as unavailable so access can be renewed or removed |
| File selected individually | Retain access for the session; do not grant or persist access to its parent or siblings |
| Grant removed | Remove the saved bookmark, stop its active scope and discard related single-file scopes; overlapping grants can still cover the path |

Settings → Folder Access offers add, renew and remove actions. Saved records
contain an ID, bookmark bytes and a display path. The last directory is stored as
an authorized root ID and relative path, allowing a moved root to be followed.
A raw path in preferences or the address editor is never proof of authorization.
Containment checks resolve symlinks and compare path components, including when
the final destination does not exist yet.

Browsing outside a grant, accessing sibling archive volumes and staging an
update beside an archive can require a containing-folder selection. The UI owns
these panels and retries. The service and engine report access errors rather
than trying to expand permissions themselves. Removing saved access does not
delete files or remove access supplied by another explicit grant.

## Archive paths and outputs

[ArchivePath](../macOS/Sources/VibeZipCore/Models.swift) rejects absolute paths,
empty or dot components, traversal, control characters, backslashes and an
ambiguous colon in the first component. Decoding legacy ZIP bytes happens before
path validation; a multibyte character's trail byte is not treated as a separator.
Unsafe names may remain visible for inspection but cannot be materialized as
unsafe paths.

Extraction rejects archive links and ambiguous path collisions. Native input
opens require regular files and use `O_NOFOLLOW`; output creation uses exclusive
creation and refuses an existing final-component symlink. Private scratch
directories have mode `0700`, and new native output files begin with `0600`.
The merge layer refuses destination symlinks and stages individual copies before
replacement. These checks complement the sandbox and the
[transaction rules](archive-operations.md); they are not a claim of isolation
against every concurrent filesystem mutation.

## Built-in preview and external actions

[PreviewWindow.swift](../macOS/Sources/VibeZip/PreviewWindow.swift) reads local
regular files with bounded input. An archive member is first extracted through
the normal safe extraction path. Its extraction may therefore exceed the
renderer input limit while still remaining subject to the extraction quota.

| Content | Current presentation and limit |
| --- | --- |
| UTF-8 text | Read-only, selectable, wrapping text; first 4 MiB |
| Other bytes | Hex and ASCII representation; first 16 KiB |
| Supported raster images | ImageIO thumbnail, at most 2048 pixels on its longest side; document input at most 32 MiB |
| PDF | Core Graphics rasterization of page 1; document input at most 32 MiB |

HTML and scripts remain text. Preview does not use WebKit, Quick Look providers,
interactive PDF actions or external viewers. There is no **Open in Preview**
button or preference. Opening a file in the browser means attempting to browse
it as an archive; archive contents are never launched as programs.

Two deliberate external actions remain: **Reveal in Finder** shows a local file
or the outer archive, and the About badge opens the configured HTTPS GitHub
project page in the user's browser. Neither is a general external-file opener.

## Persistence and cleanup

Preferences, authorization history and window state stay in local preferences.
Passwords live in session memory and can be cleared through the Tools menu or
by quitting; they are not written to command arguments, preferences or logs.
This is not a guarantee of cryptographic zeroization of all process memory.

Temporary nested archives and preview files can contain decrypted data. They
use private directories and are removed during normal cleanup; some materialized
preview files remain until app cleanup. A crash can leave temporary files behind.
There is no persistent crash-recovery journal or explicit startup scavenger, and
cleanup is not secure erasure. User-enabled backups intentionally remain beside
the original archive.

The app has no accounts, analytics or upload feature. Local operation details
can contain filenames and paths, so they should not be copied into public issues
without review. Keep the user-facing [Privacy.txt](../macOS/Resources/Privacy.txt)
and [PrivacyInfo.xcprivacy](../macOS/Resources/PrivacyInfo.xcprivacy) consistent with
actual behavior when changing this design.
