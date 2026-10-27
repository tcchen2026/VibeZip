import Foundation
import Observation

// MARK: - Archive formats

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case sevenZip = "7z", zip, tar, wim, xz, gzip, bzip2, rar, iso, dmg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sevenZip: "7z"
        case .gzip: "GZip"
        case .bzip2: "BZip2"
        default: rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .gzip: "gz"
        case .bzip2: "bz2"
        default: rawValue
        }
    }

    /// Formats 7-Zip can create. The rest are read-only.
    static let writable: [ArchiveFormat] = [.sevenZip, .zip, .tar, .wim, .xz, .gzip, .bzip2]

    var compresses: Bool { self != .tar && self != .wim }
    var supportsEncryption: Bool { self == .sevenZip || self == .zip }
    var singleFileOnly: Bool { self == .xz || self == .gzip || self == .bzip2 }

    var methods: [String] {
        switch self {
        case .sevenZip: ["LZMA2", "LZMA", "PPMd", "BZip2"]
        case .zip: ["Deflate", "Deflate64", "BZip2", "LZMA", "PPMd"]
        case .tar: ["GNU", "POSIX"]
        case .xz: ["LZMA2"]
        case .gzip: ["Deflate"]
        case .bzip2: ["BZip2"]
        default: ["Store"]
        }
    }

    var encryptionMethods: [String] {
        switch self {
        case .zip: ["AES-256", "ZipCrypto"]
        case .sevenZip: ["AES-256"]
        default: []
        }
    }
}

/// What 7-Zip reports about an archive (File ▸ Properties).
struct ArchiveInfo {
    var format: ArchiveFormat
    var methodTag = "LZMA2:24"
    var method = ""
    var solid = false
    var blocks = 0
    var headersSize: Int64 = 0
    var physicalSize: Int64 = 0
    var unpackedSize: Int64 = 0
    var files = 0
    var folders = 0
    var encrypted = false
    var headersEncrypted = false
    var locked = false
    var volumes = 0
    var comment = ""
    var tested = false

    init(_ format: ArchiveFormat, solid: Bool = false, encrypted: Bool = false, headersEncrypted: Bool = false,
         volumes: Int = 0, comment: String = "") {
        self.format = format
        self.solid = solid
        self.encrypted = encrypted
        self.headersEncrypted = headersEncrypted
        self.locked = headersEncrypted
        self.volumes = volumes
        self.comment = comment
    }
}

// MARK: - File tree

enum NodeKind: Equatable { case folder, file, archive }

@Observable
final class FileNode: Identifiable {
    let id = UUID()
    var name: String
    var kind: NodeKind
    var size: Int64
    var modified: Date
    var created: Date
    var children: [FileNode]
    @ObservationIgnored weak var parent: FileNode?
    var archive: ArchiveInfo?

    // 7-Zip columns for items stored inside an archive
    var packed: Int64?
    var solidContinuation = false
    var crc = ""
    var method = ""
    var attributes = ""

    var isExecutable = false
    var isApp = false

    init(name: String, kind: NodeKind, size: Int64 = 0, modified: Date, children: [FileNode] = [],
         archive: ArchiveInfo? = nil, executable: Bool = false, app: Bool = false) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = modified
        self.children = children
        self.archive = archive
        self.isExecutable = executable
        self.isApp = app
        for child in children { child.parent = self }
    }

    var ext: String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.contains(" ") ? "" : e
    }

    var isContainer: Bool { kind != .file }

    var path: String {
        var parts: [String] = []
        var node: FileNode? = self
        while let n = node, n.parent != nil {
            parts.insert(n.name, at: 0)
            node = n.parent
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Nearest archive at or above this node.
    var enclosingArchive: FileNode? {
        sequence(first: self, next: { $0.parent }).first { $0.kind == .archive }
    }

    /// Outermost archive above this node, i.e. the file that exists on disk.
    var outermostArchive: FileNode? {
        sequence(first: self, next: { $0.parent }).filter { $0.kind == .archive }.last
    }

    var isInsideArchive: Bool { parent?.enclosingArchive != nil }

    var totalSize: Int64 {
        kind == .folder ? children.reduce(0) { $0 + $1.totalSize } : size
    }

    var totalPacked: Int64 {
        kind == .folder ? children.reduce(0) { $0 + $1.totalPacked } : (packed ?? 0)
    }

    var fileCount: Int {
        kind == .folder ? children.reduce(0) { $0 + $1.fileCount } : 1
    }

    var folderCount: Int {
        children.reduce(0) { $0 + ($1.kind == .folder ? 1 + $1.folderCount : 0) }
    }

    /// Files below this node, without descending into nested archives.
    func allFiles() -> [FileNode] {
        children.flatMap { $0.kind == .folder ? $0.allFiles() : [$0] }
    }

    func add(_ node: FileNode) {
        node.parent = self
        children.append(node)
    }

    func remove(_ node: FileNode) {
        children.removeAll { $0 === node }
    }

    func uniqueChildName(_ name: String) -> String {
        guard children.contains(where: { $0.name == name }) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension, base = ext.isEmpty ? name : ns.deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !children.contains(where: { $0.name == candidate }) { return candidate }
            i += 1
        }
    }

    func copy(intoArchive: Bool) -> FileNode {
        let c = FileNode(name: name, kind: kind, size: kind == .folder ? 0 : size, modified: modified,
                         archive: archive, executable: isExecutable, app: isApp)
        if intoArchive {
            c.packed = packed; c.crc = crc; c.method = method; c.attributes = attributes
            c.solidContinuation = solidContinuation
        }
        for child in children { c.add(child.copy(intoArchive: intoArchive && kind != .archive)) }
        c.archive?.tested = false
        return c
    }

    func clearArchiveColumns() {
        packed = nil; crc = ""; method = ""; attributes = ""; solidContinuation = false
        for child in children where child.kind == .folder { child.clearArchiveColumns() }
    }
}

// MARK: - Store

@MainActor @Observable
final class ArchiveStore {
    let root: FileNode
    var openArchives: [String] = []
    var history: [String] = []

    init(root: FileNode) { self.root = root }

    static func sample() -> ArchiveStore {
        let store = ArchiveStore(root: SampleLibrary.make())
        store.openArchives = [Paths.home + "/Downloads/Kestrel-4.2.0.7z"]
        store.history = [Paths.home + "/Downloads", Paths.home + "/Documents/Projects", "/Volumes/Backup T7/Archives"]
        return store
    }

    func resolve(_ raw: String) -> FileNode? {
        var node = root
        for part in Paths.expand(raw).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// Creates missing folders on disk (never inside an archive).
    func makeFolders(_ raw: String) -> FileNode? {
        var node = root
        for part in Paths.expand(raw).split(separator: "/").map(String.init) {
            guard node.kind == .folder else { return nil }
            if let next = node.children.first(where: { $0.name == part }) {
                node = next
            } else {
                let folder = FileNode(name: part, kind: .folder, modified: .now)
                node.add(folder)
                node = folder
            }
        }
        return node.kind == .folder && node.enclosingArchive == nil ? node : nil
    }

    func noteVisit(_ node: FileNode) {
        let p = node.path
        history.removeAll { $0 == p }
        history.insert(p, at: 0)
        if history.count > 15 { history.removeLast() }
        if let top = node.outermostArchive, !openArchives.contains(top.path) {
            openArchives.append(top.path)
        }
    }
}

enum Paths {
    static let home = "/Users/mira"

    static func expand(_ p: String) -> String {
        let t = p.trimmingCharacters(in: .whitespaces)
        if t == "~" { return home }
        if t.hasPrefix("~/") { return home + t.dropFirst() }
        return t
    }

    /// Path as a person reads it: “Macintosh HD” for the root, “~” for the home folder.
    static func pretty(_ p: String) -> String {
        p == "/" ? "Macintosh HD" : tilde(p)
    }

    /// Path to type into a field: “~” abbreviates the home folder, the root stays “/”.
    static func tilde(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}

// MARK: - Packing (fills in what 7-Zip would report)

enum Packer {
    private static let media: Set<String> = ["png", "caf", "otf", "pdf", "heic", "mov", "wav", "jpg", "squashfs", "efi", "icns", "numbers", "key"]

    static func pack(_ archive: FileNode) {
        guard var info = archive.archive else { return }
        let files = archive.allFiles()

        switch info.format {
        case .sevenZip:
            if info.solid {
                // Solid 7z: files share compressed blocks, and 7-Zip shows the block's packed size on its first file.
                let groups = Dictionary(grouping: files) { $0.isExecutable ? 0 : (media.contains($0.ext) ? 2 : 1) }
                let ratios: [Int: Double] = [0: 0.36, 1: 0.21, 2: 0.965]
                for key in groups.keys.sorted() {
                    let group = groups[key] ?? []
                    let total = group.reduce(Int64(0)) { $0 + $1.size }
                    for (i, f) in group.enumerated() {
                        f.packed = i == 0 ? Int64(Double(total) * (ratios[key] ?? 0.3)) : 0
                        f.solidContinuation = i > 0
                    }
                }
                info.blocks = groups.count
            } else {
                for f in files { f.packed = Int64(Double(f.size) * (media.contains(f.ext) ? 0.97 : 0.3)); f.solidContinuation = false }
                info.blocks = files.count
            }
            for f in files {
                f.method = (f.isExecutable ? "ARM64 " : "") + info.methodTag + (info.encrypted ? " 7zAES" : "")
            }
            info.method = info.methodTag + (files.contains(where: \.isExecutable) ? " ARM64" : "") + (info.encrypted ? " 7zAES" : "")
        case .zip:
            for f in files {
                let store = media.contains(f.ext) && f.ext != "wav"
                f.packed = Int64(Double(f.size) * (store ? 1 : f.ext == "wav" ? 0.83 : 0.31)) + 30 + Int64(f.name.utf8.count)
                f.method = (info.encrypted ? "AES-256 " : "") + (store ? "Store" : "Deflate")
            }
            info.method = (info.encrypted ? "AES-256 " : "") + "Deflate"
        case .xz, .gzip, .bzip2:
            for f in files { f.packed = Int64(Double(f.size) * 0.104); f.method = info.format == .xz ? "LZMA2:26 CRC64" : info.format.methods[0] }
            info.method = files.first?.method ?? ""
        case .rar:
            for f in files { f.packed = Int64(Double(f.size) * 0.91); f.method = "m3:4M" }
            info.method = "m3:4M"
        default:
            for f in files { f.packed = info.format == .tar ? (f.size + 511) / 512 * 512 + 512 : f.size; f.method = "" }
        }

        let unixAttributes = info.format != .zip && info.format != .iso
        func mark(_ node: FileNode) {
            for n in node.children {
                n.crc = n.kind == .folder ? "" : Hash.crcString(n.name, n.size)
                if n.kind == .folder {
                    n.attributes = unixAttributes ? "D drwxr-xr-x" : "D"
                    mark(n)
                } else {
                    n.attributes = info.format == .iso ? "R" : unixAttributes ? (n.isExecutable ? "A -rwxr-xr-x" : "A -rw-r--r--") : "A"
                }
            }
        }
        mark(archive)

        switch info.format {
        case .zip:
            var central: Int64 = 22
            for f in files { central += 46 + Int64(f.name.utf8.count) }
            info.headersSize = central
        case .tar: info.headersSize = 1024
        default: info.headersSize = 4096
        }
        info.files = files.count
        info.folders = archive.folderCount
        info.unpackedSize = files.reduce(0) { $0 + $1.size }
        info.physicalSize = files.reduce(0) { $0 + ($1.packed ?? 0) } + info.headersSize
        archive.archive = info
        // Size on disk for an archive file; nested archives report their unpacked size instead.
        archive.size = archive.isInsideArchive ? info.unpackedSize : (info.volumes > 0 ? 4_290_772_992 : info.physicalSize)
    }
}

enum Hash {
    static func fnv(_ s: String, seed: UInt32 = 0x811C_9DC5) -> UInt32 {
        var h = seed
        for b in s.utf8 { h ^= UInt32(b); h = h &* 0x0100_0193 }
        return h
    }

    static func crcString(_ name: String, _ size: Int64) -> String {
        String(format: "%08X", fnv("\(name):\(size)"))
    }

    /// Stand-in digest of the requested length (hex characters) for the design build.
    static func hex(_ s: String, length: Int) -> String {
        var out = "", i: UInt32 = 0
        while out.count < length {
            out += String(format: "%08X", fnv("\(s)#\(i)", seed: 0x811C_9DC5 ^ (i &* 2_654_435_761)))
            i += 1
        }
        return String(out.prefix(length))
    }
}
