import SwiftUI

/// Help ▸ Shortcut Map for 7-Zip Users: every key, and what moved on the Mac.
struct ShortcutMapView: View {
    @AppStorage(PrefKey.keyMode) private var keyMode: KeyMode = .sevenZip
    @AppStorage(PrefKey.shortcutMapTab) private var tab = "keys"
    @State private var search = ""

    private static let moved: [(String, String)] = [
        ("Tools ▸ Options", "Sevenfold ▸ Settings (⌘,). Tools ▸ Options… opens the same window."),
        ("Properties (Alt+Enter)", "The Info inspector (⌘I). It stays open while you browse."),
        ("Explorer context menu", "Finder Quick Actions. Choose them in Settings ▸ Integration."),
        ("File associations", "Settings ▸ File Types. macOS confirms each default-app change."),
        ("Recycle Bin", "Delete moves items to the Trash. Deleting inside an archive is permanent, as in 7-Zip."),
        ("Ctrl+Z for Comment", "⇧⌘K, because ⌘Z is Undo on a Mac."),
        ("Backspace for Up One Level", "⌘↑, as in Finder. ⌫ deletes on a Mac."),
        ("Restore file security", "Restore extended attributes, plus an option to keep the quarantine flag."),
        ("NTFS streams and security", "Store extended attributes and tags. Add can also leave out .DS_Store and __MACOSX."),
        ("Grey + / Grey − / Grey *", "⌘=, ⌘− and ⇧⌘I, for keyboards without a keypad."),
        ("Alt+Shift+0–9 to save a bookmark", "⌥⌘0–9. Alt+0–9 still opens bookmarks as ⌥0–9."),
        ("Byte counts and ISO dates", "Kept as the default. Switch to Finder style in Settings ▸ General.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Show", selection: $tab) {
                    Text("Shortcuts").tag("keys")
                    Text("What Moved").tag("moved")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Picker("Key bindings", selection: $keyMode) {
                    ForEach(KeyMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            if tab == "keys" { shortcutTable } else { movedTable }
            Text("Ctrl becomes ⌘ and Alt becomes ⌥ for every 7-Zip shortcut. Return and double-click open items in both modes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var shortcutTable: some View {
        let rows = Shortcuts.all.filter {
            search.isEmpty || $0.command.title.localizedCaseInsensitiveContains(search) || $0.menu.localizedCaseInsensitiveContains(search)
        }
        return Table(rows) {
            TableColumn("Menu") { Text($0.menu).foregroundStyle(.secondary) }
                .width(70)
            TableColumn("Command") { spec in
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.command.title)
                    if let note = spec.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
            TableColumn("7-Zip on Windows") { Text($0.windows).font(.system(.body, design: .monospaced)) }
                .width(130)
            TableColumn("Sevenfold, 7-Zip keys") { spec in key(spec.sevenZip, highlighted: keyMode == .sevenZip) }
                .width(150)
            TableColumn("Sevenfold, Mac keys") { spec in key(spec.mac, highlighted: keyMode == .mac) }
                .width(150)
        }
    }

    private var movedTable: some View {
        let rows = Self.moved.enumerated().filter {
            search.isEmpty || ($0.element.0 + $0.element.1).localizedCaseInsensitiveContains(search)
        }
        return List(rows, id: \.offset) { item in
            VStack(alignment: .leading, spacing: 3) {
                Text(item.element.0).font(.headline)
                Text(item.element.1).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    private func key(_ shortcut: KeyboardShortcut?, highlighted: Bool) -> some View {
        Text(Shortcuts.label(shortcut))
            .font(.body.weight(highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? Color.primary : Color.secondary)
    }
}
