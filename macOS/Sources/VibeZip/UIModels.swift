#if os(macOS)
import AppKit
import VibeZipCore

final class ArchiveContext {
    let session: ArchiveSession
    var id: UUID { session.id }
    var url: URL { session.url }
    var listing: ArchiveListing { session.listing }
    var password: String? { get { session.password } set { session.password = newValue } }
    let returnLocation: BrowserLocation?
    var isNested: Bool { session.isNested }
    var canModify: Bool { session.canModify }
    init(session: ArchiveSession, returnLocation: BrowserLocation? = nil) {
        self.session = session; self.returnLocation = returnLocation
    }
}

enum BrowserLocation {
    case none
    case directory(URL)
    case archive(ArchiveContext, String)
    var directory: URL? { if case .directory(let url) = self { return url }; return nil }
    var archive: ArchiveContext? { if case .archive(let context, _) = self { return context }; return nil }
    var prefix: String { if case .archive(_, let prefix) = self { return prefix }; return "" }
    var isEmpty: Bool { if case .none = self { return true }; return false }
    var display: String {
        switch self {
        case .none: return ""
        case .directory(let url): return UserPath.abbreviate(url.path)
        case .archive(let archive, let prefix): return UserPath.abbreviate(archive.session.displayPath) + " ▸ /" + prefix
        }
    }
    var identity: String {
        switch self { case .none: return "no-location"
        case .directory(let url): return url.path
        case .archive(let archive, let prefix): return archive.id.uuidString + "/" + prefix }
    }
    struct Breadcrumb {
        let title: String
        let location: BrowserLocation
    }
    var breadcrumbs: [Breadcrumb] {
        func fileComponents(_ url: URL) -> [Breadcrumb] {
            let home = UserPath.homeDirectory
            var current = url.standardizedFileURL
            var components: [Breadcrumb] = []
            while true {
                components.append(Breadcrumb(title: current.path == home.path ? "~" : (current.path == "/" ? "/" : current.lastPathComponent),
                                             location: .directory(current)))
                if current.path == "/" || current.path == home.path { break }
                current.deleteLastPathComponent()
            }
            return components.reversed()
        }
        switch self {
        case .none: return [Breadcrumb(title: L10n.tr("No folder selected"), location: .none)]
        case .directory(let url): return fileComponents(url)
        case .archive(let archive, let prefix):
            var components: [Breadcrumb]
            if let parent = archive.returnLocation?.archive, let memberPath = archive.session.parentPath {
                // Search may have opened this archive from a different folder in its parent.
                components = BrowserLocation.archive(parent, ArchivePath.parent(of: memberPath)).breadcrumbs
            } else {
                components = fileComponents(archive.session.rootURL.deletingLastPathComponent())
            }
            components.append(Breadcrumb(title: archive.url.lastPathComponent, location: .archive(archive, "")))
            var folder = ""
            for name in prefix.split(separator: "/") {
                folder = folder.isEmpty ? String(name) : folder + "/" + String(name)
                components.append(Breadcrumb(title: String(name), location: .archive(archive, folder)))
            }
            return components
        }
    }
}

struct BrowserRow {
    let name: String
    let path: String
    let url: URL?
    let member: ArchiveEntry?
    let isDirectory: Bool
    let isLink: Bool
    let size: UInt64?
    let packedSize: UInt64?
    let modified: String
    var identity: String { member?.index.map { "entry:\($0)" } ?? path }
    var symbol: String {
        if isLink { return "link" }
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "7z", "zip", "rar", "tar", "gz", "bz2", "xz", "wim", "dmg", "iso": return "archivebox.fill"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp": return "photo"
        case "txt", "md", "rtf", "log": return "doc.text"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
    var type: String {
        if isLink { return L10n.tr("Link") }
        if isDirectory { return L10n.tr("Folder") }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? L10n.tr("File") : L10n.tr("\(ext) file")
    }
    init(entry: ArchiveEntry) {
        name = entry.name; path = entry.path; url = nil; member = entry
        isDirectory = entry.isDirectory; isLink = entry.isLink; size = entry.size
        packedSize = entry.packedSize
        modified = entry.modifiedNS.map { UIFormat.date.string(from: Date(timeIntervalSince1970: Double($0) / 1e9)) }
            ?? String(entry.modified.prefix(19))
    }
    init(url: URL, values: URLResourceValues) {
        self.url = url; name = url.lastPathComponent; path = url.path; member = nil
        isDirectory = values.isDirectory ?? false; isLink = values.isSymbolicLink ?? false
        size = values.fileSize.map { UInt64(max(0, $0)) }; packedSize = nil
        if let date = values.contentModificationDate { modified = UIFormat.date.string(from: date) } else { modified = "" }
    }
}

enum UIFormat {
    static func totalSize(_ rows: [BrowserRow]) -> UInt64 {
        rows.reduce(UInt64(0)) { sum, row in
            let (next, overflow) = sum.addingReportingOverflow(row.size ?? 0)
            return overflow ? UInt64.max : next
        }
    }
    static let date: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
    }()
    static func bytes(_ count: UInt64?) -> String {
        guard let count = count else { return "—" }
        if count > UInt64(Int64.max) { return String(count) + " B" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
    static func error(_ error: Error) {
        if case FMError.cancelled = error { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.tr("Operation could not be completed")
        alert.informativeText = String(error.localizedDescription.prefix(5000))
        alert.addButton(withTitle: L10n.tr("OK")); alert.runModal()
    }
    static func confirm(_ title: String, _ message: String, action: String = L10n.tr("Continue")) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: L10n.tr("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func prompt(_ title: String, message: String = "", value: String = "", secure: Bool = false) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 26); field.stringValue = value
        alert.accessoryView = field; alert.addButton(withTitle: L10n.tr("OK")); alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

final class TableTextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier; textField = label
        label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class ActionButton: NSButton {
    var onAction: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(frame: .zero); self.title = title; bezelStyle = .rounded
        target = self; self.action = #selector(invoke); onAction = action
    }
    @objc private func invoke() { onAction?() }
}

final class PathInput: NSView {
    let field = NSTextField()
    let button = NSButton(title: L10n.tr("Browse…"), target: nil, action: nil)
    let saving: Bool
    init(path: String, saving: Bool) {
        self.saving = saving
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 28))
        field.stringValue = path; field.frame = NSRect(x: 0, y: 1, width: 348, height: 25)
        field.autoresizingMask = [.width]
        button.frame = NSRect(x: 355, y: 0, width: 75, height: 28)
        button.autoresizingMask = [.minXMargin]; button.bezelStyle = .rounded
        button.target = self; button.action = #selector(browse)
        addSubview(field); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var url: URL { URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath).standardizedFileURL }
    @objc private func browse() {
        if saving {
            let panel = NSSavePanel(); panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent; panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.canCreateDirectories = true; panel.directoryURL = url
            if panel.runModal() == .OK, let url = panel.url {
                defer { url.stopAccessingSecurityScopedResource() }
                do { field.stringValue = try DirectoryAccessStore.shared.authorize(url).path }
                catch { UIFormat.error(error) }
            }
        }
    }
}

final class FormView: NSView {
    override var isFlipped: Bool { true }
    private var nextY: CGFloat = 0
    private var labelWidth: CGFloat
    private var rows: [(NSTextField, NSView)] = []
    init(width: CGFloat = 585, labelWidth: CGFloat = 142) {
        self.labelWidth = labelWidth
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func row(_ title: String, _ control: NSView, height: CGFloat = 34) {
        let y = nextY
        let label = NSTextField(labelWithString: title)
        labelWidth = max(labelWidth, min(ceil(label.fittingSize.width), floor(frame.width * 0.45)))
        label.alignment = .right; label.frame = NSRect(x: 0, y: y + 5, width: labelWidth, height: 22)
        control.frame = NSRect(x: 0, y: y, width: frame.width, height: height - 6)
        rows.append((label, control))
        for (rowLabel, rowControl) in rows {
            rowLabel.frame.size.width = labelWidth
            let leading: CGFloat = rowLabel.stringValue.isEmpty ? 0 : labelWidth + 12
            rowControl.frame.origin.x = leading; rowControl.frame.size.width = frame.width - leading - 1
        }
        addSubview(label); addSubview(control); nextY += height; frame.size.height = nextY
    }
}

final class TextWindow: NSWindowController {
    init(title: String, text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        super.init(window: window)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = LocalTextView(frame: scroll.bounds)
        view.isEditable = false; view.isSelectable = true
        view.isRichText = false; view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false; view.string = text
        scroll.documentView = view; window.contentView?.addSubview(scroll)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
