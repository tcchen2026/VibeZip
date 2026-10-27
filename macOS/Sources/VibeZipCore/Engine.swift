import Foundation
import CVibeZip

public struct ArchiveProgress: Sendable {
    public enum Phase: Int32, Sendable { case open, extract, test, update, hash, copy }
    public let phase: Phase
    public let completed: UInt64
    public let total: UInt64
    public let path: String
    public var fraction: Double? { total == 0 ? nil : min(1, Double(completed) / Double(total)) }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observer: ((ArchiveProgress) -> Void)?
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw FMError.cancelled } }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func observeProgress(_ observer: ((ArchiveProgress) -> Void)?) {
        lock.lock(); self.observer = observer; lock.unlock()
    }
    public func report(_ progress: ArchiveProgress) {
        lock.lock(); let receive = observer; lock.unlock(); receive?(progress)
    }
}

public struct ArchiveReport {
    public let output: String
}

private final class CallbackContext {
    let password: String?
    let token: CancellationToken
    init(_ password: String?, _ token: CancellationToken) { self.password = password; self.token = token }
}
enum NativeCallbackError: Error { case parentPassword(String) }

private func nativeCheck(_ status: Int32, _ error: inout VZError) throws {
    guard status != VZ_OK else { return }
    let message = withUnsafePointer(to: &error.message) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
    }
    switch status {
    case Int32(VZ_CANCELLED): throw FMError.cancelled
    case Int32(VZ_PASSWORD): throw FMError.passwordRequired(message)
    case Int32(VZ_PARENT_PASSWORD): throw NativeCallbackError.parentPassword(message)
    case Int32(VZ_ACCESS): throw FMError.fileAccessRequired(message)
    default: throw FMError.engine(error.detail == 0 ? status : error.detail, message)
    }
}

private func withCallbacks<T>(_ password: String?, _ token: CancellationToken,
                              _ body: (UnsafePointer<VZCallbacks>) throws -> T) throws -> T {
    if let password = password { try Engine.validatePassword(password) }
    try token.check()
    let context = CallbackContext(password, token)
    var callbacks = VZCallbacks()
    callbacks.context = Unmanaged.passUnretained(context).toOpaque()
    callbacks.cancelled = { pointer in
        guard let pointer = pointer else { return 0 }
        return Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue().token.isCancelled ? 1 : 0
    }
    callbacks.progress = { pointer, phase, done, total, path in
        guard let pointer = pointer else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
        context.token.report(ArchiveProgress(phase: ArchiveProgress.Phase(rawValue: phase) ?? .open,
            completed: done, total: total, path: path.map { String(cString: $0) } ?? ""))
    }
    callbacks.password = { pointer, buffer, capacity in
        guard let pointer = pointer, let buffer = buffer else { return 0 }
        let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
        if context.token.isCancelled { return -1 }
        guard let password = context.password else { return 0 }
        return password.withCString { value in
            let count = password.utf8.count + 1
            guard count <= capacity else { return 0 }
            buffer.update(from: value, count: count); return 1
        }
    }
    callbacks.filename_code_page = { _, bytes, count in
        guard let bytes = bytes, count > 0 else { return 437 }
        return ZIPFilenameEncoding.detect(Data(bytes: bytes, count: count))
    }
    return try withExtendedLifetime(context) { try body(&callbacks) }
}

struct NativeUpdateItem {
    var existingIndex: UInt32 = .max
    var path: String?
    var source: URL?
    var size: UInt64 = 0
    var modifiedNS: Int64 = 0
    var mode: UInt32 = 0
    var isDirectory = false
}

/// Loads the bundled full 7-Zip archive library. No child process or textual
/// protocol is involved in archive operations.
public final class Engine {
    public let libraryURL: URL
    let handle: OpaquePointer
    public init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
        var pointer: OpaquePointer?; var error = VZError()
        let status = vz_library_open(libraryURL.path, &pointer, &error)
        try nativeCheck(status, &error)
        guard let pointer = pointer else { throw FMError.message("Cannot load the 7-Zip archive library.") }
        handle = pointer
    }
    deinit { vz_library_close(handle) }

    public static func locate() throws -> URL {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        #if os(macOS)
        let filename = "libVibeZip7z.dylib"
        #else
        let filename = "libVibeZip7z.so"
        #endif
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/" + filename)
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard FileManager.default.fileExists(atPath: bundled.path) else { throw FMError.message("The bundled archive engine is missing. Please reinstall VibeZip.") }
            return bundled
        }
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["VIBEZIP_LIBRARY"] { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(bundled)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(project.appendingPathComponent(".build/native/\(architecture)/\(filename)"))
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/native/\(architecture)/\(filename)"))
        #endif
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FMError.message("The bundled 7-Zip library is missing. Run ./build.sh and open dist/VibeZip.app.")
        }
        return found
    }
    public static func validatePassword(_ password: String) throws {
        guard password.utf8.count <= 4096, !password.contains("\0") else {
            throw FMError.message("Passwords cannot contain NUL and must fit within 4,096 UTF-8 bytes.")
        }
    }
    public func formats() -> String {
        guard let result = vz_library_formats(handle) else { return "No archive formats available." }
        defer { vz_string_free(result) }; return String(cString: result)
    }
    func open(_ url: URL, password: String?, token: CancellationToken) throws -> NativeArchive {
        try withCallbacks(password, token) { callbacks in
            var pointer: OpaquePointer?; var error = VZError()
            let status = vz_archive_open(handle, url.path, callbacks, &pointer, &error)
            try nativeCheck(status, &error)
            guard let pointer = pointer else { throw FMError.message("Cannot open archive.") }
            return NativeArchive(engine: self, handle: pointer)
        }
    }
    func rewrite(_ old: NativeArchive?, output: URL, items: [NativeUpdateItem], options: CompressionOptions?,
                 password: String?, encryptedHeaders: Bool = false, zipAES: Bool? = nil,
                 token: CancellationToken) throws {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { for string in strings { free(string) } }
        func retain(_ value: String?) -> UnsafePointer<CChar>? {
            guard let value = value, let pointer = strdup(value) else { return nil }
            strings.append(pointer); return UnsafePointer(pointer)
        }
        let data = items.map { item -> VZUpdateItem in
            var value = VZUpdateItem(); value.existing_index = item.existingIndex
            value.path = retain(item.path); value.source = retain(item.source?.path)
            value.size = item.size; value.modified_ns = item.modifiedNS
            value.mode = item.mode; value.is_directory = item.isDirectory ? 1 : 0; return value
        }
        var settings = VZOptions(); settings.level = -1; settings.solid = -1
        settings.encrypt_headers = encryptedHeaders ? 1 : -1; settings.zip_aes = zipAES.map { $0 ? 1 : 0 } ?? -1
        if let options = options {
            try options.validate()
            settings.format = retain(options.format); settings.method = retain(options.method)
            settings.dictionary_bytes = try CompressionOptions.byteCount(options.dictionary)
            settings.volume_bytes = try CompressionOptions.byteCount(options.volumeSize)
            settings.level = Int32(options.level); settings.threads = Int32(options.threads)
            settings.solid = options.solid ? 1 : 0
            settings.encrypt_headers = options.password != nil && options.encryptHeaders ? 1 : 0
            settings.zip_aes = options.zipAES ? 1 : 0
        }
        try withCallbacks(password, token) { callbacks in
            var error = VZError()
            let status = data.withUnsafeBufferPointer {
                vz_archive_rewrite(handle, old?.handle, output.path, $0.baseAddress, UInt32($0.count), &settings, callbacks, &error)
            }
            try nativeCheck(status, &error)
        }
    }
    func hash(_ url: URL, algorithm: String, token: CancellationToken) throws -> String {
        try withCallbacks(nil, token) { callbacks in
            var digest: UnsafeMutablePointer<CChar>?; var error = VZError()
            let status = vz_library_hash(handle, algorithm, url.path, callbacks, &digest, &error)
            defer { if let digest = digest { vz_string_free(digest) } }
            try nativeCheck(status, &error)
            return digest.map { String(cString: $0) } ?? ""
        }
    }
}

final class NativeArchive {
    let engine: Engine
    let handle: OpaquePointer
    init(engine: Engine, handle: OpaquePointer) { self.engine = engine; self.handle = handle }
    deinit { vz_archive_close(handle) }

    func listing(token: CancellationToken) throws -> ArchiveListing {
        var info = VZArchiveInfo(); var error = VZError()
        let infoStatus = vz_archive_info(handle, &info, &error)
        try nativeCheck(infoStatus, &error)
        defer { vz_archive_info_free(&info) }
        var entries: [ArchiveEntry] = []; entries.reserveCapacity(Int(info.entry_count))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for index in 0..<info.entry_count {
            if index % 256 == 0 {
                try token.check()
                token.report(ArchiveProgress(phase: .open, completed: UInt64(index), total: UInt64(info.entry_count), path: "Reading entries"))
            }
            var item = VZEntry()
            let status = vz_archive_entry(handle, index, &item, &error)
            try nativeCheck(status, &error)
            defer { vz_entry_free(&item) }
            var properties: [String: String] = [:]
            if let method = item.method { properties["Method"] = String(cString: method) }
            if item.has_crc != 0 { properties["CRC"] = String(format: "%08X", item.crc) }
            if item.has_modified != 0 { properties["Modified"] = formatter.string(from: Date(timeIntervalSince1970: Double(item.modified_ns) / 1e9)) }
            entries.append(ArchiveEntry(path: item.path.map { String(cString: $0) } ?? "", size: item.has_size != 0 ? item.size : nil,
                packedSize: item.has_packed_size != 0 ? item.packed_size : nil, isDirectory: item.is_directory != 0,
                isLink: item.is_link != 0, isEncrypted: item.is_encrypted != 0, properties: properties,
                index: index, modifiedNS: item.has_modified != 0 ? item.modified_ns : nil, mode: item.mode))
        }
        return ArchiveListing(entries: entries, properties: ["Type": info.format.map { String(cString: $0) } ?? "",
            "Multivolume": info.multi_volume != 0 ? "+" : "-", "Writable": info.can_update != 0 ? "+" : "-",
            "Encrypted headers": info.encrypted_headers != 0 ? "+" : "-", "Direct stream": info.direct_stream != 0 ? "+" : "-"])
    }
    var bytesRead: UInt64 {
        var info = VZArchiveInfo(); var error = VZError()
        guard vz_archive_info(handle, &info, &error) == VZ_OK else { return 0 }
        defer { vz_archive_info_free(&info) }; return info.bytes_read
    }
    func nested(_ index: UInt32, scratch: URL, limit: UInt64, parentPassword: String?, password: String?,
                token: CancellationToken) throws -> NativeArchive {
        try withCallbacks(parentPassword, token) { parentCallbacks in
            try withCallbacks(password, token) { childCallbacks in
                var pointer: OpaquePointer?; var error = VZError()
                let status = vz_archive_open_nested(handle, index, scratch.path, limit, parentCallbacks, childCallbacks, &pointer, &error)
                try nativeCheck(status, &error)
                guard let pointer = pointer else { throw FMError.message("Cannot open nested archive.") }
                return NativeArchive(engine: engine, handle: pointer)
            }
        }
    }
    func extract(_ destinations: [(UInt32, URL?)], test: Bool = false, all: Bool = false,
                 limit: UInt64, password: String?, token: CancellationToken) throws {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { for string in strings { free(string) } }
        let items = destinations.map { index, url -> VZExtractItem in
            var item = VZExtractItem(); item.index = index
            if let path = url?.path, let string = strdup(path) { strings.append(string); item.destination = UnsafePointer(string) }
            return item
        }
        try withCallbacks(password, token) { callbacks in
            var error = VZError()
            let status = items.withUnsafeBufferPointer {
                vz_archive_extract(handle, all ? nil : $0.baseAddress, UInt32($0.count), test ? 1 : 0, limit, callbacks, &error)
            }
            try nativeCheck(status, &error)
        }
    }
}
