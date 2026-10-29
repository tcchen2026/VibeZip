#if os(macOS)
import Foundation
import VibeZipCore

/// App-wide archive sessions and temporary resources, shared by every browser window.
final class BrowserWorkspace {
    let service: ArchiveService
    private(set) weak var operationOwner: MainWindowController?
    var onBusyChange: (() -> Void)?
    var temporaryFiles: [ScratchDirectory] = []
    var isBusy: Bool { operationOwner != nil }

    init(service: ArchiveService) { self.service = service }

    func beginOperation(_ owner: MainWindowController) -> Bool {
        guard !isBusy else { return false }
        operationOwner = owner; onBusyChange?(); return true
    }
    func endOperation(_ owner: MainWindowController) {
        guard operationOwner === owner else { return }
        operationOwner = nil; onBusyChange?()
    }
    func cleanupTemporaryFiles() {
        service.cleanupTemporaryFiles()
        for scratch in temporaryFiles { try? FileManager.default.removeItem(at: scratch.url) }
        temporaryFiles.removeAll()
        DirectoryAccessStore.shared.close()
    }
}
#endif
