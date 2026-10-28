import Foundation

public struct MutationResult {
    /// Optional recovery copy in managed temporary storage; cleanup may remove it.
    public let backup: URL?
    public let log: String
}

/// A live IInArchive session. Nested sessions own their parent and, when needed,
/// a private disk spool. File contents never accumulate in Swift Data buffers.
public final class ArchiveSession {
    public let id = UUID()
    public let url: URL
    public let rootURL: URL
    public let parent: ArchiveSession?
    public let parentPath: String?
    public fileprivate(set) var listing: ArchiveListing
    public var password: String?
    fileprivate var openedPassword: String?
    fileprivate var native: NativeArchive
    fileprivate var fingerprint: FileFingerprint
    fileprivate var scratch: ScratchDirectory?
    fileprivate var parentIndex: UInt32?
    fileprivate var valid = true
    public var isNested: Bool { parent != nil }
    public var depth: Int { (parent?.depth ?? -1) + 1 }
    public var canModify: Bool { listing.canUpdate && (parent?.canModify ?? true) }
    public var usesDirectStream: Bool { listing.usesDirectStream }
    public var bytesRead: UInt64 { native.bytesRead }
    public var displayPath: String { parent.map { $0.displayPath + " ▸ " + (parentPath ?? "") } ?? rootURL.path }
    fileprivate init(url: URL, native: NativeArchive, listing: ArchiveListing, password: String?, fingerprint: FileFingerprint,
                     parent: ArchiveSession? = nil, entry: ArchiveEntry? = nil, scratch: ScratchDirectory? = nil) {
        self.url = url; self.native = native; self.listing = listing; self.password = password; openedPassword = password
        self.fingerprint = fingerprint; self.parent = parent; self.parentPath = entry?.path; parentIndex = entry?.index
        self.scratch = scratch; rootURL = parent?.rootURL ?? url
    }
}

public final class ArchiveService {
    private final class WeakSession {
        weak var value: ArchiveSession?
        init(_ value: ArchiveSession) { self.value = value }
    }
    public let engine: Engine
    /// Enforced both against declared sizes and every output write, including nested spools.
    public var extractionLimit: UInt64 = 100 * 1024 * 1024 * 1024
    private let lock = NSRecursiveLock()
    private var sessions: [URL: WeakSession] = [:]
    private var recentRoots: [ArchiveSession] = []
    private var liveSessions: [ArchiveSession] { sessions.values.compactMap(\.value) }
    private func remember(_ session: ArchiveSession) {
        sessions = sessions.filter { $0.value.value != nil }
        sessions[session.url.standardizedFileURL] = WeakSession(session)
        if !session.isNested { recentRoots.append(session); if recentRoots.count > 4 { recentRoots.removeFirst() } }
    }
    public init(engine: Engine) { self.engine = engine }

    public func open(_ url: URL, password: String? = nil, token: CancellationToken = CancellationToken()) throws -> ArchiveSession {
        lock.lock(); defer { lock.unlock() }; try token.check()
        let url = url.standardizedFileURL
        if let session = sessions[url]?.value {
            if session.parent != nil {
                if !session.valid, let parent = session.parent { try openParent(parent, token: token) }
                else { try requireFresh(session) }
                if !session.valid || session.openedPassword != password { try reopen(session, password: password, token: token) }
                session.password = password; return session
            }
            if session.valid, try FileFingerprint(url) == session.fingerprint, session.openedPassword == password {
                session.password = password; return session
            }
            try reopen(session, password: password, token: token); return session
        }
        guard SafeFileSystem.type(of: url) == .typeRegular else { throw FMError.message(L10n.tr("Open a regular archive file, not a symbolic link.")) }
        let fingerprint = try FileFingerprint(url)
        let native = try engine.open(url, password: password, token: token)
        let listing = try native.listing(token: token)
        guard try FileFingerprint(url) == fingerprint else { throw FMError.message(L10n.tr("The archive changed while it was being opened.")) }
        let session = ArchiveSession(url: url, native: native, listing: listing, password: password, fingerprint: fingerprint)
        remember(session); return session
    }

    public func openNested(in parent: ArchiveSession, index: UInt32, password: String? = nil,
                           token: CancellationToken = CancellationToken()) throws -> ArchiveSession {
        lock.lock(); defer { lock.unlock() }
        guard try FileFingerprint(parent.rootURL) == parent.fingerprint else {
            throw FMError.message(L10n.tr("The containing archive changed. Refresh it before opening this entry."))
        }
        try openParent(parent, token: token); try requireFresh(parent)
        guard parent.depth < 64 else { throw FMError.message(L10n.tr("The maximum nesting depth is 64 archives.")) }
        guard let entry = parent.listing.entries.first(where: { $0.index == index }), !entry.isDirectory, !entry.isLink else {
            throw FMError.message(L10n.tr("Select a regular archive entry."))
        }
        _ = try ArchivePath.validate(entry.path)
        if let existing = liveSessions.first(where: { $0.parent === parent && $0.parentIndex == index && $0.openedPassword == password && $0.valid }) {
            return existing
        }
        let scratch = try ScratchDirectory(label: "nested")
        let path = scratch.url.appendingPathComponent(entry.name)
        let native = try nestedNative(parent, index: index, scratch: path, password: password, token: token)
        let listing = try native.listing(token: token); try requireFresh(parent)
        let child = ArchiveSession(url: path, native: native, listing: listing, password: password,
            fingerprint: parent.fingerprint, parent: parent, entry: entry, scratch: listing.usesDirectStream ? nil : scratch)
        remember(child); return child
    }

    public func list(_ archive: URL, password: String? = nil, token: CancellationToken = CancellationToken()) throws -> ArchiveListing {
        try open(archive, password: password, token: token).listing
    }

    public func forgetPasswords() {
        lock.lock(); defer { lock.unlock() }
        for session in liveSessions { session.password = nil; session.openedPassword = nil; session.valid = false }
    }
    public func cleanupTemporaryFiles() {
        lock.lock(); defer { lock.unlock() }
        for session in liveSessions {
            if let scratch = session.scratch { try? FileManager.default.removeItem(at: scratch.url) }
            session.valid = false
        }
        recentRoots.removeAll(); sessions.removeAll()
    }

    @discardableResult
    public func test(_ archive: URL, password: String? = nil, paths: [String] = [], token: CancellationToken = CancellationToken(),
                     output: @escaping (String) -> Void = { _ in }) throws -> ArchiveReport {
        lock.lock(); defer { lock.unlock() }
        let session = try open(archive, password: password, token: token); try requireFresh(session)
        let selected = session.listing.selected(paths)
        guard paths.isEmpty || !selected.isEmpty else { throw FMError.message(L10n.tr("The selected entries no longer exist.")) }
        output(L10n.tr("Testing \(session.displayPath)\n"))
        try session.native.extract(selected.compactMap { $0.index.map { ($0, nil) } }, test: true, all: paths.isEmpty,
            limit: .max, password: password, token: token)
        try requireFresh(session)
        let text = L10n.tr("Everything is OK. \(selected.count) entries tested.\n"); output(text)
        return ArchiveReport(output: text)
    }

    @discardableResult
    public func extract(_ archive: URL, paths: [String] = [], indices: [UInt32]? = nil, to destination: URL,
                        layout: ExtractionLayout = .fullPaths, policy: ConflictPolicy = .rename,
                        password: String? = nil, token: CancellationToken = CancellationToken(),
                        output: @escaping (String) -> Void = { _ in }) throws -> TransferReport {
        lock.lock(); defer { lock.unlock() }
        let session = try open(archive, password: password, token: token); try requireFresh(session)
        let selected: [ArchiveEntry]
        if let indices = indices { let ids = Set(indices); selected = session.listing.entries.filter { $0.index.map(ids.contains) ?? false } }
        else { selected = session.listing.selected(paths) }
        guard (paths.isEmpty && indices == nil) || !selected.isEmpty else { throw FMError.message(L10n.tr("The selected entries no longer exist.")) }
        try validateEntries(selected, unique: true)
        var declared: UInt64 = 0
        for entry in selected {
            guard !entry.isLink else { throw FMError.message(L10n.tr("Extracting symbolic links or hard links is not supported: \(entry.path)")) }
            let (sum, overflow) = declared.addingReportingOverflow(entry.size ?? 0)
            guard !overflow, sum <= extractionLimit else { throw FMError.message(L10n.tr("The selected files exceed the extraction size limit.")) }; declared = sum
        }
        let scratch = try ScratchDirectory(label: "extract")
        var destinations: [(UInt32, URL?)] = []
        for entry in selected {
            try token.check(); let path = scratch.url.appendingPathComponent(entry.path)
            try SafeFileSystem.ensureDirectory(entry.isDirectory ? path : path.deletingLastPathComponent())
            if let index = entry.index { destinations.append((index, path)) }
        }
        output(L10n.tr("Extracting \(selected.count) entries…\n"))
        try session.native.extract(destinations, limit: extractionLimit, password: password, token: token)
        try requireFresh(session)
        for entry in selected.sorted(by: { $0.path.count > $1.path.count }) {
            let url = scratch.url.appendingPathComponent(entry.path)
            var attributes: [FileAttributeKey: Any] = [:]
            if let ns = entry.modifiedNS { attributes[.modificationDate] = Date(timeIntervalSince1970: Double(ns) / 1e9) }
            if entry.mode != 0 { attributes[.posixPermissions] = NSNumber(value: entry.mode & 0o777) }
            if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path) }
        }
        try token.check(); try SafeFileSystem.ensureDirectory(destination)
        output(L10n.tr("Copying extracted files to the destination…\n"))
        var report = TransferReport()
        func mergeChildren(_ directory: URL) throws {
            guard SafeFileSystem.type(of: directory) == .typeDirectory else { throw FMError.message(L10n.tr("The selected archive folder does not exist.")) }
            for source in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try SafeFileSystem.merge(source, into: destination.appendingPathComponent(source.lastPathComponent), policy: policy, token: token, report: &report)
            }
        }
        switch layout {
        case .fullPaths: try mergeChildren(scratch.url)
        case .relativeTo(let prefix):
            if !prefix.isEmpty { _ = try ArchivePath.validate(prefix) }
            try mergeChildren(prefix.isEmpty ? scratch.url : scratch.url.appendingPathComponent(prefix))
        case .flat:
            for entry in selected where !entry.isDirectory {
                try SafeFileSystem.merge(scratch.url.appendingPathComponent(entry.path), into: destination.appendingPathComponent(entry.name),
                    policy: policy, token: token, report: &report)
            }
        }
        output(L10n.tr("Completed: \(report.written) files, \(report.skipped) skipped.\n")); return report
    }

    @discardableResult
    public func create(_ sources: [URL], output archive: URL, options: CompressionOptions,
                       token: CancellationToken = CancellationToken(), progress: @escaping (String) -> Void = { _ in }) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }; try token.check(); try options.validate()
        guard !SafeFileSystem.exists(archive) else { throw FMError.message(L10n.tr("The archive already exists. Use Add to update an existing archive.")) }
        let parent = archive.deletingLastPathComponent().resolvingSymlinksInPath()
        for source in sources where SafeFileSystem.type(of: source) == .typeDirectory {
            let path = source.resolvingSymlinksInPath().path
            guard !ArchivePath.isWithin(parent.path, parent: path) else { throw FMError.message(L10n.tr("The output archive cannot be inside an input folder.")) }
        }
        let inputs = try sourceItems(sources, prefix: "", token: token)
        if ["gzip", "bzip2", "xz"].contains(options.format), inputs.items.count != 1 || inputs.items[0].isDirectory {
            throw FMError.message(L10n.tr("GZip, BZip2 and XZ require one regular file. Create a TAR first for multiple files."))
        }
        try SafeFileSystem.ensureDirectory(parent)
        let scratch = try ScratchDirectory(parent: parent, label: "create")
        let staged = scratch.url.appendingPathComponent(archive.lastPathComponent)
        progress(L10n.tr("Creating \(archive.lastPathComponent)…\n"))
        try engine.rewrite(nil, output: staged, items: inputs.items, options: options, password: options.password, token: token)
        try checkInputs(inputs.snapshots)
        let files = try FileManager.default.contentsOfDirectory(at: scratch.url, includingPropertiesForKeys: nil)
            .filter { SafeFileSystem.type(of: $0) == .typeRegular }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = files.first else { throw FMError.message(L10n.tr("The archive engine did not create an output file.")) }
        if options.verify { try verify(first, password: options.password, token: token, output: progress) }
        let destinations = files.map { parent.appendingPathComponent($0.lastPathComponent) }
        guard destinations.allSatisfy({ !SafeFileSystem.exists($0) }) else { throw FMError.message(L10n.tr("An output file or volume already exists.")) }
        try token.check(); var committed: [URL] = []
        do {
            for (file, destination) in zip(files, destinations) {
                try FileManager.default.moveItem(at: file, to: destination); committed.append(destination)
            }
        } catch { for file in committed { try? FileManager.default.removeItem(at: file) }; throw error }
        progress(L10n.tr("Created \(destinations.count) archive file(s).\n")); return destinations
    }

    public func add(_ sources: [URL], to archive: URL, prefix: String = "", password: String? = nil,
                    replaceExisting: Bool = true, backup: Bool = false, token: CancellationToken = CancellationToken(),
                    output: @escaping (String) -> Void = { _ in }) throws -> MutationResult {
        lock.lock(); defer { lock.unlock() }
        let session = try open(archive, password: password, token: token)
        let inputs = try sourceItems(sources, prefix: prefix, token: token)
        let paths = Set(inputs.items.compactMap(\.path))
        if !replaceExisting, session.listing.entries.contains(where: { paths.contains($0.path) }) {
            throw FMError.message(L10n.tr("The destination name already exists."))
        }
        var items = retainedItems(session).filter { !paths.contains(session.listing.entries[Int($0.existingIndex)].path) }
        items.append(contentsOf: inputs.items)
        return try mutate(session, items: items, snapshots: inputs.snapshots, backup: backup, token: token, output: output)
    }

    public func delete(_ paths: [String], from archive: URL, password: String? = nil, backup: Bool = false,
                       token: CancellationToken = CancellationToken(), output: @escaping (String) -> Void = { _ in }) throws -> MutationResult {
        lock.lock(); defer { lock.unlock() }
        guard !paths.isEmpty else { throw FMError.message(L10n.tr("No entries selected.")) }
        let session = try open(archive, password: password, token: token)
        let removed = Set(session.listing.selected(paths).compactMap(\.index))
        guard !removed.isEmpty else { throw FMError.message(L10n.tr("The selected entries no longer exist.")) }
        return try mutate(session, items: retainedItems(session).filter { !removed.contains($0.existingIndex) },
            backup: backup, token: token, output: output)
    }

    public func rename(_ path: String, to newPath: String, in archive: URL, password: String? = nil, backup: Bool = false,
                       token: CancellationToken = CancellationToken(), output: @escaping (String) -> Void = { _ in }) throws -> MutationResult {
        lock.lock(); defer { lock.unlock() }
        _ = try ArchivePath.validate(path); _ = try ArchivePath.validate(newPath)
        guard path != newPath, !ArchivePath.isWithin(newPath, parent: path) else { throw FMError.message(L10n.tr("Choose a different name outside the source folder.")) }
        let session = try open(archive, password: password, token: token)
        guard !session.listing.selected([path]).isEmpty else { throw FMError.message(L10n.tr("The entry to rename does not exist.")) }
        guard session.listing.selected([newPath]).isEmpty else { throw FMError.message(L10n.tr("The destination name already exists.")) }
        let items = session.listing.entries.map { entry -> NativeUpdateItem in
            var item = NativeUpdateItem(existingIndex: entry.index!)
            if ArchivePath.isWithin(entry.path, parent: path) { item.path = newPath + entry.path.dropFirst(path.count) }
            return item
        }
        return try mutate(session, items: items, backup: backup, token: token, output: output)
    }

    public func updateFile(_ source: URL, path: String, in archive: URL, password: String? = nil,
                           expectedFingerprint: FileFingerprint? = nil, backup: Bool = false,
                           token: CancellationToken = CancellationToken(), output: @escaping (String) -> Void = { _ in }) throws -> MutationResult {
        lock.lock(); defer { lock.unlock() }; _ = try ArchivePath.validate(path)
        let session = try open(archive, password: password, token: token)
        if let expected = expectedFingerprint, try FileFingerprint(session.rootURL) != expected {
            throw FMError.message(L10n.tr("The original archive has changed. The edited file has been kept; no archive data was overwritten."))
        }
        guard let entry = session.listing.entries.first(where: { $0.path == path }), !entry.isDirectory else {
            throw FMError.message(L10n.tr("The entry to update no longer exists."))
        }
        var item = try sourceItem(source, path: path); item.existingIndex = entry.index!
        let items = retainedItems(session).map { $0.existingIndex == entry.index ? item : $0 }
        return try mutate(session, items: items, snapshots: [(source, try FileFingerprint(source))], backup: backup, token: token, output: output)
    }

    public func hash(_ sources: [URL], algorithm: String = "SHA256", token: CancellationToken = CancellationToken(),
                     output: @escaping (String) -> Void = { _ in }) throws -> ArchiveReport {
        lock.lock(); defer { lock.unlock() }
        guard ["CRC32", "CRC64", "SHA1", "SHA256", "SHA512", "BLAKE2sp", "XXH64"].contains(algorithm) else {
            throw FMError.message(L10n.tr("Unsupported hash algorithm."))
        }
        let inputs = try sourceItems(sources, prefix: "", token: token)
        var result = "\(algorithm)\n"
        for item in inputs.items where !item.isDirectory {
            let digest = try engine.hash(item.source!, algorithm: algorithm, token: token)
            let line = "\(digest)  \(item.source!.path)\n"; result += line; output(line)
        }
        try checkInputs(inputs.snapshots); return ArchiveReport(output: result)
    }

    private func requireFresh(_ session: ArchiveSession) throws {
        guard session.valid, try FileFingerprint(session.rootURL) == session.fingerprint else {
            throw FMError.message(L10n.tr("The archive changed outside this session. Reopen the outer archive before continuing."))
        }
    }
    private func openParent(_ parent: ArchiveSession, token: CancellationToken) throws {
        do { _ = try open(parent.url, password: parent.password, token: token) }
        catch FMError.passwordRequired(let message) { throw FMError.passwordForArchive(parent.url, message) }
    }
    private func nestedNative(_ parent: ArchiveSession, index: UInt32, scratch: URL, password: String?, token: CancellationToken) throws -> NativeArchive {
        do {
            return try parent.native.nested(index, scratch: scratch, limit: extractionLimit,
                parentPassword: parent.password, password: password, token: token)
        } catch NativeCallbackError.parentPassword(let message) { throw FMError.passwordForArchive(parent.url, message) }
    }
    private func reopen(_ session: ArchiveSession, password: String?, token: CancellationToken) throws {
        let native: NativeArchive; var scratch: ScratchDirectory?
        let fingerprint = try FileFingerprint(session.rootURL)
        if let parent = session.parent, let path = session.parentPath {
            try requireFresh(parent)
            let matches = parent.listing.entries.filter { $0.path == path && !$0.isDirectory }
            guard matches.count == 1, let index = matches[0].index else { throw FMError.message(L10n.tr("The containing archive entry changed or no longer exists.")) }
            scratch = try ScratchDirectory(label: "nested")
            native = try nestedNative(parent, index: index, scratch: scratch!.url.appendingPathComponent(matches[0].name), password: password, token: token)
            session.parentIndex = index
        } else { native = try engine.open(session.rootURL, password: password, token: token) }
        let listing = try native.listing(token: token)
        guard try FileFingerprint(session.rootURL) == fingerprint else { throw FMError.message(L10n.tr("The archive changed while it was being opened.")) }
        session.native = native; session.listing = listing
        session.scratch = listing.usesDirectStream ? nil : scratch
        session.fingerprint = fingerprint; session.password = password; session.openedPassword = password; session.valid = true
    }
    private func retainedItems(_ session: ArchiveSession) -> [NativeUpdateItem] {
        session.listing.entries.map { NativeUpdateItem(existingIndex: $0.index!) }
    }
    private func verify(_ url: URL, password: String?, token: CancellationToken, output: (String) -> Void) throws {
        output(L10n.tr("Verifying \(url.lastPathComponent)…\n"))
        let archive = try engine.open(url, password: password, token: token)
        try archive.extract([], test: true, all: true, limit: .max, password: password, token: token)
    }
    private func sourceItem(_ url: URL, path: String) throws -> NativeUpdateItem {
        _ = try ArchivePath.validate(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw FMError.message(L10n.tr("Only regular files and folders can be added: \(url.path)")) }
        let directory = type == .typeDirectory
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? (directory ? 0o755 : 0o644)
        let time = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return NativeUpdateItem(path: path, source: url, size: directory ? 0 : (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modifiedNS: Int64(max(0, min(Double(Int64.max / 2), time * 1e9))),
            mode: permissions | (directory ? 0o040000 : 0o100000), isDirectory: directory)
    }
    private func sourceItems(_ sources: [URL], prefix: String, token: CancellationToken) throws -> (items: [NativeUpdateItem], snapshots: [(URL, FileFingerprint)]) {
        guard !sources.isEmpty else { throw FMError.message(L10n.tr("No files selected.")) }
        if !prefix.isEmpty { _ = try ArchivePath.validate(prefix) }
        var items: [NativeUpdateItem] = []; var snapshots: [(URL, FileFingerprint)] = []
        for source in sources {
            let name = (prefix.isEmpty ? "" : prefix + "/") + source.lastPathComponent
            func add(_ url: URL, _ path: String) throws {
                try token.check(); let item = try sourceItem(url, path: path); items.append(item)
                snapshots.append((url, try FileFingerprint(url)))
            }
            try add(source, name)
            if SafeFileSystem.type(of: source) == .typeDirectory {
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
                    errorHandler: { _, error in enumerationError = error; return false }) else { throw FMError.message(L10n.tr("Cannot read an input folder.")) }
                for case let url as URL in enumerator {
                    // Foundation can return /private/var for a /var input URL.
                    // Enumeration depth is independent of such filesystem aliases.
                    let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                    try add(url, name + "/" + relative)
                }
                if let error = enumerationError { throw error }
            }
        }
        try validateEntries(items.map { ArchiveEntry(path: $0.path!, isDirectory: $0.isDirectory) }, unique: true)
        return (items, snapshots)
    }
    private func checkInputs(_ snapshots: [(URL, FileFingerprint)]) throws {
        for (url, fingerprint) in snapshots where try FileFingerprint(url) != fingerprint {
            throw FMError.message(L10n.tr("An input changed while it was being archived: \(url.path)"))
        }
    }
    private func validateEntries(_ entries: [ArchiveEntry], unique: Bool) throws {
        var paths = Set<String>(); var normalized: [String: String] = [:]; var filePaths = Set<String>()
        for entry in entries {
            _ = try ArchivePath.validate(entry.path)
            if unique && !paths.insert(entry.path).inserted { throw FMError.message(L10n.tr("Duplicate paths require selecting one entry at a time: \(entry.path)")) }
            if !entry.isDirectory { filePaths.insert(entry.path) }
            var path = ""
            for component in entry.path.split(separator: "/") {
                path = path.isEmpty ? String(component) : path + "/" + component
                let key = path.precomposedStringWithCanonicalMapping.lowercased()
                if let previous = normalized[key], previous != path { throw FMError.message(L10n.tr("Paths collide on a case insensitive filesystem: \(previous) / \(path)")) }
                normalized[key] = path
            }
        }
        for entry in entries {
            var parent = ArchivePath.parent(of: entry.path)
            while !parent.isEmpty {
                guard !filePaths.contains(parent) else { throw FMError.message(L10n.tr("An archive path is both a file and a folder: \(parent)")) }
                parent = ArchivePath.parent(of: parent)
            }
        }
    }

    private func mutate(_ session: ArchiveSession, items: [NativeUpdateItem], snapshots: [(URL, FileFingerprint)] = [],
                        backup: Bool, token: CancellationToken, output: (String) -> Void) throws -> MutationResult {
        try requireFresh(session)
        guard session.canModify else { throw FMError.message(L10n.tr("This archive or one of its containing archives is read only. Extract it to edit a separate copy.")) }
        var chain: [ArchiveSession] = []; var current: ArchiveSession? = session
        while let value = current {
            try requireFresh(value); try validateEntries(value.listing.entries, unique: true)
            if value.listing.hasEncryptedHeaders || value.listing.entries.contains(where: \.isEncrypted), value.password == nil {
                throw FMError.passwordForArchive(value.url, L10n.tr("A password is required to preserve encryption in \(value.displayPath)."))
            }
            if value.listing.format.lowercased() == "zip", let password = value.password {
                let encrypted = value.listing.entries.filter(\.isEncrypted)
                try CompressionOptions.validateZIPPassword(password, aes: !encrypted.allSatisfy { $0.method.contains("ZipCrypto") })
            }
            chain.append(value); current = value.parent
        }
        // Validate the proposed namespace before writing, including file/folder conflicts.
        try validateEntries(items.map { item in
            let old = item.existingIndex == .max ? nil : session.listing.entries[Int(item.existingIndex)]
            return ArchiveEntry(path: item.path ?? old!.path, isDirectory: item.source != nil ? item.isDirectory : old?.isDirectory ?? item.isDirectory)
        }, unique: true)
        let root = session.rootURL; let fingerprint = try FileFingerprint(root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let scratch = try ScratchDirectory(parent: root.deletingLastPathComponent(), label: "transaction")
        var updates = items; var staged: URL?
        for (level, archive) in chain.enumerated() {
            try token.check()
            let folder = scratch.url.appendingPathComponent(String(level), isDirectory: true); try SafeFileSystem.ensureDirectory(folder)
            let file = folder.appendingPathComponent(archive.url.lastPathComponent)
            output(L10n.tr("Updating \(archive.displayPath)…\n"))
            let encrypted = archive.listing.entries.filter(\.isEncrypted)
            let zipAES: Bool? = archive.listing.format.lowercased() == "zip" && !encrypted.isEmpty ? !encrypted.allSatisfy { $0.method.contains("ZipCrypto") } : nil
            try engine.rewrite(archive.native, output: file, items: updates, options: nil, password: archive.password,
                encryptedHeaders: archive.listing.hasEncryptedHeaders, zipAES: zipAES, token: token)
            try verify(file, password: archive.password, token: token, output: output); staged = file
            if let parent = archive.parent, let index = archive.parentIndex, let path = archive.parentPath {
                var replacement = try sourceItem(file, path: path); replacement.existingIndex = index
                updates = retainedItems(parent).map { $0.existingIndex == index ? replacement : $0 }
            }
        }
        guard let staged = staged else { throw FMError.message(L10n.tr("No archive changes were produced.")) }
        try checkInputs(snapshots); try token.check()
        guard try FileFingerprint(root) == fingerprint else { throw FMError.message(L10n.tr("The original archive changed. No changes were committed.")) }
        var backupURL: URL?
        var recovery: ScratchDirectory?
        defer { withExtendedLifetime(recovery) {} }
        if backup {
            let directory = try ScratchDirectory(label: "recovery")
            recovery = directory
            let destination = directory.url.appendingPathComponent(root.lastPathComponent)
            try FileManager.default.copyItem(at: root, to: destination)
            backupURL = destination
        }
        if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path) }
        try token.check()
        guard try FileFingerprint(root) == fingerprint else { throw FMError.message(L10n.tr("The original archive changed before commit. No changes were committed.")) }
        try SafeFileSystem.atomicReplace(staged, destination: root)
        // Retain only successful edits' recovery copies. Before commit, failure
        // or cancellation releases the directory and the original stays intact.
        _ = recovery?.retainOnDisk()
        if let backupURL = backupURL { output(L10n.tr("Recovery copy: \(backupURL.path)\n")) }
        // Rebind live ancestors/children after the single root commit. A failed
        // refresh cannot undo a completed commit, so report it separately.
        var log = L10n.tr("Changes committed. \(chain.count) archive level(s) verified.\n")
        let affected = liveSessions.filter { $0.rootURL == root }.sorted { $0.depth < $1.depth }
        for archive in affected { archive.valid = false }
        for archive in affected {
            do { try reopen(archive, password: archive.password, token: CancellationToken()) }
            catch { log += L10n.tr("Reopen \(archive.displayPath): \(error.localizedDescription)\n") }
        }
        output(log); return MutationResult(backup: backupURL, log: log)
    }
}
