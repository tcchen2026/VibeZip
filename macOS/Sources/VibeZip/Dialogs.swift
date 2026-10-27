#if os(macOS)
import AppKit
import VibeZipCore

/// Shared form presentation from the Sevenfold design, using the existing native controls.
private final class FormDialog: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let cancelButton = NSButton()
    private let acceptButton = NSButton()
    var isBusy = false {
        didSet {
            cancelButton.isEnabled = !isBusy; acceptButton.isEnabled = !isBusy
            window.standardWindowButton(.closeButton)?.isEnabled = !isBusy
        }
    }
    init(title: String, subtitle: String, symbol: String, content: NSView, action: String) {
        let width = max(520, content.frame.width + 40)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: content.frame.height + 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle); detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [heading, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular); icon.contentTintColor = .controlAccentColor
        let header = NSStackView(views: [icon, labels]); header.spacing = 14; header.alignment = .centerY
        cancelButton.title = L10n.tr("Cancel"); cancelButton.target = self; cancelButton.action = #selector(cancelDialog)
        cancelButton.bezelStyle = .rounded; cancelButton.keyEquivalent = "\u{1b}"
        acceptButton.title = action; acceptButton.target = self; acceptButton.action = #selector(acceptDialog)
        acceptButton.bezelStyle = .rounded; acceptButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [cancelButton, acceptButton]); footer.spacing = 8
        let root = window.contentView!
        for child in [header, content, footer] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20), content.heightAnchor.constraint(equalToConstant: content.frame.height),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
    }
    func run() -> Bool {
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        return NSApp.runModal(for: window) == .OK
    }
    @objc private func acceptDialog() { if !isBusy { NSApp.stopModal(withCode: .OK) } }
    @objc private func cancelDialog() { if !isBusy { NSApp.stopModal(withCode: .cancel) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelDialog(); return false }
}

final class CompressionDialog: NSObject {
    private let path: PathInput
    private let format = NSPopUpButton()
    private let level = NSPopUpButton()
    private let method = NSPopUpButton()
    private let dictionary = NSPopUpButton()
    private let threads = NSTextField(string: "0")
    private let solid = NSButton(checkboxWithTitle: L10n.tr("Solid compression (7z)"), target: nil, action: nil)
    private let password = NSSecureTextField()
    private let confirmation = NSSecureTextField()
    private let headers = NSButton(checkboxWithTitle: L10n.tr("Encrypt file names (7z)"), target: nil, action: nil)
    private let aes = NSButton(checkboxWithTitle: L10n.tr("Use AES-256 encryption"), target: nil, action: nil)
    private let volume = NSTextField()
    private let verify = NSButton(checkboxWithTitle: L10n.tr("Test archive after compression"), target: nil, action: nil)
    private let formats = ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim"]
    private let extensions = ["7z", "zip", "tar", "gz", "bz2", "xz", "wim"]
    init(suggestedURL: URL) {
        path = PathInput(path: suggestedURL.path, saving: true)
        super.init()
        format.addItems(withTitles: ["7z", "ZIP", "TAR", L10n.tr("GZip (one file)"), L10n.tr("BZip2 (one file)"), L10n.tr("XZ (one file)"), "WIM"])
        format.target = self; format.action = #selector(formatChanged)
        level.addItems(withTitles: [L10n.tr("0 — Store"), L10n.tr("1 — Fastest"), L10n.tr("3 — Fast"), L10n.tr("5 — Normal"), L10n.tr("7 — Maximum"), L10n.tr("9 — Ultra")])
        level.selectItem(at: 3)
        method.addItems(withTitles: [L10n.tr("Automatic"), "LZMA2", "LZMA", "PPMd", "BZip2"])
        dictionary.addItems(withTitles: [L10n.tr("Automatic"), "16m", "32m", "64m", "128m", "256m"])
        solid.state = .on; headers.state = .on; aes.state = .on; verify.state = .on
        volume.placeholderString = L10n.tr("Optional: 100m, 700m, 4g")
        threads.placeholderString = L10n.tr("0 = automatic")
        updateEnabled()
    }
    @objc private func formatChanged() {
        path.field.stringValue = path.url.deletingPathExtension().appendingPathExtension(extensions[format.indexOfSelectedItem]).path
        updateEnabled()
    }
    private func updateEnabled() {
        let seven = format.indexOfSelectedItem == 0
        method.isEnabled = seven; dictionary.isEnabled = seven; solid.isEnabled = seven; headers.isEnabled = seven
        aes.isEnabled = format.indexOfSelectedItem == 1
        let encrypted = format.indexOfSelectedItem <= 1
        password.isEnabled = encrypted; confirmation.isEnabled = encrypted
    }
    func run(count: Int) -> (URL, CompressionOptions)? {
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 344))
        let archive = FormView(width: 860, labelWidth: 70); archive.row(L10n.tr("Archive"), path)
        archive.frame.origin = NSPoint(x: 0, y: 310); form.addSubview(archive)
        let compression = FormView(width: 396, labelWidth: 135)
        compression.row(L10n.tr("Archive format"), format); compression.row(L10n.tr("Compression level"), level)
        compression.row(L10n.tr("Method"), method); compression.row(L10n.tr("Dictionary size"), dictionary)
        compression.row(L10n.tr("CPU threads"), threads); compression.row("", solid)
        let options = FormView(width: 396, labelWidth: 120)
        options.row(L10n.tr("Password"), password); options.row(L10n.tr("Confirm password"), confirmation)
        options.row("", headers); options.row("", aes)
        options.row(L10n.tr("Split into volumes"), volume); options.row("", verify)
        for (title, body, x) in [(L10n.tr("Compression"), compression, CGFloat(0)), (L10n.tr("Encryption and Options"), options, CGFloat(440))] {
            let group = NSBox(frame: NSRect(x: x, y: 10, width: 420, height: 278)); group.title = title
            body.frame.origin = NSPoint(x: 10, y: 20); group.contentView?.addSubview(body); form.addSubview(group)
        }
        let dialog = FormDialog(title: L10n.tr("Add to Archive"), subtitle: L10n.tr("Compress \(count) selected items into a new archive."),
            symbol: "archivebox", content: form, action: L10n.tr("Add"))
        dialog.window.initialFirstResponder = path.field
        while dialog.run() {
            do {
                guard !path.field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { throw FMError.message(L10n.tr("Enter an output archive path.")) }
                guard !password.isEnabled || password.stringValue == confirmation.stringValue else { throw FMError.message(L10n.tr("The passwords do not match.")) }
                var options = CompressionOptions(); options.format = formats[format.indexOfSelectedItem]
                options.level = [0, 1, 3, 5, 7, 9][level.indexOfSelectedItem]
                options.method = method.isEnabled && method.indexOfSelectedItem > 0 ? method.titleOfSelectedItem! : ""
                options.dictionary = dictionary.isEnabled && dictionary.indexOfSelectedItem > 0 ? dictionary.titleOfSelectedItem! : ""
                guard let threadCount = Int(threads.stringValue) else { throw FMError.message(L10n.tr("Enter a whole number of threads; 0 selects automatically.")) }
                options.threads = threadCount; options.solid = solid.state == .on
                options.password = password.isEnabled && !password.stringValue.isEmpty ? password.stringValue : nil
                options.encryptHeaders = headers.state == .on; options.zipAES = aes.state == .on
                options.volumeSize = volume.stringValue.trimmingCharacters(in: .whitespaces)
                options.verify = verify.state == .on; try options.validate()
                return (path.url, options)
            } catch { UIFormat.error(error) }
        }
        return nil
    }
}

struct ExtractionRequest {
    let destination: URL
    let layout: ExtractionLayout
    let policy: ConflictPolicy
    let password: String?
    let reveal: Bool
}

enum Dialogs {
    static func extraction(archive: ArchiveContext, prefix: String, suggested: URL) -> ExtractionRequest? {
        let form = FormView(); let path = PathInput(path: suggested.path, saving: false)
        let layout = NSPopUpButton(); layout.addItems(withTitles: [L10n.tr("Full paths"), L10n.tr("Relative to current folder"), L10n.tr("No paths (files only)")])
        let conflicts = NSPopUpButton(); conflicts.addItems(withTitles: ConflictPolicy.allCases.map(\.title))
        let password = NSSecureTextField(); password.stringValue = archive.password ?? ""
        let reveal = NSButton(checkboxWithTitle: L10n.tr("Reveal destination in Finder"), target: nil, action: nil); reveal.state = .off
        form.row(L10n.tr("Extract to"), path); form.row(L10n.tr("Path mode"), layout); form.row(L10n.tr("Existing files"), conflicts)
        form.row(L10n.tr("Password (if needed)"), password); form.row(L10n.tr("After extraction"), reveal)
        let dialog = FormDialog(title: L10n.tr("Extract Files"), subtitle: L10n.tr("Choose where to extract items from “\(archive.url.lastPathComponent)”."),
            symbol: "square.and.arrow.up.on.square", content: form, action: L10n.tr("Extract"))
        dialog.window.initialFirstResponder = path.field
        guard dialog.run() else { return nil }
        return ExtractionRequest(destination: path.url,
            layout: layout.indexOfSelectedItem == 0 ? .fullPaths : (layout.indexOfSelectedItem == 1 ? .relativeTo(prefix) : .flat),
            policy: ConflictPolicy(rawValue: conflicts.indexOfSelectedItem) ?? .rename,
            password: password.stringValue.isEmpty ? nil : password.stringValue, reveal: reveal.state == .on)
    }

    static func destination(title: String, suggested: URL) -> (URL, ConflictPolicy)? {
        let form = FormView(); let path = PathInput(path: suggested.path, saving: false)
        let conflicts = NSPopUpButton(); conflicts.addItems(withTitles: ConflictPolicy.allCases.map(\.title))
        form.row(L10n.tr("Destination"), path); form.row(L10n.tr("Existing files"), conflicts)
        let dialog = FormDialog(title: title, subtitle: L10n.tr("Choose a destination and how to handle existing files."),
            symbol: "folder", content: form, action: L10n.tr("Continue"))
        dialog.window.initialFirstResponder = path.field
        guard dialog.run() else { return nil }
        return (path.url, ConflictPolicy(rawValue: conflicts.indexOfSelectedItem) ?? .rename)
    }

    static func preferences(folderAccess: Bool = false, onTemporaryCleanup: @escaping (CancellationToken?) -> Void = { _ in }) -> Bool {
        let defaults = UserDefaults.standard
        let form = FormView()
        let backups = NSButton(checkboxWithTitle: L10n.tr("Keep a backup before updating an archive"), target: nil, action: nil)
        backups.state = defaults.bool(forKey: "keepBackups") ? .on : .off
        let hidden = NSButton(checkboxWithTitle: L10n.tr("Show Hidden Files"), target: nil, action: nil)
        hidden.state = defaults.bool(forKey: "showHidden") ? .on : .off
        let cap = NSTextField(string: String(defaults.integer(forKey: "extractionLimitGiB")))
        form.row(L10n.tr("Archive backups"), backups); form.row(L10n.tr("Hidden items"), hidden); form.row(L10n.tr("Extraction limit (GiB)"), cap)
        let temporaryFiles = TemporaryFilesView()
        form.row("", temporaryFiles, height: 160)
        let defaultApplication = DefaultApplicationView()
        form.row("", defaultApplication, height: 140)
        let folders = FolderAccessView()
        let content = NSTabView(frame: NSRect(x: 0, y: 0, width: 625, height: max(320, form.frame.height + 56)))
        for (title, body) in [(L10n.tr("General"), form as NSView), (L10n.tr("Folder Access"), folders as NSView)] {
            let tab = NSTabViewItem(identifier: title); tab.label = title
            let container = NSView(); body.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(body)
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                body.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
                body.widthAnchor.constraint(equalToConstant: 585), body.heightAnchor.constraint(equalToConstant: body.frame.height)
            ])
            tab.view = container; content.addTabViewItem(tab)
        }
        if folderAccess { content.selectTabViewItem(at: 1) }
        let dialog = FormDialog(title: L10n.tr("Settings"), subtitle: L10n.tr("Manage browsing, archive options and access to your folders."),
            symbol: "gearshape", content: content, action: L10n.tr("Save"))
        temporaryFiles.onCleanupStateChanged = { [weak dialog, weak defaultApplication] token in
            dialog?.isBusy = token != nil; defaultApplication?.isEnabled = token == nil
            onTemporaryCleanup(token)
        }
        defaultApplication.onRequestStateChanged = { [weak dialog, weak temporaryFiles] pending in
            dialog?.isBusy = pending; temporaryFiles?.allowsCleanup = !pending
        }
        while dialog.run() {
            guard let value = Int(cap.stringValue), (1...100_000).contains(value) else {
                UIFormat.error(FMError.message(L10n.tr("The extraction limit must be between 1 and 100,000 GiB."))); continue
            }
            defaults.set(backups.state == .on, forKey: "keepBackups")
            defaults.set(hidden.state == .on, forKey: "showHidden")
            defaults.set(value, forKey: "extractionLimitGiB")
            return true
        }
        return false
    }
}
#endif
