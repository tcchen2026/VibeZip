import Foundation

public enum FMError: LocalizedError {
    case message(String)
    case cancelled
    case passwordRequired(String)
    case passwordForArchive(URL, String)
    case fileAccessRequired(String)
    case engine(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return L10n.tr("Operation cancelled.")
        case .passwordRequired(let text): return text.isEmpty ? L10n.tr("A password is required or the password is incorrect.") : text
        case .passwordForArchive(_, let text): return text
        case .fileAccessRequired(let text): return text
        case .engine(let code, let text): return L10n.tr("\(text)\n\n7-Zip error: \(code)")
        }
    }
}

public enum ArchivePath {
    /// Unsafe names remain visible when browsing, but cannot escape extraction roots.
    public static func validate(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !path.contains("\\") else {
            throw FMError.message(L10n.tr("This archive path cannot be used safely: \(path.debugDescription)"))
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !(components.first?.contains(":") ?? false) else {
            throw FMError.message(L10n.tr("The archive contains an unsafe or ambiguous path: \(path)"))
        }
        return path
    }
    public static func isWithin(_ path: String, parent: String) -> Bool {
        parent.isEmpty || path == parent || path.hasPrefix(parent + "/")
    }
    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }; return String(path[..<slash])
    }
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FMError.message(L10n.tr("Names cannot be empty or contain /, \\, : or control characters."))
        }
    }
}

public struct ArchiveEntry: Equatable {
    public var path: String
    public var size: UInt64?
    public var packedSize: UInt64?
    public var isDirectory: Bool
    public var isLink: Bool
    public var isEncrypted: Bool
    public var properties: [String: String]
    /// Stable native item identity; nil only for an inferred directory.
    public var index: UInt32?
    public var modifiedNS: Int64?
    public var mode: UInt32
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var modified: String { properties["Modified"] ?? "" }
    public var crc: String { properties["CRC"] ?? "" }
    public var method: String { properties["Method"] ?? "" }
    public init(path: String, size: UInt64? = nil, packedSize: UInt64? = nil,
                isDirectory: Bool = false, isLink: Bool = false, isEncrypted: Bool = false,
                properties: [String: String] = [:], index: UInt32? = nil, modifiedNS: Int64? = nil, mode: UInt32 = 0) {
        self.path = path; self.size = size; self.packedSize = packedSize
        self.isDirectory = isDirectory; self.isLink = isLink; self.isEncrypted = isEncrypted
        self.properties = properties; self.index = index; self.modifiedNS = modifiedNS; self.mode = mode
    }
}

public struct ArchiveListing {
    public let entries: [ArchiveEntry]
    public let properties: [String: String]
    private let directoryIndex: [String: [ArchiveEntry]]
    public let totalSize: UInt64
    public var format: String { properties["Type"] ?? "" }
    public var isMultiVolume: Bool { properties["Multivolume"] == "+" }
    public var canUpdate: Bool { properties["Writable"] == "+" && !isMultiVolume }
    public var hasEncryptedHeaders: Bool { properties["Encrypted headers"] == "+" }
    public var usesDirectStream: Bool { properties["Direct stream"] == "+" }
    public init(entries: [ArchiveEntry], properties: [String: String] = [:]) {
        self.entries = entries; self.properties = properties
        var index: [String: [ArchiveEntry]] = [:]
        var directories: [String: ArchiveEntry] = [:]
        var total: UInt64 = 0
        for entry in entries {
            let (sum, overflow) = total.addingReportingOverflow(entry.size ?? 0); total = overflow ? .max : sum
            if entry.isDirectory { directories[entry.path] = entry }
            else { index[ArchivePath.parent(of: entry.path), default: []].append(entry) }
            var parent = ArchivePath.parent(of: entry.path)
            while !parent.isEmpty && directories[parent] == nil {
                directories[parent] = ArchiveEntry(path: parent, isDirectory: true)
                parent = ArchivePath.parent(of: parent)
            }
        }
        for entry in directories.values { index[ArchivePath.parent(of: entry.path), default: []].append(entry) }
        directoryIndex = index; totalSize = total
    }
    /// O(number of visible children), independent of total archive size.
    public func children(of prefix: String) -> [ArchiveEntry] { directoryIndex[prefix] ?? [] }
    /// Searches names and paths throughout this archive without reading file contents.
    /// The directory index also includes inferred folders and preserves duplicate file identities.
    public func search(_ query: String) -> [ArchiveEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var matches: [ArchiveEntry] = []
        for children in directoryIndex.values {
            for entry in children {
                if entry.path.localizedCaseInsensitiveContains(query) { matches.append(entry) }
            }
        }
        return matches
    }
    public func selected(_ paths: [String]) -> [ArchiveEntry] {
        guard !paths.isEmpty else { return entries }
        let selected = Set(paths)
        return entries.filter { entry in
            var path = entry.path
            while !path.isEmpty {
                if selected.contains(path) { return true }; path = ArchivePath.parent(of: path)
            }
            return selected.contains("")
        }
    }
}

public enum ConflictPolicy: Int, CaseIterable {
    case rename, skip, replace
    public var title: String {
        switch self { case .rename: return L10n.tr("Auto rename"); case .skip: return L10n.tr("Skip existing files"); case .replace: return L10n.tr("Replace existing files") }
    }
}
public enum ExtractionLayout { case fullPaths, relativeTo(String), flat }

public struct CompressionOptions {
    public var format = "7z"
    public var level = 5
    public var method = ""
    public var dictionary = ""
    public var threads = 0
    public var solid = true
    public var password: String?
    public var encryptHeaders = true
    public var zipAES = true
    public var volumeSize = ""
    public var verify = true
    public init() {}
    public func validate() throws {
        guard ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim"].contains(format), (0...9).contains(level),
              (0...1024).contains(threads) else { throw FMError.message(L10n.tr("Invalid compression settings.")) }
        if format == "7z" {
            guard ["", "LZMA2", "LZMA", "PPMd", "BZip2"].contains(method) else { throw FMError.message(L10n.tr("Unsupported compression method.")) }
            if !dictionary.isEmpty {
                guard ["16m", "32m", "64m", "128m", "256m"].contains(dictionary.lowercased()), ["", "LZMA2", "LZMA"].contains(method) else {
                    throw FMError.message(L10n.tr("These dictionary sizes require LZMA or LZMA2."))
                }
            }
        }
        if let password = password {
            try Engine.validatePassword(password)
            guard ["7z", "zip"].contains(format) else { throw FMError.message(L10n.tr("Use 7z or ZIP for password encryption.")) }
            if format == "zip" { try Self.validateZIPPassword(password, aes: zipAES) }
        }
        let volume = try Self.byteCount(volumeSize)
        guard volume == 0 || volume >= 1024 else { throw FMError.message(L10n.tr("Volumes must be at least 1 KiB.")) }
    }
    static func validateZIPPassword(_ password: String, aes: Bool) throws {
        guard password.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            throw FMError.message(L10n.tr("7-Zip requires printable ASCII passwords when writing ZIP archives. Use 7z for Unicode passwords."))
        }
        if aes && password.utf8.count > 99 { throw FMError.message(L10n.tr("ZIP AES passwords can contain at most 99 characters.")) }
    }
    public static func byteCount(_ value: String) throws -> UInt64 {
        guard !value.isEmpty else { return 0 }
        let value = value.lowercased()
        let multipliers: [Character: UInt64] = ["k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024]
        let multiplier = value.last.flatMap { multipliers[$0] } ?? 1
        let digits = multiplier == 1 ? value : String(value.dropLast())
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let number = UInt64(digits), number > 0 else {
            throw FMError.message(L10n.tr("Enter a size such as 100m, 700m or 4g."))
        }
        let (bytes, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow, bytes <= UInt64(Int64.max) else { throw FMError.message(L10n.tr("The requested size is too large.")) }
        return bytes
    }
}
