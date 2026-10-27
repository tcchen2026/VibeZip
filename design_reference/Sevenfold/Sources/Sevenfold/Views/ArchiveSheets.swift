import SwiftUI
import AppKit

/// Routes a `BrowserSheet` to its view.
struct SheetContent: View {
    let sheet: BrowserSheet
    let model: BrowserModel

    var body: some View {
        switch sheet {
        case .add(let sources, let destination): AddArchiveSheet(model: model, sources: sources, destination: destination)
        case .extract(let archive, let items): ExtractSheet(model: model, archive: archive, items: items)
        case .transfer(let move, let items): TransferSheet(model: model, move: move, items: items)
        case .checksum(let items, let algorithm): ChecksumSheet(model: model, nodes: items, algorithm: algorithm)
        case .split(let node): SplitSheet(model: model, node: node)
        case .comment(let archive): CommentSheet(model: model, archive: archive)
        case .match(let select): MatchSheet(model: model, select: select)
        case .help: HelpSheet(model: model)
        case .progress(let op): ProgressSheet(model: model, op: op)
        }
    }
}

/// Shared sheet layout: symbol, title, explanation, content, buttons.
struct SheetLayout<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol = "archivebox"
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
            HStack(spacing: 8) { actions }
        }
        .padding(20)
        .frame(width: width)
    }
}

/// The same job as a `7zz` command, for people who also script 7-Zip.
struct CommandLineView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .help("The same job in 7-Zip’s command-line tool, 7zz")
    }
}

// MARK: - Add to Archive

struct AddArchiveSheet: View {
    let model: BrowserModel
    let sources: [FileNode]
    @State private var options: AddOptions

    init(model: BrowserModel, sources: [FileNode], destination: FileNode) {
        self.model = model
        self.sources = sources
        let base: String
        if sources.count == 1 {
            let n = sources[0]
            base = n.kind == .folder ? n.name : (n.name as NSString).deletingPathExtension
        } else {
            base = model.active.isInArchive ? model.active.node.name : destination.name
        }
        let folder = destination.parent == nil ? "" : Paths.tilde(destination.path)
        _options = State(initialValue: AddOptions(archivePath: folder + "/" + base + ".7z"))
    }

    private var total: Int64 { sources.reduce(0) { $0 + $1.totalSize } }
    private var isSingleFile: Bool { sources.count == 1 && sources[0].kind != .folder }
    private var formats: [ArchiveFormat] { ArchiveFormat.writable.filter { isSingleFile || !$0.singleFileOnly } }
    private var fromArchive: Bool { sources.first?.isInsideArchive == true }

    var body: some View {
        SheetLayout(title: "Add to Archive", subtitle: subtitle, symbol: "archivebox", width: 880) {
            LabeledContent("Archive") {
                HStack {
                    TextField("Archive", text: $options.archivePath)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Menu {
                        ForEach([Paths.home + "/Desktop", Paths.home + "/Documents", Paths.home + "/Downloads", "/Volumes/Backup T7/Archives"], id: \.self) { folder in
                            Button(Paths.pretty(folder)) {
                                options.archivePath = Paths.tilde(folder) + "/" + (options.archivePath as NSString).lastPathComponent
                            }
                        }
                    } label: { Image(systemName: "folder") }
                    .fixedSize()
                    .help("Save in")
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Form { compressionSection }.formStyle(.grouped)
                Form {
                    updateSection
                    optionsSection
                    encryptionSection
                }
                .formStyle(.grouped)
            }
            .frame(height: 450)
            CommandLineView(text: options.commandLine(sources: sources.map(\.name)))
        } actions: {
            Text("Estimated size \(Fmt.human(Int64(Double(total) * options.ratio)))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { model.closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                let chosen = options
                model.closeSheet()
                Task { await model.createArchive(chosen, from: sources) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(options.archivePath.isEmpty || !options.passwordsMatch)
        }
        .onChange(of: options.format) { options.formatChanged() }
        .onChange(of: options.level) { options.applyLevelDefaults() }
        .onChange(of: options.method) { options.applyLevelDefaults() }
    }

    private var subtitle: String {
        let what = sources.count == 1 ? "“\(sources[0].name)”" : "\(sources.count) items"
        let files = sources.reduce(0) { $0 + $1.fileCount }
        let from = fromArchive ? ". They are unpacked to a temporary folder first." : ""
        return "\(what), \(files) files, \(Fmt.human(total))\(from)"
    }

    private var compressionSection: some View {
        Section("Compression") {
            Picker("Archive format", selection: $options.format) {
                ForEach(formats) { Text($0.title).tag($0) }
            }
            Picker("Level", selection: $options.level) {
                ForEach(AddOptions.levels) { Text($0.title).tag($0.value) }
            }
            .disabled(!options.format.compresses)
            Picker("Method", selection: $options.method) {
                ForEach(options.format.methods, id: \.self) { Text($0).tag($0) }
            }
            Picker("Dictionary size", selection: $options.dictionary) {
                ForEach(AddOptions.dictionaries, id: \.self) { Text(Fmt.dictionary($0)).tag($0) }
            }
            .disabled(!options.dictionaryApplies)
            Picker("Word size", selection: $options.wordSize) {
                ForEach(AddOptions.wordSizes, id: \.self) { Text("\($0)").tag($0) }
            }
            .disabled(!options.dictionaryApplies || options.method == "PPMd")
            Picker("Solid block size", selection: $options.solidBlock) {
                ForEach(AddOptions.solidSizes, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!options.solidApplies)
            Picker("CPU threads", selection: $options.threads) {
                ForEach(1...Hardware.cores, id: \.self) { Text("\($0) of \(Hardware.cores)").tag($0) }
            }
            LabeledContent("Memory to compress") { MemoryMeter(bytes: options.memory.compress) }
            LabeledContent("Memory to decompress", value: Fmt.human(options.memory.decompress))
            Group {
                TextField("Split to volumes", text: $options.volumes, prompt: Text("e.g. 4092M"))
                TextField("Parameters", text: $options.parameters, prompt: Text("e.g. -mqs=on"))
            }
        }
    }

    private var updateSection: some View {
        Section("Update") {
            Picker("Update mode", selection: $options.updateMode) {
                ForEach(AddOptions.UpdateMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Path mode", selection: $options.pathMode) {
                ForEach(AddOptions.PathMode.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle(isOn: $options.excludeMetadata) {
                Text("Leave out macOS metadata")
                Text(".DS_Store, ._ files and __MACOSX, which Windows users see as clutter")
            }
            Toggle(isOn: $options.storeExtendedAttributes) {
                Text("Store extended attributes and tags")
                Text("The Mac counterpart of 7-Zip’s NTFS stream and security options")
            }
            Toggle(isOn: $options.deleteAfter) {
                Text("Delete files after compression")
                if fromArchive { Text("Not available for items inside an archive") }
            }
            .disabled(fromArchive)
        }
    }

    private var encryptionSection: some View {
        Section("Encryption") {
            if options.showPassword {
                TextField("Password", text: $options.password)
            } else {
                SecureField("Password", text: $options.password)
                SecureField("Reenter password", text: $options.passwordAgain)
            }
            Toggle("Show password", isOn: $options.showPassword)
            Picker("Method", selection: $options.encryption) {
                ForEach(options.format.encryptionMethods, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Encrypt file names", isOn: $options.encryptNames)
                .disabled(options.format != .sevenZip || options.password.isEmpty)
            if !options.passwordsMatch {
                Text("The passwords don’t match.").foregroundStyle(.red)
            } else if options.encryption == "ZipCrypto" && !options.password.isEmpty {
                Text("ZipCrypto is weak. Use AES-256 unless the recipient needs Windows Explorer.").foregroundStyle(.orange)
            }
        }
        .disabled(!options.format.supportsEncryption)
    }
}

struct MemoryMeter: View {
    let bytes: Int64
    var body: some View {
        let fraction = min(1, Double(bytes) / Double(Hardware.memory))
        VStack(alignment: .trailing, spacing: 3) {
            ProgressView(value: fraction)
                .tint(fraction > 0.8 ? .orange : .accentColor)
                .frame(width: 150)
            Text("\(Fmt.human(bytes)) of \(Fmt.human(Hardware.memory))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Extract

struct ExtractSheet: View {
    let model: BrowserModel
    let archive: FileNode
    let items: [FileNode]?
    @State private var options: ExtractOptions
    @State private var showPassword = false

    init(model: BrowserModel, archive: FileNode, items: [FileNode]?) {
        self.model = model
        self.archive = archive
        self.items = items
        let folder = archive.outermostArchive?.parent?.path ?? Paths.home
        let name = archive.name
            .replacingOccurrences(of: #"(\.tar)?\.(7z|zip|rar|xz|gz|bz2|tar|iso|dmg|wim)(\.\d{3})?$"#, with: "", options: .regularExpression)
        _options = State(initialValue: ExtractOptions(destination: Paths.tilde(folder), folderName: name))
    }

    private var needsPassword: Bool { archive.archive?.encrypted == true }

    var body: some View {
        SheetLayout(title: "Extract", subtitle: subtitle, symbol: "square.and.arrow.up.on.square", width: 580) {
            Form {
                Section {
                    LabeledContent("Extract to") {
                        HStack {
                            TextField("Extract to", text: $options.destination)
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                            Menu {
                                ForEach([Paths.home + "/Desktop", Paths.home + "/Documents", Paths.home + "/Downloads"], id: \.self) { folder in
                                    Button(Paths.pretty(folder)) { options.destination = Paths.tilde(folder) }
                                }
                                if model.twoPanels {
                                    Divider()
                                    Button("Other Panel: \(Paths.pretty(model.other.path))") { options.destination = Paths.tilde(model.other.path) }
                                }
                            } label: { Image(systemName: "folder") }
                            .fixedSize()
                        }
                    }
                    Toggle("Create folder", isOn: $options.createFolder)
                    TextField("Folder name", text: $options.folderName)
                        .disabled(!options.createFolder)
                    LabeledContent("Files go to", value: Paths.tilde(Paths.expand(options.targetPath)))
                }
                Section {
                    Picker("Path mode", selection: $options.pathMode) {
                        ForEach(ExtractOptions.PathMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Overwrite mode", selection: $options.overwrite) {
                        ForEach(ExtractOptions.Overwrite.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                if needsPassword {
                    Section("Password") {
                        if showPassword {
                            TextField("Password", text: $options.password)
                        } else {
                            SecureField("Password", text: $options.password)
                        }
                        Toggle("Show password", isOn: $showPassword)
                    }
                }
                Section("Options") {
                    Toggle(isOn: $options.eliminateDuplicateRoot) {
                        Text("Eliminate duplication of root folder")
                        Text("Skips the extra level when the archive holds one folder with the same name")
                    }
                    Toggle(isOn: $options.restoreExtendedAttributes) {
                        Text("Restore extended attributes")
                        Text("Replaces 7-Zip’s “Restore file security”, which is for NTFS")
                    }
                    Toggle(isOn: $options.keepQuarantine) {
                        Text("Keep the quarantine flag")
                        Text("Gatekeeper still checks apps and scripts that came from the internet")
                    }
                    Toggle("Show in Finder when done", isOn: $options.revealInFinder)
                }
            }
            .formStyle(.grouped)
            .frame(height: needsPassword ? 540 : 450)
            CommandLineView(text: options.commandLine(archive: archive.name, items: (items ?? []).map(\.name)))
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { model.closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Extract") {
                let chosen = options
                model.closeSheet()
                Task { await model.extract(archive, items: items, options: chosen) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(options.destination.isEmpty || (needsPassword && options.password.isEmpty))
        }
    }

    private var subtitle: String {
        if let items { return "\(items.count) selected item\(items.count == 1 ? "" : "s") from “\(archive.name)”" }
        return "“\(archive.name)”, \(archive.archive?.files ?? 0) files, \(Fmt.human(archive.archive?.unpackedSize ?? 0))"
    }
}

// MARK: - Progress (7-Zip's operation window)

struct ProgressSheet: View {
    let model: BrowserModel
    let op: OperationModel

    var body: some View {
        SheetLayout(title: op.title, subtitle: op.detail, symbol: symbol, width: 540) {
            ProgressView(value: op.fraction)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    stat("Elapsed", Fmt.duration(op.elapsed))
                    stat("Remaining", op.remaining.map(Fmt.duration) ?? "—")
                    stat("Files", "\(op.filesDone) of \(op.totalFiles)")
                }
                GridRow {
                    stat("Speed", op.speed.map { Fmt.human(Int64($0)) + "/s" } ?? "—")
                    stat("Processed", Fmt.human(op.processed))
                    stat(op.kind == .compressing ? "Compressed size" : "Packed size", Fmt.human(op.packed))
                }
                GridRow {
                    stat("Total size", Fmt.human(op.totalBytes))
                    stat("Compression ratio", "\(Int((op.ratio * 100).rounded()))%")
                    stat("Errors", "0")
                }
            }
        } actions: {
            Button("Background") { model.sendToBackground(op) }
                .help("Keep working. Progress stays in the toolbar.")
            Spacer()
            Button(op.isPaused ? "Continue" : "Pause") { op.isPaused.toggle() }
            Button("Cancel", role: .cancel) { op.isCancelled = true }
                .keyboardShortcut(.cancelAction)
        }
        .interactiveDismissDisabled()
    }

    private var symbol: String {
        switch op.kind {
        case .extracting: "square.and.arrow.up.on.square"
        case .compressing: "archivebox"
        case .testing: "checkmark.seal"
        case .moving: "folder"
        default: "doc.on.doc"
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
