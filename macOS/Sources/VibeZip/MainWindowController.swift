#if os(macOS)
import AppKit
import VibeZipCore

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSWindowDelegate, NSMenuItemValidation {
    let workspace: BrowserWorkspace
    var service: ArchiveService { workspace.service }
    let directoryAccess = DirectoryAccessStore.shared
    let workQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "VibeZip.operations"; queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated; return queue
    }()
    let left: PaneController
    let right: PaneController
    private weak var focusedPane: PaneController?
    private var operationPane: PaneController?
    private(set) var usesTwoPanes = false
    private(set) var browserLayout: BrowserWindowLayout?
    var isBusy: Bool { workspace.isBusy }
    private var viewPicker: NSSegmentedControl?
    private var searchItem: NSSearchToolbarItem?
    var onIdle: (() -> Void)?
    var onBecomeMain: (() -> Void)?
    var onClose: (() -> Void)?
    var canManageSharedAccess: (() -> Bool)?
    private var currentToken: CancellationToken?
    private var settingsCleanupToken: CancellationToken?
    private var progressWindow: OperationProgressWindow?
    private var lastLog = L10n.tr("No operations yet.")
    private var auxiliaryWindows: [NSWindowController] = []
    var activePane: PaneController { usesTwoPanes ? (focusedPane ?? left) : left }
    var panes: [PaneController] { [left, right] }
    var keepBackups: Bool { UserDefaults.standard.bool(forKey: "temporaryArchiveBackupsEnabled") }
    var hasActiveOperations: Bool { workspace.operationOwner === self || workQueue.operationCount > 0 || settingsCleanupToken != nil }
    var canAcceptCommands: Bool { !isBusy && window?.attachedSheet == nil && NSApp.modalWindow == nil }

    init(workspace: BrowserWorkspace, autosavesFrame: Bool = true) {
        self.workspace = workspace
        left = PaneController(directory: directoryAccess.restoreLastDirectory())
        right = PaneController(directory: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VibeZip"; window.minSize = NSSize(width: 850, height: 520)
        window.isReleasedWhenClosed = false
        if autosavesFrame { window.setFrameAutosaveName("VibeZip.MainWindow.Sevenfold") }
        super.init(window: window)
        window.delegate = self
        left.owner = self; right.owner = self
        let layout = BrowserWindowLayout(owner: self); browserLayout = layout
        window.contentViewController = layout
        for pane in panes {
            pane.status.onDetails = { [weak self] in self?.showLastLog(nil) }
            pane.status.onCancel = { [weak self] in self?.progressWindow?.showCancelling() }
        }
        let toolbar = NSToolbar(identifier: "VibeZip.Toolbar.Sevenfold"); toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = .unified
        for pane in panes { pane.table.menu = makeContextMenu(); pane.collection.menu = makeContextMenu() }
        applyPreferences(); activate(left)
        if UserDefaults.standard.bool(forKey: "twoPanels") { toggleTwoPanels(nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    func activate(_ pane: PaneController) {
        guard !isBusy || pane === activePane else { return }
        focusedPane = pane
        pane.focusFiles(); updateTitle()
        viewPicker?.selectedSegment = pane.viewStyle.rawValue
        searchItem?.searchField = pane.search
        panes.forEach { $0.setActive($0 === pane, framed: usesTwoPanes) }
    }
    func updateTitle() {
        let name = activePane.location.archive?.url.lastPathComponent ?? activePane.suggestedDirectory?.lastPathComponent
        window?.title = name.map { "VibeZip - " + $0 } ?? "VibeZip"
        if NSApp.mainWindow === window, let directory = activePane.location.directory { directoryAccess.remember(directory) }
        window?.toolbar?.validateVisibleItems()
        browserLayout?.refresh()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasActiveOperations { NSSound.beep(); return false }
        return true
    }
    func windowDidBecomeMain(_ notification: Notification) {
        onBecomeMain?(); refreshSharedState()
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func updateBusyState() {
        window?.toolbar?.validateVisibleItems(); browserLayout?.refresh()
    }
    @objc private func appActivated() { refreshSharedState() }
    func refreshSharedState() {
        guard canAcceptCommands, !hasActiveOperations else { return }
        directoryAccess.refreshUnavailable(); panes.forEach { $0.discardRevokedLocations() }
    }
    func applyPreferences() {
        guard !isBusy else { return }
        let defaults = UserDefaults.standard
        let configuredLimit = max(1, min(100_000, defaults.integer(forKey: "extractionLimitGiB")))
        service.extractionLimit = UInt64(configuredLimit) * 1024 * 1024 * 1024
        panes.forEach { $0.refresh() }
    }
    func perform<T>(_ title: String, showCompletion: Bool = true, work: @escaping (CancellationToken, @escaping (String) -> Void) throws -> T,
                    success: @escaping (T) -> Void = { _ in }, failure: ((Error) -> Void)? = nil) {
        guard canAcceptCommands, window != nil, workspace.beginOperation(self) else { return }
        let token = CancellationToken(); currentToken = token
        let pane = activePane; operationPane = pane
        pane.status.begin(title, token: token)
        let startedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak token] in
            guard let self = self, let token = token, self.currentToken === token, !token.isCancelled,
                  let window = self.window, window.isVisible else { return }
            let progress = OperationProgressWindow(title: title, token: token, startedAt: startedAt,
                cancel: { [weak self] in self?.cancelCurrent(nil) })
            progress.append(pane.status.message.stringValue)
            if let value = pane.status.currentProgress { progress.update(value) }
            self.progressWindow = progress; progress.show(attachedTo: window)
        }
        let output = JobOutput(receive: { [weak self] chunk in
            guard let self = self, self.currentToken === token else { return }
            pane.status.append(chunk); self.progressWindow?.append(chunk)
        }, progress: { [weak self] value in
            guard let self = self, self.currentToken === token else { return }
            pane.status.update(value); self.progressWindow?.update(value)
        })
        token.observeProgress(output.emitProgress)
        workQueue.addOperation { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try work(token, output.emit)) } catch { result = .failure(error) }
            token.observeProgress(nil)
            DispatchQueue.main.async {
                guard let self = self else { return }
                output.flush(); self.lastLog = title + "\n" + output.log
                self.progressWindow?.close(); self.progressWindow = nil
                self.workspace.endOperation(self); self.currentToken = nil; pane.status.finish()
                switch result {
                case .success(let value):
                    self.lastLog += L10n.tr("\nCompleted.")
                    if showCompletion { pane.status.showMessage(L10n.tr("\(title) completed.")) }
                    success(value)
                case .failure(let error):
                    self.lastLog += "\n" + error.localizedDescription
                    if case FMError.cancelled = error {
                        pane.status.showMessage(L10n.tr("Cancelled. Completed file copies are kept."))
                    } else if let failure = failure { failure(error) } else { self.reportError(error) }
                }
                self.updateTitle()
                self.operationPane = nil
                self.onIdle?()
            }
        }
    }
    @objc func cancelCurrent(_ sender: Any?) {
        if let token = settingsCleanupToken { token.cancel() }
        else { (operationPane ?? activePane).status.cancelJob() }
    }
    func reportError(_ error: Error) {
        if case FMError.cancelled = error { return }
        if !lastLog.hasSuffix(error.localizedDescription) { lastLog += "\n" + error.localizedDescription }
        (operationPane ?? activePane).status.showMessage(error.localizedDescription, error: true)
    }
    func showText(_ title: String, _ text: String) {
        let controller = TextWindow(title: title, text: text); auxiliaryWindows.append(controller); controller.showWindow(nil)
    }
    func obtainPassword(_ archive: ArchiveContext, force: Bool = false) -> Bool {
        var chain: [ArchiveSession] = []; var current: ArchiveSession? = archive.session
        while let session = current { chain.append(session); current = session.parent }
        for session in chain.reversed() {
            if !(force && session === archive.session) && (session.password != nil || (!session.listing.hasEncryptedHeaders && !session.listing.entries.contains(where: \.isEncrypted))) { continue }
            guard let password = UIFormat.prompt(L10n.tr("Archive password"), message: session.displayPath, secure: true) else { return false }
            session.password = password
        }
        return true
    }
    private func archiveFailure(_ archive: ArchiveContext, retry: @escaping () -> Void,
                                terminalFailure: ((Error) -> Void)? = nil) -> (Error) -> Void {
        return { [weak self] error in
            if case FMError.fileAccessRequired = error {
                guard let self = self else { return }
                let parent = archive.session.rootURL.deletingLastPathComponent()
                if self.directoryAccess.allows(parent) {
                    if let terminalFailure = terminalFailure { terminalFailure(error) } else { self.reportError(error) }
                }
                else if self.ensureFolderAccess(parent) { retry() }
            } else if case FMError.passwordForArchive(let url, _) = error {
                var current: ArchiveSession? = archive.session
                while let session = current {
                    if session.url == url {
                        if let password = UIFormat.prompt(L10n.tr("Archive password"), message: session.displayPath, secure: true) {
                            session.password = password; retry()
                        }
                        return
                    }
                    current = session.parent
                }
                if let terminalFailure = terminalFailure { terminalFailure(error) } else { self?.reportError(error) }
            } else if case FMError.passwordRequired = error {
                if self?.obtainPassword(archive, force: true) == true { retry() }
            } else if let terminalFailure = terminalFailure { terminalFailure(error) } else { self?.reportError(error) }
        }
    }
    func openURL(_ url: URL, in pane: PaneController, userSelected: Bool = false, afterOpen: ((ArchiveContext) -> Void)? = nil) {
        guard canAcceptCommands else { return }
        if userSelected {
            guard acceptUserSelectedURLs([url]) else { return }
        } else if !directoryAccess.canReadFile(url), !ensureFolderAccess(url) { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { reportError(FMError.message(L10n.tr("Path does not exist: \(url.path)"))); return }
        if isDirectory.boolValue { pane.navigate(.directory(url.standardizedFileURL)); return }
        openArchive(url, in: pane, afterOpen: afterOpen)
    }
    private func openArchive(_ url: URL, in pane: PaneController, password: String? = nil,
                             afterOpen: ((ArchiveContext) -> Void)? = nil) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            reportError(FMError.message(L10n.tr("This file cannot be read. Check its permissions and try again."))); return
        }
        let service = self.service
        perform(L10n.tr("Open archive"), showCompletion: false, work: { token, _ in try service.open(url, password: password, token: token) }, success: { [weak self, weak pane] session in
            guard let self = self, let pane = pane else { return }
            let context = ArchiveContext(session: session)
            pane.navigate(.archive(context, "")); self.activate(pane)
            NSDocumentController.shared.noteNewRecentDocumentURL(url); afterOpen?(context)
        }, failure: { [weak self, weak pane] error in
            guard let self = self, let pane = pane else { return }
            if case FMError.fileAccessRequired = error {
                let parent = url.deletingLastPathComponent()
                if self.directoryAccess.allows(parent) { self.reportError(error) }
                else if self.ensureFolderAccess(parent) { self.openArchive(url, in: pane, password: password, afterOpen: afterOpen) }
            } else if case FMError.passwordRequired = error {
                guard let password = UIFormat.prompt(L10n.tr("Archive password"), message: url.lastPathComponent, secure: true) else { return }
                self.openArchive(url, in: pane, password: password, afterOpen: afterOpen)
            } else {
                self.cannotOpenArchive(url.lastPathComponent, reveal: url, nested: false) { [weak self] in
                    self?.previewFile(url, name: url.lastPathComponent)
                }
            }
        })
    }
    private func openNested(_ row: BrowserRow, in pane: PaneController, password: String? = nil) {
        guard let parent = pane.location.archive, let index = row.member?.index, obtainPassword(parent) else { return }
        let previous = pane.location; let service = self.service
        perform(L10n.tr("Open nested archive"), showCompletion: false, work: { token, _ in
            try service.openNested(in: parent.session, index: index, password: password, token: token)
        }, success: { [weak self, weak pane] session in
            guard let self = self, let pane = pane else { return }
            let context = ArchiveContext(session: session, returnLocation: previous)
            pane.navigate(.archive(context, "")); self.activate(pane)
        }, failure: { [weak self, weak pane] error in
            guard let self = self, let pane = pane else { return }
            if case FMError.passwordForArchive = error {
                self.archiveFailure(parent, retry: { [weak self, weak pane] in
                    guard let pane = pane else { return }; self?.openNested(row, in: pane, password: password)
                })(error)
                return
            }
            if case FMError.passwordRequired = error {
                guard let password = UIFormat.prompt(L10n.tr("Archive password"), message: row.name, secure: true) else { return }
                self.openNested(row, in: pane, password: password)
            } else {
                self.cannotOpenArchive(row.name, reveal: parent.session.rootURL, nested: true) { [weak self, weak pane] in
                    guard let pane = pane else { return }; self?.preview(row, in: pane)
                }
            }
        })
    }
    private func cannotOpenArchive(_ name: String, reveal url: URL, nested: Bool, preview: @escaping () -> Void) {
        guard let window = window else { return }
        let alert = NSAlert(); alert.alertStyle = .informational
        alert.messageText = L10n.tr("This doesn't seem to be an archive")
        alert.informativeText = L10n.tr("“\(name)” isn't an archive type VibeZip recognizes. Would you like to preview this file?") +
            (nested ? L10n.tr("\n\nReveal in Finder will show the containing archive.") : "")
        alert.addButton(withTitle: L10n.tr("Preview")); alert.addButton(withTitle: L10n.tr("Reveal in Finder")); alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            // Start preview after the sheet has detached, before draining queued open requests.
            DispatchQueue.main.async {
                if response == .alertFirstButtonReturn { preview() }
                else if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                self?.onIdle?()
            }
        }
    }
    @objc func chooseOpen(_ sender: Any?) {
        guard canAcceptCommands else { return }
        defer { onIdle?() }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.directoryURL = activePane.suggestedDirectory; panel.title = L10n.tr("Choose Folder or Archive"); panel.prompt = L10n.tr("Browse")
        if panel.runModal() == .OK, let url = panel.url { openURL(url, in: activePane, userSelected: true) }
    }
    @objc func chooseFolder(_ sender: Any?) {
        guard canAcceptCommands else { return }
        defer { onIdle?() }
        do {
            if let directory = try FolderAccessPicker.choose(suggested: activePane.suggestedDirectory) { activePane.navigate(.directory(directory)) }
        } catch { reportError(error) }
    }
    func ensureFolderAccess(_ directory: URL) -> Bool {
        if directoryAccess.allows(directory) { return true }
        do {
            guard try FolderAccessPicker.choose(required: directory, suggested: directory) != nil else { return false }
            return directoryAccess.allows(directory)
        }
        catch { reportError(error); return false }
    }
    private func acceptUserSelectedURLs(_ urls: [URL]) -> Bool {
        do {
            for url in urls {
                defer { url.stopAccessingSecurityScopedResource() }
                if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    if !directoryAccess.allows(url) { try directoryAccess.authorize(url) }
                } else { try directoryAccess.retainSelectedFile(url) }
            }
            return true
        } catch { reportError(error); return false }
    }
    @objc func openAsArchive(_ sender: Any?) {
        guard canAcceptCommands, activePane.selectedRows.count == 1, let row = activePane.selectedRows.first else { return }
        let pane = activePane
        if row.isDirectory {
            if let url = row.url { pane.navigate(.directory(url)) }
            else if let archive = pane.location.archive { pane.navigate(.archive(archive, row.path)) }
        } else if let url = row.url { openArchive(url, in: pane) }
        else { openNested(row, in: pane) }
    }
    private func materialize(_ row: BrowserRow, in pane: PaneController,
                             completion: @escaping (URL, ScratchDirectory?) -> Void) {
        if let url = row.url { completion(url, nil); return }
        guard let archive = pane.location.archive, obtainPassword(archive) else { return }
        let service = self.service
        let retry = { [weak self, weak pane] in guard let self = self, let pane = pane else { return }; self.materialize(row, in: pane, completion: completion) }
        perform(L10n.tr("Extract selected file"), showCompletion: false, work: { token, output in
            let scratch = try ScratchDirectory(label: "open")
            try service.extract(archive.url, paths: [row.path], indices: row.member?.index.map { [$0] }, to: scratch.url, layout: .relativeTo(ArchivePath.parent(of: row.path)),
                password: archive.password, token: token, output: output)
            return (scratch.url.appendingPathComponent(row.name), scratch)
        }, success: { value in completion(value.0, value.1) }, failure: archiveFailure(archive, retry: retry))
    }
    @objc func previewSelected(_ sender: Any?) {
        guard canAcceptCommands, activePane.selectedRows.count == 1,
              let row = activePane.selectedRows.first, !row.isDirectory else { return }
        preview(row, in: activePane)
    }
    private func preview(_ row: BrowserRow, in pane: PaneController) {
        guard canAcceptCommands, !row.isDirectory else { return }
        materialize(row, in: pane) { [weak self] url, scratch in self?.previewFile(url, name: row.name, temporaryFile: scratch) }
    }
    private func previewFile(_ url: URL, name: String, temporaryFile: ScratchDirectory? = nil) {
        perform(L10n.tr("Prepare preview"), showCompletion: false, work: { token, _ in
            defer { withExtendedLifetime(temporaryFile) {} }
            let fingerprint = try FileFingerprint(url)
            let content = try LocalPreview.load(url, token: token)
            try token.check()
            guard try FileFingerprint(url) == fingerprint else { throw FMError.message(L10n.tr("The file changed while preparing its preview.")) }
            return content
        }, success: { [weak self] content in
            guard let self = self else { return }
            let controller = PreviewWindow(name: name, content: content)
            controller.onClose = { [weak self, weak controller] in
                DispatchQueue.main.async { self?.auxiliaryWindows.removeAll { $0 === controller } }
            }
            self.auxiliaryWindows.append(controller); controller.showWindow(nil)
        })
    }

    @objc func addArchive(_ sender: Any?) {
        guard canAcceptCommands, let directory = activePane.suggestedDirectory else { return }
        if let archive = activePane.location.archive {
            guard archive.canModify else { reportError(FMError.message(L10n.tr("This archive or its containing archive is read only. Extract it to edit a separate copy."))); return }
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
            panel.title = L10n.tr("Choose files to add"); panel.directoryURL = activePane.suggestedDirectory
            if panel.runModal() == .OK, acceptUserSelectedURLs(panel.urls) { addSources(panel.urls, to: archive, prefix: activePane.location.prefix) }
        } else {
            var urls = activePane.selectedURLs
            if urls.isEmpty {
                let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
                panel.directoryURL = activePane.suggestedDirectory
                guard panel.runModal() == .OK, acceptUserSelectedURLs(panel.urls) else { return }; urls = panel.urls
            }
            let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : L10n.tr("Archive")
            let suggested = directory.appendingPathComponent(base + ".7z")
            guard let (archive, options) = CompressionDialog(suggestedURL: suggested).run(count: urls.count) else { return }
            guard ensureFolderAccess(archive.deletingLastPathComponent()) else { return }
            let service = self.service
            perform(L10n.tr("Create archive"), work: { token, output in try service.create(urls, output: archive, options: options, token: token, progress: output) },
                success: { [weak self] _ in self?.refreshFilePanes() })
        }
    }
    private func addSources(_ urls: [URL], to archive: ArchiveContext, prefix: String, confirmAddition: Bool = true) {
        guard canAcceptCommands, archive.canModify, !urls.isEmpty else { return }
        // A matching folder can contain replacements, so ask before merging it too.
        let names = Set(urls.map(\.lastPathComponent))
        let mayReplace = archive.listing.children(of: prefix).contains { names.contains($0.name) }
        if confirmAddition || mayReplace {
            guard UIFormat.confirm(L10n.tr("Add to archive"), L10n.tr("\(urls.count) items → \(archive.url.lastPathComponent)/\(prefix)\nExisting entries with the same paths will be updated."), action: L10n.tr("Add")) else { return }
        }
        let service = self.service; let backup = keepBackups
        mutateJob(L10n.tr("Update archive"), archive: archive) { token, output in
            try service.add(urls, to: archive.url, prefix: prefix, password: archive.password,
                replaceExisting: confirmAddition || mayReplace, backup: backup, token: token, output: output)
        }
    }
    private func mutateJob(_ title: String, archive: ArchiveContext,
                           operation: @escaping (CancellationToken, @escaping (String) -> Void) throws -> MutationResult) {
        guard archive.canModify, ensureFolderAccess(archive.session.rootURL.deletingLastPathComponent()), obtainPassword(archive) else { return }
        let service = self.service
        perform(title, work: { token, output -> (MutationResult, ArchiveListing?) in
            let result = try operation(token, output)
            let listing = try? service.list(archive.url, password: archive.password, token: token)
            return (result, listing)
        }, success: { [weak self] _, listing in
            guard let self = self else { return }
            if let listing = listing { self.updateContexts(archive.url, listing: listing) }
            else { self.activePane.status.showMessage(L10n.tr("Changes saved. Refresh to reload the archive.")) }
            self.refreshFilePanes()
        }, failure: archiveFailure(archive, retry: { [weak self] in self?.mutateJob(title, archive: archive, operation: operation) }))
    }
    private func updateContexts(_ url: URL, listing: ArchiveListing) {
        panes.forEach { $0.refresh() }
    }
    private func refreshFilePanes() { for pane in panes where pane.location.directory != nil { pane.refresh() } }
    @objc func extractArchive(_ sender: Any?) {
        guard canAcceptCommands else { return }
        let pane = activePane
        guard let archive = pane.location.archive else {
            guard pane.selectedRows.count == 1, let row = pane.selectedRows.first,
                  !row.isDirectory, let url = row.url else { return }
            openURL(url, in: pane, afterOpen: { [weak self] _ in self?.extractArchive(nil) }); return
        }
        let suggested = archive.session.rootURL.deletingLastPathComponent().appendingPathComponent(archive.url.deletingPathExtension().lastPathComponent)
        guard let request = Dialogs.extraction(archive: archive, prefix: pane.isSearchingArchive ? "" : pane.location.prefix, suggested: suggested) else { return }
        guard ensureFolderAccess(request.destination) else { return }
        archive.password = request.password
        extractJob(archive, paths: pane.selectedPaths, indices: pane.selectedArchiveIndices, request: request)
    }
    private func extractJob(_ archive: ArchiveContext, paths: [String], indices: [UInt32]?, request: ExtractionRequest) {
        let service = self.service
        perform(L10n.tr("Extract files"), work: { token, output in
            try service.extract(archive.url, paths: paths, indices: indices, to: request.destination, layout: request.layout, policy: request.policy,
                password: archive.password, token: token, output: output)
        }, success: { [weak self] _ in
            self?.refreshFilePanes(); if request.reveal { NSWorkspace.shared.activateFileViewerSelecting([request.destination]) }
        }, failure: archiveFailure(archive, retry: { [weak self] in self?.extractJob(archive, paths: paths, indices: indices, request: request) }))
    }
    @objc func testArchive(_ sender: Any?) {
        guard !isBusy else { return }
        guard let archive = activePane.location.archive else {
            guard let url = activePane.selectedURLs.first else { return }
            openURL(url, in: activePane, afterOpen: { [weak self] _ in self?.testArchive(nil) }); return
        }
        guard obtainPassword(archive) else { return }
        let service = self.service
        let paths = archive.listing.selected(activePane.selectedPaths).map(\.path)
        perform(L10n.tr("Test archive"), showCompletion: false,
            work: { token, output in try service.test(archive.url, password: archive.password, paths: paths, token: token, output: output) },
            success: { [weak self] report in self?.showTestResult(archive, message: report.output, failed: false) },
            failure: archiveFailure(archive, retry: { [weak self] in self?.testArchive(nil) }, terminalFailure: { [weak self] error in
                self?.showTestResult(archive, message: error.localizedDescription, failed: true)
            }))
    }
    private func showTestResult(_ archive: ArchiveContext, message: String, failed: Bool) {
        guard let window = window else { return }
        let alert = NSAlert(); alert.alertStyle = failed ? .warning : .informational
        alert.messageText = failed ? L10n.tr("Test failed") : L10n.tr("Test passed")
        alert.informativeText = archive.url.lastPathComponent + "\n\n" + String(message.prefix(2000))
        alert.addButton(withTitle: L10n.tr("OK"))
        if failed { alert.addButton(withTitle: L10n.tr("Details…")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.showLastLog(nil) }
            self?.window?.toolbar?.validateVisibleItems(); self?.onIdle?()
        }
    }
    @objc func refreshAll(_ sender: Any?) {
        guard !isBusy else { return }
        var seen = Set<UUID>()
        let archives = panes.compactMap { $0.location.archive }.filter { seen.insert($0.id).inserted }
        if archives.isEmpty { refreshFilePanes(); return }
        let service = self.service
        perform(L10n.tr("Refresh archive"), showCompletion: false, work: { token, _ in
            try archives.map { ($0.url, try service.list($0.url, password: $0.password, token: token)) }
        }, success: { [weak self] values in
            for (url, listing) in values { self?.updateContexts(url, listing: listing) }; self?.refreshFilePanes()
        })
    }
    @objc func renameSelected(_ sender: Any?) {
        guard !isBusy, activePane.selectedRows.count == 1, let row = activePane.selectedRows.first else { return }
        guard let name = UIFormat.prompt(L10n.tr("Rename"), value: row.name), name != row.name else { return }
        do { try ArchivePath.validateName(name) } catch { reportError(error); return }
        if let url = row.url {
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            perform(L10n.tr("Rename"), work: { _, _ in
                guard !SafeFileSystem.exists(destination) else { throw FMError.message(L10n.tr("The destination name already exists.")) }
                try FileManager.default.moveItem(at: url, to: destination)
            }, success: { [weak self] _ in self?.refreshFilePanes() })
        } else if let archive = activePane.location.archive {
            let parent = ArchivePath.parent(of: row.path); let path = (parent.isEmpty ? "" : parent + "/") + name
            let service = self.service; let backup = keepBackups
            mutateJob(L10n.tr("Rename archive entry"), archive: archive) { token, output in
                try service.rename(row.path, to: path, in: archive.url, password: archive.password, backup: backup, token: token, output: output)
            }
        }
    }
    @objc func newFolder(_ sender: Any?) {
        guard !isBusy, let name = UIFormat.prompt(L10n.tr("New Folder"), value: L10n.tr("New Folder")) else { return }
        do { try ArchivePath.validateName(name) } catch { reportError(error); return }
        if let directory = activePane.location.directory {
            do {
                let url = directory.appendingPathComponent(name)
                guard !SafeFileSystem.exists(url) else { throw FMError.message(L10n.tr("An item with this name already exists.")) }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); refreshFilePanes()
            } catch { reportError(error) }
        } else if let archive = activePane.location.archive {
            let prefix = activePane.location.prefix; let service = self.service; let backup = keepBackups
            let path = (prefix.isEmpty ? "" : prefix + "/") + name
            guard !archive.listing.entries.contains(where: { ArchivePath.isWithin($0.path, parent: path) }) else { reportError(FMError.message(L10n.tr("An item with this name already exists."))); return }
            mutateJob(L10n.tr("Create folder in archive"), archive: archive) { token, output in
                let scratch = try ScratchDirectory(label: "mkdir"); let directory = scratch.url.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                return try service.add([directory], to: archive.url, prefix: prefix, password: archive.password, backup: backup, token: token, output: output)
            }
        }
    }
    @objc func deleteSelected(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if text.isEditable { text.deleteToBeginningOfLine(sender) }; return
        }
        guard NSApp.keyWindow === window, !isBusy, !activePane.selectedRows.isEmpty else { return }
        let rows = activePane.selectedRows
        if let archive = activePane.location.archive {
            guard archive.canModify, UIFormat.confirm(L10n.tr("Delete \(rows.count) items from the archive?"), L10n.tr("All contents of the selected folders will also be deleted.") + (keepBackups ? L10n.tr("\nA temporary recovery copy of the original archive will be kept.") : ""), action: L10n.tr("Delete")) else { return }
            let service = self.service; let backup = keepBackups
            mutateJob(L10n.tr("Delete from archive"), archive: archive) { token, output in
                try service.delete(rows.map(\.path), from: archive.url, password: archive.password, backup: backup, token: token, output: output)
            }
        } else {
            let urls = rows.compactMap(\.url)
            guard UIFormat.confirm(L10n.tr("Move to Trash?"), L10n.tr("\(urls.count) items and their contents will be moved to Trash."), action: L10n.tr("Move to Trash")) else { return }
            perform(L10n.tr("Move to Trash"), work: { token, output in
                for url in urls { try token.check(); try FileManager.default.trashItem(at: url, resultingItemURL: nil); output(url.path + "\n") }
            }, success: { [weak self] _ in self?.refreshFilePanes() })
        }
    }
    @objc func copyTo(_ sender: Any?) { transfer(move: false) }
    @objc func moveTo(_ sender: Any?) { transfer(move: true) }
    private func transfer(move: Bool) {
        guard !isBusy, !activePane.selectedRows.isEmpty else { return }
        let other = activePane === left ? right : left
        guard let suggested = (usesTwoPanes ? other.location.directory : nil) ?? activePane.suggestedDirectory,
              let (directory, policy) = Dialogs.destination(title: move ? L10n.tr("Move To…") : L10n.tr("Copy To…"), suggested: suggested),
              ensureFolderAccess(directory) else { return }
        let pane = activePane
        if let archive = pane.location.archive {
            guard !move || archive.canModify, obtainPassword(archive) else { return }
            if move && !ensureFolderAccess(archive.session.rootURL.deletingLastPathComponent()) { return }
            let paths = pane.selectedPaths; let indices = pane.selectedArchiveIndices
            let prefix = pane.location.prefix; let service = self.service; let backup = keepBackups
            perform(move ? L10n.tr("Move from archive") : L10n.tr("Copy from archive"), work: { token, output -> ArchiveListing? in
                let before = try FileFingerprint(archive.session.rootURL)
                let report = try service.extract(archive.url, paths: paths, indices: indices, to: directory, layout: .relativeTo(prefix), policy: policy,
                    password: archive.password, token: token, output: output)
                if move {
                    guard report.skipped == 0 else { throw FMError.message(L10n.tr("Some files were skipped. All original archive entries have been kept, along with the files already copied.")) }
                    guard try FileFingerprint(archive.session.rootURL) == before else { throw FMError.message(L10n.tr("The archive changed after copying. The original entries were kept.")) }
                    _ = try service.delete(paths, from: archive.url, password: archive.password, backup: backup, token: token, output: output)
                    return try? service.list(archive.url, password: archive.password, token: token)
                }
                return nil
            }, success: { [weak self] listing in
                if let listing = listing { self?.updateContexts(archive.url, listing: listing) }; self?.refreshFilePanes()
            })
        } else { transferFiles(pane.selectedURLs, to: directory, policy: policy, move: move) }
    }
    private func transferFiles(_ urls: [URL], to directory: URL, policy: ConflictPolicy, move: Bool) {
        perform(move ? L10n.tr("Move files") : L10n.tr("Copy files"), work: { token, output in
            try FileOperations.copy(urls, to: directory, move: move, policy: policy, token: token, output: output)
        }, success: { [weak self] _ in self?.refreshFilePanes() })
    }
    func receiveDropped(_ urls: [URL], in pane: PaneController, into destination: BrowserLocation) -> Bool {
        guard canAcceptCommands, !hasActiveOperations, !urls.isEmpty else { return false }
        defer { onIdle?() }
        if destination.isEmpty || destination.archive?.canModify == false {
            guard urls.count == 1, let url = urls.first else { return false }
            activate(pane)
            // The drop grants access to this URL, not its parent folder.
            openURL(url, in: pane, userSelected: true)
            return true
        }
        activate(pane)
        if let archive = destination.archive {
            let target = destination.prefix.isEmpty ? archive.url.lastPathComponent : archive.url.lastPathComponent + "/" + destination.prefix
            switch Dialogs.archiveDrop(urls, destination: target) {
            case .open:
                guard urls.count == 1, let url = urls.first else { return false }
                openURL(url, in: pane, userSelected: true)
            case .add:
                guard acceptUserSelectedURLs(urls) else { return false }
                addSources(urls, to: archive, prefix: destination.prefix, confirmAddition: false)
            case .cancel: return false
            }
            return true
        }
        guard acceptUserSelectedURLs(urls) else { return false }
        if let directory = destination.directory, ensureFolderAccess(directory) {
            transferFiles(urls, to: directory, policy: .rename, move: false)
            return true
        }
        return false
    }
    private func materializeSelection(_ pane: PaneController, completion: @escaping ([URL]) -> Void) {
        let rows = pane.selectedRows
        guard !rows.isEmpty else { return }
        if pane.location.directory != nil { completion(rows.compactMap(\.url)); return }
        guard let archive = pane.location.archive, obtainPassword(archive) else { return }
        let service = self.service; let prefix = pane.location.prefix; let indices = pane.selectedArchiveIndices
        perform(L10n.tr("Extract selected items"), work: { token, output in
            let scratch = try ScratchDirectory(label: "selection")
            try service.extract(archive.url, paths: rows.map(\.path), indices: indices, to: scratch.url, layout: .relativeTo(prefix),
                password: archive.password, token: token, output: output)
            return (scratch, rows.map { scratch.url.appendingPathComponent($0.name) })
        }, success: { [weak self] scratch, urls in self?.workspace.temporaryFiles.append(scratch); completion(urls) },
            failure: archiveFailure(archive, retry: { [weak self, weak pane] in
                guard let pane = pane else { return }; self?.materializeSelection(pane, completion: completion)
            }))
    }
    @objc func copySelection(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.copy(sender); return }
        guard NSApp.keyWindow === window, !isBusy else { return }
        materializeSelection(activePane) { urls in
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL])
        }
    }
    @objc func cutSelection(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if text.isEditable { text.cut(sender) }; return
        }
        guard NSApp.keyWindow === window, !isBusy, activePane.location.directory != nil, !activePane.selectedURLs.isEmpty else { return }
        let type = NSPasteboard.PasteboardType("org.vibezip.cut")
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(activePane.selectedURLs as [NSURL])
        NSPasteboard.general.addTypes([type], owner: nil); NSPasteboard.general.setString("move", forType: type)
    }
    @objc func pasteSelection(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if text.isEditable { text.paste(sender) }; return
        }
        guard NSApp.keyWindow === window, !isBusy, let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        guard acceptUserSelectedURLs(urls) else { return }
        if let archive = activePane.location.archive { addSources(urls, to: archive, prefix: activePane.location.prefix) }
        else if let directory = activePane.location.directory {
            let move = NSPasteboard.general.string(forType: NSPasteboard.PasteboardType("org.vibezip.cut")) == "move"
            if move && !UIFormat.confirm(L10n.tr("Move files from the clipboard?"), L10n.tr("Source files will be removed after copying. Name conflicts will be resolved by renaming the new files."), action: L10n.tr("Move")) { return }
            transferFiles(urls, to: directory, policy: .rename, move: move)
            // Clear move intent immediately; a second paste should never move files twice.
            if move { NSPasteboard.general.clearContents() }
        }
    }
    @objc func selectAllItems(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.selectAll(sender) }
        else if NSApp.keyWindow === window { activePane.selectAllRows() }
    }
    @objc func invertSelection(_ sender: Any?) { activePane.invertSelection() }
    @objc func hashSelected(_ sender: Any?) {
        guard !isBusy else { return }
        let algorithm = (sender as? NSMenuItem)?.representedObject as? String ?? "SHA256"
        materializeSelection(activePane) { [weak self] urls in
            guard let self = self else { return }; let service = self.service
            self.perform(L10n.tr("Calculate \(algorithm)"), work: { token, output in try service.hash(urls, algorithm: algorithm, token: token, output: output) },
                success: { [weak self] result in self?.showText(L10n.tr("\(algorithm) Checksums"), result.output) })
        }
    }
    @objc func properties(_ sender: Any?) {
        browserLayout?.toggleInfo()
    }
    @objc func toggleTwoPanels(_ sender: Any?) {
        guard canAcceptCommands else { return }
        usesTwoPanes.toggle()
        UserDefaults.standard.set(usesTwoPanes, forKey: "twoPanels")
        browserLayout?.setTwoPanes(usesTwoPanes)
        if usesTwoPanes && right.location.isEmpty { right.navigate(left.location) }
        activate(usesTwoPanes ? activePane : left)
    }
    func switchPane() {
        if usesTwoPanes && canAcceptCommands { activate(activePane === left ? right : left) }
    }
    @objc func togglePlaces(_ sender: Any?) { browserLayout?.togglePlaces() }
    @objc func changeViewStyle(_ sender: Any?) {
        let index = (sender as? NSSegmentedControl)?.selectedSegment ?? (sender as? NSMenuItem)?.tag ?? 2
        guard let style = BrowserViewStyle(rawValue: index) else { return }
        activePane.setViewStyle(style); viewPicker?.selectedSegment = index
    }
    @objc func revealInFinder(_ sender: Any?) {
        let urls = activePane.selectedURLs
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        else if let archive = activePane.location.archive { NSWorkspace.shared.activateFileViewerSelecting([archive.session.rootURL]) }
        else if let directory = activePane.suggestedDirectory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
    }
    @objc func focusAddress(_ sender: Any?) { activePane.focusAddress() }
    @objc func focusSearch(_ sender: Any?) { activePane.focusSearch() }
    @objc func goUp(_ sender: Any?) { activePane.goUp() }
    @objc func goBack(_ sender: Any?) { activePane.goBack() }
    @objc func goForward(_ sender: Any?) { activePane.goForward() }
    @objc func toggleHidden(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "showHidden"), forKey: "showHidden"); applyPreferences()
    }
    @objc func showPreferences(_ sender: Any?) {
        editPreferences(folderAccess: false)
    }
    @objc func showFolderAccess(_ sender: Any?) {
        editPreferences(folderAccess: true)
    }
    private func editPreferences(folderAccess: Bool) {
        guard canAcceptCommands, !hasActiveOperations, canManageSharedAccess?() != false else { return }
        defer { onIdle?() }
        let changed = Dialogs.preferences(folderAccess: folderAccess) { [weak self] token in self?.settingsCleanupToken = token }
        panes.forEach { $0.discardRevokedLocations() }
        if changed { applyPreferences() }
    }
    @objc func forgetPasswords(_ sender: Any?) {
        service.forgetPasswords()
        activePane.status.showMessage(L10n.tr("Passwords cleared."))
    }
    @objc func showLastLog(_ sender: Any?) { showText(L10n.tr("Last operation log"), lastLog) }
    @objc func engineInformation(_ sender: Any?) {
        showText(L10n.tr("Archive Formats"), service.engine.formats())
    }
    @objc func splitFile(_ sender: Any?) {
        guard !isBusy, activePane.selectedURLs.count == 1, let source = activePane.selectedURLs.first else { return }
        guard let text = UIFormat.prompt(L10n.tr("Split File"), message: L10n.tr("Split a file into byte volumes. Enter a size such as 100m or 4g."), value: "100m") else { return }
        do {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value.range(of: "^[1-9][0-9]*[kmg]?$", options: .regularExpression) != nil else { throw FMError.message(L10n.tr("Invalid volume size.")) }
            let factors: [Character: UInt64] = ["k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024]
            let factor = value.last.flatMap { factors[$0] } ?? 1
            guard let amount = UInt64(factor == 1 ? value : String(value.dropLast())) else { throw FMError.message(L10n.tr("The volume size is too large.")) }
            let (bytes, overflow) = amount.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw FMError.message(L10n.tr("The volume size is too large.")) }
            let panel = NSSavePanel(); panel.title = L10n.tr("Choose a base name for the volumes")
            panel.directoryURL = source.deletingLastPathComponent(); panel.nameFieldStringValue = source.lastPathComponent + ".split"
            guard panel.runModal() == .OK, let base = panel.url else { return }
            guard ensureFolderAccess(base.deletingLastPathComponent()) else { return }
            perform(L10n.tr("Split File"), work: { token, output in try FileOperations.split(source, to: base, volumeBytes: bytes, token: token, output: output) },
                success: { [weak self] _ in self?.refreshFilePanes() })
        } catch { reportError(error) }
    }
    @objc func combineFiles(_ sender: Any?) {
        guard !isBusy, let first = activePane.selectedURLs.first, first.pathExtension == "001" else { return }
        let panel = NSSavePanel(); panel.directoryURL = first.deletingLastPathComponent(); panel.title = L10n.tr("Combine File Volumes")
        panel.message = L10n.tr("All consecutive volumes must be present, including the last one.")
        panel.nameFieldStringValue = "Combined-" + first.deletingPathExtension().lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard ensureFolderAccess(destination.deletingLastPathComponent()) else { return }
        perform(L10n.tr("Combine Files"), work: { token, output in try FileOperations.combine(first, to: destination, token: token, output: output) },
            success: { [weak self] _ in self?.refreshFilePanes() })
    }

    func closeAuxiliaryWindows() {
        for controller in auxiliaryWindows { controller.close() }
        auxiliaryWindows.removeAll()
    }
    @objc func showHelp(_ sender: Any?) {
        let url = L10n.resourceURL("Help", extension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L10n.tr("See macOS/README.md in the source package.")
        showText(L10n.tr("VibeZip Help"), text)
    }
    @objc func showPrivacyPolicy(_ sender: Any?) {
        let url = L10n.resourceURL("Privacy", extension: "txt")
        showText(L10n.tr("VibeZip Privacy"), url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L10n.tr("The privacy notice is unavailable. Please reinstall VibeZip."))
    }

    private var toolbarItems: [(String, String, String, Selector)] {
        [
            ("sidebar", L10n.tr("Sidebar"), "sidebar.left", #selector(togglePlaces)),
            ("twoPanels", L10n.tr("2 Panels"), "rectangle.split.2x1", #selector(toggleTwoPanels)),
            ("back", L10n.tr("Back"), "chevron.left", #selector(goBack)),
            ("forward", L10n.tr("Forward"), "chevron.right", #selector(goForward)),
            ("up", L10n.tr("Up"), "arrow.up", #selector(goUp)),
            ("add", L10n.tr("Add"), "archivebox", #selector(addArchive)),
            ("extract", L10n.tr("Extract"), "square.and.arrow.up.on.square", #selector(extractArchive)),
            ("test", L10n.tr("Test"), "checkmark.seal", #selector(testArchive)),
            ("copy", L10n.tr("Copy"), "doc.on.doc", #selector(copyTo)),
            ("move", L10n.tr("Move"), "folder", #selector(moveTo)),
            ("delete", L10n.tr("Delete"), "trash", #selector(deleteSelected)),
            ("preview", L10n.tr("Preview"), "eye", #selector(previewSelected)),
            ("info", L10n.tr("Info"), "info.circle", #selector(properties)),
            ("refresh", L10n.tr("Refresh"), "arrow.clockwise", #selector(refreshAll)),
        ]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems.map { NSToolbarItem.Identifier($0.0) } + [NSToolbarItem.Identifier("viewStyle"), NSToolbarItem.Identifier("search"), .flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["sidebar", "back", "forward"].map { NSToolbarItem.Identifier($0) } + [.flexibleSpace] +
            ["add", "extract", "test"].map { NSToolbarItem.Identifier($0) } + [.space] +
            ["copy", "move", "delete", "preview", "info", "viewStyle", "twoPanels", "search"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField = activePane.search; item.label = L10n.tr("Filter"); item.paletteLabel = L10n.tr("Filter")
            item.visibilityPriority = .high; searchItem = item; return item
        }
        if itemIdentifier.rawValue == "viewStyle" {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier); item.label = L10n.tr("View"); item.paletteLabel = L10n.tr("View")
            let picker = NSSegmentedControl(images: ["square.grid.2x2", "list.bullet", "list.bullet.rectangle"].map {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
            }, trackingMode: .selectOne, target: self, action: #selector(changeViewStyle))
            picker.selectedSegment = activePane.viewStyle.rawValue
            for (index, title) in [L10n.tr("Icons"), L10n.tr("List"), L10n.tr("Details")].enumerated() { picker.setToolTip(title, forSegment: index) }
            picker.setAccessibilityLabel(L10n.tr("File view"))
            let overflow = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            let modes = NSMenu(title: item.label)
            for (index, title) in [L10n.tr("Icons"), L10n.tr("List"), L10n.tr("Details")].enumerated() {
                let choice = menuItem(title, #selector(changeViewStyle)); choice.tag = index
                modes.addItem(choice)
            }
            overflow.submenu = modes; item.menuFormRepresentation = overflow
            item.view = picker; viewPicker = picker; return item
        }
        guard let definition = toolbarItems.first(where: { $0.0 == itemIdentifier.rawValue }) else { return nil }
        let isNavigation = ["sidebar", "back", "forward", "up"].contains(definition.0)
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = isNavigation ? "" : definition.1; item.paletteLabel = definition.1
        item.isNavigational = isNavigation
        item.image = NSImage(systemSymbolName: definition.2, accessibilityDescription: definition.1)
        item.toolTip = definition.1
        if isNavigation {
            item.menuFormRepresentation = menuItem(definition.1, definition.3)
            item.visibilityPriority = .high
        }
        item.target = self; item.action = definition.3; return item
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { canAcceptCommands && isActionEnabled(item.action) }
    func menuItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = modifiers; return item
    }
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action): (String, Selector) in [
            (L10n.tr("Open"), #selector(openAsArchive)),
            (L10n.tr("Preview"), #selector(previewSelected)),
            (L10n.tr("Reveal in Finder"), #selector(revealInFinder)),
            (L10n.tr("Extract"), #selector(extractArchive)),
            (L10n.tr("Add to Archive"), #selector(addArchive)),
            (L10n.tr("Info"), #selector(properties))
        ] { menu.addItem(menuItem(title, action)) }
        return menu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            switch menuItem.action {
            case #selector(copySelection): return text.isSelectable && text.selectedRange().length > 0
            case #selector(selectAllItems): return text.isSelectable
            case #selector(cutSelection), #selector(pasteSelection), #selector(deleteSelected): return text.isEditable
            default: break
            }
        }
        if NSApp.keyWindow !== window {
            return [#selector(chooseOpen), #selector(showHelp), #selector(showPrivacyPolicy), #selector(showLastLog)].contains(menuItem.action)
        }
        if window?.attachedSheet != nil { return false }
        if isBusy { return menuItem.action == #selector(cancelCurrent) }
        if menuItem.menu === activePane.table.menu && activePane.selectedRows.isEmpty { return false }
        if menuItem.action == #selector(toggleHidden) {
            menuItem.state = UserDefaults.standard.bool(forKey: "showHidden") ? .on : .off
        }
        if menuItem.action == #selector(togglePlaces) { menuItem.state = browserLayout?.placesItem.isCollapsed == false ? .on : .off }
        if menuItem.action == #selector(properties) { menuItem.state = browserLayout?.infoItem.isCollapsed == false ? .on : .off }
        if menuItem.action == #selector(changeViewStyle) { menuItem.state = menuItem.tag == activePane.viewStyle.rawValue ? .on : .off }
        if menuItem.action == #selector(toggleTwoPanels) { menuItem.state = usesTwoPanes ? .on : .off }
        return isActionEnabled(menuItem.action)
    }
    private func isActionEnabled(_ action: Selector?) -> Bool {
        if [#selector(togglePlaces), #selector(properties), #selector(changeViewStyle), #selector(toggleTwoPanels)].contains(action) { return true }
        if [#selector(showPreferences), #selector(showFolderAccess)].contains(action) {
            return !hasActiveOperations && canManageSharedAccess?() != false
        }
        if activePane.location.isEmpty {
            return [#selector(chooseOpen), #selector(chooseFolder), #selector(focusAddress), #selector(showHelp), #selector(showPrivacyPolicy),
                    #selector(showLastLog), #selector(engineInformation), #selector(forgetPasswords), #selector(toggleHidden)].contains(action)
        }
        let selected = activePane.selectedRows
        let archive = activePane.location.archive
        let editable = archive == nil || archive?.canModify == true
        switch action {
        case #selector(goBack): return activePane.canGoBack
        case #selector(goForward): return activePane.canGoForward
        case #selector(goUp): return activePane.canGoUp
        case #selector(renameSelected): return editable && selected.count == 1
        case #selector(deleteSelected), #selector(moveTo): return editable && !selected.isEmpty
        case #selector(pasteSelection): return editable
        case #selector(addArchive), #selector(newFolder): return editable
        case #selector(copyTo), #selector(hashSelected): return !selected.isEmpty
        case #selector(previewSelected): return selected.count == 1 && !selected[0].isDirectory
        case #selector(openAsArchive): return selected.count == 1
        case #selector(extractArchive), #selector(testArchive): return archive != nil || (selected.count == 1 && !selected[0].isDirectory)
        case #selector(splitFile): return selected.count == 1 && selected[0].url != nil && !selected[0].isDirectory
        case #selector(combineFiles): return selected.count == 1 && selected[0].url?.pathExtension == "001"
        case #selector(cutSelection): return activePane.location.directory != nil
        default: break
        }
        return true
    }
}
#endif
