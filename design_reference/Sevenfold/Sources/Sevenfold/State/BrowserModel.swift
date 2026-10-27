import SwiftUI
import AppKit

enum BrowserSheet: Identifiable {
    case add(sources: [FileNode], destination: FileNode)
    case extract(archive: FileNode, items: [FileNode]?)
    case transfer(move: Bool, items: [FileNode])
    case checksum(items: [FileNode], algorithm: String)
    case split(FileNode)
    case comment(FileNode)
    case match(select: Bool)
    case help
    case progress(OperationModel)

    var id: String {
        switch self {
        case .add: "add"
        case .extract: "extract"
        case .transfer(let move, _): move ? "move" : "copy"
        case .checksum: "checksum"
        case .split: "split"
        case .comment: "comment"
        case .match(let select): select ? "select" : "deselect"
        case .help: "help"
        case .progress(let op): "progress-\(op.id)"
        }
    }
}

enum BrowserAlert: Identifiable {
    case newFolder
    case password(archive: FileNode, path: String)
    case replace(name: String, folder: String)
    case modified(FileNode)
    case message(title: String, text: String)

    var id: String {
        switch self {
        case .newFolder: "newFolder"
        case .password: "password"
        case .replace(let name, _): "replace-\(name)"
        case .modified(let n): "modified-\(n.id)"
        case .message(let t, _): "message-\(t)"
        }
    }
}

enum ReplaceChoice { case replace, replaceAll, keepBoth, skip, stop }

@MainActor @Observable
final class BrowserModel {
    let store: ArchiveStore
    let panes: [PaneState]
    var activeIndex = 0
    var twoPanels = false
    var showInspector = false
    var sheet: BrowserSheet?
    var alert: BrowserAlert?
    var alertText = ""
    var pendingDelete: [FileNode]?
    var backgroundOperation: OperationModel?
    var quickLookURL: URL?
    var toast: String?

    @ObservationIgnored var openWindow: ((String) -> Void)?
    @ObservationIgnored private var lastSheetClose = Date.distantPast
    @ObservationIgnored private var replaceReply: CheckedContinuation<ReplaceChoice, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(store: ArchiveStore) {
        self.store = store
        let start = Paths.home + "/Downloads/Kestrel-4.2.0.7z/Kestrel-4.2.0"
        let left = PaneState(store: store, path: start)
        left.backStack = [Paths.home + "/Downloads", Paths.home + "/Downloads/Kestrel-4.2.0.7z"]
        left.selection = Set(left.node.children.filter { $0.name == "README.md" || $0.name == "CHANGELOG.md" }.map(\.id))
        panes = [left, PaneState(store: store, path: Paths.home + "/Desktop")]
        store.noteVisit(left.node)
    }

    var active: PaneState { panes[twoPanels ? activeIndex : 0] }
    var other: PaneState { panes[twoPanels ? 1 - activeIndex : 1] }

    var title: String { active.archive?.name ?? (active.node.parent == nil ? "Macintosh HD" : active.node.name) }

    var subtitle: String {
        let node = active.node
        if let archive = active.archive {
            let inside = String(node.path.dropFirst(archive.path.count))
            return "\(archive.archive?.format.title ?? "") archive · \(inside.isEmpty ? "/" : inside)"
        }
        return Paths.pretty(node.parent?.path ?? "/")
    }

    func activate(_ pane: PaneState) {
        if let i = panes.firstIndex(where: { $0 === pane }), twoPanels { activeIndex = i }
    }

    // MARK: Sheets, alerts, toasts

    func present(_ next: BrowserSheet) {
        Task { await settle(); sheet = next }
    }

    func closeSheet() {
        sheet = nil
        lastSheetClose = .now
    }

    /// Waits for a closing sheet to finish its animation before presenting something else.
    private func settle() async {
        if sheet != nil { closeSheet() }
        let wait = 0.35 - Date.now.timeIntervalSince(lastSheetClose)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.8))
            if !Task.isCancelled { toast = nil }
        }
    }

    func message(_ title: String, _ text: String) {
        alert = .message(title: title, text: text)
    }

    private func askReplace(_ name: String, in folder: FileNode) async -> ReplaceChoice {
        await settle()
        return await withCheckedContinuation { continuation in
            replaceReply = continuation
            alert = .replace(name: name, folder: Paths.pretty(folder.path))
        }
    }

    func answerReplace(_ choice: ReplaceChoice) {
        replaceReply?.resume(returning: choice)
        replaceReply = nil
    }

    // MARK: Operations (7-Zip's progress window)

    func run(_ kind: OperationKind, title: String, detail: String, bytes: Int64, files: Int, ratio: Double, speed: Double = 260e6) async -> Bool {
        let op = OperationModel(kind: kind, title: title, detail: detail, bytes: bytes, files: files, ratio: ratio, speed: speed)
        await settle()
        sheet = .progress(op)
        let finished = await op.run()
        if case .progress(let shown)? = sheet, shown === op { closeSheet() }
        if backgroundOperation === op { backgroundOperation = nil }
        if !finished { flash("\(kind.rawValue) cancelled") }
        return finished
    }

    func sendToBackground(_ op: OperationModel) {
        backgroundOperation = op
        closeSheet()
    }

    func bringToFront(_ op: OperationModel) {
        backgroundOperation = nil
        present(.progress(op))
    }

    private func updateArchive(_ archive: FileNode, _ change: () -> Void) async -> Bool {
        let info = archive.archive
        guard await run(.updating, title: "Updating \(archive.name)", detail: "7-Zip rewrites the archive with the change",
                        bytes: max(info?.physicalSize ?? 0, 4_000_000), files: info?.files ?? 1, ratio: 0.3, speed: 900e6) else { return false }
        change()
        archive.modified = .now
        Packer.pack(archive)
        return true
    }

    // MARK: Navigation

    func go(_ pane: PaneState, to raw: String, push: Bool = true, select name: String? = nil) {
        guard let node = store.resolve(raw), node.isContainer else {
            flash("There is no folder “\(Paths.pretty(raw))”")
            return
        }
        if let locked = sequence(first: node, next: { $0.parent }).first(where: { $0.archive?.locked == true }) {
            alertText = ""
            alert = .password(archive: locked, path: node.path)
            return
        }
        let path = node.path
        if push, path != pane.path {
            pane.backStack.append(pane.path)
            pane.forwardStack.removeAll()
        }
        pane.path = path
        pane.selection = []
        pane.filter = ""
        pane.renaming = nil
        pane.editingPath = false
        if let name, let child = node.children.first(where: { $0.name == name }) { pane.selection = [child.id] }
        store.noteVisit(node)
    }

    func unlock(_ archive: FileNode, thenOpen path: String) {
        guard !alertText.isEmpty else { flash("Enter the password to open “\(archive.name)”"); return }
        archive.archive?.locked = false
        go(active, to: path)
    }

    func up(_ pane: PaneState) {
        guard let parent = pane.node.parent else { return }
        go(pane, to: parent.path, select: pane.node.name)
    }

    func open(_ ids: Set<UUID>, in pane: PaneState) {
        activate(pane)
        if ids.contains(FileRow.parentID) { up(pane); return }
        guard let node = pane.rows(showParent: false).first(where: { ids.contains($0.id) })?.node else { return }
        if node.isContainer { go(pane, to: node.path); return }
        flash(pane.isInArchive
              ? "Extracted “\(node.name)” to a temporary folder and opened it in \(Fmt.app(for: node))"
              : "Opening “\(node.name)” in \(Fmt.app(for: node))")
    }

    // MARK: Command availability and dispatch

    func isEnabled(_ command: Command) -> Bool {
        let pane = active
        let selected = pane.selectedNodes()
        let one = selected.count == 1 ? selected.first : nil
        switch command {
        case .open, .openInside, .openOutside, .quickLook, .rename: return one != nil
        case .edit: return one.map { $0.kind != .folder } ?? false
        case .add, .copyTo, .checksum: return !selected.isEmpty
        case .moveTo, .delete: return !selected.isEmpty
        case .extract, .test: return pane.isInArchive || selected.contains { $0.kind == .archive }
        case .comment: return pane.archive?.archive?.format == .zip
        case .split: return (one.map { $0.kind != .folder } ?? false) && !pane.isInArchive
        case .combine: return (one?.name.hasSuffix(".001") ?? false) && !pane.isInArchive
        case .up: return pane.node.parent != nil
        case .back: return !pane.backStack.isEmpty
        case .forward: return !pane.forwardStack.isEmpty
        default: return true
        }
    }

    func perform(_ command: Command) {
        guard sheet == nil, alert == nil else { return }
        guard isEnabled(command) else { NSSound.beep(); return }
        let pane = active
        let selected = pane.selectedNodes()
        switch command {
        case .open: open(pane.selection, in: pane)
        case .openInside:
            if let node = selected.first, node.isContainer { go(pane, to: node.path) }
            else { message("Can not open the file as archive", "“\(selected.first?.name ?? "")” is not an archive in any format Sevenfold reads.") }
        case .openOutside:
            if let node = selected.first { flash("Opening “\(node.name)” in \(node.kind == .folder ? "Finder" : Fmt.app(for: node))") }
        case .quickLook: if let node = selected.first { quickLook(node) }
        case .edit: if let node = selected.first { edit(node, in: pane) }
        case .add:
            let destination = pane.archive?.outermostArchive?.parent ?? pane.node
            present(.add(sources: selected, destination: destination))
        case .extract:
            if let archive = pane.archive {
                present(.extract(archive: archive, items: selected.isEmpty ? nil : selected))
            } else if let archive = selected.first(where: { $0.kind == .archive }) {
                present(.extract(archive: archive, items: nil))
            }
        case .test: Task { await test() }
        case .rename: pane.renaming = selected.first?.id
        case .copyTo: present(.transfer(move: false, items: selected))
        case .moveTo: present(.transfer(move: true, items: selected))
        case .delete: pendingDelete = selected
        case .info: showInspector.toggle()
        case .comment: if let archive = pane.archive { present(.comment(archive)) }
        case .checksum: present(.checksum(items: selected, algorithm: "CRC-32"))
        case .split: if let node = selected.first { present(.split(node)) }
        case .combine: if let node = selected.first { Task { await combine(node) } }
        case .newFolder: alertText = "New Folder"; alert = .newFolder
        case .selectMatching: present(.match(select: true))
        case .deselectMatching: present(.match(select: false))
        case .invertSelection:
            let all = Set(pane.rows(showParent: false).map(\.id))
            pane.selection = all.subtracting(pane.selection)
        case .viewLarge: pane.style = .largeIcons
        case .viewSmall: pane.style = .smallIcons
        case .viewList: pane.style = .list
        case .viewDetails: pane.style = .details
        case .sortName: pane.sort(by: \FileRow.name)
        case .sortType: pane.sort(by: \FileRow.type)
        case .sortDate: pane.sort(by: \FileRow.modified)
        case .sortSize: pane.sort(by: \FileRow.size)
        case .unsorted: pane.sortOrder = []
        case .flatView: pane.flat.toggle()
        case .twoPanels: twoPanels.toggle(); if !twoPanels { activeIndex = 0 }
        case .up: up(pane)
        case .back:
            guard let previous = pane.backStack.popLast() else { return }
            pane.forwardStack.append(pane.path)
            go(pane, to: previous, push: false)
        case .forward:
            guard let next = pane.forwardStack.popLast() else { return }
            pane.backStack.append(pane.path)
            go(pane, to: next, push: false)
        case .goToFolder: pane.editingPath = true
        case .refresh: flash("Refreshed \(title)")
        case .benchmark: openWindow?(WindowID.benchmark)
        case .help: present(.help)
        }
    }

    func openBookmark(_ index: Int) {
        let path = Prefs.bookmarks[index]
        guard !path.isEmpty else { NSSound.beep(); return }
        go(active, to: path)
    }

    func setBookmark(_ index: Int) {
        var list = Prefs.bookmarks
        list[index] = active.path
        Prefs.bookmarks = list
        flash("Bookmark \(index) is now \(Paths.pretty(active.path)). Press ⌥\(index) to open it.")
    }

    // MARK: File actions

    func quickLook(_ node: FileNode) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sevenfold Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(node.kind == .folder ? node.name + ".txt" : node.name)
        let text = SampleText.preview[node.name]
            ?? "\(node.name)\n\(Fmt.kind(node)) · \(Fmt.human(node.totalSize))\n\nIn the shipping app, Sevenfold extracts the item to a temporary folder and Quick Look previews the real file."
        try? text.write(to: url, atomically: true, encoding: .utf8)
        quickLookURL = url
    }

    private func edit(_ node: FileNode, in pane: PaneState) {
        flash("Editing “\(node.name)” in \(Prefs.editor)")
        guard pane.isInArchive else { return }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            alert = .modified(node)
        }
    }

    func saveEdited(_ node: FileNode) async {
        guard let archive = node.enclosingArchive else { return }
        if await updateArchive(archive, { node.modified = .now; node.size += 214 }) {
            flash("Updated “\(node.name)” in \(archive.name)")
        }
    }

    func rename(_ node: FileNode, to raw: String, in pane: PaneState) async {
        pane.renaming = nil
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard name != node.name else { return }
        guard !name.isEmpty, !name.contains("/") else { flash("A name can’t be empty or contain “/”"); return }
        guard let parent = node.parent, !parent.children.contains(where: { $0 !== node && $0.name == name }) else {
            flash("“\(name)” is already taken. Choose a different name.")
            return
        }
        if let archive = pane.archive {
            _ = await updateArchive(archive) { node.name = name }
        } else {
            node.name = name
        }
        pane.selection = [node.id]
    }

    func createFolder() async {
        let pane = active
        let folder = pane.node
        let name = alertText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { flash("Enter a folder name without “/”"); return }
        guard !folder.children.contains(where: { $0.name == name }) else { flash("“\(name)” already exists here"); return }
        let new = FileNode(name: name, kind: .folder, modified: .now)
        if let archive = pane.archive {
            guard await updateArchive(archive, { folder.add(new) }) else { return }
        } else {
            folder.add(new)
        }
        pane.selection = [new.id]
    }

    func delete(_ nodes: [FileNode]) async {
        let pane = active
        let what = nodes.count == 1 ? "“\(nodes[0].name)”" : "\(nodes.count) items"
        if let archive = pane.archive {
            guard await updateArchive(archive, { for n in nodes { n.parent?.remove(n) } }) else { return }
            flash("Deleted \(what) from \(archive.name)")
        } else {
            for n in nodes { n.parent?.remove(n) }
            flash("Moved \(what) to the Trash")
        }
        pane.selection = []
    }

    func setComment(_ text: String, on archive: FileNode) async {
        if await updateArchive(archive, { archive.archive?.comment = text }) { flash("Comment saved") }
    }

    /// Copy, move, extract (archive → disk) or add (disk → archive), depending on source and destination.
    @discardableResult
    func transfer(_ items: [FileNode], to destination: FileNode, move: Bool,
                  policy: ExtractOptions.Overwrite = .ask, flatten: Bool = false, title: String? = nil) async -> Bool {
        guard !items.isEmpty, destination.isContainer else { return false }
        for item in items where sequence(first: destination, next: { $0.parent }).contains(where: { $0 === item }) {
            message("Can’t copy a folder into itself", "“\(item.name)” contains the destination folder.")
            return false
        }
        let sourceArchive = items[0].parent?.enclosingArchive
        let targetArchive = destination.enclosingArchive
        let nodes = flatten ? items.flatMap { $0.kind == .folder ? $0.allFiles() : [$0] } : items

        var plan: [(node: FileNode, choice: ReplaceChoice?)] = []
        var sticky: ReplaceChoice? = switch policy {
            case .ask: nil
            case .overwrite: .replace
            case .skip: .skip
            case .renameExtracted, .renameExisting: .keepBoth
        }
        for node in nodes {
            guard let existing = destination.children.first(where: { $0.name == node.name }) else { plan.append((node, nil)); continue }
            if existing === node { if !move { plan.append((node, .keepBoth)) }; continue }
            var choice = sticky
            if choice == nil {
                let answer = await askReplace(node.name, in: destination)
                switch answer {
                case .stop: return false
                case .replaceAll: sticky = .replace; choice = .replace
                default: choice = answer
                }
            }
            if choice != .skip { plan.append((node, choice)) }
        }
        guard !plan.isEmpty else { flash("Nothing to do. Every item was skipped."); return false }

        let kind: OperationKind = sourceArchive != nil && targetArchive == nil ? .extracting
            : targetArchive != nil && targetArchive !== sourceArchive ? .compressing : (move ? .moving : .copying)
        let bytes = plan.reduce(Int64(0)) { $0 + $1.node.totalSize }
        let files = plan.reduce(0) { $0 + $1.node.fileCount }
        let label = title ?? "\(kind.rawValue) \(plan.count) item\(plan.count == 1 ? "" : "s")"
        guard await run(kind, title: label, detail: "to \(Paths.pretty(destination.path))", bytes: bytes, files: files,
                        ratio: kind == .compressing ? 0.31 : 1, speed: kind == .compressing ? 70e6 : 260e6) else { return false }

        var touched: [FileNode] = []
        for (node, choice) in plan {
            var name = node.name
            let existing = destination.children.first { $0.name == node.name && $0 !== node }
            if choice == .replace, let existing { destination.remove(existing) }
            if choice == .keepBoth {
                if policy == .renameExisting, let existing { existing.name = destination.uniqueChildName(existing.name) }
                else { name = destination.uniqueChildName(name) }
            }
            if move, let from = node.parent {
                if let archive = from.enclosingArchive { touched.append(archive) }
                from.remove(node)
                if targetArchive == nil { node.clearArchiveColumns() }
                node.name = name
                destination.add(node)
            } else {
                let copy = node.copy(intoArchive: targetArchive != nil)
                copy.name = name
                if targetArchive == nil { copy.clearArchiveColumns() }
                destination.add(copy)
            }
        }
        if let targetArchive { touched.append(targetArchive) }
        for archive in touched { archive.modified = .now; Packer.pack(archive) }
        flash("\(kind == .extracting ? "Extracted" : kind == .compressing ? "Added" : move ? "Moved" : "Copied") \(plan.count) item\(plan.count == 1 ? "" : "s") to \(Paths.pretty(destination.path))")
        return true
    }

    func createArchive(_ options: AddOptions, from sources: [FileNode]) async {
        let path = Paths.expand(options.archivePath)
        let name = (path as NSString).lastPathComponent
        let folderPath = (path as NSString).deletingLastPathComponent
        guard let folder = store.resolve(folderPath) ?? store.makeFolders(folderPath), folder.kind == .folder, folder.enclosingArchive == nil else {
            message("Can’t save the archive there", "Choose a folder on your Mac for “\(name)”.")
            return
        }
        let total = sources.reduce(Int64(0)) { $0 + $1.totalSize }
        guard await run(.compressing, title: "Compressing to \(name)", detail: "in \(Paths.pretty(folder.path))", bytes: total,
                        files: sources.reduce(0) { $0 + $1.fileCount }, ratio: options.ratio,
                        speed: options.level >= 7 ? 38e6 : options.level >= 5 ? 70e6 : 220e6) else { return }

        let archive: FileNode
        if let existing = folder.children.first(where: { $0.name == name && $0.kind == .archive }) {
            archive = existing   // 7-Zip adds to an existing archive using the update mode
        } else {
            var info = ArchiveInfo(options.format, solid: options.solidApplies && options.solidBlock != "Non-solid")
            info.encrypted = !options.password.isEmpty
            info.headersEncrypted = info.encrypted && options.encryptNames && options.format == .sevenZip
            archive = FileNode(name: name, kind: .archive, modified: .now, archive: info)
            folder.add(archive)
        }
        archive.archive?.methodTag = options.methodTag
        for source in sources {
            if let old = archive.children.first(where: { $0.name == source.name }) { archive.remove(old) }
            archive.add(source.copy(intoArchive: true))
        }
        archive.modified = .now
        Packer.pack(archive)
        if options.deleteAfter, sources.first?.isInsideArchive == false {
            for s in sources { s.parent?.remove(s) }
        }
        for pane in panes where pane.node === folder { pane.selection = [archive.id] }
        flash("Created \(name): \(Fmt.human(archive.size)) from \(Fmt.human(total))")
    }

    func extract(_ archive: FileNode, items: [FileNode]?, options: ExtractOptions) async {
        guard let folder = store.makeFolders(options.targetPath) else {
            message("Can’t extract there", "Choose a folder on your Mac, not one inside an archive.")
            return
        }
        if archive.archive?.encrypted == true { archive.archive?.locked = false }
        var nodes = items ?? archive.children
        // “Eliminate duplication of root folder”: skip the archive's own top folder when it matches the new folder.
        if options.eliminateDuplicateRoot, items == nil, options.createFolder, nodes.count == 1,
           nodes[0].kind == .folder, nodes[0].name == options.folderName {
            nodes = nodes[0].children
        }
        let policy: ExtractOptions.Overwrite = options.overwrite
        let done = await transfer(nodes, to: folder, move: false, policy: policy, flatten: options.pathMode == .none,
                                  title: "Extracting \(archive.name)")
        if done, options.revealInFinder { flash("Revealed \(Paths.pretty(folder.path)) in Finder") }
    }

    func test() async {
        let pane = active
        let archives = pane.archive.map { [$0] } ?? pane.selectedNodes().filter { $0.kind == .archive }
        guard !archives.isEmpty else { return }
        let infos = archives.compactMap(\.archive)
        let unpacked = infos.reduce(Int64(0)) { $0 + $1.unpackedSize }
        let physical = infos.reduce(Int64(0)) { $0 + $1.physicalSize }
        guard await run(.testing, title: "Testing \(archives.count == 1 ? archives[0].name : "\(archives.count) archives")",
                        detail: Paths.pretty(archives[0].path), bytes: unpacked, files: infos.reduce(0) { $0 + $1.files },
                        ratio: Double(physical) / Double(max(unpacked, 1)), speed: 1.4e9) else { return }
        for a in archives { a.archive?.tested = true }
        let files = infos.reduce(0) { $0 + $1.files }, folders = infos.reduce(0) { $0 + $1.folders }
        message("There are no errors", "Archives: \(archives.count)   Folders: \(folders)   Files: \(files)\nSize: \(Fmt.bytes(unpacked)) bytes   Packed size: \(Fmt.bytes(physical)) bytes")
    }

    func split(_ node: FileNode, volumeSize: Int64) async {
        guard let folder = node.parent, volumeSize > 0 else { return }
        let count = Int((node.size + volumeSize - 1) / volumeSize)
        guard await run(.splitting, title: "Splitting \(node.name)", detail: "into \(count) volumes", bytes: node.size, files: count, ratio: 1) else { return }
        for i in 1...count {
            let size = i < count ? volumeSize : node.size - volumeSize * Int64(count - 1)
            folder.add(FileNode(name: node.name + String(format: ".%03d", i), kind: .file, size: size, modified: .now))
        }
        flash("Split “\(node.name)” into \(count) volumes")
    }

    func combine(_ first: FileNode) async {
        guard let folder = first.parent else { return }
        let base = String(first.name.dropLast(4))
        let parts = folder.children.filter { $0.name.hasPrefix(base + ".") && Int($0.name.suffix(3)) != nil }.sorted { $0.name < $1.name }
        let total = parts.reduce(Int64(0)) { $0 + $1.size }
        guard await run(.combining, title: "Combining \(parts.count) files", detail: "into \(base)", bytes: total, files: parts.count, ratio: 1) else { return }
        let combined = first.copy(intoArchive: false)
        combined.name = folder.uniqueChildName(base)
        combined.size = total
        combined.archive?.volumes = 0
        folder.add(combined)
        flash("Combined \(parts.count) files into \(combined.name)")
    }
}
