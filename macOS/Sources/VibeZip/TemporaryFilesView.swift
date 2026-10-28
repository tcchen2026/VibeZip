#if os(macOS)
import AppKit
import VibeZipCore

final class TemporaryFilesView: NSView {
    var onCleanupStateChanged: ((CancellationToken?) -> Void)?
    var allowsCleanup = true { didSet { cleanButton.isEnabled = allowsCleanup && token == nil } }
    private var token: CancellationToken?
    private var usageToken: CancellationToken?
    private let usage = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cleanButton = NSButton(title: L10n.tr("Clean Temporary Files"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.tr("Cancel"), target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 585, height: 150))
        let heading = NSTextField(labelWithString: L10n.tr("Temporary files"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        usage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); usage.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading, usage]); header.spacing = 12
        let description = NSTextField(wrappingLabelWithString: L10n.tr("VibeZip may store temporary files for previews, nested archives, and extraction. Clean removes unused files, including recovery copies; files still in use are kept."))
        description.font = .systemFont(ofSize: 12); description.textColor = .secondaryLabelColor
        let showButton = NSButton(title: L10n.tr("Show Temporary Folder"), target: self, action: #selector(showFolder))
        cleanButton.target = self; cleanButton.action = #selector(clean)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        for button in [showButton, cleanButton, cancelButton] { button.bezelStyle = .rounded }
        cancelButton.isHidden = true; cancelButton.controlSize = .small
        let buttons = NSStackView(views: [showButton, cleanButton]); buttons.spacing = 8
        progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true; progress.isHidden = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let feedback = NSStackView(views: [progress, status, cancelButton]); feedback.spacing = 8
        let stack = NSStackView(views: [header, description, buttons, feedback])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor), feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalToConstant: 14), progress.heightAnchor.constraint(equalToConstant: 14)
        ])
        refreshUsage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { usageToken?.cancel() }

    private func refreshUsage() {
        usageToken?.cancel()
        let token = CancellationToken(); usageToken = token
        usage.stringValue = L10n.tr("Calculating…"); usage.toolTip = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try TemporaryFiles.usageBytes(token: token) }
            DispatchQueue.main.async {
                guard let self = self, self.usageToken === token, !token.isCancelled else { return }
                self.usageToken = nil
                switch result {
                case .success(let bytes):
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file; formatter.allowedUnits = [.useMB, .useGB]
                    formatter.allowsNonnumericFormatting = false
                    let size = formatter.string(fromByteCount: Int64(clamping: bytes))
                    self.usage.stringValue = L10n.tr("\(size) used")
                case .failure(let error):
                    self.usage.stringValue = L10n.tr("Usage unavailable"); self.usage.toolTip = error.localizedDescription
                }
            }
        }
    }

    @objc private func showFolder() {
        do { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: try TemporaryFiles.prepareDirectory().path) }
        catch { UIFormat.error(error) }
    }

    @objc private func clean() {
        guard allowsCleanup, token == nil else { return }
        usageToken?.cancel(); usageToken = nil
        usage.stringValue = L10n.tr("Calculating…"); usage.toolTip = nil
        let token = CancellationToken(); self.token = token
        cleanButton.isEnabled = false; status.textColor = .secondaryLabelColor
        status.stringValue = L10n.tr("Cleaning temporary files…")
        onCleanupStateChanged?(token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.token === token else { return }
            self.progress.isHidden = false; self.progress.startAnimation(nil)
            self.cancelButton.isHidden = false; self.cancelButton.isEnabled = !token.isCancelled
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try TemporaryFiles.cleanUnused(token: token) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.token = nil; self.cleanButton.isEnabled = self.allowsCleanup
                self.progress.stopAnimation(nil); self.progress.isHidden = true; self.cancelButton.isHidden = true
                switch result {
                case .success(let count):
                    self.status.stringValue = count == 0 ? L10n.tr("No unused temporary files.") : L10n.tr("Unused temporary files removed.")
                case .failure(FMError.cancelled): self.status.stringValue = L10n.tr("Cleanup cancelled.")
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription; self.status.textColor = .systemRed
                }
                self.onCleanupStateChanged?(nil)
                self.refreshUsage()
            }
        }
    }
    @objc private func cancel() {
        token?.cancel(); cancelButton.isEnabled = false; status.stringValue = L10n.tr("Cancelling…")
    }
}
#endif
