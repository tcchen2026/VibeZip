#if os(macOS)
import AppKit
import VibeZipCore

/// A fixed-height footer for quiet browsing and immediate operation feedback.
final class OperationStatusView: NSView {
    let message = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let cancel = NSButton(title: L10n.tr("Cancel"), target: nil, action: nil)
    let details = NSButton(title: L10n.tr("Details…"), target: nil, action: nil)
    private let contextLabel = NSTextField(labelWithString: "")
    var context = "" { didSet { contextLabel.stringValue = context; contextLabel.isHidden = context.isEmpty || token != nil || hasNotice } }
    var onDetails: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var currentProgress: ArchiveProgress?
    var summary = "" { didSet { if token == nil && !hasNotice { display(summary) } } }
    private var token: CancellationToken?
    private var revision = UUID()
    private var hasNotice = false

    init() {
        super.init(frame: .zero)
        message.font = .systemFont(ofSize: 11); message.lineBreakMode = .byTruncatingMiddle
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar; progress.controlSize = .small; progress.isHidden = true
        progress.minValue = 0; progress.maxValue = 100
        for button in [cancel, details] {
            button.controlSize = .small; button.bezelStyle = .rounded; button.target = self; button.isHidden = true
        }
        cancel.action = #selector(cancelJob); details.action = #selector(showDetails)
        cancel.toolTip = L10n.tr("Cancel the current operation. Completed file copies are kept.")
        contextLabel.font = .systemFont(ofSize: 10, weight: .medium); contextLabel.textColor = .secondaryLabelColor
        contextLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [message, progress, details, cancel, contextLabel])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), progress.widthAnchor.constraint(equalToConstant: 140)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func begin(_ title: String, token: CancellationToken) {
        revision = UUID(); hasNotice = false; self.token = token; currentProgress = nil
        display(title + "…"); details.isHidden = true; cancel.isHidden = true; cancel.isEnabled = true
        progress.isHidden = true; progress.isIndeterminate = true; progress.doubleValue = 0
        // Small archive opens normally finish before these controls are needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak token] in
            guard let self = self, let token = token, self.token === token else { return }
            self.progress.isHidden = false; self.cancel.isHidden = false
            if self.progress.isIndeterminate { self.progress.startAnimation(nil) }
        }
    }
    func finish(_ text: String? = nil) {
        token = nil; currentProgress = nil; progress.stopAnimation(nil); progress.isHidden = true; cancel.isHidden = true
        clearNotice()
        if let text = text { showMessage(text) }
    }
    func showMessage(_ text: String, error: Bool = false) {
        guard token == nil else { return }
        let id = UUID(); revision = id; hasNotice = true
        display(text, error: error); details.isHidden = !error
        if !error {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self, self.revision == id else { return }
                self.clearNotice()
            }
        }
    }
    func clearNotice() {
        guard token == nil else { return }
        revision = UUID(); hasNotice = false; details.isHidden = true; display(summary)
    }
    private func display(_ text: String, error: Bool = false) {
        contextLabel.isHidden = context.isEmpty || token != nil || hasNotice
        message.stringValue = text.components(separatedBy: .newlines).joined(separator: " ")
        message.toolTip = text; message.textColor = error ? .systemRed : .secondaryLabelColor
    }
    @objc func cancelJob() {
        guard let token = token else { return }
        token.cancel(); cancel.isEnabled = false; display(L10n.tr("Cancelling…")); onCancel?()
    }
    @objc private func showDetails() { onDetails?() }
    func update(_ value: ArchiveProgress) {
        guard let token = token, !token.isCancelled else { return }
        currentProgress = value
        if let fraction = value.fraction {
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = fraction * 100
        } else {
            progress.isIndeterminate = true
            if !progress.isHidden { progress.startAnimation(nil) }
        }
        let names: [ArchiveProgress.Phase: String] = [.open: L10n.tr("Opening"), .extract: L10n.tr("Extracting"), .test: L10n.tr("Testing"), .update: L10n.tr("Compressing"), .hash: L10n.tr("Hashing"), .copy: L10n.tr("Copying")]
        let percentage = value.fraction.map { " · \(Int($0 * 100))%" } ?? ""
        display((names[value.phase] ?? L10n.tr("Working")) + percentage + (value.path.isEmpty ? "…" : " · " + value.path))
    }
    func append(_ chunk: String) {
        guard let token = token, !token.isCancelled else { return }
        let cleaned = chunk.replacingOccurrences(of: "\u{8}", with: "").replacingOccurrences(of: "\r", with: "\n")
        if let line = cleaned.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            display(String(line.prefix(300)))
        }
    }
}

/// Shown after an operation has remained active for one second.
final class OperationProgressWindow: NSWindowController {
    private let detail = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let amount = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: L10n.tr("Cancel"), target: nil, action: nil)
    private let token: CancellationToken
    private let startedAt: TimeInterval
    private let onCancel: () -> Void
    private var timer: Timer?

    init(title: String, token: CancellationToken, startedAt: TimeInterval, cancel: @escaping () -> Void) {
        self.token = token; self.startedAt = startedAt; onCancel = cancel
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        super.init(window: window)
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar; progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 100
        amount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); amount.textColor = .secondaryLabelColor
        elapsed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); elapsed.textColor = .secondaryLabelColor
        amount.setContentHuggingPriority(.defaultLow, for: .horizontal)
        amount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(self.cancel)
        let footer = NSStackView(views: [amount, elapsed, cancelButton]); footer.orientation = .horizontal; footer.spacing = 12
        let stack = NSStackView(views: [heading, detail, progress, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor), progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateElapsed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { timer?.invalidate() }

    func show(attachedTo parent: NSWindow) {
        guard let window = window else { return }
        window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
        parent.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
        if progress.isIndeterminate { progress.startAnimation(nil) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateElapsed() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func close() {
        timer?.invalidate(); timer = nil; progress.stopAnimation(nil)
        if let window = window { window.parent?.removeChildWindow(window) }
        super.close()
    }
    func update(_ value: ArchiveProgress) {
        guard !token.isCancelled else { return }
        if let fraction = value.fraction {
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = fraction * 100
            amount.stringValue = L10n.tr("\(Int(fraction * 100))% · \(UIFormat.bytes(value.completed)) of \(UIFormat.bytes(value.total))")
        } else {
            progress.isIndeterminate = true; progress.startAnimation(nil)
            amount.stringValue = value.completed > 0 ? UIFormat.bytes(value.completed) : ""
        }
        if !value.path.isEmpty { detail.stringValue = value.path; detail.toolTip = value.path }
    }
    func append(_ chunk: String) {
        guard !token.isCancelled else { return }
        let cleaned = chunk.replacingOccurrences(of: "\u{8}", with: "").replacingOccurrences(of: "\r", with: "\n")
        if let line = cleaned.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            detail.stringValue = String(line.prefix(300)); detail.toolTip = detail.stringValue
        }
    }
    func showCancelling() { cancelButton.isEnabled = false; detail.stringValue = L10n.tr("Cancelling…") }
    @objc private func cancel() { onCancel(); showCancelling() }
    private func updateElapsed() {
        let seconds = Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt))
        let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        elapsed.stringValue = L10n.tr("Elapsed \(time)")
    }
}

/// Coalesces high-frequency engine output before updating AppKit.
final class JobOutput {
    private let lock = NSLock()
    private var pending = ""
    private var total = ""
    private var scheduled = false
    private let receive: (String) -> Void
    private var latestProgress: ArchiveProgress?
    private let receiveProgress: (ArchiveProgress) -> Void
    init(receive: @escaping (String) -> Void, progress: @escaping (ArchiveProgress) -> Void) {
        self.receive = receive; receiveProgress = progress
    }
    func emitProgress(_ value: ArchiveProgress) {
        lock.lock(); latestProgress = value
        let schedule = !scheduled; scheduled = true; lock.unlock()
        if schedule { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flush() } }
    }
    func emit(_ chunk: String) {
        lock.lock()
        pending += chunk; total += chunk
        if pending.utf8.count > 300_000 { pending = String(pending.suffix(180_000)) }
        if total.utf8.count > 2_000_000 { total = String(total.suffix(1_000_000)) }
        let schedule = !scheduled; scheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flush() } }
    }
    func flush() {
        lock.lock(); let chunk = pending; let value = latestProgress
        pending = ""; latestProgress = nil; scheduled = false; lock.unlock()
        if !chunk.isEmpty { receive(chunk) }
        if let value = value { receiveProgress(value) }
    }
    var log: String { lock.lock(); defer { lock.unlock() }; return total }
}
#endif
