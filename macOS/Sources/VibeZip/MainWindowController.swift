#if os(macOS)
import AppKit
import VibeZipCore

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSWindowDelegate, NSMenuItemValidation {
    let service: ArchiveService
    let directoryAccess = DirectoryAccessStore.shared
    let workQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "VibeZip.operations"; queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated; return queue
    }()
    let left: PaneController
    private(set) var isBusy = false { didSet { window?.toolbar?.validateVisibleItems() } }
    var onIdle: (() -> Void)?
    private var currentToken: CancellationToken?
    private var progressWindow: OperationProgressWindow?
    private var lastLog = "No operations yet."
    private var auxiliaryWindows: [NSWindowController] = []
    private var temporaryFiles: [ScratchDirectory] = []
    var activePane: PaneController { left }
    var keepBackups: Bool { UserDefaults.standard.bool(forKey: "keepBackups") }
    var hasActiveOperations: Bool { isBusy || workQueue.operationCount > 0 }
    var canAcceptCommands: Bool { !isBusy && window?.attachedSheet == nil && NSApp.modalWindow == nil }

    init(service: ArchiveService) {
        self.service = service
        left = PaneController(directory: directoryAccess.restoreLastDirectory())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VibeZip"; window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false; window.setFrameAutosaveName("VibeZip.MainWindow.Native")
        super.init(window: window)
        window.delegate = self
        left.owner = self
        window.contentView = left.view
        left.status.onDetails = { [weak self] in self?.showLastLog(nil) }
        left.status.onCancel = { [weak self] in self?.progressWindow?.showCancelling() }
        let toolbar = NSToolbar(identifier: "VibeZip.Toolbar.Native"); toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = .unified
        migrateToolbar(toolbar)
        left.table.menu = makeContextMenu()
        applyPreferences(); activate(left)
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    func activate(_ pane: PaneController) {
        window?.makeFirstResponder(pane.table); updateTitle()
    }
    func updateTitle() {
        let name = activePane.location.archive?.url.lastPathComponent ?? activePane.suggestedDirectory?.lastPathComponent
        window?.title = name.map { "VibeZip — " + $0 } ?? "VibeZip"
        if let directory = left.location.directory { directoryAccess.remember(directory) }
        window?.toolbar?.validateVisibleItems()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasActiveOperations { NSSound.beep(); return false }
        return true
    }
    @objc private func appActivated() {
        guard canAcceptCommands, !hasActiveOperations else { return }
        directoryAccess.refreshUnavailable(); left.discardRevokedLocations()
    }
    func applyPreferences() {
        let defaults = UserDefaults.standard
        let configuredLimit = max(1, min(100_000, defaults.integer(forKey: "extractionLimitGiB")))
        service.extractionLimit = UInt64(configuredLimit) * 1024 * 1024 * 1024
        left.refresh()
    }
    func perform<T>(_ title: String, showCompletion: Bool = true, work: @escaping (CancellationToken, @escaping (String) -> Void) throws -> T,
                    success: @escaping (T) -> Void = { _ in }, failure: ((Error) -> Void)? = nil) {
        guard canAcceptCommands, window != nil else { return }
        isBusy = true; let token = CancellationToken(); currentToken = token
        left.status.begin(title, token: token)
        let startedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak token] in
            guard let self = self, let token = token, self.currentToken === token, !token.isCancelled,
                  let window = self.window, window.isVisible else { return }
            let progress = OperationProgressWindow(title: title, token: token, startedAt: startedAt,
                cancel: { [weak self] in self?.cancelCurrent(nil) })
            progress.append(self.left.status.message.stringValue)
            if let value = self.left.status.currentProgress { progress.update(value) }
            self.progressWindow = progress; progress.show(attachedTo: window)
        }
        let output = JobOutput(receive: { [weak self] chunk in
            guard let self = self, self.currentToken === token else { return }
            self.left.status.append(chunk); self.progressWindow?.append(chunk)
        }, progress: { [weak self] value in
            guard let self = self, self.currentToken === token else { return }
            self.left.status.update(value); self.progressWindow?.update(value)
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
                self.isBusy = false; self.currentToken = nil; self.left.status.finish()
                switch result {
                case .success(let value):
                    self.lastLog += "\nCompleted."
                    if showCompletion { self.left.status.showMessage(title + " completed.") }
                    success(value)
                case .failure(let error):
                    self.lastLog += "\n" + error.localizedDescription
                    if case FMError.cancelled = error {
                        self.left.status.showMessage("Cancelled. Completed file copies are kept.")
                    } else if let failure = failure { failure(error) } else { self.reportError(error) }
                }
                self.updateTitle()
                self.onIdle?()
            }
        }
    }
    @objc func cancelCurrent(_ sender: Any?) { left.status.cancelJob() }
    func reportError(_ error: Error) {
        if case FMError.cancelled = error { return }
        if !lastLog.hasSuffix(error.localizedDescription) { lastLog += "\n" + error.localizedDescription }
        left.status.showMessage(error.localizedDescription, error: true)
    }
    func showText(_ title: String, _ text: String) {
        let controller = TextWindow(title: title, text: text); auxiliaryWindows.append(controller); controller.showWindow(nil)
    }
    func obtainPassword(_ archive: ArchiveContext, force: Bool = false) -> Bool {
        var chain: [ArchiveSession] = []; var current: ArchiveSession? = archive.session
        while let session = current { chain.append(session); current = session.parent }
        for session in chain.reversed() {
            if !(force && session === archive.session) && (session.password != nil || (!session.listing.hasEncryptedHeaders && !session.listing.entries.contains(where: \.isEncrypted))) { continue }
            guard let password = UIFormat.prompt("Archive password", message: session.displayPath, secure: true) else { return false }
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
                        if let password = UIFormat.prompt("Archive password", message: session.displayPath, secure: true) {
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
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { reportError(FMError.message("Path does not exist: \(url.path)")); return }
        if isDirectory.boolValue { pane.navigate(.directory(url.standardizedFileURL)); return }
        openArchive(url, in: pane, afterOpen: afterOpen)
    }
    private func openArchive(_ url: URL, in pane: PaneController, password: String? = nil,
                             afterOpen: ((ArchiveContext) -> Void)? = nil) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            reportError(FMError.message("This file cannot be read. Check its permissions and try again.")); return
        }
        let service = self.service
        perform("Open archive", showCompletion: false, work: { token, _ in try service.open(url, password: password, token: token) }, success: { [weak self, weak pane] session in
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
                guard let password = UIFormat.prompt("Archive password", message: url.lastPathComponent, secure: true) else { return }
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
        perform("Open nested archive", showCompletion: false, work: { token, _ in
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
                guard let password = UIFormat.prompt("Archive password", message: row.name, secure: true) else { return }
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
        alert.messageText = "This doesn't seem to be an archive"
        alert.informativeText = "“\(name)” isn't an archive type VibeZip recognizes. Would you like to preview this file?" +
            (nested ? "\n\nReveal in Finder will show the containing archive." : "")
        alert.addButton(withTitle: "Preview"); alert.addButton(withTitle: "Reveal in Finder"); alert.addButton(withTitle: "Cancel")
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
        panel.directoryURL = activePane.suggestedDirectory; panel.title = "Choose Folder or Archive"; panel.prompt = "Browse"
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
        perform("Extract selected file", showCompletion: false, work: { token, output in
            let scratch = try ScratchDirectory(label: "open")
            try service.extract(archive.url, paths: [row.path], indices: row.member?.index.map { [$0] }, to: scratch.url, layout: .relativeTo(ArchivePath.parent(of: row.path)),
                password: archive.password, token: token, output: output)
            return (scratch.url.appendingPathComponent(row.name), scratch)
        }, success: { [weak self] value in self?.temporaryFiles.append(value.1); completion(value.0, value.1) }, failure: archiveFailure(archive, retry: retry))
    }
    @objc func previewSelected(_ sender: Any?) {
        guard canAcceptCommands, activePane.selectedRows.count == 1,
              let row = activePane.selectedRows.first, !row.isDirectory else { return }
        preview(row, in: activePane)
    }
    private func preview(_ row: BrowserRow, in pane: PaneController) {
        guard canAcceptCommands, !row.isDirectory else { return }
        materialize(row, in: pane) { [weak self] url, _ in self?.previewFile(url, name: row.name) }
    }
    private func previewFile(_ url: URL, name: String) {
        perform("Prepare preview", showCompletion: false, work: { token, _ in
            let fingerprint = try FileFingerprint(url)
            let content = try LocalPreview.load(url, token: token)
            try token.check()
            guard try FileFingerprint(url) == fingerprint else { throw FMError.message("The file changed while preparing its preview.") }
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
            guard archive.canModify else { reportError(FMError.message("This archive or its containing archive is read only. Extract it to edit a separate copy.")); return }
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
            panel.title = "Choose files to add"; panel.directoryURL = activePane.suggestedDirectory
            if panel.runModal() == .OK, acceptUserSelectedURLs(panel.urls) { addSources(panel.urls, to: archive, prefix: activePane.location.prefix) }
        } else {
            var urls = activePane.selectedURLs
            if urls.isEmpty {
                let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
                panel.directoryURL = activePane.suggestedDirectory
                guard panel.runModal() == .OK, acceptUserSelectedURLs(panel.urls) else { return }; urls = panel.urls
            }
            let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
            let suggested = directory.appendingPathComponent(base + ".7z")
            guard let (archive, options) = CompressionDialog(suggestedURL: suggested).run(count: urls.count) else { return }
            guard ensureFolderAccess(archive.deletingLastPathComponent()) else { return }
            let service = self.service
            perform("Create archive", work: { token, output in try service.create(urls, output: archive, options: options, token: token, progress: output) },
                success: { [weak self] _ in self?.refreshFilePanes() })
        }
    }
    private func addSources(_ urls: [URL], to archive: ArchiveContext, prefix: String) {
        guard archive.canModify, !urls.isEmpty else { return }
        guard UIFormat.confirm("Add to archive", "\(urls.count) items → \(archive.url.lastPathComponent)/\(prefix)\nExisting entries with the same paths will be updated.", action: "Add") else { return }
        let service = self.service; let backup = keepBackups
        mutateJob("Update archive", archive: archive) { token, output in
            try service.add(urls, to: archive.url, prefix: prefix, password: archive.password, backup: backup, token: token, output: output)
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
            else { self.left.status.showMessage("Changes saved. Refresh to reload the archive.") }
            self.refreshFilePanes()
        }, failure: archiveFailure(archive, retry: { [weak self] in self?.mutateJob(title, archive: archive, operation: operation) }))
    }
    private func updateContexts(_ url: URL, listing: ArchiveListing) {
        left.refresh()
    }
    private func refreshFilePanes() { for pane in [left] where pane.location.directory != nil { pane.refresh() } }
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
        perform("Extract files", work: { token, output in
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
        perform("Test archive", showCompletion: false,
            work: { token, output in try service.test(archive.url, password: archive.password, paths: paths, token: token, output: output) },
            success: { [weak self] report in self?.showTestResult(archive, message: report.output, failed: false) },
            failure: archiveFailure(archive, retry: { [weak self] in self?.testArchive(nil) }, terminalFailure: { [weak self] error in
                self?.showTestResult(archive, message: error.localizedDescription, failed: true)
            }))
    }
    private func showTestResult(_ archive: ArchiveContext, message: String, failed: Bool) {
        guard let window = window else { return }
        let alert = NSAlert(); alert.alertStyle = failed ? .warning : .informational
        alert.messageText = failed ? "Test failed" : "Test passed"
        alert.informativeText = archive.url.lastPathComponent + "\n\n" + String(message.prefix(2000))
        alert.addButton(withTitle: "OK")
        if failed { alert.addButton(withTitle: "Details…") }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.showLastLog(nil) }
            self?.window?.toolbar?.validateVisibleItems(); self?.onIdle?()
        }
    }
    @objc func refreshAll(_ sender: Any?) {
        guard !isBusy else { return }
        let archives = [left.location.archive].compactMap { $0 }
        if archives.isEmpty { refreshFilePanes(); return }
        let service = self.service
        perform("Refresh archive", showCompletion: false, work: { token, _ in
            try archives.map { ($0.url, try service.list($0.url, password: $0.password, token: token)) }
        }, success: { [weak self] values in
            for (url, listing) in values { self?.updateContexts(url, listing: listing) }; self?.refreshFilePanes()
        })
    }
    @objc func renameSelected(_ sender: Any?) {
        guard !isBusy, activePane.selectedRows.count == 1, let row = activePane.selectedRows.first else { return }
        guard let name = UIFormat.prompt("Rename", value: row.name), name != row.name else { return }
        do { try ArchivePath.validateName(name) } catch { reportError(error); return }
        if let url = row.url {
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            perform("Rename", work: { _, _ in
                guard !SafeFileSystem.exists(destination) else { throw FMError.message("The destination name already exists.") }
                try FileManager.default.moveItem(at: url, to: destination)
            }, success: { [weak self] _ in self?.refreshFilePanes() })
        } else if let archive = activePane.location.archive {
            let parent = ArchivePath.parent(of: row.path); let path = (parent.isEmpty ? "" : parent + "/") + name
            let service = self.service; let backup = keepBackups
            mutateJob("Rename archive entry", archive: archive) { token, output in
                try service.rename(row.path, to: path, in: archive.url, password: archive.password, backup: backup, token: token, output: output)
            }
        }
    }
    @objc func newFolder(_ sender: Any?) {
        guard !isBusy, let name = UIFormat.prompt("New Folder", value: "New Folder") else { return }
        do { try ArchivePath.validateName(name) } catch { reportError(error); return }
        if let directory = activePane.location.directory {
            do {
                let url = directory.appendingPathComponent(name)
                guard !SafeFileSystem.exists(url) else { throw FMError.message("An item with this name already exists.") }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); refreshFilePanes()
            } catch { reportError(error) }
        } else if let archive = activePane.location.archive {
            let prefix = activePane.location.prefix; let service = self.service; let backup = keepBackups
            let path = (prefix.isEmpty ? "" : prefix + "/") + name
            guard !archive.listing.entries.contains(where: { ArchivePath.isWithin($0.path, parent: path) }) else { reportError(FMError.message("An item with this name already exists.")); return }
            mutateJob("Create folder in archive", archive: archive) { token, output in
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
            guard archive.canModify, UIFormat.confirm("Delete \(rows.count) items from the archive?", "All contents of the selected folders will also be deleted." + (keepBackups ? "\nA backup of the original archive will be kept." : "\nArchive backups are currently disabled."), action: "Delete") else { return }
            let service = self.service; let backup = keepBackups
            mutateJob("Delete from archive", archive: archive) { token, output in
                try service.delete(rows.map(\.path), from: archive.url, password: archive.password, backup: backup, token: token, output: output)
            }
        } else {
            let urls = rows.compactMap(\.url)
            guard UIFormat.confirm("Move to Trash?", "\(urls.count) items and their contents will be moved to Trash.", action: "Move to Trash") else { return }
            perform("Move to Trash", work: { token, output in
                for url in urls { try token.check(); try FileManager.default.trashItem(at: url, resultingItemURL: nil); output(url.path + "\n") }
            }, success: { [weak self] _ in self?.refreshFilePanes() })
        }
    }
    @objc func copyTo(_ sender: Any?) { transfer(move: false) }
    @objc func moveTo(_ sender: Any?) { transfer(move: true) }
    private func transfer(move: Bool) {
        guard !isBusy, !activePane.selectedRows.isEmpty else { return }
        guard let suggested = activePane.suggestedDirectory,
              let (directory, policy) = Dialogs.destination(title: move ? "Move To…" : "Copy To…", suggested: suggested),
              ensureFolderAccess(directory) else { return }
        let pane = activePane
        if let archive = pane.location.archive {
            guard !move || archive.canModify, obtainPassword(archive) else { return }
            if move && !ensureFolderAccess(archive.session.rootURL.deletingLastPathComponent()) { return }
            let paths = pane.selectedPaths; let indices = pane.selectedArchiveIndices
            let prefix = pane.location.prefix; let service = self.service; let backup = keepBackups
            perform(move ? "Move from archive" : "Copy from archive", work: { token, output -> ArchiveListing? in
                let before = try FileFingerprint(archive.session.rootURL)
                let report = try service.extract(archive.url, paths: paths, indices: indices, to: directory, layout: .relativeTo(prefix), policy: policy,
                    password: archive.password, token: token, output: output)
                if move {
                    guard report.skipped == 0 else { throw FMError.message("Some files were skipped. All original archive entries have been kept, along with the files already copied.") }
                    guard try FileFingerprint(archive.session.rootURL) == before else { throw FMError.message("The archive changed after copying. The original entries were kept.") }
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
        perform(move ? "Move files" : "Copy files", work: { token, output in
            try FileOperations.copy(urls, to: directory, move: move, policy: policy, token: token, output: output)
        }, success: { [weak self] _ in self?.refreshFilePanes() })
    }
    func receiveDropped(_ urls: [URL], in pane: PaneController) {
        guard acceptUserSelectedURLs(urls) else { return }
        if let archive = pane.location.archive { addSources(urls, to: archive, prefix: pane.location.prefix) }
        else if let directory = pane.location.directory { transferFiles(urls, to: directory, policy: .rename, move: false) }
    }
    private func materializeSelection(_ pane: PaneController, completion: @escaping ([URL]) -> Void) {
        let rows = pane.selectedRows
        guard !rows.isEmpty else { return }
        if pane.location.directory != nil { completion(rows.compactMap(\.url)); return }
        guard let archive = pane.location.archive, obtainPassword(archive) else { return }
        let service = self.service; let prefix = pane.location.prefix; let indices = pane.selectedArchiveIndices
        perform("Extract selected items", work: { token, output in
            let scratch = try ScratchDirectory(label: "selection")
            try service.extract(archive.url, paths: rows.map(\.path), indices: indices, to: scratch.url, layout: .relativeTo(prefix),
                password: archive.password, token: token, output: output)
            return (scratch, rows.map { scratch.url.appendingPathComponent($0.name) })
        }, success: { [weak self] scratch, urls in self?.temporaryFiles.append(scratch); completion(urls) },
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
            if move && !UIFormat.confirm("Move files from the clipboard?", "Source files will be removed after copying. Name conflicts will be resolved by renaming the new files.", action: "Move") { return }
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
            self.perform("Calculate " + algorithm, work: { token, output in try service.hash(urls, algorithm: algorithm, token: token, output: output) },
                success: { [weak self] result in self?.showText(algorithm + " Checksums", result.output) })
        }
    }
    @objc func properties(_ sender: Any?) {
        let pane = activePane; let rows = pane.selectedRows
        var lines: [String] = []
        if rows.isEmpty, let archive = pane.location.archive {
            lines.append(archive.url.path + "\n")
            lines += archive.listing.properties.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            lines += ["", "Entries: \(archive.listing.entries.count)", "Unpacked size: \(UIFormat.bytes(archive.listing.totalSize))"]
        } else {
            for row in rows {
                lines += [row.path, String(repeating: "─", count: 60)]
                if let entry = row.member { lines += entry.properties.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" } }
                else if let url = row.url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                    lines += attrs.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue): \($0.value)" }
                }
                lines.append("")
            }
        }
        if lines.isEmpty { lines = [pane.location.display] }
        showText("Info", lines.joined(separator: "\n"))
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
        guard canAcceptCommands, !hasActiveOperations else { return }
        defer { onIdle?() }
        let changed = Dialogs.preferences()
        left.discardRevokedLocations()
        if changed { applyPreferences() }
    }
    @objc func forgetPasswords(_ sender: Any?) {
        service.forgetPasswords()
        left.status.showMessage("Passwords cleared.")
    }
    @objc func showLastLog(_ sender: Any?) { showText("Last operation log", lastLog) }
    @objc func engineInformation(_ sender: Any?) {
        showText("7-Zip formats", service.engine.formats())
    }
    @objc func splitFile(_ sender: Any?) {
        guard !isBusy, activePane.selectedURLs.count == 1, let source = activePane.selectedURLs.first else { return }
        guard let text = UIFormat.prompt("Split File", message: "Split a file into byte volumes. Enter a size such as 100m or 4g.", value: "100m") else { return }
        do {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value.range(of: "^[1-9][0-9]*[kmg]?$", options: .regularExpression) != nil else { throw FMError.message("Invalid volume size.") }
            let factors: [Character: UInt64] = ["k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024]
            let factor = value.last.flatMap { factors[$0] } ?? 1
            guard let amount = UInt64(factor == 1 ? value : String(value.dropLast())) else { throw FMError.message("The volume size is too large.") }
            let (bytes, overflow) = amount.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw FMError.message("The volume size is too large.") }
            let panel = NSSavePanel(); panel.title = "Choose a base name for the volumes"
            panel.directoryURL = source.deletingLastPathComponent(); panel.nameFieldStringValue = source.lastPathComponent + ".split"
            guard panel.runModal() == .OK, let base = panel.url else { return }
            guard ensureFolderAccess(base.deletingLastPathComponent()) else { return }
            perform("Split File", work: { token, output in try FileOperations.split(source, to: base, volumeBytes: bytes, token: token, output: output) },
                success: { [weak self] _ in self?.refreshFilePanes() })
        } catch { reportError(error) }
    }
    @objc func combineFiles(_ sender: Any?) {
        guard !isBusy, let first = activePane.selectedURLs.first, first.pathExtension == "001" else { return }
        let panel = NSSavePanel(); panel.directoryURL = first.deletingLastPathComponent(); panel.title = "Combine File Volumes"
        panel.message = "All consecutive volumes must be present, including the last one."
        panel.nameFieldStringValue = "Combined-" + first.deletingPathExtension().lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard ensureFolderAccess(destination.deletingLastPathComponent()) else { return }
        perform("Combine Files", work: { token, output in try FileOperations.combine(first, to: destination, token: token, output: output) },
            success: { [weak self] _ in self?.refreshFilePanes() })
    }

    func cleanupTemporaryFiles() {
        service.cleanupTemporaryFiles()
        for scratch in temporaryFiles { try? FileManager.default.removeItem(at: scratch.url) }
        directoryAccess.close()
    }
    @objc func showHelp(_ sender: Any?) {
        let url = Bundle.main.resourceURL?.appendingPathComponent("README.md")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "See macOS/README.md in the source package."
        showText("VibeZip Help", text)
    }
    @objc func showPrivacyPolicy(_ sender: Any?) {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Privacy.txt")
        showText("VibeZip Privacy", url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The privacy notice is unavailable. Please reinstall VibeZip.")
    }

    private var toolbarItems: [(String, String, String, Selector)] {
        [
            ("back", "Back", "chevron.left", #selector(goBack)),
            ("forward", "Forward", "chevron.right", #selector(goForward)),
            ("up", "Up", "arrow.up", #selector(goUp)),
            ("add", "Add", "plus.rectangle.on.folder", #selector(addArchive)),
            ("extract", "Extract", "arrow.down.doc", #selector(extractArchive)),
            ("test", "Test", "checkmark.shield", #selector(testArchive)),
            ("copy", "Copy", "doc.on.doc", #selector(copyTo)),
            ("move", "Move", "arrow.right.doc.on.clipboard", #selector(moveTo)),
            ("delete", "Delete", "trash", #selector(deleteSelected)),
            ("preview", "Preview", "eye", #selector(previewSelected)),
            ("info", "Info", "info.circle", #selector(properties)),
            ("refresh", "Refresh", "arrow.clockwise", #selector(refreshAll)),
        ]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems.map { NSToolbarItem.Identifier($0.0) } + [.flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["back", "forward", "up"].map { NSToolbarItem.Identifier($0) } + [.flexibleSpace] +
            ["add", "extract", "test", "copy", "move", "delete", "preview", "info"].map { NSToolbarItem.Identifier($0) }
    }
    private func migrateToolbar(_ toolbar: NSToolbar) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "toolbarHasNavigationAndPreview") else { return }
        // Preserve saved arrangements while adding the newly available default actions once.
        for id in ["up", "forward", "back"] where !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == id }) {
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(id), at: 0)
        }
        if !toolbar.items.contains(where: { $0.itemIdentifier == .flexibleSpace }) {
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: min(3, toolbar.items.count))
        }
        if !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "preview" }) {
            let index = toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "info" } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("preview"), at: index)
        }
        defaults.set(true, forKey: "toolbarHasNavigationAndPreview")
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let definition = toolbarItems.first(where: { $0.0 == itemIdentifier.rawValue }) else { return nil }
        let isNavigation = ["back", "forward", "up"].contains(definition.0)
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
            ("Open", #selector(openAsArchive)),
            ("Preview", #selector(previewSelected)),
            ("Reveal in Finder", #selector(revealInFinder)),
            ("Extract", #selector(extractArchive)),
            ("Add to Archive", #selector(addArchive)),
            ("Info", #selector(properties))
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
        return isActionEnabled(menuItem.action)
    }
    private func isActionEnabled(_ action: Selector?) -> Bool {
        if action == #selector(showPreferences) { return !hasActiveOperations }
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
