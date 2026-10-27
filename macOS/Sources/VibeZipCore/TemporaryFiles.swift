import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Only disposable copies go here. Archive transactions stay beside their destination.
public enum TemporaryFiles {
    public static var directory: URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("VibeZip", isDirectory: true)
    }

    @discardableResult
    public static func prepareDirectory() throws -> URL {
        let url = directory
        if !SafeFileSystem.exists(url) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            } catch {
                if SafeFileSystem.type(of: url) != .typeDirectory { throw error }
            }
        }
        try requireDirectory(url)
        return url
    }

    /// Total logical file size, including active copies. Reads metadata only and never follows links.
    public static func usageBytes(token: CancellationToken = CancellationToken()) throws -> UInt64 {
        try usageBytes(in: prepareDirectory(), token: token)
    }

    static func usageBytes(in directory: URL, token: CancellationToken = CancellationToken()) throws -> UInt64 {
        try token.check(); try requireDirectory(directory)
        var pending = [directory]
        var total: UInt64 = 0
        while let item = pending.popLast() {
            try token.check()
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    pending += try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                case .typeRegular:
                    let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let (sum, overflow) = total.addingReportingOverflow(bytes)
                    total = overflow ? UInt64.max : sum
                default: break
                }
            } catch let error as NSError where
                (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                // Another operation may release a scratch directory while it is being counted.
                continue
            }
        }
        return total
    }

    /// A live scratch directory holds a lock, including across VibeZip processes.
    /// Only matching, unlocked directories directly inside our temporary folder are removed.
    public static func cleanUnused(token: CancellationToken = CancellationToken()) throws -> Int {
        try cleanUnused(in: prepareDirectory(), token: token)
    }

    static func cleanUnused(in directory: URL, token: CancellationToken = CancellationToken()) throws -> Int {
        try token.check(); try requireDirectory(directory)
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var removed = 0
        for item in items {
            try token.check()
            let name = item.lastPathComponent
            guard name.hasPrefix("VibeZip-"), name.count > 44,
                  name.dropLast(36).hasSuffix("-"), UUID(uuidString: String(name.suffix(36))) != nil,
                  SafeFileSystem.type(of: item) == .typeDirectory else { continue }
            let lease: TemporaryDirectoryLease
            do { lease = try TemporaryDirectoryLease(item) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain &&
                    [Int(EWOULDBLOCK), Int(ENOENT), Int(ELOOP)].contains(error.code) { continue }
            try withExtendedLifetime(lease) { try removeTree(item, token: token) }
            removed += 1
        }
        return removed
    }

    private static func requireDirectory(_ url: URL) throws {
        guard SafeFileSystem.type(of: url) == .typeDirectory else {
            throw FMError.message(L10n.tr("The temporary folder is unavailable or is a symbolic link."))
        }
    }

    private static func removeTree(_ url: URL, token: CancellationToken) throws {
        try token.check()
        if SafeFileSystem.type(of: url) == .typeDirectory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try removeTree(child, token: token)
            }
        }
        // FileManager removes symbolic links themselves, never their destinations.
        try token.check(); try FileManager.default.removeItem(at: url)
    }
}

final class TemporaryDirectoryLease {
    private let descriptor: Int32
    init(_ url: URL) throws {
        let opened = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(opened)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        descriptor = opened
    }
    deinit { close(descriptor) }
}
