# Interface and interaction

The interface should feel like a compact macOS file manager. It follows the macOS
app language, supporting English, Simplified Chinese, Japanese and Korean, with
English as the fallback. One or two file panes carry filesystem and archive browsing, including nested
archives. The active pane owns command targets, filter text and the Info selection. Prefer native AppKit controls, readable
rows and familiar actions over decorative panels or new navigation modes.

## Window layout

The layout adapts the supplied Sevenfold SwiftUI design to VibeZip's real,
browser, including the prototype's optional second pane. It remains compatible with macOS 26 and later; native
materials follow the running system's appearance.

The title bar shows `VibeZip - <active folder or archive name>`, or just `VibeZip`
before a location is opened. It has no subtitle.

The default arrangement has these working areas:

1. A collapsible sidebar: Favorites are actual saved folder grants, followed by
   open archives and recent folders from the current session. Add Folder uses
   the existing system permission picker. Unavailable grants remain visible.
2. A native toolbar: Sidebar, Back and Forward at the left; Add, Extract and Test
   grouped separately from Copy, Move, Delete, Preview and Info.
3. A rounded breadcrumb location row. Up and
   Folders History sit beside each path; the toolbar filter follows the active pane.
4. Icons, List or a sortable inset Details table in each pane and a fixed-height status area showing counts,
   sizes, archive format and operation feedback.
5. An optional Info inspector showing the current selection and archive's live
   metadata. Command-I toggles it without opening a separate window.

Sidebar, inspector and two-pane mode are saved locally.
The toolbar's **2 Panels** control toggles two panes; Tab changes the active pane. Each
pane keeps its own path, history, filter, view style and selection. Both panes
refresh after archive mutations, and each permission check uses the same shared
DirectoryAccessStore. Copy/Move offers the other pane's filesystem folder as its
default destination. Switching panes during an active operation is disabled so
completion and cancellation remain attached to the initiating pane.
View can restore the sidebar and inspector. Shortcut tips, maps, key-mode
selectors and platform comparisons are not part of the shipping interface.
Empty folders and searches have distinct empty states. The prototype's sample
files, simulated operations, external viewers and unimplemented
Finder integration are not part of this adaptation.

Use consistent toolbar spacing and vertically center every table cell's text
and icon, including metadata columns and the Folder Access table. The property
action is named **Info**. The toolbar remains customizable through native macOS
behavior; these rules describe its default arrangement.
When the toolbar overflows, **View** in the `»` menu has **Icons**, **List** and
**Details** children. Their checkmarks and actions follow the active pane.

Click an ancestor breadcrumb to navigate directly to that directory, archive root
or folder inside an archive. Archive breadcrumbs retain their existing sessions,
including parent archives and containing folders when a nested archive was opened
from search. Filesystem destinations still pass through the folder access rules.
Click the current location or empty space, or use Command-L, to edit the path.
Return submits; Escape restores the displayed location. Entering a path still
passes through the folder access rules. Back and Forward traverse navigation
history; Up moves toward a parent directory or out of the current archive context.
Locations within the user's home display `~` as the first breadcrumb and use
paths such as `~/Downloads` in the editor and history. Expansion uses the account's
home directory from the account database, including in the sandbox, and still passes through folder access
checks. Nested archive paths retain this abbreviation without changing session identity.

Sources: [MainWindowController.swift](../macOS/Sources/VibeZip/MainWindowController.swift),
[BrowserChrome.swift](../macOS/Sources/VibeZip/BrowserChrome.swift),
[PaneController.swift](../macOS/Sources/VibeZip/PaneController.swift),
[LocationBar.swift](../macOS/Sources/VibeZip/LocationBar.swift).

## Opening and previewing

Double-click and the context-menu **Open** action have the same meaning: enter a
directory or attempt to open a file as an archive. They never launch the file's
associated program. **Preview** is a separate command, also available from the
toolbar and Space / F3.

When a file cannot be recognized as an archive, the informational sheet says
**This doesn't seem to be an archive**, explains that VibeZip does not recognize
its archive type, and offers **Preview**, **Reveal in Finder**, and **Cancel**.
For a nested item, Finder reveals the outer archive and the sheet explains this.
Password and access failures have their own request/retry paths where available.

The context menu contains, in order:

| Command | Meaning |
| --- | --- |
| Open | Same action as double-click |
| Preview | Built-in local preview of one regular file |
| Reveal in Finder | Show selected filesystem files, or the containing outer archive |
| Extract | Extract the selected archive or selected archive entries |
| Add to Archive | Create an archive from filesystem items or add sources to the current archive |
| Info | Inspect selected file or archive metadata |

Disable commands when the selection, archive capabilities or an active operation
make them unavailable. Preview text wraps automatically. The preview window is
read only and has no external-viewer button. Content limits are documented in
[Sandbox and security](sandbox-and-security.md).

## Drag and drop

An empty browser accepts one file or folder URL from Finder. A file opens through
the same user-selected-file path as Browse, without requiring authorization for
its parent folder. A dropped folder is explicitly authorized and browsed. Multiple
URLs and file promises are rejected while there is no destination. This applies
to an empty second pane as well as first launch.

Drop files or folders from Finder into an open writable archive to add them to
the current archive folder. Dropping onto a folder row or icon adds them inside
that folder, including folders found through archive search. Icons, List and
Details share the same drop handling, and empty-state text remains a valid drop
area. Drops copy sources; they do not remove the originals.

New names begin the normal staged, verified archive update without an extra
Add confirmation. A matching entry or folder asks before proceeding, since a
folder merge may replace existing contents. Password and containing-folder
authorization prompts still apply. Read-only archives and busy or modal windows
do not accept drops. A filesystem destination uses the existing copy operation
with automatic conflict renaming.

Archive entries can be dragged out as file promises. Incoming file promises are
accepted into filesystem folders in all three views; adding them directly to
another archive is not implemented. Finder file URLs can be added to an archive.

## Search

Search is immediate filtering of the current metadata snapshot:

- In the filesystem, filter names in the current directory only.
- Inside an archive, search names and paths across that archive's entire listing,
  regardless of the currently displayed subdirectory. Include inferred folders
  and retain each real entry's native identity.
- Do not read file contents, descend into nested archives or start a separate
  search task. Clearing the query restores the current folder view.

Archive search shows a Location column to distinguish matches with the same
name. Results remain selectable for ordinary commands. Listing an archive and
obtaining filesystem metadata are separate I/O operations; the query itself
uses the already loaded data.

## Feedback and dialogs

Ordinary navigation and successful short operations should not require an
acknowledgment. Use the status area for completion notices and recoverable errors,
with operation details available when needed. Dialogs are appropriate for a
meaningful choice, a password, destructive confirmation, compression/extraction
options and the explicit result of **Test archive**.

An operation starts status feedback immediately. If it remains active for more
than one second, show a progress window with the current phase, known progress,
elapsed time and Cancel. Use indeterminate progress when the engine cannot supply
a total. Close that window when the operation finishes. Cancellation is
cooperative; preserve the distinction between an uncommitted archive edit and
file copies already completed at the destination.

Test displays **Test passed** or **Test failed** in a result sheet; failure offers
Details. This explicit result is useful because the user requested validation.
The threshold and UI implementation are in
[OperationStatusView.swift](../macOS/Sources/VibeZip/OperationStatusView.swift) and
`MainWindowController.perform`.

## First launch and About

Without a restorable authorized directory, show **Open an archive or choose a folder**,
an explanation of archive drops, and a **Choose Folder…** button. Sidebar Favorites
starts empty until access is granted; displaying a place never grants permission.
A later launch restores the last available authorized directory. Settings exposes
saved grants so users can understand and
change the app's access.

The compact About window shows the app icon, name, version from the bundle,
a one-line description, a labeled black GitHub button with a subtle border,
highlight and shadow, and a small localized “Licensed under LGPL 2.1 or later” footer.
The button links to the project URL in
[Info.plist](../macOS/Resources/Info.plist), currently
[tcchen2026/VibeZip](https://github.com/tcchen2026/VibeZip).
Full license terms and third-party notices remain bundled with the app. Maintain
keyboard focus, accessibility labels and adequate contrast when changing custom
controls. Visual layout review is manual; do not add screenshot test machinery
for routine spacing changes.

## Settings

Settings uses General and Folder Access tabs. Keyboard bindings continue to work
without dedicated shortcut UI; a key-mode preference saved by an older build is
still honored so existing users' keys do not change. Compression, extraction and
transfer forms share the design's symbol, heading and footer layout while
retaining real option validation.

General includes a short explanation of temporary files, **Show Temporary Folder**
to open VibeZip's dedicated temporary folder in Finder, and **Clean Temporary Files**
to remove unused copies. Live scratch directories are kept. Cleanup runs off the
main thread and shows cancellable progress after one second; Settings stays open
until cleanup completes or cancellation finishes. The controls and explanation
are translated into each supported language.

A compact MB/GB total beside the temporary-files heading counts all regular files
in the dedicated folder, including copies still in use. It reads metadata in the
background when Settings opens and after cleanup, including cancellation or a
partial failure. Closing Settings cancels the scan. The total is logical file size,
not a claim about reclaimable space or physical allocation; links are not followed.

General also includes **Set VibeZip as Default** with a file-format selector.
The first and initially selected item is `.zip/.7z/.rar`, followed by the individual
extensions declared by the app. The button requests the selected content types
through [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopen:completion:)).
Requests run one at a time, skip types already assigned to this app, and deduplicate
aliases. macOS may ask for confirmation for each type. The control reads back each
actual default before continuing; a declined or unsuccessful request stops the
batch and preserves earlier confirmed changes. Single-format failures show a brief
Finder **Get Info → Open with → Change All** instruction. No association is changed at
launch or merely by opening Settings. Aliases of the same macOS content type share
their default app. The native consent flow requires manual testing in the signed app.

## Language and localization

Menus, toolbar controls, dialogs, accessibility text, the Info inspector, normal
operation feedback and Swift error messages use shared translation tables in
[VibeZipCore/Resources](../macOS/Sources/VibeZipCore/Resources/). Help and Privacy
have a document for each supported language. Native engine diagnostics and system
errors retain the language supplied by their source; bundled license notices
remain in their original language.

macOS chooses the app language from the user's preferred languages or the
per-app setting in System Settings → General → Language & Region. Reopen VibeZip
after changing that setting. No in-app language selector is required.

[Localization.swift](../macOS/Sources/VibeZipCore/Localization.swift) keeps fixed
translation keys separate from interpolated filenames, paths, counts and codec
names. Translations can reorder arguments without changing their contents.
Archive metadata keys, compression identifiers and saved preferences stay stable.
Displayed filesystem and archive dates use the current locale. Form labels and
folder-access buttons size to their translated text within the available width.
