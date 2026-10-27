import SwiftUI

enum ViewStyle: String, CaseIterable, Identifiable {
    case largeIcons, smallIcons, list, details
    var id: String { rawValue }
    var command: Command {
        switch self {
        case .largeIcons: .viewLarge
        case .smallIcons: .viewSmall
        case .list: .viewList
        case .details: .viewDetails
        }
    }
}

/// One row of the file list. The “..” row points at the parent folder, as in 7-Zip.
struct FileRow: Identifiable {
    static let parentID = UUID()

    let node: FileNode
    var isParent = false
    var prefix = ""          // folder path shown in Flat View

    var id: UUID { isParent ? Self.parentID : node.id }

    // Sort keys for Table columns
    var name: String { node.name }
    var size: Int64 { node.totalSize }
    var packed: Int64 { node.totalPacked }
    var modified: Date { node.modified }
    var created: Date { node.created }
    var type: String { Fmt.kind(node) }
    var attributes: String { node.attributes }
    var crc: String { node.crc }
    var method: String { node.method }
}

@MainActor @Observable
final class PaneState: Identifiable {
    let id = UUID()
    let store: ArchiveStore
    var path: String
    var selection: Set<UUID> = []
    var sortOrder: [KeyPathComparator<FileRow>] = [KeyPathComparator(\FileRow.name)]
    var style: ViewStyle = .details
    var filter = ""
    var flat = false
    var backStack: [String] = []
    var forwardStack: [String] = []
    var renaming: UUID?
    var editingPath = false

    init(store: ArchiveStore, path: String) {
        self.store = store
        self.path = path
    }

    var node: FileNode { store.resolve(path) ?? store.root }
    var archive: FileNode? { node.enclosingArchive }
    var isInArchive: Bool { archive != nil }

    func rows(showParent: Bool) -> [FileRow] {
        let folder = node
        var items: [FileRow] = []
        if flat {
            func walk(_ dir: FileNode, _ prefix: String) {
                for child in dir.children {
                    if child.kind == .folder { walk(child, prefix + child.name + "/") }
                    else { items.append(FileRow(node: child, prefix: prefix)) }
                }
            }
            walk(folder, "")
        } else {
            items = folder.children.map { FileRow(node: $0) }
        }
        if !filter.isEmpty {
            items = items.filter { $0.node.name.localizedCaseInsensitiveContains(filter) }
        }
        if !sortOrder.isEmpty { items.sort(using: sortOrder) }
        // 7-Zip lists folders before files whatever the sort column.
        items = items.filter { $0.node.kind == .folder } + items.filter { $0.node.kind != .folder }
        if showParent, !flat, filter.isEmpty, let parent = folder.parent {
            items.insert(FileRow(node: parent, isParent: true), at: 0)
        }
        return items
    }

    func selectedNodes() -> [FileNode] {
        rows(showParent: false).filter { selection.contains($0.id) }.map(\.node)
    }

    func isSorted(by keyPath: PartialKeyPath<FileRow>) -> Bool { sortOrder.first?.keyPath == keyPath }

    func sort(by keyPath: KeyPath<FileRow, String>) { toggleSort(KeyPathComparator(keyPath)) }
    func sort(by keyPath: KeyPath<FileRow, Int64>) { toggleSort(KeyPathComparator(keyPath)) }
    func sort(by keyPath: KeyPath<FileRow, Date>) { toggleSort(KeyPathComparator(keyPath)) }

    private func toggleSort(_ comparator: KeyPathComparator<FileRow>) {
        if var current = sortOrder.first, current.keyPath == comparator.keyPath {
            current.order = current.order == .forward ? .reverse : .forward
            sortOrder = [current]
        } else {
            sortOrder = [comparator]
        }
    }
}
