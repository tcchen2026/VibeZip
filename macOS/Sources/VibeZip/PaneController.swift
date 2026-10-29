#if os(macOS)
import AppKit
import VibeZipCore

final class FileTableView: NSTableView {
    var onFocus: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        onFocus?()
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        super.rightMouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Handles drops over the empty-state overlay and unused space around the file views.
final class FileDropView: NSView {
    var validateDrop: ((NSDraggingInfo) -> NSDragOperation)?
    var acceptDrop: ((NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = validateDrop?(sender) ?? []
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = operation.isEmpty ? 0 : 2
        return operation
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !(validateDrop?(sender) ?? []).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        return acceptDrop?(sender) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
}

final class ArchiveFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let service: ArchiveService
    let context: ArchiveContext
    let entry: BrowserRow
    let queue: OperationQueue
    let password: String?
    var completed: (() -> Void)?
    init(service: ArchiveService, context: ArchiveContext, entry: BrowserRow, queue: OperationQueue) {
        self.service = service; self.context = context; self.entry = entry; self.queue = queue; self.password = context.password
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        defer { DispatchQueue.main.async { [self] in completed?() } }
        do {
            let scratch = try ScratchDirectory(label: "drag")
            let token = CancellationToken()
            try service.extract(context.url, paths: [entry.path], indices: entry.isDirectory ? nil : entry.member?.index.map { [$0] }, to: scratch.url,
                layout: .relativeTo(ArchivePath.parent(of: entry.path)), password: password, token: token)
            let source = scratch.url.appendingPathComponent(entry.name)
            guard !SafeFileSystem.exists(url) else { throw FMError.message(L10n.tr("The drop destination already exists: \(url.path)")) }
            var report = TransferReport()
            try SafeFileSystem.merge(source, into: url, policy: .rename, token: token, report: &report)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

final class PaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var owner: MainWindowController?
    var location: BrowserLocation
    private(set) var rows: [BrowserRow] = []
    private var allRows: [BrowserRow] = []
    private var archiveListing: ArchiveListing?
    private var history: [BrowserLocation] = []
    private var historyIndex = -1
    private var loadingID = UUID()
    private var promiseDelegates: [ArchiveFilePromise] = []
    private let emptyState = NSStackView()
    private let emptyHeading = NSTextField(labelWithString: "")
    private let emptyExplanation = NSTextField(wrappingLabelWithString: "")
    private let emptyIcon = NSImageView()
    private let chooseButton = NSButton(title: L10n.tr("Choose Folder…"), target: nil, action: nil)
    private let upButton = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: L10n.tr("Up one level"))!, target: nil, action: nil)
    private let historyButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let table = FileTableView()
    let collection = FileCollectionView()
    private let gridScroll = NSScrollView()
    private var detailsHeader: NSTableHeaderView?
    private var syncingSelection = false
    private(set) var viewStyle = BrowserViewStyle(rawValue: UserDefaults.standard.integer(forKey: "browserViewStyle")) ?? .details
    private let locationBar = LocationBar()
    var address: NSTextField { locationBar.editor }
    let search = NSSearchField()
    let status = OperationStatusView()
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var canGoUp: Bool { !location.isEmpty && (location.directory.map { $0.path != "/" } ?? true) }
    var recentLocations: [BrowserLocation] {
        var seen = Set<String>()
        return history.reversed().filter { seen.insert($0.identity).inserted }
    }
    private var query: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearchingArchive: Bool { location.archive != nil && !query.isEmpty }
    private let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    init(directory: URL?) {
        location = directory.map(BrowserLocation.directory) ?? .none
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = BrowserBackgroundView()
        locationBar.canEdit = { [weak self] in self?.owner?.canAcceptCommands == true }
        locationBar.onSubmit = { [weak self] path in self?.addressEntered(path) }
        locationBar.onNavigate = { [weak self] location in
            guard let self = self, let owner = self.owner, owner.canAcceptCommands else { return }
            owner.activate(self)
            self.navigate(location)
        }
        locationBar.onCancel = { [weak self] in
            guard let self = self else { return }; self.owner?.activate(self)
        }
        search.placeholderString = L10n.tr("Search this folder")
        search.setAccessibilityLabel(L10n.tr("Search"))
        search.target = self; search.action = #selector(searchChanged); search.sendsSearchStringImmediately = true
        search.delegate = self
        table.headerView = NSTableHeaderView(); table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true; table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 29; table.intercellSpacing = NSSize(width: 10, height: 3)
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openDoubleClick)
        let columns: [(String, String, CGFloat)] = [
            ("name", L10n.tr("Name"), 300), ("location", L10n.tr("Location"), 240), ("size", L10n.tr("Size"), 100), ("packed", L10n.tr("Packed Size"), 100),
            ("modified", L10n.tr("Modified"), 156), ("type", L10n.tr("Type"), 100), ("crc", L10n.tr("CRC"), 95), ("method", L10n.tr("Method"), 135)
        ]
        let visibleColumns = Set(UserDefaults.standard.stringArray(forKey: "visibleBrowserColumns") ?? ["name", "size", "packed", "modified"])
        let columnMenu = NSMenu()
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title
            column.width = width; column.minWidth = id == "name" ? 140 : 65
            column.isHidden = id == "location" || (id != "name" && !visibleColumns.contains(id))
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
            if id != "location" {
                let item = NSMenuItem(title: title, action: #selector(toggleColumn), keyEquivalent: "")
                item.target = self; item.representedObject = id; columnMenu.addItem(item)
            }
        }
        table.headerView?.menu = columnMenu
        detailsHeader = table.headerView
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.onFocus = { [weak self] in guard let self = self else { return }; self.owner?.activate(self) }
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.registerForDraggedTypes(dropTypes)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 110, height: 100); flow.minimumInteritemSpacing = 8; flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = flow; collection.dataSource = self; collection.delegate = self
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.register(FileGridItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("file"))
        collection.onFocus = { [weak self] in guard let self = self else { return }; self.owner?.activate(self) }
        collection.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        collection.onOpen = { [weak self] in self?.owner?.openAsArchive(nil) }
        collection.registerForDraggedTypes(dropTypes)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        gridScroll.documentView = collection; gridScroll.hasVerticalScroller = true; gridScroll.autohidesScrollers = true
        emptyHeading.font = .systemFont(ofSize: 19, weight: .semibold)
        emptyExplanation.alignment = .center; emptyExplanation.textColor = .secondaryLabelColor
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = .init(pointSize: 48, weight: .light)
        chooseButton.target = self; chooseButton.action = #selector(chooseFolder); chooseButton.bezelStyle = .rounded
        emptyState.orientation = .vertical; emptyState.spacing = 12; emptyState.alignment = .centerX
        for child in [emptyIcon as NSView, emptyHeading, emptyExplanation, chooseButton] { emptyState.addArrangedSubview(child) }
        let listContainer = FileDropView()
        listContainer.registerForDraggedTypes(dropTypes)
        listContainer.validateDrop = { [weak self] info in
            guard let self = self else { return [] }
            return self.validateDrop(info, into: self.location)
        }
        listContainer.acceptDrop = { [weak self] info in
            guard let self = self else { return false }
            return self.acceptDrop(info, into: self.location)
        }
        for child in [scroll as NSView, gridScroll, emptyState] { child.translatesAutoresizingMaskIntoConstraints = false; listContainer.addSubview(child) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor), gridScroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            gridScroll.topAnchor.constraint(equalTo: listContainer.topAnchor), gridScroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: listContainer.widthAnchor, constant: -48)
        ])
        let pathContainer = NSView(); let statusContainer = NSView()
        upButton.target = self; upButton.action = #selector(goUp); upButton.bezelStyle = .texturedRounded
        upButton.toolTip = L10n.tr("Up one level (Backspace)"); upButton.isBordered = false
        historyButton.bezelStyle = .texturedRounded; historyButton.isBordered = false
        historyButton.toolTip = L10n.tr("Folders History")
        locationBar.translatesAutoresizingMaskIntoConstraints = false; search.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        for child in [upButton, locationBar, historyButton] {
            child.translatesAutoresizingMaskIntoConstraints = false; pathContainer.addSubview(child)
        }
        statusContainer.addSubview(status)
        let topSeparator = NSBox(); topSeparator.boxType = .separator
        let bottomSeparator = NSBox(); bottomSeparator.boxType = .separator
        let stack = NSStackView(views: [pathContainer, topSeparator, listContainer, bottomSeparator, statusContainer]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 0; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pathContainer.heightAnchor.constraint(equalToConstant: 50), pathContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            upButton.leadingAnchor.constraint(equalTo: pathContainer.leadingAnchor, constant: 10),
            upButton.centerYAnchor.constraint(equalTo: pathContainer.centerYAnchor), upButton.widthAnchor.constraint(equalToConstant: 28),
            locationBar.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 6),
            locationBar.trailingAnchor.constraint(equalTo: historyButton.leadingAnchor, constant: -4),
            locationBar.centerYAnchor.constraint(equalTo: pathContainer.centerYAnchor),
            locationBar.heightAnchor.constraint(equalToConstant: 32),
            historyButton.centerYAnchor.constraint(equalTo: pathContainer.centerYAnchor), historyButton.widthAnchor.constraint(equalToConstant: 32),
            historyButton.trailingAnchor.constraint(equalTo: pathContainer.trailingAnchor, constant: -8),
            topSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor), bottomSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.widthAnchor.constraint(equalTo: stack.widthAnchor), statusContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusContainer.heightAnchor.constraint(equalToConstant: 30),
            status.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        setViewStyle(viewStyle, focus: false)
    }
    override func viewDidLoad() { super.viewDidLoad(); navigate(location) }

    var selectedRows: [BrowserRow] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    var selectedPaths: [String] { selectedRows.map(\.path) }
    var selectedArchiveIndices: [UInt32]? {
        guard let archive = location.archive, !selectedRows.isEmpty else { return nil }
        var result = Set<UInt32>()
        for row in selectedRows {
            if row.isDirectory { result.formUnion(archive.listing.selected([row.path]).compactMap(\.index)) }
            else if let index = row.member?.index { result.insert(index) }
        }
        return result.sorted()
    }
    var selectedURLs: [URL] { selectedRows.compactMap(\.url) }
    var suggestedDirectory: URL? {
        location.directory ?? location.archive?.session.rootURL.deletingLastPathComponent()
    }
    @discardableResult func navigate(_ newLocation: BrowserLocation, record: Bool = true) -> Bool {
        guard owner?.isBusy != true else { return false }
        if let directory = newLocation.directory, owner?.ensureFolderAccess(directory) != true { return false }
        status.clearNotice()
        location = newLocation; search.stringValue = ""
        archiveListing = nil; allRows = []; rows = []; table.reloadData(); collection.reloadData()
        if record && !newLocation.isEmpty && (historyIndex < 0 || history[historyIndex].identity != newLocation.identity) {
            if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)..<history.count) }
            history.append(newLocation)
            if history.count > 24 { history.removeFirst() }
            historyIndex = history.count - 1
        }
        refresh(); return true
    }
    func refresh() {
        guard owner?.isBusy != true else { return }
        locationBar.show(path: location.display, components: location.breadcrumbs)
        updateEmptyState(loading: !location.isEmpty)
        upButton.isEnabled = canGoUp && owner?.isBusy != true
        updateHistory()
        search.isEnabled = !location.isEmpty
        search.placeholderString = location.archive == nil ? L10n.tr("Search this folder") : L10n.tr("Search archive")
        search.toolTip = location.archive == nil ? L10n.tr("Search names in this folder") : L10n.tr("Search names and paths throughout this archive")
        owner?.window?.toolbar?.validateVisibleItems()
        let id = UUID(); loadingID = id; status.summary = L10n.tr("Reading…")
        if location.isEmpty { status.summary = L10n.tr("Open an archive or choose a folder"); owner?.updateTitle(); return }
        let current = location
        let listingSnapshot = location.archive?.listing
        let showHidden = UserDefaults.standard.bool(forKey: "showHidden")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<[BrowserRow], Error>
            do {
                switch current {
                case .none: result = .success([])
                case .directory(let directory):
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                        options: showHidden ? [] : [.skipsHiddenFiles])
                    let rows = try files.map { try BrowserRow(url: $0, values: $0.resourceValues(forKeys: keys)) }
                    result = .success(rows)
                case .archive(_, let prefix):
                    result = .success((listingSnapshot?.children(of: prefix) ?? []).map(BrowserRow.init(entry:)))
                }
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self, self.loadingID == id else { return }
                switch result {
                case .success(let rows): self.allRows = rows; self.archiveListing = listingSnapshot; self.applyFilter()
                case .failure(let error):
                    self.allRows = []; self.rows = []; self.table.reloadData()
                    self.owner?.reportError(error)
                }
                self.owner?.updateTitle()
            }
        }
    }
    func discardRevokedLocations() {
        let access = DirectoryAccessStore.shared
        func allowed(_ location: BrowserLocation) -> Bool {
            if let directory = location.directory { return access.allows(directory) }
            if let archive = location.archive { return access.canReadFile(archive.session.rootURL) }
            return true
        }
        history.removeAll { !allowed($0) }
        historyIndex = history.lastIndex { $0.identity == location.identity } ?? -1
        if !allowed(location) { navigate(.none, record: false) }
        else { refresh() }
    }
    @objc private func chooseFolder() { owner?.chooseFolder(nil) }
    func setActive(_ active: Bool, framed: Bool) {
        view.wantsLayer = true; view.layer?.cornerRadius = framed ? 10 : 0
        view.layer?.borderWidth = framed ? (active ? 2 : 1) : 0
        view.layer?.borderColor = (active ? NSColor.controlAccentColor.withAlphaComponent(0.65) : NSColor.separatorColor).cgColor
    }
    private func updateEmptyState(loading: Bool = false) {
        emptyState.isHidden = loading || (!location.isEmpty && !rows.isEmpty)
        table.enclosingScrollView?.isHidden = location.isEmpty || viewStyle == .icons
        gridScroll.isHidden = location.isEmpty || viewStyle != .icons
        emptyIcon.image = NSImage(systemSymbolName: query.isEmpty ? "folder" : "magnifyingglass", accessibilityDescription: nil)
        emptyHeading.stringValue = location.isEmpty ? L10n.tr("Open an archive or choose a folder") : (query.isEmpty ? L10n.tr("Empty Folder") : L10n.tr("No Results"))
        emptyExplanation.stringValue = location.isEmpty ? L10n.tr("Drop an archive here to open it.\nChoose a folder to browse its contents.") :
            (query.isEmpty ? L10n.tr("Drop files here or use Add to put something in it.") : L10n.tr("No items match “\(query)”. Try a different search."))
        chooseButton.isHidden = !location.isEmpty
    }
    private func updateHistory() {
        historyButton.removeAllItems()
        historyButton.addItem(withTitle: "")
        historyButton.item(at: 0)?.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: L10n.tr("Folders History"))
        for location in recentLocations {
            let item = NSMenuItem(title: location.display, action: #selector(visitHistory), keyEquivalent: "")
            item.target = self; item.representedObject = location; historyButton.menu?.addItem(item)
        }
        historyButton.isEnabled = !recentLocations.isEmpty
    }
    @objc private func visitHistory(_ sender: NSMenuItem) {
        guard owner?.canAcceptCommands == true, let location = sender.representedObject as? BrowserLocation else { return }
        if navigate(location) { owner?.activate(self) }
    }
    private func applyFilter() {
        let selection = Set(selectedRows.map(\.identity))
        let query = self.query
        if let listing = archiveListing, !query.isEmpty {
            rows = listing.search(query).map(BrowserRow.init(entry:))
        } else {
            rows = allRows.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        }
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.isHidden = !isSearchingArchive || viewStyle == .list
        let descriptor = table.sortDescriptors.first
        let key = descriptor?.key ?? "name"; let ascending = descriptor?.ascending ?? true
        rows.sort { first, second in
            if first.isDirectory != second.isDirectory { return first.isDirectory }
            var comparison: ComparisonResult
            switch key {
            case "size", "packed":
                let a = (key == "size" ? first.size : first.packedSize) ?? 0
                let b = (key == "size" ? second.size : second.packedSize) ?? 0
                comparison = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            default:
                func value(_ row: BrowserRow) -> String {
                    switch key { case "modified": return row.modified; case "type": return row.type
                    case "location": return ArchivePath.parent(of: row.path)
                    case "crc": return row.member?.crc ?? ""; case "method": return row.member?.method ?? ""; default: return row.name }
                }
                comparison = value(first).localizedStandardCompare(value(second))
            }
            if comparison == .orderedSame { comparison = first.path.localizedStandardCompare(second.path) }
            if comparison == .orderedSame { comparison = first.identity.compare(second.identity) }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        table.reloadData()
        collection.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selection.contains(rows[$0].identity) }), byExtendingSelection: false)
        updateEmptyState()
        updateStatus()
    }
    private func updateStatus() {
        let selected = selectedRows
        let total = UIFormat.totalSize(selected.isEmpty ? rows : selected)
        let count: String
        if isSearchingArchive, let archive = location.archive {
            count = rows.count == 1 ? L10n.tr("1 match in \(archive.url.lastPathComponent)") :
                L10n.tr("\(rows.count) matches in \(archive.url.lastPathComponent)")
        } else { count = query.isEmpty ? L10n.tr("\(rows.count) items") : L10n.tr("\(rows.count) of \(allRows.count) items") }
        status.summary = count + (location.archive?.canModify == false ? L10n.tr("  ·  Read only") : "") +
            (selected.isEmpty ? "  ·  \(UIFormat.bytes(total))" : L10n.tr("  ·  Selected \(selected.count) items  ·  \(UIFormat.bytes(total))"))
        status.context = location.archive?.listing.format.uppercased() ?? ""
        owner?.window?.toolbar?.validateVisibleItems()
        owner?.browserLayout?.refresh()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let item = rows[row]; let id = column.identifier.rawValue
        if id == "name" {
            let identifier = NSUserInterfaceItemIdentifier("name-cell")
            let cell = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeNameCell(identifier)
            cell.textField?.stringValue = (item.member?.isEncrypted == true ? "🔒 " : "") + item.name
            cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.type)
            cell.imageView?.contentTintColor = item.isDirectory ? .systemBlue : (item.symbol == "archivebox.fill" ? .systemOrange : .secondaryLabelColor)
            cell.toolTip = item.path; return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("text-" + id)
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? TableTextCellView ?? TableTextCellView(identifier: identifier)
        let field = cell.label
        field.font = (id == "size" || id == "packed") ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        field.alignment = (id == "size" || id == "packed") ? .right : .left
        switch id {
        case "size": field.stringValue = item.isDirectory ? "—" : UIFormat.bytes(item.size)
        case "packed": field.stringValue = item.isDirectory ? "—" : UIFormat.bytes(item.packedSize)
        case "modified": field.stringValue = item.modified
        case "location": field.stringValue = "/" + ArchivePath.parent(of: item.path)
        case "type": field.stringValue = item.type
        case "crc": field.stringValue = item.member?.crc ?? ""
        case "method": field.stringValue = item.member?.method ?? ""
        default: field.stringValue = ""
        }
        field.textColor = .secondaryLabelColor; cell.toolTip = field.stringValue
        return cell
    }
    private func makeNameCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = identifier
        let image = NSImageView(); let text = NSTextField(labelWithString: "")
        text.usesSingleLineMode = true; text.lineBreakMode = .byTruncatingMiddle; text.font = .systemFont(ofSize: 13)
        text.setContentHuggingPriority(.required, for: .vertical)
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        image.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image); cell.addSubview(text); cell.imageView = image; cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        syncingSelection = true
        let selection = Set(table.selectedRowIndexes.map { IndexPath(item: $0, section: 0) })
        if collection.selectionIndexPaths != selection { collection.selectionIndexPaths = selection }
        syncingSelection = false
        updateStatus()
    }
    func focusFiles() { view.window?.makeFirstResponder(viewStyle == .icons ? collection : table) }
    func setViewStyle(_ style: BrowserViewStyle, focus: Bool = true) {
        viewStyle = style; UserDefaults.standard.set(style.rawValue, forKey: "browserViewStyle")
        table.headerView = style == .list ? nil : detailsHeader
        let visible = Set(UserDefaults.standard.stringArray(forKey: "visibleBrowserColumns") ?? ["name", "size", "packed", "modified"])
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            column.isHidden = id == "name" ? false : (style == .list || (id == "location" ? !isSearchingArchive : !visible.contains(id)))
        }
        updateEmptyState()
        if focus { focusFiles() }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("file"), for: indexPath) as! FileGridItem
        item.configure(rows[indexPath.item]); return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncGridSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncGridSelection() }
    private func syncGridSelection() {
        guard !syncingSelection else { return }
        let selected = IndexSet(collection.selectionIndexPaths.map(\.item))
        if selected != table.selectedRowIndexes { table.selectRowIndexes(selected, byExtendingSelection: false) }
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        tableView(table, pasteboardWriterForRow: indexPath.item)
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let indexPath = proposedIndexPath.pointee as IndexPath
        let row = dropOperation.pointee == .on ? indexPath.item : -1
        let destination = dropLocation(forRow: row)
        let operation = validateDrop(draggingInfo, into: destination)
        if destination.identity == location.identity {
            dropOperation.pointee = .before
            proposedIndexPath.pointee = IndexPath(item: rows.count, section: 0) as NSIndexPath
        }
        return operation
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        acceptDrop(draggingInfo, into: dropLocation(forRow: dropOperation == .on ? indexPath.item : -1))
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilter() }
    @objc func searchChanged() { applyFilter() }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === search { applyFilter() } }
    private func addressEntered(_ path: String) {
        guard owner?.canAcceptCommands == true else { return }
        let path = UserPath.expand(path)
        owner?.activate(self)
        var context = location.archive
        while let archive = context {
            let base = archive.session.displayPath
            if path == base { navigate(.archive(archive, "")); return }
            if path.hasPrefix(base + " ▸ /") {
                let prefix = String(path.dropFirst((base + " ▸ /").count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let folderExists = archive.listing.children(of: ArchivePath.parent(of: prefix)).contains { $0.path == prefix && $0.isDirectory }
                if prefix.isEmpty || folderExists { navigate(.archive(archive, prefix)) }
                else { owner?.reportError(FMError.message(L10n.tr("The folder does not exist in this archive."))) }
                return
            }
            context = archive.returnLocation?.archive
        }
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if let directory = suggestedDirectory { url = directory.appendingPathComponent(path).standardizedFileURL }
        else { owner?.reportError(FMError.message(L10n.tr("Enter an absolute path or choose a folder first."))); return }
        owner?.openURL(url, in: self)
    }
    @objc func goBack() {
        guard owner?.isBusy != true, historyIndex > 0 else { return }
        let index = historyIndex - 1
        if navigate(history[index], record: false) { historyIndex = index; owner?.updateTitle() }
    }
    @objc func goForward() {
        guard owner?.isBusy != true, historyIndex + 1 < history.count else { return }
        let index = historyIndex + 1
        if navigate(history[index], record: false) { historyIndex = index; owner?.updateTitle() }
    }
    @objc func goUp() {
        switch location {
        case .none: break
        case .directory(let url): navigate(.directory(url.deletingLastPathComponent()))
        case .archive(let archive, let prefix):
            if !prefix.isEmpty { navigate(.archive(archive, ArchivePath.parent(of: prefix))) }
            else { navigate(archive.returnLocation ?? .directory(archive.url.deletingLastPathComponent())) }
        }
    }
    @objc private func openDoubleClick() { owner?.activate(self); owner?.openAsArchive(nil) }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard owner?.isBusy != true, !location.isEmpty else { return false }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            // Preserve existing keyboard behavior after removal of the mode picker.
            let macKeys = UserDefaults.standard.string(forKey: "keyMode") == "mac"
            if macKeys && [120, 99, 96, 97, 98, 100, 101].contains(event.keyCode) { return false }
            switch event.keyCode {
            case 36, 76: owner?.openAsArchive(nil)
            case 49: owner?.previewSelected(nil)
            case 51: if macKeys { owner?.deleteSelected(nil) } else { goUp() }
            case 48: if owner?.usesTwoPanes == true { owner?.switchPane() } else { return false }
            case 101: owner?.toggleTwoPanels(nil)
            case 120: owner?.renameSelected(nil)
            case 99: owner?.previewSelected(nil)
            case 96: owner?.copyTo(nil)
            case 97: owner?.moveTo(nil)
            case 98: owner?.newFolder(nil)
            case 100, 117: owner?.deleteSelected(nil)
            default: return false
            }
            return true
        }
        return false
    }
    func selectAllRows() { table.selectAll(nil) }
    func invertSelection() {
        let inverse = IndexSet(rows.indices.filter { !table.selectedRowIndexes.contains($0) })
        table.selectRowIndexes(inverse, byExtendingSelection: false)
    }
    func focusAddress() { locationBar.beginEditing() }
    func focusSearch() { view.window?.makeFirstResponder(search) }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != "name",
              let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
        column.isHidden.toggle()
        UserDefaults.standard.set(table.tableColumns.filter { !$0.isHidden && $0.identifier.rawValue != "location" }.map { $0.identifier.rawValue },
                                  forKey: "visibleBrowserColumns")
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String,
              let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return false }
        item.state = column.isHidden ? .off : .on
        return id != "name"
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard owner?.isBusy != true, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        if let url = item.url { return url as NSURL }
        guard let owner = owner, let archive = location.archive, owner.obtainPassword(archive) else { return nil }
        let delegate = ArchiveFilePromise(service: owner.service, context: archive, entry: item, queue: owner.workQueue)
        promiseDelegates.append(delegate)
        delegate.completed = { [weak self, weak delegate] in self?.promiseDelegates.removeAll { $0 === delegate } }
        let provider = NSFilePromiseProvider(fileType: item.isDirectory ? "public.folder" : "public.data", delegate: delegate)
        return provider
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let destination = dropLocation(forRow: dropOperation == .on ? row : -1)
        let operation = validateDrop(info, into: destination)
        if destination.identity == location.identity { tableView.setDropRow(-1, dropOperation: .above) }
        return operation
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        acceptDrop(info, into: dropLocation(forRow: dropOperation == .on ? row : -1))
    }

    private func dropLocation(forRow row: Int) -> BrowserLocation {
        guard rows.indices.contains(row), rows[row].isDirectory, !rows[row].isLink else { return location }
        if let archive = location.archive { return .archive(archive, rows[row].path) }
        if let url = rows[row].url { return .directory(url) }
        return location
    }

    private func validateDrop(_ info: NSDraggingInfo, into destination: BrowserLocation) -> NSDragOperation {
        guard let owner = owner, owner.canAcceptCommands, !owner.hasActiveOperations else { return [] }
        let pasteboard = info.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            // Empty and read-only archive panes can open one item, but cannot add files.
            let opensOnly = destination.isEmpty || destination.archive?.canModify == false
            guard !opensOnly || pasteboard.pasteboardItems?.count == 1 else { return [] }
            return .copy
        }
        if destination.directory != nil, pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return .copy }
        return []
    }

    private func acceptDrop(_ info: NSDraggingInfo, into destination: BrowserLocation) -> Bool {
        guard let owner = owner, !validateDrop(info, into: destination).isEmpty else { return false }
        owner.activate(self)
        let pasteboard = info.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return owner.receiveDropped(urls, in: self, into: destination)
        }
        if let directory = destination.directory,
           let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty, owner.ensureFolderAccess(directory) {
            for promise in promises {
                promise.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: owner.workQueue) { [weak self] _, error in
                    DispatchQueue.main.async {
                        if let error = error { self?.owner?.reportError(error) }
                        self?.refresh()
                    }
                }
            }
            return true
        }
        return false
    }
}
#endif
