#if os(macOS)
import AppKit
import SwiftUI
import VibeZipCore

/// Presentation of real browser state; archive operations remain in the AppKit controller.
final class BrowserPresentation: ObservableObject {
    struct Place: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let location: BrowserLocation
        var available = true
    }
    struct Detail: Identifiable {
        let name: String
        let value: String
        var id: String { name }
    }
    @Published var folders: [Place] = []
    @Published var archives: [Place] = []
    @Published var recent: [Place] = []
    @Published var selectedPlace = ""
    @Published var title = "No selection"
    @Published var subtitle = "Choose a folder to get started"
    @Published var symbol = "folder"
    @Published var details: [Detail] = []
    @Published var archiveDetails: [Detail] = []
    @Published var canTest = false
    @Published var busy = false

    func update(from pane: PaneController, panes: [PaneController], busy: Bool) {
        self.busy = busy
        folders = DirectoryAccessStore.shared.directories.map {
            Place(id: $0.url.path, name: $0.url.lastPathComponent.isEmpty ? "Macintosh HD" : $0.url.lastPathComponent,
                  symbol: "folder", location: .directory($0.url), available: $0.isAvailable)
        }
        var seen = Set<String>()
        archives = (panes.map(\.location) + panes.flatMap(\.recentLocations)).compactMap { location in
            guard let archive = location.archive, seen.insert(archive.id.uuidString).inserted else { return nil }
            return Place(id: archive.id.uuidString, name: archive.url.lastPathComponent, symbol: "archivebox",
                         location: .archive(archive, ""))
        }
        recent = pane.recentLocations.compactMap { location in
            guard let url = location.directory, !folders.contains(where: { $0.id == url.path }) else { return nil }
            return Place(id: url.path, name: url.lastPathComponent, symbol: "folder", location: location)
        }
        selectedPlace = pane.location.archive?.id.uuidString ?? pane.location.directory?.path ?? ""
        let selected = pane.selectedRows
        details = []; archiveDetails = []
        func detail(_ name: String, _ value: String) {
            if !value.isEmpty { details.append(Detail(name: name, value: value)) }
        }
        if selected.count == 1, let row = selected.first {
            title = row.name; subtitle = row.type; symbol = row.symbol
            detail(pane.location.archive == nil ? "Where" : "Path", pane.location.archive == nil ? (row.url?.deletingLastPathComponent().path ?? "") : row.path)
            if !row.isDirectory { detail("Size", UIFormat.bytes(row.size)) }
            if row.packedSize != nil { detail("Packed size", UIFormat.bytes(row.packedSize)) }
            detail("Modified", row.modified)
            if let member = row.member {
                detail("CRC", member.crc); detail("Method", member.method)
                detail("Encrypted", member.isEncrypted ? "Yes" : "No")
            }
        } else if selected.count > 1 {
            title = "\(selected.count) items"; subtitle = "Selected in this folder"; symbol = "doc.on.doc"
            detail("Files", String(selected.filter { !$0.isDirectory }.count))
            detail("Folders", String(selected.filter(\.isDirectory).count))
            detail("Size", UIFormat.bytes(UIFormat.totalSize(selected)))
        } else {
            title = pane.location.archive?.url.lastPathComponent ?? pane.location.directory?.lastPathComponent ?? "No folder selected"
            if title.isEmpty { title = "Macintosh HD" }
            subtitle = pane.location.archive == nil ? "Folder" : "Archive"
            symbol = pane.location.archive == nil ? "folder" : "archivebox"
            detail("Path", pane.location.display)
            if !pane.location.isEmpty { detail("Items", String(pane.rows.count)) }
        }
        if let archive = pane.location.archive {
            archiveDetails = archive.listing.properties.sorted { $0.key < $1.key }
                .filter { ["Type", "Physical Size", "Headers Size", "Method", "Solid", "Blocks", "Encrypted headers", "Multivolume", "Volumes"].contains($0.key) && !$0.value.isEmpty }
                .map { Detail(name: $0.key, value: $0.value) }
            archiveDetails.append(Detail(name: "Entries", value: String(archive.listing.entries.count)))
            archiveDetails.append(Detail(name: "Unpacked size", value: UIFormat.bytes(archive.listing.totalSize)))
            archiveDetails.append(Detail(name: "Access", value: archive.canModify ? "Read and write" : "Read only"))
        }
        canTest = pane.location.archive != nil && !busy
    }
}

final class BrowserWindowLayout: NSSplitViewController {
    let presentation = BrowserPresentation()
    private weak var owner: MainWindowController?
    private(set) var placesItem: NSSplitViewItem!
    private(set) var infoItem: NSSplitViewItem!
    private let filePanes = NSSplitViewController()
    private var secondPane: NSSplitViewItem!
    private var tipsView: NSView?
    init(owner: MainWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSHostingController(rootView: PlacesSidebar(model: presentation,
            open: { [weak owner] place in
                guard let owner = owner, owner.canAcceptCommands else { return }
                if owner.activePane.navigate(place.location) { owner.activate(owner.activePane) }
            }, add: { [weak owner] in owner?.chooseFolder(nil) },
            settings: { [weak owner] in owner?.showFolderAccess(nil) },
            shortcuts: { [weak owner] in owner?.showShortcuts(nil) }))
        placesItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        placesItem.minimumThickness = 180; placesItem.maximumThickness = 280
        placesItem.preferredThicknessFraction = 0.19; placesItem.canCollapse = true
        placesItem.isCollapsed = UserDefaults.standard.bool(forKey: "sidebarHidden")
        let firstPane = NSSplitViewItem(viewController: owner.left); firstPane.minimumThickness = 330
        secondPane = NSSplitViewItem(viewController: owner.right); secondPane.minimumThickness = 330
        secondPane.canCollapse = true; secondPane.isCollapsed = true
        filePanes.addSplitViewItem(firstPane); filePanes.addSplitViewItem(secondPane)
        filePanes.splitView.dividerStyle = .thin
        let workspace = NSViewController(); workspace.view = BrowserBackgroundView()
        workspace.addChild(filePanes)
        let tips = NSHostingView(rootView: ShortcutTipBar(showMap: { [weak owner] in owner?.showShortcuts(nil) },
                                                       close: { [weak owner] in owner?.toggleKeyTips(nil) }))
        tipsView = tips
        let stack = NSStackView(views: [tips, filePanes.view]); stack.orientation = .vertical; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false; workspace.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: workspace.view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: workspace.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: workspace.view.topAnchor), stack.bottomAnchor.constraint(equalTo: workspace.view.bottomAnchor),
            tips.widthAnchor.constraint(equalTo: stack.widthAnchor), filePanes.view.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let files = NSSplitViewItem(viewController: workspace)
        files.minimumThickness = 460
        let inspector = NSHostingController(rootView: FileInspector(model: presentation,
            close: { [weak owner] in owner?.properties(nil) }, test: { [weak owner] in owner?.testArchive(nil) }))
        infoItem = NSSplitViewItem(viewController: inspector)
        infoItem.minimumThickness = 250; infoItem.maximumThickness = 350
        infoItem.preferredThicknessFraction = 0.25; infoItem.canCollapse = true
        infoItem.isCollapsed = !UserDefaults.standard.bool(forKey: "showInspector")
        addSplitViewItem(placesItem); addSplitViewItem(files); addSplitViewItem(infoItem)
        splitView.dividerStyle = .thin
        updateKeyTips()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh() {
        guard let owner = owner else { return }
        presentation.update(from: owner.activePane, panes: owner.panes, busy: owner.isBusy)
    }
    func togglePlaces() {
        placesItem.isCollapsed.toggle()
        UserDefaults.standard.set(placesItem.isCollapsed, forKey: "sidebarHidden")
    }
    func toggleInfo() {
        infoItem.isCollapsed.toggle()
        if let window = owner?.window {
            window.minSize.width = minimumWidth
            if window.frame.width < window.minSize.width {
                var frame = window.frame; frame.size.width = window.minSize.width
                window.setFrame(frame, display: true)
            }
        }
        UserDefaults.standard.set(!infoItem.isCollapsed, forKey: "showInspector")
        refresh()
    }
    private var minimumWidth: CGFloat {
        (owner?.usesTwoPanes == true ? 1000 : 850) + (infoItem.isCollapsed ? 0 : 250)
    }
    func updateKeyTips() { tipsView?.isHidden = !UserDefaults.standard.bool(forKey: "showKeyTips") }
    func setTwoPanes(_ enabled: Bool) {
        secondPane.isCollapsed = !enabled
        updateKeyTips()
        if let window = owner?.window {
            window.minSize.width = minimumWidth
            if window.frame.width < minimumWidth {
                var frame = window.frame; frame.size.width = minimumWidth; window.setFrame(frame, display: true)
            }
        }
        filePanes.splitView.adjustSubviews()
    }
}

final class BrowserBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

private struct PlacesSidebar: View {
    @ObservedObject var model: BrowserPresentation
    let open: (BrowserPresentation.Place) -> Void
    let add: () -> Void
    let settings: () -> Void
    let shortcuts: () -> Void
    @AppStorage("keyMode") private var keyMode = "7z"
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Favorites") {
                    ForEach(model.folders) { place in placeRow(place) }
                    Button(action: add) { Label("Add Folder…", systemImage: "folder.badge.plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if !model.archives.isEmpty {
                    Section("Open Archives") { ForEach(model.archives) { place in placeRow(place) } }
                }
                if !model.recent.isEmpty {
                    Section("Recent Folders") { ForEach(model.recent.prefix(8)) { place in placeRow(place) } }
                }
            }
            .listStyle(.sidebar)
            .disabled(model.busy)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Picker("Keys", selection: $keyMode) {
                    Text("7-Zip").tag("7z"); Text("Mac").tag("mac")
                }.pickerStyle(.segmented).help("Choose 7-Zip function keys or Mac conventions")
                Button("Shortcut Map", action: shortcuts).buttonStyle(.link)
                Button(action: settings) { Label("Folder Access…", systemImage: "lock.shield") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.busy)
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func placeRow(_ place: BrowserPresentation.Place) -> some View {
        Button { open(place) } label: {
            HStack(spacing: 8) {
                Image(systemName: place.symbol).foregroundStyle(Color.accentColor).frame(width: 18)
                Text(place.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if !place.available { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .background(model.selectedPlace == place.id ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(place.location.display)
    }
}

private struct FileInspector: View {
    @ObservedObject var model: BrowserPresentation
    let close: () -> Void
    let test: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Info").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide Info")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 9) {
                        Image(systemName: model.symbol).font(.system(size: 46, weight: .light)).foregroundStyle(.tint).padding(.top, 8)
                        Text(model.title).font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                        Text(model.subtitle).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    if !model.details.isEmpty { detailGroup("Item", rows: model.details) }
                    if !model.archiveDetails.isEmpty {
                        detailGroup("Archive", rows: model.archiveDetails)
                        Button(action: test) { Label("Test Archive", systemImage: "checkmark.seal") }
                            .disabled(!model.canTest)
                    }
                }.padding(16)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func detailGroup(_ title: String, rows: [BrowserPresentation.Detail]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.name).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }.font(.callout)
                }
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct ShortcutTipBar: View {
    let showMap: () -> Void
    let close: () -> Void
    @AppStorage("keyMode") private var keyMode = "7z"
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").foregroundStyle(.tint)
            ViewThatFits(in: .horizontal) {
                hints(full: true)
                hints(full: false)
            }
            Spacer(minLength: 0)
            Button("Shortcut Map", action: showMap).buttonStyle(.link)
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide key tips")
        }
        .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }
    private func hints(full: Bool) -> some View {
        HStack(spacing: 9) {
            if full { Text(keyMode == "7z" ? "7-Zip keys are on." : "Mac keys are on.").fontWeight(.semibold) }
            if keyMode == "7z" {
                key("F5", "Copy"); key("F6", "Move")
                if full { key("F2", "Rename"); key("F9", "2 Panels") }
            } else {
                key("⌘Y", "Preview"); key("⌘I", "Info")
                if full { key("⌘⌫", "Delete") }
            }
        }.fixedSize()
    }
    private func key(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
            Text(label)
        }
    }
}

struct ShortcutMapView: View {
    struct Shortcut: Identifiable {
        let command: String
        let windows: String
        let sevenZip: String
        let mac: String
        var id: String { command }
    }
    @AppStorage("keyMode") private var keyMode = "7z"
    @State private var section = "keys"
    @State private var search = ""
    private let keys: [Shortcut] = [
        .init(command: "Open as Archive / Enter Folder", windows: "Enter", sevenZip: "↩", mac: "↩"),
        .init(command: "Up One Level", windows: "Backspace", sevenZip: "⌫ / ⌘↑", mac: "⌘↑"),
        .init(command: "Back / Forward", windows: "Alt+← / →", sevenZip: "⌘[ / ⌘]", mac: "⌘[ / ⌘]"),
        .init(command: "Edit Path", windows: "Alt+D", sevenZip: "⌘L", mac: "⌘L"),
        .init(command: "Search", windows: "—", sevenZip: "⌘F", mac: "⌘F"),
        .init(command: "Rename", windows: "F2", sevenZip: "F2", mac: "Edit → Rename"),
        .init(command: "Built-in Preview", windows: "F3", sevenZip: "F3 / Space / ⌘Y", mac: "Space / ⌘Y"),
        .init(command: "Copy / Move", windows: "F5 / F6", sevenZip: "F5 / F6", mac: "Edit → Copy / Move"),
        .init(command: "New Folder", windows: "F7", sevenZip: "F7 / ⇧⌘N", mac: "⇧⌘N"),
        .init(command: "Delete / Move to Trash", windows: "Delete / F8", sevenZip: "F8 / ⌘⌫", mac: "⌫ / ⌘⌫"),
        .init(command: "2 Panels", windows: "F9", sevenZip: "F9", mac: "View → 2 Panels"),
        .init(command: "Switch Panel", windows: "Tab", sevenZip: "Tab", mac: "Tab"),
        .init(command: "Add to Archive", windows: "Alt+A", sevenZip: "⇧⌘A", mac: "⇧⌘A"),
        .init(command: "Extract", windows: "Ctrl+Alt+E", sevenZip: "⇧⌘E", mac: "⇧⌘E"),
        .init(command: "Test Archive", windows: "Ctrl+Alt+T", sevenZip: "⇧⌘T", mac: "⇧⌘T"),
        .init(command: "Info", windows: "Alt+Enter", sevenZip: "⌘I", mac: "⌘I"),
        .init(command: "Icons / List / Details", windows: "View menu", sevenZip: "⌘1 / ⌘2 / ⌘3", mac: "⌘1 / ⌘2 / ⌘3")
    ]
    private let moved = [
        ("Tools → Options", "VibeZip → Settings (⌘,). Saved folder access is managed here too."),
        ("Properties", "The Info inspector (⌘I) stays open as you browse either pane."),
        ("Recycle Bin", "Delete moves filesystem items to Trash. Deleting archive entries rebuilds the archive."),
        ("Viewer", "Space, ⌘Y or F3 opens the built-in, read-only preview."),
        ("Two Panels", "F9 or the toolbar toggles a second browser. Tab changes the active pane."),
        ("Folder Bookmarks", "Authorized folders appear under Favorites. The system picker grants access.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Show", selection: $section) {
                    Text("Shortcuts").tag("keys"); Text("What Moved").tag("moved")
                }.pickerStyle(.segmented).fixedSize()
                Spacer()
                Picker("Key bindings", selection: $keyMode) {
                    Text("7-Zip").tag("7z"); Text("Mac").tag("mac")
                }.pickerStyle(.segmented).fixedSize()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            if section == "keys" {
                Table(keys.filter { search.isEmpty || $0.command.localizedCaseInsensitiveContains(search) }) {
                    TableColumn("Command", value: \.command).width(min: 190)
                    TableColumn("7-Zip on Windows", value: \.windows).width(150)
                    TableColumn("VibeZip, 7-Zip keys") { row in
                        Text(row.sevenZip).fontWeight(keyMode == "7z" ? .semibold : .regular)
                    }.width(160)
                    TableColumn("VibeZip, Mac keys") { row in
                        Text(row.mac).fontWeight(keyMode == "mac" ? .semibold : .regular)
                    }.width(170)
                }
            } else {
                List(moved.filter { search.isEmpty || ($0.0 + $0.1).localizedCaseInsensitiveContains(search) }, id: \.0) { title, text in
                    VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary) }.padding(.vertical, 5)
                }
            }
            Text("Return and double-click open items in both modes. Your Mac may require Fn for function keys.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(20).frame(width: 840, height: 540)
    }
}
#endif
