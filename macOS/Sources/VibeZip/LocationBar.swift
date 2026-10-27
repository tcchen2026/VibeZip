#if os(macOS)
import AppKit

private final class LocationPathControl: NSPathControl {
    var onEdit: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onEdit?() }
    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode) { onEdit?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onEdit?(); return true }
}

/// Displays the current path as native breadcrumbs until the user chooses to edit it.
final class LocationBar: NSView, NSTextFieldDelegate {
    let editor = NSTextField()
    private let breadcrumbs = LocationPathControl()
    private var representedPath = ""
    private var isEditing = false
    var canEdit: (() -> Bool)?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The entire breadcrumb area opens the editor, including native path subviews and blank space.
        return !isEditing && hit != nil ? self : hit
    }
    override func mouseDown(with event: NSEvent) { beginEditing() }

    init() {
        super.init(frame: .zero)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbs.pathStyle = .standard; breadcrumbs.backgroundColor = .clear
        breadcrumbs.isEditable = false; breadcrumbs.unregisterDraggedTypes()
        breadcrumbs.cell?.isSelectable = false
        breadcrumbs.font = .systemFont(ofSize: 13)
        breadcrumbs.setAccessibilityLabel("Location")
        breadcrumbs.setAccessibilityHelp("Click or press Command-L to edit the path.")
        breadcrumbs.onEdit = { [weak self] in self?.beginEditing() }
        editor.font = .systemFont(ofSize: 13); editor.bezelStyle = .roundedBezel
        editor.isEditable = true; editor.isSelectable = true; editor.isEnabled = true
        editor.placeholderString = "Enter a folder or archive path"
        editor.setAccessibilityLabel("Location")
        editor.delegate = self; editor.target = self; editor.action = #selector(submit)
        editor.cell?.sendsActionOnEndEditing = false
        editor.isHidden = true
        for control in [breadcrumbs as NSControl, editor] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor), control.trailingAnchor.constraint(equalTo: trailingAnchor),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.heightAnchor.constraint(equalToConstant: 26)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(path: String, components: [String]) {
        let changed = path != representedPath
        representedPath = path
        breadcrumbs.pathItems = components.map { title in
            let item = NSPathControlItem(); item.title = title; return item
        }
        breadcrumbs.toolTip = path; breadcrumbs.setAccessibilityValue(path)
        editor.toolTip = path
        if changed { endEditing(moveFocus: true) }
        if !isEditing { editor.stringValue = path }
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
