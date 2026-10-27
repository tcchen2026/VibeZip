# Sandbox, file access and local data

VibeZip targets Mac App Store distribution with explicit user-selected file
access. The current app bundle enables App Sandbox, user-selected read/write
access and app-scoped bookmarks. Both `com.apple.security.network.client` and
`com.apple.security.network.server` are explicitly false, disabling outgoing and
incoming network access in the app process. See
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

The explicit Finder actions reveal selected items or show VibeZip's temporary
folder from Settings. The About button opens the configured HTTPS GitHub project
page in the user's browser. These controls do not open archive contents in external viewers.

The Settings default-app button asks macOS to associate selected archive content
types with VibeZip and verifies each reported handler. The `.zip/.7z/.rar` preset
applies the three types sequentially and stops if a request is declined or fails.
It uses NSWorkspace's public
API and system consent; no sandbox exception, startup association change or direct
Launch Services preference write is introduced. Being a default handler does not
grant folder access. Files opened from Finder use the existing user-selected-file path.

## Persistence and cleanup

Preferences, authorization history and window state stay in local preferences.
Passwords live in session memory and can be cleared through the Tools menu or
by quitting; they are not written to command arguments, preferences or logs.
This is not a guarantee of cryptographic zeroization of all process memory.

Temporary nested archives, previews and extraction copies can contain decrypted
data. They use mode-0700 directories inside `VibeZip` under the sandbox's temporary
directory. A scratch owner holds an exclusive directory lock until it releases
the directory. Preview copies are released once their bounded, in-memory content
has been loaded; nested sessions and clipboard copies may stay until app cleanup.
A crash releases the locks but can leave files behind.

Settings → General can show this folder in Finder or clean unused copies.
Its MB/GB total is a background snapshot of regular-file sizes, including active
copies, and does not read file contents or follow symbolic links.
Cleanup only visits matching VibeZip work directories inside this dedicated
folder and skips locks held by this or another running process. It ignores
unrelated files and top-level symlinks, and removes links inside a discarded
directory without following their targets. Cancellation is checked between files.
It does not sweep the system temporary directory, older builds' temporary folders,
archive staging beside user files, or backups. There is no persistent crash-recovery
journal or automatic startup scavenger, and cleanup is not secure erasure.

Sources: [TemporaryFiles.swift](../macOS/Sources/VibeZipCore/TemporaryFiles.swift)
and [FileOperations.swift](../macOS/Sources/VibeZipCore/FileOperations.swift).

The app has no accounts, analytics or upload feature. Local operation details
can contain filenames and paths, so they should not be copied into public issues
without review. Keep the user-facing [Privacy.txt](../macOS/Resources/Privacy.txt)
and [PrivacyInfo.xcprivacy](../macOS/Resources/PrivacyInfo.xcprivacy) consistent with
actual behavior when changing this design.

The in-app Privacy window reads the document for the selected app language from
the shared localization bundle. Its English copy is checked against the source
privacy notice, and translations describe the same local processing and access
behavior.
