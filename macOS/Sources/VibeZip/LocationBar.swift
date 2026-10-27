#if os(macOS)
import AppKit
import VibeZipCore

private final class LocationPathControl: NSPathControl {
    var onEdit: (() -> Void)?
    var onChoose: ((NSPathControlItem) -> Void)?
    private var activatedItem = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(chooseItem)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        activatedItem = false
        super.mouseDown(with: event)
        if !activatedItem { onEdit?() }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode) { onEdit?() } else { super.keyDown(with: event) }
    }
    @objc private func chooseItem() {
        activatedItem = true
        if let item = clickedPathItem { onChoose?(item) } else { onEdit?() }
    }
}

/// Displays the current path as native breadcrumbs until the user chooses to edit it.
final class LocationBar: NSView, NSTextFieldDelegate {
    let editor = NSTextField()
    private let breadcrumbs = LocationPathControl()
    private var components: [BrowserLocation.Breadcrumb] = []
    private var representedPath = ""
    private var isEditing = false
    var canEdit: (() -> Bool)?
    var onSubmit: ((String) -> Void)?
    var onNavigate: ((BrowserLocation) -> Void)?
    var onCancel: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard !isEditing, let hit = hit else { return hit }
        // Native path items keep their click handling; the surrounding padding edits the path.
        return hit === breadcrumbs || hit.isDescendant(of: breadcrumbs) ? hit : self
    }
    override func mouseDown(with event: NSEvent) { beginEditing() }

    init() {
        super.init(frame: .zero)
        let glass = NSGlassEffectView(); glass.cornerRadius = 16
        glass.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); glass.contentView = content; addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbs.pathStyle = .standard; breadcrumbs.backgroundColor = .clear
        breadcrumbs.isEditable = false; breadcrumbs.unregisterDraggedTypes()
        breadcrumbs.cell?.isSelectable = false
        breadcrumbs.font = .systemFont(ofSize: 13)
        breadcrumbs.setAccessibilityLabel(L10n.tr("Location"))
        breadcrumbs.setAccessibilityHelp(L10n.tr("Click an ancestor to go there. Click the current location or empty space to edit the path."))
        breadcrumbs.onEdit = { [weak self] in self?.beginEditing() }
        breadcrumbs.onChoose = { [weak self] item in self?.choose(item) }
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isBordered = false; editor.drawsBackground = false; editor.focusRingType = .none
        editor.isEditable = true; editor.isSelectable = true; editor.isEnabled = true
        editor.placeholderString = L10n.tr("Enter a folder or archive path")
        editor.setAccessibilityLabel(L10n.tr("Location"))
        editor.delegate = self; editor.target = self; editor.action = #selector(submit)
        editor.cell?.sendsActionOnEndEditing = false
        editor.isHidden = true
        for control in [breadcrumbs as NSControl, editor] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            content.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.heightAnchor.constraint(equalToConstant: 26)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(path: String, components: [BrowserLocation.Breadcrumb]) {
        let changed = path != representedPath
        representedPath = path
        self.components = components
        breadcrumbs.pathItems = components.map { component in
            let item = NSPathControlItem(); item.title = component.title; return item
        }
        breadcrumbs.toolTip = path; breadcrumbs.setAccessibilityValue(path)
        editor.toolTip = path
        if changed { endEditing(moveFocus: true) }
        if !isEditing { editor.stringValue = path }
    }
    private func choose(_ item: NSPathControlItem) {
        guard canEdit?() != false,
              let index = breadcrumbs.pathItems.firstIndex(where: { $0 === item }), components.indices.contains(index) else { return }
        if index == components.count - 1 { beginEditing() }
        else { onNavigate?(components[index].location) }
    }
    func beginEditing() {
        guard canEdit?() != false, let window = window else { return }
        if !isEditing { editor.stringValue = representedPath }
        isEditing = true; breadcrumbs.isHidden = true; editor.isHidden = false
        layoutSubtreeIfNeeded()
        if window.makeFirstResponder(editor) { editor.currentEditor()?.selectAll(nil) }
        else { endEditing(moveFocus: false) }
    }
    private func endEditing(moveFocus: Bool) {
        guard isEditing else { return }
        isEditing = false; breadcrumbs.isHidden = false
        if moveFocus { window?.makeFirstResponder(breadcrumbs) }
        editor.isHidden = true; editor.stringValue = representedPath
    }
    @objc private func submit() {
        guard isEditing else { return }
        let path = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endEditing(moveFocus: true)
        if !path.isEmpty { onSubmit?(path) } else { onCancel?() }
    }
    func controlTextDidEndEditing(_ notification: Notification) { endEditing(moveFocus: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(moveFocus: true); onCancel?(); return true
        }
        return false
    }
}
#endif
