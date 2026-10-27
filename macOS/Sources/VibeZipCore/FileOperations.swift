import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class ScratchDirectory {
    public let url: URL
    private var retained = false
    public init(parent: URL = FileManager.default.temporaryDirectory, label: String = "work") throws {
        url = parent.resolvingSymlinksInPath().appendingPathComponent(".VibeZip-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
    }
    public func retainOnDisk() -> URL { retained = true; return url }
    deinit { if !retained { try? FileManager.default.removeItem(at: url) } }
}

public struct FileFingerprint: Equatable {
    public let size: UInt64
    public let modified: Date
    public let inode: UInt64
    public init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date ?? .distantPast
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

public struct TransferReport {
    public var written = 0
    public var skipped = 0
    public var paths: [URL] = []
    public init() {}
}

public enum SafeFileSystem {
    public static func type(of url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }
    public static func exists(_ url: URL) -> Bool { type(of: url) != nil }

    public static func ensureDirectory(_ directory: URL) throws {
        if let type = type(of: directory) {
            guard type == .typeDirectory else { throw FMError.message("The destination is not a regular folder or contains a symbolic link: \(directory.path)") }
        } else {
            try ensureDirectory(directory.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }

    public static func uniqueURL(_ url: URL) -> URL {
        if !exists(url) { return url }
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for index in 2...100_000 {
            let name = "\(base) (\(index))" + (ext.isEmpty ? "" : "." + ext)
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(candidate) { return candidate }
        }
        return url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    }

    /// rename(2) is atomic on a single volume. Never remove the original first.
    public static func atomicReplace(_ source: URL, destination: URL) throws {
        let result = source.path.withCString { from in destination.path.withCString { to in rename(from, to) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path]) }
    }

    public static func inspectTree(_ root: URL, limit: UInt64 = UInt64.max, rejectLinks: Bool = true) throws -> UInt64 {
        var total: UInt64 = 0
        func inspect(_ url: URL) throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                if rejectLinks { throw FMError.message("Extracting symbolic links is not supported: \(url.lastPathComponent)") }
                return
            }
            guard type == .typeRegular || type == .typeDirectory else {
                throw FMError.message("Special files such as devices and sockets are not supported: \(url.path)")
            }
            if type == .typeRegular {
                let bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let (sum, overflow) = total.addingReportingOverflow(bytes)
                guard !overflow, sum <= limit else { throw FMError.message("Extracted data exceeds the configured size limit.") }
                total = sum
            }
        }
        try inspect(root)
        if type(of: root) == .typeDirectory {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, error in enumerationError = error; return false }) else { return total }
            for case let url as URL in enumerator { try inspect(url) }
            if let error = enumerationError { throw error }
        }
        return total
    }

    @discardableResult
    public static func merge(_ source: URL, into requestedDestination: URL, policy: ConflictPolicy,
                             token: CancellationToken, report: inout TransferReport,
                             allowSourceLinks: Bool = false) throws -> Bool {
        try token.check()
        let sourceType = type(of: source)
        guard sourceType == .typeRegular || sourceType == .typeDirectory ||
                (allowSourceLinks && sourceType == .typeSymbolicLink) else {
            throw FMError.message("Cannot copy this special file or archive link: \(source.path)")
        }
        let parent = requestedDestination.deletingLastPathComponent()
        try ensureDirectory(parent)
        var destination = requestedDestination
        let destinationType = type(of: destination)
        // Existing destination symlinks are never followed or silently replaced.
        if destinationType == .typeSymbolicLink { throw FMError.message("The destination contains a symbolic link: \(destination.path)") }
        if sourceType == .typeDirectory && destinationType == .typeDirectory {
            var complete = true
            for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if try !merge(item, into: destination.appendingPathComponent(item.lastPathComponent),
                    policy: policy, token: token, report: &report, allowSourceLinks: allowSourceLinks) { complete = false }
            }
            return complete
        }
        if destinationType != nil {
            switch policy {
            case .skip: report.skipped += 1; return false
            case .rename: destination = uniqueURL(destination)
            case .replace:
                guard sourceType != .typeDirectory, destinationType == .typeRegular else {
                    throw FMError.message("A file and a folder share this name. Choose Auto rename: \(destination.path)")
                }
            }
        }
        if sourceType == .typeDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            report.paths.append(destination)
            var complete = true
            for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if try !merge(item, into: destination.appendingPathComponent(item.lastPathComponent),
                    policy: policy, token: token, report: &report, allowSourceLinks: allowSourceLinks) { complete = false }
            }
            // Preserve directory timestamps after copying its children.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: source.path), let date = attrs[.modificationDate] {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
            }
            return complete
        }
        let temporary = parent.appendingPathComponent(".VibeZip-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Copying a single file is not interruptible by FileManager; check before committing.
        try FileManager.default.copyItem(at: source, to: temporary)
        try token.check()
        if policy == .replace && destinationType != nil {
            guard type(of: destination) == .typeRegular else { throw FMError.message("The destination changed while copying.") }
            try atomicReplace(temporary, destination: destination)
        } else {
            // moveItem fails if another process creates the name, rather than clobbering it.
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        report.written += 1; report.paths.append(destination)
        return true
    }
}

public enum FileOperations {
    public static func copy(_ sources: [URL], to directory: URL, move: Bool, policy: ConflictPolicy,
                            token: CancellationToken, output: (String) -> Void = { _ in }) throws -> TransferReport {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try SafeFileSystem.ensureDirectory(directory)
        var report = TransferReport()
        for source in sources {
            let source = source.standardizedFileURL
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            guard source != destination else { throw FMError.message("The source and destination are the same file.") }
            if SafeFileSystem.type(of: source) == .typeDirectory {
                let canonical = source.resolvingSymlinksInPath().path
                guard !directory.path.hasPrefix(canonical + "/"), directory.path != canonical else {
                    throw FMError.message("A folder cannot be copied or moved inside itself.")
                }
            }
            try token.check(); output((move ? "Move " : "Copy ") + source.path + "\n")
            let complete = try SafeFileSystem.merge(source, into: destination, policy: policy,
                token: token, report: &report, allowSourceLinks: true)
            // A skipped item means the source tree must stay intact.
            if move && complete { try token.check(); try FileManager.default.removeItem(at: source) }
        }
        return report
    }

    public static func split(_ source: URL, to base: URL, volumeBytes: UInt64,
                             token: CancellationToken, output: (String) -> Void = { _ in }) throws -> [URL] {
        guard volumeBytes >= 1024, SafeFileSystem.type(of: source) == .typeRegular else {
            throw FMError.message("The source must be a regular file and the volume size must be at least 1 KiB.")
        }
        let before = try FileFingerprint(source)
        let count64 = max(1, before.size / volumeBytes + (before.size % volumeBytes == 0 ? 0 : 1))
        guard count64 <= 999_999 else { throw FMError.message("Too many volumes requested.") }
        let count = Int(count64)
        let destinations = (1...count).map { base.appendingPathExtension(String(format: "%03d", $0)) }
        guard destinations.allSatisfy({ !SafeFileSystem.exists($0) }) else { throw FMError.message("An output volume already exists.") }
        try SafeFileSystem.ensureDirectory(base.deletingLastPathComponent().resolvingSymlinksInPath())
        let scratch = try ScratchDirectory(parent: base.deletingLastPathComponent(), label: "split")
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        var staged: [URL] = []
        for (index, destination) in destinations.enumerated() {
            let file = scratch.url.appendingPathComponent(destination.lastPathComponent)
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            do {
                var remaining = min(volumeBytes, before.size - min(before.size, UInt64(index) * volumeBytes))
                while remaining > 0 {
                    try token.check()
                    let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                    guard !data.isEmpty else { throw FMError.message("The source file became shorter while splitting.") }
                    try handle.write(contentsOf: data); remaining -= UInt64(data.count)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            staged.append(file); output("\((index + 1) * 100 / count)%  \(destination.lastPathComponent)\n")
        }
        guard try FileFingerprint(source) == before else { throw FMError.message("The source file changed while splitting.") }
        try token.check(); var committed: [URL] = []
        do {
            for (file, destination) in zip(staged, destinations) {
                try FileManager.default.moveItem(at: file, to: destination); committed.append(destination)
            }
        } catch { for file in committed { try? FileManager.default.removeItem(at: file) }; throw error }
        return destinations
    }

    public static func combine(_ first: URL, to destination: URL, token: CancellationToken,
                               output: (String) -> Void = { _ in }) throws -> [URL] {
        guard first.pathExtension == "001", !SafeFileSystem.exists(destination) else {
            throw FMError.message("Choose the .001 volume and a new output filename.")
        }
        let base = first.deletingPathExtension()
        let names = try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path)
        let prefix = base.lastPathComponent + "."
        let indexes = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            let ext = String(name.dropFirst(prefix.count))
            guard ext.count >= 3, ext.allSatisfy({ $0.isNumber }) else { return nil }
            return Int(ext)
        }.filter { $0 > 0 }.sorted()
        guard let last = indexes.last, last <= 999_999, indexes == Array(1...last) else {
            throw FMError.message("Volume numbers are not consecutive. A volume is missing or duplicated.")
        }
        let parts = (1...last).map { base.appendingPathExtension(String(format: "%03d", $0)) }
        let snapshots = try parts.map { try FileFingerprint($0) }
        let scratch = try ScratchDirectory(parent: destination.deletingLastPathComponent(), label: "combine")
        let combined = scratch.url.appendingPathComponent(destination.lastPathComponent)
        _ = FileManager.default.createFile(atPath: combined.path, contents: nil)
        let handle = try FileHandle(forWritingTo: combined)
        do {
            for (index, part) in parts.enumerated() {
                let input = try FileHandle(forReadingFrom: part)
                do {
                    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                        try token.check(); try handle.write(contentsOf: data)
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
                guard try FileFingerprint(part) == snapshots[index] else { throw FMError.message("A volume changed while combining.") }
                output("\((index + 1) * 100 / parts.count)%  \(part.lastPathComponent)\n")
            }
            try handle.close(); try token.check()
            try FileManager.default.moveItem(at: combined, to: destination)
        } catch { try? handle.close(); throw error }
        return parts
    }
}
