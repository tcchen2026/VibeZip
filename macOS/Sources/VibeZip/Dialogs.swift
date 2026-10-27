#if os(macOS)
import AppKit
import VibeZipCore

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
        let alert = NSAlert(); alert.messageText = "Add to Archive"
        alert.informativeText = "\(count) items selected."
        let form = FormView()
        form.row("Archive", path); form.row("Archive format", format); form.row("Compression level", level)
        form.row("Compression method", method); form.row("Dictionary size", dictionary); form.row("CPU threads", threads)
        form.row("Solid compression", solid); form.row("Password", password); form.row("Confirm password", confirmation)
        form.row("File name encryption", headers); form.row("ZIP encryption", aes); form.row("Split into volumes", volume)
        form.row("Verification", verify)
        alert.accessoryView = form; alert.addButton(withTitle: "Compress"); alert.addButton(withTitle: "Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
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
        let alert = NSAlert(); alert.messageText = "Extract files"
        alert.informativeText = "\(archive.url.lastPathComponent)\nChoose a destination for the selected files."
        let form = FormView(); let path = PathInput(path: suggested.path, saving: false)
        let layout = NSPopUpButton(); layout.addItems(withTitles: ["Full paths", "Relative to current folder", "No paths (files only)"])
        let conflicts = NSPopUpButton(); conflicts.addItems(withTitles: ConflictPolicy.allCases.map(\.title))
        let password = NSSecureTextField(); password.stringValue = archive.password ?? ""
        let reveal = NSButton(checkboxWithTitle: "Reveal destination in Finder", target: nil, action: nil); reveal.state = .off
        form.row("Extract to", path); form.row("Path mode", layout); form.row("Existing files", conflicts)
        form.row("Password (if needed)", password); form.row("After extraction", reveal)
        alert.accessoryView = form; alert.addButton(withTitle: "Extract"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return ExtractionRequest(destination: path.url,
            layout: layout.indexOfSelectedItem == 0 ? .fullPaths : (layout.indexOfSelectedItem == 1 ? .relativeTo(prefix) : .flat),
            policy: ConflictPolicy(rawValue: conflicts.indexOfSelectedItem) ?? .rename,
            password: password.stringValue.isEmpty ? nil : password.stringValue, reveal: reveal.state == .on)
    }

    static func destination(title: String, suggested: URL) -> (URL, ConflictPolicy)? {
        let alert = NSAlert(); alert.messageText = title
        let form = FormView(); let path = PathInput(path: suggested.path, saving: false)
        let conflicts = NSPopUpButton(); conflicts.addItems(withTitles: ConflictPolicy.allCases.map(\.title))
        form.row("Destination", path); form.row("Existing files", conflicts)
        alert.accessoryView = form; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (path.url, ConflictPolicy(rawValue: conflicts.indexOfSelectedItem) ?? .rename)
    }

    static func preferences() -> Bool {
        let defaults = UserDefaults.standard
        let alert = NSAlert(); alert.messageText = "VibeZip Settings"
        alert.informativeText = "Passwords are remembered only until you quit or clear them."
        let form = FormView()
        let backups = NSButton(checkboxWithTitle: "Keep a backup before updating an archive", target: nil, action: nil)
        backups.state = defaults.bool(forKey: "keepBackups") ? .on : .off
        let hidden = NSButton(checkboxWithTitle: "Show Hidden Files", target: nil, action: nil)
        hidden.state = defaults.bool(forKey: "showHidden") ? .on : .off
        let cap = NSTextField(string: String(defaults.integer(forKey: "extractionLimitGiB")))
        form.row("Archive backups", backups); form.row("Hidden items", hidden); form.row("Extraction limit (GiB)", cap)
        let folders = FolderAccessView()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 585, height: form.frame.height + folders.frame.height + 16))
        folders.frame.origin = .zero; form.frame.origin = NSPoint(x: 0, y: folders.frame.height + 16)
        content.addSubview(form); content.addSubview(folders)
        alert.accessoryView = content; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
            guard let value = Int(cap.stringValue), (1...100_000).contains(value) else {
                UIFormat.error(FMError.message("The extraction limit must be between 1 and 100,000 GiB.")); continue
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
