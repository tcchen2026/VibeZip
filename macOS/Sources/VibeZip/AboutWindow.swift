#if os(macOS)
import AppKit
import VibeZipCore

final class AboutWindow: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.tr("About VibeZip"); window.isReleasedWhenClosed = false
        super.init(window: window)
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: "VibeZip")
        name.font = .systemFont(ofSize: 24, weight: .semibold)
        let versionNumber = (Bundle.main.object(forInfoDictionaryKey: "VibeZipVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let version = NSTextField(labelWithString: versionNumber.map { L10n.tr("Version \($0)") } ?? "")
        version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor
        version.isSelectable = true; version.isHidden = versionNumber == nil
        let description = NSTextField(labelWithString: L10n.tr("Archive manager for macOS"))
        description.font = .systemFont(ofSize: 13); description.textColor = .secondaryLabelColor
        let badge = GitHubBadge()
        let license = NSTextField(labelWithString: L10n.tr("Licensed under LGPL 2.1 or later"))
        license.font = .systemFont(ofSize: 11); license.textColor = .secondaryLabelColor
        license.isSelectable = true
        let stack = NSStackView(views: [icon, name, version, description, badge, license])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 8
        stack.setCustomSpacing(14, after: icon); stack.setCustomSpacing(3, after: name)
        stack.setCustomSpacing(12, after: version); stack.setCustomSpacing(20, after: description)
        stack.setCustomSpacing(12, after: badge)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72), icon.heightAnchor.constraint(equalToConstant: 72),
            badge.widthAnchor.constraint(equalToConstant: 132), badge.heightAnchor.constraint(equalToConstant: 46),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        window.initialFirstResponder = badge
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class GitHubBadge: NSButton {
    private let mark: NSImage?
    private let projectURL: URL?
    init() {
        mark = Bundle.main.url(forResource: "GitHub", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
        let configuredURL = (Bundle.main.object(forInfoDictionaryKey: "VibeZipRepositoryURL") as? String).flatMap(URL.init(string:))
        projectURL = configuredURL.flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
        super.init(frame: .zero)
        title = "GitHub"; isBordered = false; focusRingType = .exterior
        isEnabled = projectURL != nil
        target = self; action = #selector(openProject)
        toolTip = L10n.tr("View VibeZip on GitHub"); setAccessibilityLabel(L10n.tr("View VibeZip on GitHub"))
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
        let opacity: CGFloat = !isEnabled ? 0.45 : (isHighlighted ? 0.8 : 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity)
        ]
        let label = title as NSString; let labelSize = label.size(withAttributes: attributes)
        let iconWidth: CGFloat = mark == nil ? 0 : 22
        let gap: CGFloat = mark == nil ? 0 : 8
        let startX = bounds.midX - (iconWidth + gap + labelSize.width) / 2
        let icon = NSRect(x: startX, y: bounds.midY - 11, width: iconWidth, height: 22)
        mark?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: opacity,
                   respectFlipped: true, hints: nil)
        label.draw(at: NSPoint(x: startX + iconWidth + gap, y: bounds.midY - labelSize.height / 2), withAttributes: attributes)
    }
    @objc private func openProject() {
        guard let url = projectURL else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
