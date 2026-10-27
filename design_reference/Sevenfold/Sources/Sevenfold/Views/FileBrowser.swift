import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One file panel: path bar on top, then the list in the current view style.
struct PaneView: View {
    @Bindable var pane: PaneState
    let model: BrowserModel
    let isActive: Bool
    let framed: Bool
    @AppStorage(PrefKey.showParentRow) private var showParentRow = true

    var body: some View {
        let rows = pane.rows(showParent: showParentRow)
        let isEmpty = rows.allSatisfy(\.isParent)
        Group {
            switch pane.style {
            case .details: FileTable(pane: pane, model: model, rows: rows)
            default: FileGrid(pane: pane, model: model, rows: rows)
            }
        }
        .overlay {
            if isEmpty {
                if pane.filter.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Drop files here or use Add to put something in it."))
                } else {
                    ContentUnavailableView.search(text: pane.filter)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PathBar(pane: pane, model: model)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .overlay {
            if framed {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: isActive ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(framed ? 6 : 0)
        .frame(minWidth: 320)
        .onChange(of: pane.selection) { model.activate(pane) }
    }
}

// MARK: - Path bar (7-Zip's address bar)

struct PathBar: View {
    @Bindable var pane: PaneState
    let model: BrowserModel
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { model.activate(pane); model.up(pane) } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(pane.node.parent == nil)
            .help("Up One Level")

            Group {
                if pane.editingPath { field } else { crumbs }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .glassEffect(.regular, in: .capsule)

            Menu {
                Section("Folders History") {
                    ForEach(model.store.history.prefix(12), id: \.self) { path in
                        Button(Paths.pretty(path)) { model.go(pane, to: path) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Folders History")
        }
    }

    private var crumbs: some View {
        let chain = Array(sequence(first: pane.node, next: { $0.parent })).reversed()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button { model.activate(pane); model.go(pane, to: node.path) } label: {
                        HStack(spacing: 4) {
                            crumbIcon(node)
                            Text(node.parent == nil ? "Macintosh HD" : node.name)
                                .fontWeight(node === pane.node ? .semibold : .regular)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(node === pane.node ? .primary : .secondary)
                }
            }
            .font(.callout)
        }
        .defaultScrollAnchor(.trailing)
        .contentShape(Rectangle())
        .onTapGesture { model.activate(pane); pane.editingPath = true }
        .help("Click to type a path, including paths inside archives")
    }

    private var field: some View {
        TextField("Path", text: $text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .focused($fieldFocused)
            .onAppear {
                text = pane.path == "/" ? "/" : Paths.tilde(pane.path) + "/"
                fieldFocused = true
            }
            .onSubmit {
                let path = text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
                if model.store.resolve(path)?.isContainer == true {
                    model.go(pane, to: path)
                } else {
                    model.flash("There is no folder “\(path)”")
                }
                pane.editingPath = false
            }
            .onExitCommand { pane.editingPath = false }
            .onChange(of: fieldFocused) { _, focused in
                if !focused { pane.editingPath = false }
            }
    }

    @ViewBuilder
    private func crumbIcon(_ node: FileNode) -> some View {
        if node.parent == nil {
            Image(systemName: "internaldrive")
        } else if node.path == Paths.home {
            Image(systemName: "house")
        } else if node.path.hasPrefix("/Volumes/"), node.parent?.name == "Volumes" {
            Image(systemName: "externaldrive")
        } else {
            FileIcon(node: node, size: 15)
        }
    }
}

// MARK: - Details view

struct FileTable: View {
    @Bindable var pane: PaneState
    let model: BrowserModel
    let rows: [FileRow]
    @AppStorage(PrefKey.sizeStyle) private var sizeStyle: SizeStyle = .bytes
    @AppStorage(PrefKey.timeStyle) private var timeStyle: TimeStyle = .iso
    @AppStorage(PrefKey.alternatingRows) private var alternatingRows = true
    @State private var archiveColumns = TableColumnCustomization<FileRow>()
    @State private var folderColumns = TableColumnCustomization<FileRow>()

    var body: some View {
        let inArchive = pane.isInArchive
        Table(rows, selection: $pane.selection, sortOrder: $pane.sortOrder,
              columnCustomization: inArchive ? $archiveColumns : $folderColumns) {
            TableColumn("Name", value: \FileRow.name) { row in
                NameCell(row: row, pane: pane, model: model)
            }
            .width(min: 180, ideal: 300)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Size", value: \FileRow.size) { row in
                number(row.isParent || (row.node.kind == .folder && !inArchive) ? "" : Fmt.size(row.size, sizeStyle))
            }
            .width(min: 70, ideal: 112)
            .customizationID("size")

            TableColumn("Packed Size", value: \FileRow.packed) { row in
                number(packedText(row))
                    .help(row.node.solidContinuation ? "Stored in a solid block. 7-Zip shows the block’s packed size on its first file." : "")
            }
            .width(min: 70, ideal: 112)
            .customizationID("packed")
            .defaultVisibility(inArchive ? .visible : .hidden)

            TableColumn("Modified", value: \FileRow.modified) { row in
                Text(row.isParent ? "" : Fmt.date(row.modified, timeStyle)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
            .customizationID("modified")

            TableColumn("Created", value: \FileRow.created) { row in
                Text(row.isParent ? "" : Fmt.date(row.created, timeStyle)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
            .customizationID("created")
            .defaultVisibility(.hidden)

            TableColumn("Kind", value: \FileRow.type) { row in
                Text(row.isParent ? "" : row.type).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)
            .customizationID("kind")
            .defaultVisibility(inArchive ? .hidden : .visible)

            TableColumn("Attributes", value: \FileRow.attributes) { row in
                mono(row.isParent ? "" : row.attributes)
            }
            .width(min: 60, ideal: 110)
            .customizationID("attributes")
            .defaultVisibility(inArchive ? .visible : .hidden)

            TableColumn("CRC", value: \FileRow.crc) { row in
                mono(row.isParent ? "" : row.crc)
            }
            .width(min: 60, ideal: 84)
            .customizationID("crc")
            .defaultVisibility(inArchive ? .visible : .hidden)

            TableColumn("Method", value: \FileRow.method) { row in
                Text(row.isParent || row.node.kind == .folder ? "" : row.method).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 140)
            .customizationID("method")
            .defaultVisibility(inArchive ? .visible : .hidden)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: alternatingRows))
        .contextMenu(forSelectionType: UUID.self) { ids in
            FileContextMenu(ids: ids, pane: pane, model: model)
        } primaryAction: { ids in
            model.open(ids, in: pane)
        }
        .onDeleteCommand { model.perform(.delete) }
        .onKeyPress(.space) {
            model.perform(.quickLook)
            return .handled
        }
    }

    private func packedText(_ row: FileRow) -> String {
        if row.isParent || row.node.solidContinuation { return "" }
        if row.node.kind == .folder && row.packed == 0 { return "" }
        return Fmt.size(row.packed, sizeStyle)
    }

    private func number(_ s: String) -> some View {
        Text(s).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func mono(_ s: String) -> some View {
        Text(s).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
    }
}

struct NameCell: View {
    let row: FileRow
    let pane: PaneState
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(node: row.isParent ? nil : row.node, size: 16)
            if row.isParent {
                Text("..").foregroundStyle(.secondary)
            } else if pane.renaming == row.id {
                RenameField(node: row.node, pane: pane, model: model)
            } else {
                HStack(spacing: 0) {
                    if !row.prefix.isEmpty { Text(row.prefix).foregroundStyle(.secondary) }
                    Text(row.name)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                if row.node.archive?.encrypted == true || row.node.method.contains("AES") {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RenameField: View {
    let node: FileNode
    let pane: PaneState
    let model: BrowserModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = node.name; focused = true }
            .onSubmit { commit() }
            .onExitCommand { pane.renaming = nil }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        guard pane.renaming == node.id else { return }
        Task { await model.rename(node, to: text, in: pane) }
    }
}

// MARK: - Icons and list views

struct FileGrid: View {
    @Bindable var pane: PaneState
    let model: BrowserModel
    let rows: [FileRow]
    @State private var anchor: UUID?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: pane.style == .largeIcons ? 14 : 2) {
                ForEach(rows) { row in
                    GridTile(row: row, style: pane.style, selected: pane.selection.contains(row.id))
                        .contentShape(Rectangle())
                        .onTapGesture { select(row) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.open([row.id], in: pane) })
                        .contextMenu { FileContextMenu(ids: [row.id], pane: pane, model: model) }
                }
            }
            .padding(12)
        }
        .contextMenu { FileContextMenu(ids: [], pane: pane, model: model) }
        .focusable()
        .onKeyPress(.space) {
            model.perform(.quickLook)
            return .handled
        }
        .onDeleteCommand { model.perform(.delete) }
    }

    private var columns: [GridItem] {
        switch pane.style {
        case .largeIcons: [GridItem(.adaptive(minimum: 96, maximum: 124), spacing: 8)]
        case .smallIcons: [GridItem(.adaptive(minimum: 200), spacing: 8)]
        default: [GridItem(.adaptive(minimum: 240), spacing: 8)]
        }
    }

    private func select(_ row: FileRow) {
        model.activate(pane)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if pane.selection.contains(row.id) { pane.selection.remove(row.id) } else { pane.selection.insert(row.id) }
        } else if flags.contains(.shift), let anchor,
                  let a = rows.firstIndex(where: { $0.id == anchor }), let b = rows.firstIndex(where: { $0.id == row.id }) {
            pane.selection = Set(rows[min(a, b)...max(a, b)].map(\.id))
            return
        } else {
            pane.selection = [row.id]
        }
        anchor = row.id
    }
}

struct GridTile: View {
    let row: FileRow
    let style: ViewStyle
    let selected: Bool

    var body: some View {
        if style == .largeIcons {
            VStack(spacing: 5) {
                FileIcon(node: row.isParent ? nil : row.node, size: 56)
                    .padding(4)
                    .background(selected ? Color.secondary.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                Text(row.isParent ? ".." : row.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                FileIcon(node: row.isParent ? nil : row.node, size: style == .smallIcons ? 28 : 16)
                Text(row.isParent ? ".." : row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
    }
}

/// System icons for each kind of file, the same ones Finder shows.
struct FileIcon: View {
    let node: FileNode?
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconProvider.icon(for: node))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

@MainActor
enum IconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: FileNode?) -> NSImage {
        let (key, type) = identity(node)
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    private static func identity(_ node: FileNode?) -> (String, UTType) {
        guard let node, node.kind != .folder else { return ("folder", .folder) }
        if node.isApp { return ("app", .applicationBundle) }
        if node.isExecutable && node.ext.isEmpty { return ("exec", .unixExecutable) }
        if let type = UTType(filenameExtension: node.ext), !type.isDynamic { return ("ext." + node.ext, type) }
        return node.kind == .archive ? ("archive", .archive) : ("data", .data)
    }
}

// MARK: - Context menu

struct FileContextMenu: View {
    let ids: Set<UUID>
    let pane: PaneState
    let model: BrowserModel

    var body: some View {
        if ids.isEmpty {
            item(.newFolder)
            Divider()
            Picker("View", selection: Binding(get: { pane.style }, set: { pane.style = $0 })) {
                ForEach(ViewStyle.allCases) { Text($0.command.title).tag($0) }
            }
            item(.selectMatching)
            item(.refresh)
        } else {
            item(.open)
            item(.openInside)
            item(.openOutside)
            item(.quickLook)
            item(.edit)
            Divider()
            if pane.isInArchive || containsArchive {
                item(.extract)
                item(.test)
            }
            item(.add)
            Divider()
            item(.rename)
            item(.copyTo)
            item(.moveTo)
            item(.delete)
            Divider()
            item(.info)
            Menu("Checksum") {
                ForEach(Checksum.algorithms, id: \.self) { algorithm in
                    Button(algorithm) {
                        select()
                        model.present(.checksum(items: pane.selectedNodes(), algorithm: algorithm))
                    }
                }
            }
        }
    }

    private var containsArchive: Bool {
        pane.node.children.contains { ids.contains($0.id) && $0.kind == .archive }
    }

    private func item(_ command: Command) -> some View {
        Button {
            select()
            model.perform(command)
        } label: {
            Label(command.title, systemImage: command.symbol)
        }
    }

    private func select() {
        model.activate(pane)
        if !ids.isEmpty, !ids.isSubset(of: pane.selection) { pane.selection = ids }
    }
}
