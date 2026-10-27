# Sevenfold design integration

The complete supplied source is preserved in
[design_reference/Sevenfold](../design_reference/Sevenfold/), with an exact
per-file [checksum manifest](../design_reference/manifest.json). Importing the
reference and integrating its screens are separate steps: the reference is a
macOS 26 SwiftUI prototype backed by an in-memory sample library.

The shipping app retains the real 7-Zip sessions, safe extraction and updates,
security-scoped access and built-in preview. Its appearance follows the supplied
design while maintaining compatibility with macOS 26.

| Reference file | Shipping integration |
| --- | --- |
| `App/SevenfoldApp.swift` | AppKit application lifecycle, sandboxed startup and original VibeZip branding |
| `App/SevenfoldCommands.swift`, `Model/Commands.swift` | Existing File/Edit/View/Go/Tools menus, view commands, Info and shortcut map |
| `Views/BrowserWindow.swift` | One/two-pane split view, separated toolbar actions, view switcher, toolbar filter, shortcut strip and status area |
| `Views/SidebarView.swift` | Real authorized Favorites, session archives and recent folders; system folder picker |
| `Views/FileBrowser.swift` | Icons, List and Details over the same real rows and selection; path, history, search, sorting and empty states |
| `Views/InspectorView.swift` | Live file, selection and archive metadata plus Test Archive |
| `Views/ArchiveSheets.swift` | Two-column Add form, Extract form and shared symbol/header/footer treatment; actual compression options and progress |
| `Views/UtilitySheets.swift` | Copy/Move forms; existing real checksum, split/combine and Help commands |
| `Views/SettingsView.swift` | General, Folder Access and Keyboard tabs with real preferences and security-scoped bookmarks |
| `Views/ShortcutMapView.swift` | Filterable key comparison and What Moved tabs; 7-Zip/Mac mode picker and dismissible hints |
| `State/BrowserModel.swift`, `State/PaneState.swift` | Production AppKit controllers own navigation, selection and actions |
| `State/OperationModel.swift` | Real typed engine progress and cooperative cancellation |
| `Model/Archive.swift`, `Model/ArchiveOptions.swift`, `Model/Formatting.swift` | Production core models, validation and formatting |
| `Model/SampleLibrary.swift` | Reference only; no example files inserted into the user's browser |
| `Views/BenchmarkView.swift` | Reference only; the production engine does not expose the prototype's simulated benchmark |

The prototype's external editor/Quick Look handoff is replaced by VibeZip's
existing local preview. Finder integration, file-association toggles, archive
comment editing, simulated benchmarks and synthetic command-line estimates are
not exposed as working features. Mac and 7-Zip key modes and two independent panes are implemented. These differences must not be described
as a complete one-to-one implementation of the prototype.

The user approved the full layout, including two panes and a macOS 26 minimum.
The repository guidance and build targets now reflect that decision. Each pane
has its own state; commands and the toolbar filter follow focus. Shared archive
sessions are refreshed in both panes after mutations. Icon/List/Details changes
retain native entry identities and the current selection.

The imported simulation code is kept outside the executable target. No UI
automation or screenshot harness is included with this integration.
