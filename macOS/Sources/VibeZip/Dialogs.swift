#if os(macOS)
import AppKit
import VibeZipCore

/// Shared form presentation from the Sevenfold design, using the existing native controls.
private final class FormDialog: NSObject, NSWindowDelegate {
    let window: NSPanel
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
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDialog)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let accept = NSButton(title: action, target: self, action: #selector(acceptDialog)); accept.bezelStyle = .rounded; accept.keyEquivalent = "\r"
        let footer = NSStackView(views: [cancel, accept]); footer.spacing = 8
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
    @objc private func acceptDialog() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancelDialog() { NSApp.stopModal(withCode: .cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelDialog(); return false }
}

final class CompressionDialog: NSObject {
    private let path: PathInput
    private let format = NSPopUpButton()
    private let level = NSPopUpButton()
    private let method = NSPopUpButton()
    private let dictionary = NSPopUpButton()
    private let threads = NSTextField(string: "0")
    private let solid = NSButton(checkboxWithTitle: "Solid compression (7z)", target: nil, action: nil)
    private let password = NSSecureTextField()
    private let confirmation = NSSecureTextField()
    private let headers = NSButton(checkboxWithTitle: "Encrypt file names (7z)", target: nil, action: nil)
    private let aes = NSButton(checkboxWithTitle: "Use AES-256 encryption", target: nil, action: nil)
    private let volume = NSTextField()
    private let verify = NSButton(checkboxWithTitle: "Test archive after compression", target: nil, action: nil)
    private let formats = ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim"]
    private let extensions = ["7z", "zip", "tar", "gz", "bz2", "xz", "wim"]
    init(suggestedURL: URL) {
        path = PathInput(path: suggestedURL.path, saving: true)
        super.init()
        format.addItems(withTitles: ["7z", "ZIP", "TAR", "GZip (one file)", "BZip2 (one file)", "XZ (one file)", "WIM"])
        format.target = self; format.action = #selector(formatChanged)
        level.addItems(withTitles: ["0 — Store", "1 — Fastest", "3 — Fast", "5 — Normal", "7 — Maximum", "9 — Ultra"])
        level.selectItem(at: 3)
        method.addItems(withTitles: ["Automatic", "LZMA2", "LZMA", "PPMd", "BZip2"])
        dictionary.addItems(withTitles: ["Automatic", "16m", "32m", "64m", "128m", "256m"])
        solid.state = .on; headers.state = .on; aes.state = .on; verify.state = .on
        volume.placeholderString = "Optional: 100m, 700m, 4g"
        threads.placeholderString = "0 = automatic"
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
        let archive = FormView(width: 860, labelWidth: 70); archive.row("Archive", path)
        archive.frame.origin = NSPoint(x: 0, y: 310); form.addSubview(archive)
        let compression = FormView(width: 396, labelWidth: 135)
        compression.row("Archive format", format); compression.row("Compression level", level)
        compression.row("Method", method); compression.row("Dictionary size", dictionary)
        compression.row("CPU threads", threads); compression.row("", solid)
        let options = FormView(width: 396, labelWidth: 120)
        options.row("Password", password); options.row("Confirm password", confirmation)
        options.row("", headers); options.row("", aes)
        options.row("Split into volumes", volume); options.row("", verify)
        for (title, body, x) in [("Compression", compression, CGFloat(0)), ("Encryption and Options", options, CGFloat(440))] {
            let group = NSBox(frame: NSRect(x: x, y: 10, width: 420, height: 278)); group.title = title
            body.frame.origin = NSPoint(x: 10, y: 20); group.contentView?.addSubview(body); form.addSubview(group)
        }
        let dialog = FormDialog(title: "Add to Archive", subtitle: "Compress \(count) selected items into a new archive.",
            symbol: "archivebox", content: form, action: "Add")
        dialog.window.initialFirstResponder = path.field
        while dialog.run() {
            do {
                guard !path.field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { throw FMError.message("Enter an output archive path.") }
                guard !password.isEnabled || password.stringValue == confirmation.stringValue else { throw FMError.message("The passwords do not match.") }
                var options = CompressionOptions(); options.format = formats[format.indexOfSelectedItem]
                options.level = [0, 1, 3, 5, 7, 9][level.indexOfSelectedItem]
                options.method = method.isEnabled && method.indexOfSelectedItem > 0 ? method.titleOfSelectedItem! : ""
                options.dictionary = dictionary.isEnabled && dictionary.indexOfSelectedItem > 0 ? dictionary.titleOfSelectedItem! : ""
                guard let threadCount = Int(threads.stringValue) else { throw FMError.message("Enter a whole number of threads; 0 selects automatically.") }
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
        let layout = NSPopUpButton(); layout.addItems(withTitles: ["Full paths", "Relative to current folder", "No paths (files only)"])
        let conflicts = NSPopUpButton(); conflicts.addItems(withTitles: ConflictPolicy.allCases.map(\.title))
        let password = NSSecureTextField(); password.stringValue = archive.password ?? ""
        let reveal = NSButton(checkboxWithTitle: "Reveal destination in Finder", target: nil, action: nil); reveal.state = .off
        form.row("Extract to", path); form.row("Path mode", layout); form.row("Existing files", conflicts)
        form.row("Password (if needed)", password); form.row("After extraction", reveal)
        let dialog = FormDialog(title: "Extract Files", subtitle: "Choose where to extract items from “\(archive.url.lastPathComponent)”.",
            symbol: "square.and.arrow.up.on.square", content: form, action: "Extract")
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
        form.row("Destination", path); form.row("Existing files", conflicts)
        let dialog = FormDialog(title: title, subtitle: "Choose a destination and how to handle existing files.",
            symbol: "folder", content: form, action: "Continue")
        dialog.window.initialFirstResponder = path.field
        guard dialog.run() else { return nil }
        return (path.url, ConflictPolicy(rawValue: conflicts.indexOfSelectedItem) ?? .rename)
    }

    static func preferences(folderAccess: Bool = false) -> Bool {
        let defaults = UserDefaults.standard
        let form = FormView()
        let backups = NSButton(checkboxWithTitle: "Keep a backup before updating an archive", target: nil, action: nil)
        backups.state = defaults.bool(forKey: "keepBackups") ? .on : .off
        let hidden = NSButton(checkboxWithTitle: "Show Hidden Files", target: nil, action: nil)
        hidden.state = defaults.bool(forKey: "showHidden") ? .on : .off
        let cap = NSTextField(string: String(defaults.integer(forKey: "extractionLimitGiB")))
        form.row("Archive backups", backups); form.row("Hidden items", hidden); form.row("Extraction limit (GiB)", cap)
        let tips = NSButton(checkboxWithTitle: "Show keyboard tips above the file list", target: nil, action: nil)
        tips.state = defaults.bool(forKey: "showKeyTips") ? .on : .off
        let keyboard = FormView()
        let keyMode = NSSegmentedControl(labels: ["7-Zip", "Mac"], trackingMode: .selectOne, target: nil, action: nil)
        keyMode.selectedSegment = defaults.string(forKey: "keyMode") == "mac" ? 1 : 0
        keyboard.row("Key bindings", keyMode); keyboard.row("Key tips", tips)
        let explanation = NSTextField(wrappingLabelWithString: "7-Zip mode uses function keys for file actions. Mac mode uses ⌘Y to preview and Delete to move files to Trash. Help → Shortcut Map lists every supported shortcut.")
        explanation.textColor = .secondaryLabelColor
        keyboard.row("", explanation, height: 72)
        let folders = FolderAccessView()
        let content = NSTabView(frame: NSRect(x: 0, y: 0, width: 625, height: 320))
        for (title, body) in [("General", form as NSView), ("Folder Access", folders as NSView), ("Keyboard", keyboard as NSView)] {
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
        let dialog = FormDialog(title: "Settings", subtitle: "Manage browsing, archive options and access to your folders.",
            symbol: "gearshape", content: content, action: "Save")
        while dialog.run() {
            guard let value = Int(cap.stringValue), (1...100_000).contains(value) else {
                UIFormat.error(FMError.message("The extraction limit must be between 1 and 100,000 GiB.")); continue
            }
            defaults.set(backups.state == .on, forKey: "keepBackups")
            defaults.set(hidden.state == .on, forKey: "showHidden")
            defaults.set(value, forKey: "extractionLimitGiB")
            defaults.set(tips.state == .on, forKey: "showKeyTips")
            defaults.set(keyMode.selectedSegment == 1 ? "mac" : "7z", forKey: "keyMode")
            return true
        }
        return false
    }
}
#endif
