#if os(macOS)
import AppKit

final class AboutWindow: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About VibeZip"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let badge = GitHubBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 80), badge.heightAnchor.constraint(equalToConstant: 60),
            badge.centerXAnchor.constraint(equalTo: content.centerXAnchor), badge.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class GitHubBadge: NSButton {
    private let mark: NSImage?
    private let projectURL: URL?
    init() {
        mark = Bundle.main.url(forResource: "GitHub", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
        projectURL = (Bundle.main.object(forInfoDictionaryKey: "VibeZipRepositoryURL") as? String).flatMap(URL.init(string:))
        super.init(frame: .zero)
        title = ""; isBordered = false; focusRingType = .exterior
        target = self; action = #selector(openProject)
        toolTip = projectURL?.absoluteString; setAccessibilityLabel("GitHub")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 5, dy: 5) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 12, yRadius: 12).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = isHighlighted ? 2 : 4
        shadow.shadowOffset = NSSize(width: 0, height: isHighlighted ? -1 : -2); shadow.set()
        NSColor.black.setFill(); face.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(white: isHighlighted ? 0.10 : 0.18, alpha: 1),
                   ending: NSColor(white: 0.04, alpha: 1))?.draw(in: face, angle: -90)
        NSColor.white.withAlphaComponent(0.16).setStroke(); face.lineWidth = 0.75; face.stroke()
        let icon = NSRect(x: bounds.midX - 14, y: bounds.midY - 14, width: 28, height: 28)
        mark?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.8 : 1)
    }
    @objc private func openProject() {
        guard let url = projectURL, url.scheme == "https", url.host == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
