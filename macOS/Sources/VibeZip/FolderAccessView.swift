#if os(macOS)
import AppKit
import VibeZipCore

final class FolderAccessPicker: NSObject, NSOpenSavePanelDelegate {
    private let requiredURL: URL?
    private init(requiredURL: URL?) { self.requiredURL = requiredURL }
    static func choose(required: URL? = nil, suggested: URL? = nil, replacing id: UUID? = nil) throws -> URL? {
        let delegate = FolderAccessPicker(requiredURL: required)
        let panel = NSOpenPanel(); panel.delegate = delegate
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = L10n.tr("Allow Folder Access"); panel.prompt = L10n.tr("Allow Access"); panel.directoryURL = suggested ?? required
        panel.message = required.map { L10n.tr("Choose \($0.path) or a containing folder to continue.") } ??
            L10n.tr("Choose a folder VibeZip can browse and manage. You can change folder access in Settings.")
        guard withExtendedLifetime(delegate, { panel.runModal() }) == .OK, let url = panel.url else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        if let required = required, !DirectoryAccessStore.contains(required, in: url) {
            throw FMError.message(L10n.tr("Choose the requested folder or one of its containing folders."))
        }
        return try DirectoryAccessStore.shared.authorize(url, replacing: id)
    }
    func panel(_ sender: Any, validate url: URL) throws {
        if let required = requiredURL, !DirectoryAccessStore.contains(required, in: url) {
            throw FMError.message(L10n.tr("Choose the requested folder or one of its containing folders."))
        }
    }
}

final class FolderAccessView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let access = DirectoryAccessStore.shared
    private let table = NSTableView()
    private let renew = NSButton(title: L10n.tr("Grant Access…"), target: nil, action: nil)
    private let remove = NSButton(title: L10n.tr("Remove"), target: nil, action: nil)
    private let note = NSTextField(labelWithString: L10n.tr("Changes to folder access apply immediately."))
    private var folders: [AuthorizedDirectory] = []
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 585, height: 264))
        let heading = NSTextField(labelWithString: L10n.tr("Folder Access"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.frame = NSRect(x: 0, y: 0, width: 585, height: 24)
        addSubview(heading)
        for (id, title, width): (String, String, CGFloat) in [("folder", L10n.tr("Folder and subfolders"), 438), ("status", L10n.tr("Access"), 125)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 24
        table.allowsMultipleSelection = true; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(L10n.tr("Authorized folders"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 30, width: 585, height: 158))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        addSubview(scroll)
        let add = NSButton(title: L10n.tr("Add Folder…"), target: self, action: #selector(addFolder))
        renew.target = self; renew.action = #selector(renewFolder)
        remove.target = self; remove.action = #selector(removeFolders)
        var buttonX: CGFloat = 0
        for button in [add, renew, remove] {
            button.bezelStyle = .rounded; button.sizeToFit()
            let width = max(90, button.frame.width)
            button.frame = NSRect(x: buttonX, y: 198, width: width, height: 30)
            addSubview(button); buttonX += width + 8
        }
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 0, y: 238, width: 585, height: 20); note.lineBreakMode = .byTruncatingMiddle; addSubview(note)
        access.refreshUnavailable(); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func reload() { folders = access.directories; table.reloadData(); updateButtons() }
    private func updateButtons() { renew.isEnabled = table.selectedRowIndexes.count == 1; remove.isEnabled = !table.selectedRowIndexes.isEmpty }
    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard folders.indices.contains(row), let column = tableColumn else { return nil }
        let folder = folders[row]
        let text = column.identifier.rawValue == "folder" ? folder.url.path : (folder.isAvailable ? L10n.tr("Allowed") : L10n.tr("Unavailable"))
        let identifier = NSUserInterfaceItemIdentifier("folder-access-" + column.identifier.rawValue)
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TableTextCellView ?? TableTextCellView(identifier: identifier)
        cell.label.stringValue = text; cell.label.lineBreakMode = .byTruncatingMiddle; cell.toolTip = text
        return cell
    }
    @objc private func addFolder() { choose(replacing: nil) }
    @objc private func renewFolder() {
        guard folders.indices.contains(table.selectedRow) else { return }; choose(replacing: folders[table.selectedRow])
    }
    private func choose(replacing folder: AuthorizedDirectory?) {
        do {
            guard try FolderAccessPicker.choose(suggested: folder?.url, replacing: folder?.id) != nil else { return }
            note.stringValue = L10n.tr("Folder access saved."); note.textColor = .secondaryLabelColor; reload()
        } catch { note.stringValue = error.localizedDescription; note.toolTip = error.localizedDescription; note.textColor = .systemRed }
    }
    @objc private func removeFolders() {
        access.remove(Set(table.selectedRowIndexes.compactMap { folders.indices.contains($0) ? folders[$0].id : nil }))
        table.deselectAll(nil); reload(); note.stringValue = L10n.tr("Folder access removed."); note.textColor = .secondaryLabelColor
    }
}
#endif
