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
        case .directory(let url): return url.path
        case .archive(let archive, let prefix): return archive.session.displayPath + " ▸ /" + prefix
        }
    }
    var identity: String {
        switch self { case .none: return "no-location"
        case .directory(let url): return url.path
        case .archive(let archive, let prefix): return archive.id.uuidString + "/" + prefix }
    }
    var breadcrumbTitles: [String] {
        func fileComponents(_ url: URL) -> [String] {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let url = url.standardizedFileURL
            if url.path == home.path || url.path.hasPrefix(home.path + "/") {
                return [home.lastPathComponent] + Array(url.pathComponents.dropFirst(home.pathComponents.count))
            }
            return url.pathComponents
        }
        switch self {
        case .none: return ["No folder selected"]
        case .directory(let url): return fileComponents(url)
        case .archive(let archive, let prefix):
            var members: [String] = []; var session: ArchiveSession? = archive.session
            while let current = session, current.parent != nil {
                members.append(current.parentPath ?? current.url.lastPathComponent); session = current.parent
            }
            return fileComponents(archive.session.rootURL) +
                members.reversed().flatMap { $0.split(separator: "/").map(String.init) } + prefix.split(separator: "/").map(String.init)
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
    var type: String {
        if isLink { return "Link" }
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext + " file"
    }
    init(entry: ArchiveEntry) {
        name = entry.name; path = entry.path; url = nil; member = entry
        isDirectory = entry.isDirectory; isLink = entry.isLink; size = entry.size
        packedSize = entry.packedSize; modified = String(entry.modified.prefix(19))
    }
    init(url: URL, values: URLResourceValues) {
        self.url = url; name = url.lastPathComponent; path = url.path; member = nil
        isDirectory = values.isDirectory ?? false; isLink = values.isSymbolicLink ?? false
        size = values.fileSize.map { UInt64(max(0, $0)) }; packedSize = nil
        if let date = values.contentModificationDate { modified = UIFormat.date.string(from: date) } else { modified = "" }
    }
}

enum UIFormat {
    static let date: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; return formatter
    }()
    static func bytes(_ count: UInt64?) -> String {
        guard let count = count else { return "—" }
        if count > UInt64(Int64.max) { return String(count) + " B" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
    static func error(_ error: Error) {
        if case FMError.cancelled = error { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Operation could not be completed"
        alert.informativeText = String(error.localizedDescription.prefix(5000))
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    static func confirm(_ title: String, _ message: String, action: String = "Continue") -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func prompt(_ title: String, message: String = "", value: String = "", secure: Bool = false) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 26); field.stringValue = value
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
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
    let button = NSButton(title: "Browse…", target: nil, action: nil)
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
    private var count = 0
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 585, height: 0)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func row(_ title: String, _ control: NSView) {
        let y = CGFloat(count) * 34
        let label = NSTextField(labelWithString: title)
        label.alignment = .right; label.frame = NSRect(x: 0, y: y + 5, width: 142, height: 22)
        control.frame = NSRect(x: 154, y: y, width: 430, height: 28)
        addSubview(label); addSubview(control); count += 1; frame.size.height = CGFloat(count) * 34
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
