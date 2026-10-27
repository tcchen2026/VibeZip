# Interface and interaction

The interface should feel like a compact macOS file manager. English is the
default language. A single file list carries both filesystem browsing and archive
browsing, including nested archives. Prefer native AppKit controls, readable
rows and familiar actions over decorative panels or new navigation modes.

## Window layout

The default arrangement has three working areas:

1. A native toolbar: icon-only Back, Forward and Up at the left; compact archive
   and file actions, including Preview and Info, grouped to the right.
2. A location row: breadcrumbs use the available width; the search field stays
   at the far right with a fixed width. There is no separate **File System** label.
3. A sortable file table with a compact status area below it.

Use consistent toolbar spacing and vertically center every table cell's text
and icon, including metadata columns and the Folder Access table. The property
action is named **Info**. The toolbar remains customizable through native macOS
behavior; these rules describe its default arrangement.

The location control shows breadcrumbs until clicked or focused with Command-L.
The whole breadcrumb area enters text editing. Return submits; Escape restores
the displayed location. Entering a path still passes through the folder access
rules. Back and Forward traverse navigation history; Up moves toward a parent
directory or out of the current archive context.

Sources: [MainWindowController.swift](../macOS/Sources/VibeZip/MainWindowController.swift),
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

Without a restorable authorized directory, show **Choose a folder to get started**
and a **Choose Folder…** button. A later launch restores the last available
authorized directory. Settings exposes saved grants so users can understand and
change the app's access.

The About window's content is one black GitHub badge, with a subtle border,
highlight and shadow. It links to the project URL in
[Info.plist](../macOS/Resources/Info.plist), currently
[tcchen2026/VibeZip](https://github.com/tcchen2026/VibeZip).
Keep licensing detail in the bundled notices and source documentation. Maintain
keyboard focus, accessibility labels and adequate contrast when changing custom
controls. Visual layout review is manual; do not add screenshot test machinery
for routine spacing changes.
