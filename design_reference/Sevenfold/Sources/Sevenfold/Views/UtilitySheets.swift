import SwiftUI
import AppKit

// MARK: - Copy To / Move To (F5 / F6)

struct TransferSheet: View {
    let model: BrowserModel
    let move: Bool
    let items: [FileNode]
    @State private var path = ""
    @State private var policy: ExtractOptions.Overwrite = .ask

    var body: some View {
        SheetLayout(title: title, subtitle: subtitle, symbol: move ? "folder" : "doc.on.doc", width: 560) {
            Form {
                LabeledContent(move ? "Move to" : "Copy to") {
                    HStack {
                        TextField("Folder", text: $path)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Menu {
                            if model.twoPanels {
                                Button("Other Panel: \(Paths.pretty(model.other.path))") { path = Paths.tilde(model.other.path) }
                                Divider()
                            }
                            ForEach(model.store.history.prefix(8), id: \.self) { folder in
                                Button(Paths.pretty(folder)) { path = Paths.tilde(folder) }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                        .fixedSize()
                    }
                }
                Picker("If an item already exists", selection: $policy) {
                    ForEach(ExtractOptions.Overwrite.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 200)
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { model.closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button(move ? "Move" : "Copy") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
        }
        .onAppear {
            let fallback = model.active.archive?.outermostArchive?.parent?.path ?? model.active.path
            path = Paths.tilde(model.twoPanels ? model.other.path : fallback)
        }
    }

    private var title: String {
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        return "\(move ? "Move" : "Copy") \(what)"
    }

    private var subtitle: String {
        let files = items.reduce(0) { $0 + $1.fileCount }
        return "\(files) file\(files == 1 ? "" : "s"), \(Fmt.human(items.reduce(0) { $0 + $1.totalSize }))"
    }

    private var hint: String {
        let target = model.store.resolve(path)
        if let archive = target?.enclosingArchive { return "The items are added to \(archive.name), and the archive is rebuilt." }
        if items.first?.isInsideArchive == true { return "Copying out of an archive extracts the items." }
        if target == nil { return "This folder doesn’t exist yet. Sevenfold will create it." }
        return model.twoPanels ? "The other panel’s folder, as in 7-Zip." : "Type a folder, or a path inside an archive to add the items to it."
    }

    private func commit() {
        guard let destination = model.store.resolve(path) ?? model.store.makeFolders(path), destination.isContainer else {
            model.flash("Choose a folder, or a folder inside an archive")
            return
        }
        let chosen = policy
        model.closeSheet()
        Task { await model.transfer(items, to: destination, move: move, policy: chosen) }
    }
}

// MARK: - Checksum (7-Zip's CRC SHA menu)

struct ChecksumSheet: View {
    struct Item: Identifiable {
        let id = UUID()
        let node: FileNode
        let path: String
    }

    let model: BrowserModel
    let items: [Item]
    @State private var algorithm: String

    init(model: BrowserModel, nodes: [FileNode], algorithm: String) {
        self.model = model
        var list: [Item] = []
        func collect(_ node: FileNode, _ prefix: String) {
            if node.kind == .folder {
                for child in node.children { collect(child, prefix + node.name + "/") }
            } else {
                list.append(Item(node: node, path: prefix + node.name))
            }
        }
        for node in nodes { collect(node, "") }
        self.items = list
        _algorithm = State(initialValue: algorithm)
    }

    private var total: Int64 { items.reduce(0) { $0 + $1.node.size } }

    var body: some View {
        SheetLayout(title: "Checksum", subtitle: "\(items.count) files, \(Fmt.bytes(total)) bytes", symbol: "number", width: 760) {
            Picker("Algorithm", selection: $algorithm) {
                ForEach(Checksum.algorithms, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            Table(items) {
                TableColumn("Name") { Text($0.path).lineLimit(1).truncationMode(.middle) }
                TableColumn("Size") { Text(Fmt.bytes($0.node.size)).monospacedDigit() }
                    .width(110)
                TableColumn(algorithm) { item in
                    Text(Checksum.digest(item.node, algorithm))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(height: 230)
            LabeledContent("\(algorithm) for data") { digestText(names: false) }
            LabeledContent("\(algorithm) for data and names") { digestText(names: true) }
        } actions: {
            Button("Copy List") {
                let lines = items.map { "\(Checksum.digest($0.node, algorithm))  \($0.path)" }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                model.flash("Copied \(items.count) \(algorithm) checksums")
            }
            Spacer()
            Button("Done") { model.closeSheet() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func digestText(names: Bool) -> some View {
        let seed = items.map { (names ? $0.path : "") + ":\($0.node.size)" }.joined(separator: "|")
        return Text(Hash.hex("\(algorithm):\(names):\(seed)", length: Checksum.lengths[algorithm] ?? 8))
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
    }
}

// MARK: - Split File

struct SplitSheet: View {
    let model: BrowserModel
    let node: FileNode
    @State private var volume = "4092M"

    var body: some View {
        SheetLayout(title: "Split “\(node.name)”", subtitle: "\(Fmt.bytes(node.size)) bytes. Open part .001 to read the archive again, or use Combine Files.", symbol: "scissors", width: 480) {
            Form {
                LabeledContent("Volume size") {
                    HStack {
                        TextField("Volume size", text: $volume)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Menu {
                            ForEach(AddOptions.volumePresets, id: \.self) { preset in
                                Button(preset) { volume = preset }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .fixedSize()
                    }
                }
                Text(count > 1 ? "Creates \(count) files, \(node.name).001 to .\(String(format: "%03d", count))" : "The file fits in one volume, so there is nothing to split.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 130)
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { model.closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Split") {
                let size = bytes
                model.closeSheet()
                Task { await model.split(node, volumeSize: size) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(count < 2 || count > 999)
        }
    }

    /// Parses 7-Zip volume sizes such as 700M, 4092M or 1G.
    private var bytes: Int64 {
        let trimmed = volume.trimmingCharacters(in: .whitespaces).uppercased()
        guard let unit = trimmed.last else { return 0 }
        let multiplier: Int64 = switch unit {
            case "K": 1 << 10
            case "M": 1 << 20
            case "G": 1 << 30
            default: 1
        }
        let digits = unit.isNumber ? trimmed : String(trimmed.dropLast())
        return (Int64(digits) ?? 0) * multiplier
    }

    private var count: Int { bytes > 0 ? Int((node.size + bytes - 1) / bytes) : 0 }
}

// MARK: - Comment (ZIP archives)

struct CommentSheet: View {
    let model: BrowserModel
    let archive: FileNode
    @State private var text = ""

    var body: some View {
        SheetLayout(title: "Comment for “\(archive.name)”", subtitle: "ZIP archives store one comment for the whole archive.", symbol: "text.bubble", width: 520) {
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { model.closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Save Comment") {
                let value = text
                model.closeSheet()
                Task { await model.setComment(value, on: archive) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { text = archive.archive?.comment ?? "" }
    }
}

// MARK: - Select… / Deselect… (Grey + / Grey −)

struct MatchSheet: View {
    let model: BrowserModel
    let select: Bool
    @State private var mask = "*"

    var body: some View {
        SheetLayout(title: select ? "Select" : "Deselect",
                    subtitle: "Use * for any run of characters and ? for one character. Case doesn’t matter.",
                    symbol: select ? "checklist" : "checklist.unchecked", width: 440) {
            TextField("Mask", text: $mask)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("\(matches.count) matching item\(matches.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { model.closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button(select ? "Select" : "Deselect") {
                let ids = Set(matches.map(\.id))
                let pane = model.active
                pane.selection = select ? pane.selection.union(ids) : pane.selection.subtracting(ids)
                model.closeSheet()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var matches: [FileNode] {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: mask)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return model.active.node.children.filter {
            regex.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) != nil
        }
    }
}

// MARK: - Help

struct HelpSheet: View {
    let model: BrowserModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SheetLayout(title: "Sevenfold Help", subtitle: "An archive manager for macOS on the 7-Zip engine, laid out like 7-Zip File Manager.", symbol: "questionmark.circle", width: 560) {
            VStack(alignment: .leading, spacing: 12) {
                topic("Browse archives like folders", "Double-click an archive to open it. Click the path bar to type a path, including one inside an archive, such as ~/Downloads/Kestrel-4.2.0.7z/bin.")
                topic("The 7-Zip toolbar", "Add, Extract and Test work on archives. Copy, Move and Delete work on selected items inside or outside an archive. Copying out of an archive extracts; copying into one adds to it.")
                topic("Two panels", "Turn on 2 Panels for a commander layout. Copy and Move suggest the other panel’s folder.")
                topic("Info instead of Properties", "⌘I or Alt+Enter opens the Info inspector, which stays open while you browse.")
            }
        } actions: {
            Button("Shortcut Map") { model.closeSheet(); openWindow(id: WindowID.shortcuts) }
            SettingsLink { Text("Settings…") }
            Spacer()
            Button("Done") { model.closeSheet() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func topic(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
