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
    @Published var title = L10n.tr("No selection")
    @Published var subtitle = L10n.tr("Choose a folder to get started")
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
            detail(pane.location.archive == nil ? L10n.tr("Where") : L10n.tr("Path"), pane.location.archive == nil ? (row.url?.deletingLastPathComponent().path ?? "") : row.path)
            if !row.isDirectory { detail(L10n.tr("Size"), UIFormat.bytes(row.size)) }
            if row.packedSize != nil { detail(L10n.tr("Packed size"), UIFormat.bytes(row.packedSize)) }
            detail(L10n.tr("Modified"), row.modified)
            if let member = row.member {
                detail(L10n.tr("CRC"), member.crc); detail(L10n.tr("Method"), member.method)
                detail(L10n.tr("Encrypted"), member.isEncrypted ? L10n.tr("Yes") : L10n.tr("No"))
            }
        } else if selected.count > 1 {
            title = L10n.tr("\(selected.count) items"); subtitle = L10n.tr("Selected in this folder"); symbol = "doc.on.doc"
            detail(L10n.tr("Files"), String(selected.filter { !$0.isDirectory }.count))
            detail(L10n.tr("Folders"), String(selected.filter(\.isDirectory).count))
            detail(L10n.tr("Size"), UIFormat.bytes(UIFormat.totalSize(selected)))
        } else {
            title = pane.location.archive?.url.lastPathComponent ?? pane.location.directory?.lastPathComponent ?? L10n.tr("No folder selected")
            if title.isEmpty { title = "Macintosh HD" }
            subtitle = pane.location.archive == nil ? L10n.tr("Folder") : L10n.tr("Archive")
            symbol = pane.location.archive == nil ? "folder" : "archivebox"
            detail(L10n.tr("Path"), pane.location.display)
            if !pane.location.isEmpty { detail(L10n.tr("Items"), String(pane.rows.count)) }
        }
        if let archive = pane.location.archive {
            archiveDetails = archive.listing.properties.sorted { $0.key < $1.key }
                .filter { ["Type", "Physical Size", "Headers Size", "Method", "Solid", "Blocks", "Encrypted headers", "Multivolume", "Volumes"].contains($0.key) && !$0.value.isEmpty }
                .map { Detail(name: L10n.string($0.key), value: $0.value) }
            archiveDetails.append(Detail(name: L10n.tr("Entries"), value: String(archive.listing.entries.count)))
            archiveDetails.append(Detail(name: L10n.tr("Unpacked size"), value: UIFormat.bytes(archive.listing.totalSize)))
            archiveDetails.append(Detail(name: L10n.tr("Access"), value: archive.canModify ? L10n.tr("Read and write") : L10n.tr("Read only")))
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
    init(owner: MainWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSHostingController(rootView: PlacesSidebar(model: presentation,
            open: { [weak owner] place in
                guard let owner = owner, owner.canAcceptCommands else { return }
                if owner.activePane.navigate(place.location) { owner.activate(owner.activePane) }
            }, add: { [weak owner] in owner?.chooseFolder(nil) },
            settings: { [weak owner] in owner?.showFolderAccess(nil) }))
        placesItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        placesItem.minimumThickness = 180; placesItem.maximumThickness = 280
        placesItem.preferredThicknessFraction = 0.19; placesItem.canCollapse = true
        placesItem.isCollapsed = UserDefaults.standard.bool(forKey: "sidebarHidden")
        let firstPane = NSSplitViewItem(viewController: owner.left); firstPane.minimumThickness = 330
        secondPane = NSSplitViewItem(viewController: owner.right); secondPane.minimumThickness = 330
        secondPane.canCollapse = true; secondPane.isCollapsed = true
        filePanes.addSplitViewItem(firstPane); filePanes.addSplitViewItem(secondPane)
        filePanes.splitView.dividerStyle = .thin
        let files = NSSplitViewItem(viewController: filePanes)
        files.minimumThickness = 460
        let inspector = NSHostingController(rootView: FileInspector(model: presentation,
            close: { [weak owner] in owner?.properties(nil) }, test: { [weak owner] in owner?.testArchive(nil) }))
        infoItem = NSSplitViewItem(viewController: inspector)
        infoItem.minimumThickness = 250; infoItem.maximumThickness = 350
        infoItem.preferredThicknessFraction = 0.25; infoItem.canCollapse = true
        infoItem.isCollapsed = !UserDefaults.standard.bool(forKey: "showInspector")
        addSplitViewItem(placesItem); addSplitViewItem(files); addSplitViewItem(infoItem)
        splitView.dividerStyle = .thin
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
    func setTwoPanes(_ enabled: Bool) {
        secondPane.isCollapsed = !enabled
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
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(L10n.tr("Favorites")) {
                    ForEach(model.folders) { place in placeRow(place) }
                    Button(action: add) { Label(L10n.tr("Add Folder…"), systemImage: "folder.badge.plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if !model.archives.isEmpty {
                    Section(L10n.tr("Open Archives")) { ForEach(model.archives) { place in placeRow(place) } }
                }
                if !model.recent.isEmpty {
                    Section(L10n.tr("Recent Folders")) { ForEach(model.recent.prefix(8)) { place in placeRow(place) } }
                }
            }
            .listStyle(.sidebar)
            .disabled(model.busy)
            Divider()
            Button(action: settings) { Label(L10n.tr("Folder Access…"), systemImage: "lock.shield") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.busy)
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
                Text(L10n.tr("Info")).font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help(L10n.tr("Hide Info"))
            }.padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 9) {
                        Image(systemName: model.symbol).font(.system(size: 46, weight: .light)).foregroundStyle(.tint).padding(.top, 8)
                        Text(model.title).font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                        Text(model.subtitle).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    if !model.details.isEmpty { detailGroup(L10n.tr("Item"), rows: model.details) }
                    if !model.archiveDetails.isEmpty {
                        detailGroup(L10n.tr("Archive"), rows: model.archiveDetails)
                        Button(action: test) { Label(L10n.tr("Test Archive"), systemImage: "checkmark.seal") }
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

#endif
