import SwiftUI
import QuickLook

/// One Sevenfold window: sidebar, file panes, Info inspector, and 7-Zip's toolbar.
struct BrowserWindow: View {
    @State private var model: BrowserModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.showKeyTips) private var showKeyTips = true
    @AppStorage(PrefKey.keyMode) private var keyMode: KeyMode = .sevenZip
    @AppStorage(PrefKey.showArchiveToolbar) private var showArchiveToolbar = true
    @AppStorage(PrefKey.showStandardToolbar) private var showStandardToolbar = true

    init(store: ArchiveStore) {
        _model = State(initialValue: BrowserModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            panes
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
                }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .toolbar { toolbar }
        .searchable(text: filter, placement: .toolbar, prompt: "Filter")
        .focusedSceneValue(\.browser, model)
        .sheet(item: $model.sheet) { SheetContent(sheet: $0, model: model) }
        .alert(alertTitle, isPresented: alertShown, presenting: model.alert) { alert in
            alertActions(alert)
        } message: { alert in
            alertMessage(alert)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible, presenting: model.pendingDelete) { nodes in
            Button(model.active.isInArchive ? "Delete" : "Move to Trash", role: .destructive) {
                Task { await model.delete(nodes) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(model.active.isInArchive
                 ? "Deleting from an archive can’t be undone. Sevenfold rebuilds the archive without these items."
                 : "You can put them back from the Trash.")
        }
        .quickLookPreview($model.quickLookURL)
        .overlay(alignment: .bottom) { toast }
        .animation(.snappy, value: model.toast)
        .onChange(of: model.twoPanels) { _, on in if !on { model.activeIndex = 0 } }
        .onAppear { model.openWindow = { openWindow(id: $0) } }
    }

    // MARK: Content

    private var panes: some View {
        VStack(spacing: 0) {
            if showKeyTips {
                KeyTipBar(mode: keyMode, onMap: { openWindow(id: WindowID.shortcuts) }, onClose: { showKeyTips = false })
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if model.twoPanels {
                HSplitView {
                    PaneView(pane: model.panes[0], model: model, isActive: model.activeIndex == 0, framed: true)
                    PaneView(pane: model.panes[1], model: model, isActive: model.activeIndex == 1, framed: true)
                }
            } else {
                PaneView(pane: model.panes[0], model: model, isActive: true, framed: false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model) }
    }

    private var filter: Binding<String> {
        Binding(get: { model.active.filter }, set: { model.active.filter = $0 })
    }

    private var viewStyle: Binding<ViewStyle> {
        Binding(get: { model.active.style }, set: { model.active.style = $0 })
    }

    // MARK: Toolbar (7-Zip's Archive and Standard toolbars)

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            commandButton(.back)
            commandButton(.forward)
        }
        if showArchiveToolbar {
            ToolbarItemGroup {
                commandButton(.add)
                commandButton(.extract)
                commandButton(.test)
            }
        }
        if showStandardToolbar {
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                commandButton(.copyTo)
                commandButton(.moveTo)
                commandButton(.delete)
                Toggle(isOn: $model.showInspector) {
                    Label("Info", systemImage: Command.info.symbol)
                }
                .help(help(.info))
            }
        }
        if let op = model.backgroundOperation {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { model.bringToFront(op) } label: { BackgroundProgress(op: op) }
                    .help("Show progress")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Picker("View", selection: viewStyle) {
                Label("Icons", systemImage: Command.viewLarge.symbol).tag(ViewStyle.largeIcons)
                Label("List", systemImage: Command.viewList.symbol).tag(ViewStyle.list)
                Label("Details", systemImage: Command.viewDetails.symbol).tag(ViewStyle.details)
            }
            .pickerStyle(.segmented)
            .help("View")
        }
        ToolbarItem {
            Toggle(isOn: $model.twoPanels) {
                Label("2 Panels", systemImage: Command.twoPanels.symbol)
            }
            .help(help(.twoPanels))
        }
    }

    private func commandButton(_ command: Command) -> some View {
        Button { model.perform(command) } label: {
            Label(command.toolbarTitle, systemImage: command.symbol)
        }
        .disabled(!model.isEnabled(command))
        .help(help(command))
    }

    private func help(_ command: Command) -> String {
        let key = Shortcuts.shortcut(command, keyMode)
        return key == nil ? command.title : "\(command.title)  \(Shortcuts.label(key))"
    }

    // MARK: Alerts

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let nodes = model.pendingDelete else { return "" }
        let what = nodes.count == 1 ? "“\(nodes[0].name)”" : "\(nodes.count) items"
        if let archive = model.active.archive { return "Delete \(what) from “\(archive.name)”?" }
        return "Move \(what) to the Trash?"
    }

    private var alertTitle: String {
        switch model.alert {
        case .newFolder?: "New Folder"
        case .password(let archive, _)?: "Enter the password for “\(archive.name)”"
        case .replace(let name, _)?: "Replace “\(name)”?"
        case .modified(let node)?: "“\(node.name)” was modified"
        case .message(let title, _)?: title
        case nil: ""
        }
    }

    @ViewBuilder
    private func alertActions(_ alert: BrowserAlert) -> some View {
        switch alert {
        case .newFolder:
            TextField("Name", text: $model.alertText)
            Button("Create") { Task { await model.createFolder() } }
            Button("Cancel", role: .cancel) {}
        case .password(let archive, let path):
            SecureField("Password", text: $model.alertText)
            Button("Open") { model.unlock(archive, thenOpen: path) }
            Button("Cancel", role: .cancel) {}
        case .replace:
            Button("Replace") { model.answerReplace(.replace) }
            Button("Replace All") { model.answerReplace(.replaceAll) }
            Button("Keep Both") { model.answerReplace(.keepBoth) }
            Button("Skip") { model.answerReplace(.skip) }
            Button("Stop", role: .cancel) { model.answerReplace(.stop) }
        case .modified(let node):
            Button("Update Archive") { Task { await model.saveEdited(node) } }
            Button("Don’t Update", role: .cancel) {}
        case .message:
            Button("OK", role: .cancel) {}
        }
    }

    private func alertMessage(_ alert: BrowserAlert) -> Text {
        switch alert {
        case .newFolder: Text("The folder is created in \(model.title).")
        case .password(let archive, _):
            Text(archive.archive?.headersEncrypted == true ? "The file names are encrypted too, so the contents stay hidden until you enter it." : "The archive is encrypted.")
        case .replace(_, let folder): Text("\(folder) already contains an item with this name.")
        case .modified(let node): Text("Do you want to update it in “\(node.enclosingArchive?.name ?? "the archive")”? Sevenfold rebuilds the archive with the new version.")
        case .message(_, let text): Text(text)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toast {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Supporting views

/// The reminder strip that tells 7-Zip users their keys still work.
struct KeyTipBar: View {
    let mode: KeyMode
    let onMap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").foregroundStyle(.tint)
            ViewThatFits(in: .horizontal) {
                keys(compact: false)
                keys(compact: true)
            }
            Spacer(minLength: 8)
            Button("Shortcut Map", action: onMap).buttonStyle(.link)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide key tips")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    private func keys(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text(mode == .sevenZip ? "7-Zip keys are on." : "Mac keys are on.").fontWeight(.semibold)
            if mode == .sevenZip {
                KeyHint(key: "F5", label: "Copy")
                KeyHint(key: "F6", label: "Move")
                KeyHint(key: "F2", label: "Rename")
                if !compact {
                    KeyHint(key: "F9", label: "2 Panels")
                    Text("Ctrl is ⌘, Alt is ⌥").foregroundStyle(.secondary)
                }
            } else {
                KeyHint(key: "⌘Y", label: "Quick Look")
                KeyHint(key: "⌘I", label: "Info")
                KeyHint(key: "⌘⌫", label: "Delete")
                if !compact { KeyHint(key: "⇧⌘E", label: "Extract") }
            }
        }
        .lineLimit(1)
    }
}

struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.background, in: .rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
            Text(label)
        }
    }
}

struct StatusBar: View {
    let model: BrowserModel
    @AppStorage(PrefKey.timeStyle) private var timeStyle: TimeStyle = .iso

    var body: some View {
        let pane = model.active
        let items = pane.rows(showParent: false)
        let selected = pane.selectedNodes()
        let total = items.reduce(Int64(0)) { $0 + $1.node.totalSize }
        let picked = selected.reduce(Int64(0)) { $0 + $1.totalSize }
        HStack(spacing: 8) {
            Text(selected.isEmpty
                 ? "\(items.count) items, \(Fmt.human(total))"
                 : "\(selected.count) of \(items.count) selected, \(Fmt.human(picked))")
            Spacer(minLength: 8)
            if let info = pane.archive?.archive {
                StatusChip(text: info.format.title)
                if !info.method.isEmpty { StatusChip(text: info.method) }
                if info.solid { StatusChip(text: "Solid · \(info.blocks) blocks") }
                if info.encrypted { StatusChip(text: info.headersEncrypted ? "Names encrypted" : "Encrypted", symbol: "lock.fill", tint: .orange) }
                if info.tested { StatusChip(text: "Tested OK", symbol: "checkmark", tint: .green) }
            }
            if let last = selected.last {
                Text("Modified \(Fmt.date(last.modified, timeStyle))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(.bar)
    }
}

struct StatusChip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.fill.tertiary, in: .capsule)
    }
}

struct BackgroundProgress: View {
    let op: OperationModel
    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: op.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("\(op.kind.rawValue) \(Int(op.fraction * 100))%")
                .monospacedDigit()
        }
    }
}
