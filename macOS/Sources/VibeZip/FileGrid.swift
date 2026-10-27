#if os(macOS)
import AppKit

enum BrowserViewStyle: Int {
    case icons, list, details
}

final class FileCollectionView: NSCollectionView {
    var onFocus: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onOpen: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onFocus?(); super.mouseDown(with: event)
        if event.clickCount == 2 { onOpen?() }
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        onFocus?()
        if let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)), !selectionIndexPaths.contains(index) {
            selectionIndexPaths = [index]
            delegate?.collectionView?(self, didSelectItemsAt: [index])
        }
        return menu
    }
}

final class FileGridItem: NSCollectionViewItem {
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 8
        let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(wrappingLabelWithString: "")
        name.alignment = .center; name.font = .systemFont(ofSize: 12); name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        for child in [icon as NSView, name] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        imageView = icon; textField = name
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4), name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
    }
    func configure(_ row: BrowserRow) {
        textField?.stringValue = row.name
        imageView?.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.type)
        imageView?.contentTintColor = row.isDirectory ? .systemBlue : (row.symbol == "archivebox.fill" ? .systemOrange : .secondaryLabelColor)
        view.toolTip = row.path
        view.setAccessibilityLabel(row.name)
        updateSelection()
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        view.layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.17) : .clear).cgColor
    }
}
#endif
