#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import VibeZipCore

final class DefaultApplicationView: NSView {
    var onRequestStateChanged: ((Bool) -> Void)?
    var isEnabled = true { didSet { updateControls() } }
    private var isRequesting = false
    private var requestTask: Task<Void, Never>?
    private let formats = NSPopUpButton()
    private let button = NSButton(title: L10n.tr("Set VibeZip as Default"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let applicationURL = Bundle.main.bundleURL

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 585, height: 118))
        let heading = NSTextField(labelWithString: L10n.tr("Default archive app"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: L10n.tr("Choose formats to open with VibeZip. macOS may ask you to confirm each format."))
        description.font = .systemFont(ofSize: 12); description.textColor = .secondaryLabelColor
        let declarations = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        var seen = Set<String>()
        let extensions = declarations.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
            .filter { $0 != "*" && seen.insert($0).inserted }
        formats.addItem(withTitle: ".zip/.7z/.rar")
        formats.lastItem?.representedObject = ["zip", "7z", "rar"]
        for ext in extensions {
            formats.addItem(withTitle: "." + ext)
            formats.lastItem?.representedObject = [ext]
        }
        formats.selectItem(at: 0)
        formats.target = self; formats.action = #selector(selectionChanged)
        formats.setAccessibilityLabel(L10n.tr("Archive format"))
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(setDefault)
        let controls = NSStackView(views: [formats, button]); controls.spacing = 8
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, description, controls, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formats.widthAnchor.constraint(equalToConstant: 150)
        ])
        selectionChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { requestTask?.cancel() }

    private var contentTypes: [UTType]? {
        guard let extensions = formats.selectedItem?.representedObject as? [String], !extensions.isEmpty else { return nil }
        var types: [UTType] = []
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext),
                  ![UTType.item, .content, .data, .directory, .archive].contains(type) else { return nil }
            if !types.contains(type) { types.append(type) }
        }
        return types
    }
    private func isCurrentApplication(_ url: URL?) -> Bool {
        url?.standardizedFileURL.resolvingSymlinksInPath() == applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func updateControls() {
        formats.isEnabled = isEnabled && !isRequesting
        button.isEnabled = isEnabled && !isRequesting && contentTypes.map { types in
            types.contains { !isCurrentApplication(NSWorkspace.shared.urlForApplication(toOpen: $0)) }
        } == true
    }
    @objc private func selectionChanged() {
        status.toolTip = nil
        if let types = contentTypes {
            if types.count == 1, let type = types.first {
                let current = NSWorkspace.shared.urlForApplication(toOpen: type)
                let name = current?.deletingPathExtension().lastPathComponent ?? L10n.tr("Not set")
                status.stringValue = L10n.tr("Current app: \(name)")
            } else {
                let count = types.filter { isCurrentApplication(NSWorkspace.shared.urlForApplication(toOpen: $0)) }.count
                status.stringValue = L10n.tr("VibeZip is the default for \(count) of \(types.count) selected formats.")
            }
        } else { status.stringValue = L10n.tr("This file type is not registered with macOS.") }
        updateControls()
    }
    @objc private func setDefault() {
        guard isEnabled, !isRequesting, let types = contentTypes else { return }
        if types.allSatisfy({ isCurrentApplication(NSWorkspace.shared.urlForApplication(toOpen: $0)) }) { selectionChanged(); return }
        let names = formats.titleOfSelectedItem ?? ""
        let byIdentifier = Dictionary(uniqueKeysWithValues: types.map { ($0.identifier, $0) })
        isRequesting = true; updateControls(); onRequestStateChanged?(true)
        status.stringValue = L10n.tr("Waiting for macOS…"); status.toolTip = nil
        requestTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let outcome = await DefaultApplicationBatch.apply(types.map(\.identifier), isDefault: { identifier in
                guard let type = byIdentifier[identifier] else { return false }
                return self.isCurrentApplication(NSWorkspace.shared.urlForApplication(toOpen: type))
            }, request: { identifier in
                guard let type = byIdentifier[identifier] else { return }
                try await NSWorkspace.shared.setDefaultApplication(at: self.applicationURL, toOpen: type)
            })
            self.isRequesting = false; self.requestTask = nil
            if outcome.stoppedAt == nil && !outcome.cancelled {
                self.status.stringValue = L10n.tr("VibeZip is now the default for \(names) files.")
            } else if types.count == 1 {
                self.status.stringValue = L10n.tr("Default app unchanged. In Finder, use Get Info → Open with → VibeZip → Change All.")
                self.status.toolTip = outcome.error?.localizedDescription
            } else {
                let count = types.filter { self.isCurrentApplication(NSWorkspace.shared.urlForApplication(toOpen: $0)) }.count
                self.status.stringValue = L10n.tr("VibeZip is the default for \(count) of \(types.count) selected formats. No further changes were requested.")
                self.status.toolTip = outcome.error?.localizedDescription
            }
            self.updateControls(); self.onRequestStateChanged?(false)
        }
    }
}
#endif
