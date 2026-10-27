import SwiftUI

/// Info inspector (⌘I / Alt+Enter). Shows what 7-Zip's Properties window shows, without blocking the window.
struct InspectorView: View {
    let model: BrowserModel
    @AppStorage(PrefKey.timeStyle) private var timeStyle: TimeStyle = .iso
    @AppStorage(PrefKey.sizeStyle) private var sizeStyle: SizeStyle = .bytes

    var body: some View {
        let pane = model.active
        let selected = pane.selectedNodes()
        let archive = pane.archive ?? (selected.count == 1 && selected[0].kind == .archive ? selected[0] : nil)
        Form {
            if selected.count == 1, let node = selected.first {
                Section {
                    VStack(spacing: 8) {
                        FileIcon(node: node, size: 64)
                        Text(node.name).font(.headline).multilineTextAlignment(.center)
                        Text(Fmt.kind(node)).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                Section(pane.isInArchive ? "Item" : "Info") { itemRows(node, inArchive: pane.isInArchive) }
            } else if selected.count > 1 {
                Section("Selection") {
                    LabeledContent("Items", value: "\(selected.count)")
                    LabeledContent("Files", value: "\(selected.reduce(0) { $0 + $1.fileCount })")
                    LabeledContent("Size", value: size(selected.reduce(Int64(0)) { $0 + $1.totalSize }))
                    if pane.isInArchive {
                        LabeledContent("Packed Size", value: size(selected.reduce(Int64(0)) { $0 + $1.totalPacked }))
                    }
                }
            } else {
                Section("Folder") {
                    LabeledContent("Path", value: Paths.pretty(pane.path))
                    LabeledContent("Items", value: "\(pane.node.children.count)")
                }
            }
            if let archive, let info = archive.archive {
                Section("Archive") {
                    LabeledContent("Type", value: info.format.title)
                    LabeledContent("Physical Size", value: size(info.physicalSize))
                    LabeledContent("Headers Size", value: size(info.headersSize))
                    if !info.method.isEmpty { LabeledContent("Method", value: info.method) }
                    if info.format == .sevenZip {
                        LabeledContent("Solid", value: info.solid ? "+" : "-")
                        LabeledContent("Blocks", value: "\(info.blocks)")
                    }
                    LabeledContent("Files", value: "\(info.files)")
                    LabeledContent("Folders", value: "\(info.folders)")
                    LabeledContent("Encrypted", value: info.encrypted ? (info.headersEncrypted ? "Contents and names" : "Contents") : "No")
                    if info.volumes > 0 { LabeledContent("Volumes", value: "\(info.volumes)") }
                }
                if !info.comment.isEmpty {
                    Section("Comment") { Text(info.comment).textSelection(.enabled) }
                }
                Section {
                    Button(info.tested ? "Tested, no errors" : "Test Archive", systemImage: info.tested ? "checkmark.seal.fill" : "checkmark.seal") {
                        model.perform(.test)
                    }
                    .disabled(info.tested)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func itemRows(_ node: FileNode, inArchive: Bool) -> some View {
        if inArchive, let archive = node.enclosingArchive {
            LabeledContent("Path", value: String(node.path.dropFirst(archive.path.count + 1)))
        } else {
            LabeledContent("Where", value: Paths.pretty(node.parent?.path ?? "/"))
        }
        LabeledContent("Size", value: size(node.totalSize))
        if inArchive {
            LabeledContent("Packed Size", value: node.solidContinuation ? "In a solid block" : size(node.totalPacked))
        }
        LabeledContent("Modified", value: Fmt.date(node.modified, timeStyle))
        LabeledContent("Created", value: Fmt.date(node.created, timeStyle))
        if inArchive {
            if !node.attributes.isEmpty { LabeledContent("Attributes") { Text(node.attributes).monospaced() } }
            if !node.crc.isEmpty { LabeledContent("CRC") { Text(node.crc).monospaced().textSelection(.enabled) } }
            if !node.method.isEmpty { LabeledContent("Method", value: node.method) }
        }
    }

    private func size(_ n: Int64) -> String {
        sizeStyle == .bytes ? "\(Fmt.bytes(n)) bytes" : "\(Fmt.human(n)) (\(Fmt.bytes(n)) bytes)"
    }
}
