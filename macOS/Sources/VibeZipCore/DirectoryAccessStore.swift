#if os(macOS)
import Foundation

protocol DirectoryAccessPreferences {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}
extension UserDefaults: DirectoryAccessPreferences {}

protocol DirectoryBookmarkProvider {
    func create(_ url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool)
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

private struct SystemDirectoryBookmarks: DirectoryBookmarkProvider {
    func create(_ url: URL) throws -> Data { try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

public struct AuthorizedDirectory: Identifiable {
    public let id: UUID
    public let url: URL
    public let isAvailable: Bool
}

/// Owns process-lifetime security scopes. Use on the main thread; workers inherit the
/// process's access. Raw saved paths are display hints, never an authorization source.
public final class DirectoryAccessStore {
    public static let shared = DirectoryAccessStore()
    private struct Record: Codable {
        var id: UUID
        var bookmark: Data
        var path: String
    }
    private struct LastLocation: Codable {
        let rootID: UUID
        let relativePath: String
    }
    private let defaults: DirectoryAccessPreferences
    private let bookmarks: DirectoryBookmarkProvider
    private var records: [Record] = []
    private var active: [UUID: URL] = [:]
    private var selectedFiles: [String: URL] = [:]
    private let foldersKey = "authorizedDirectories.v1"
    private let locationKey = "authorizedLastDirectory.v1"

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, bookmarks: SystemDirectoryBookmarks())
    }
    init(defaults: DirectoryAccessPreferences, bookmarks: DirectoryBookmarkProvider) {
        self.defaults = defaults; self.bookmarks = bookmarks
        if let data = defaults.data(forKey: foldersKey), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            var seen = Set<UUID>(); records = saved.filter { seen.insert($0.id).inserted }
        }
        refreshUnavailable()
    }
    deinit { close() }

    public var directories: [AuthorizedDirectory] {
        records.map { AuthorizedDirectory(id: $0.id, url: active[$0.id] ?? URL(fileURLWithPath: $0.path), isAvailable: active[$0.id] != nil) }
    }
    public static func contains(_ url: URL, in directory: URL) -> Bool {
        guard let child = canonicalURL(url), let parent = canonicalURL(directory) else { return false }
        return child.pathComponents.starts(with: parent.pathComponents)
    }
    public func allows(_ url: URL) -> Bool { active.values.contains { Self.contains(url, in: $0) } }
    public func canReadFile(_ url: URL) -> Bool { allows(url) || selectedFiles[canonicalPath(url)] != nil }
    private func canonicalPath(_ url: URL) -> String { Self.canonicalURL(url)?.path ?? url.standardizedFileURL.path }
    private static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        // Resolve component by component: Foundation may leave a whole path
        // unresolved when its final file does not exist yet (save destinations).
        var components = url.path.split(separator: "/").map(String.init)
        var result = URL(fileURLWithPath: "/", isDirectory: true)
        var index = 0, links = 0
        while index < components.count {
            let component = components[index]; index += 1
            if component == "." { continue }
            if component == ".." { result.deleteLastPathComponent(); continue }
            let next = result.appendingPathComponent(component)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next.path) {
                links += 1; guard links <= 40 else { return nil }
                if target.hasPrefix("/") { result = URL(fileURLWithPath: "/", isDirectory: true) }
                components.insert(contentsOf: target.split(separator: "/").map(String.init), at: index)
            } else { result = next }
        }
        return result
    }
    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && FileManager.default.isReadableFile(atPath: url.path)
    }
    private func save() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: foldersKey) }
    }

    /// Call only with a URL granted by a system file panel or other user selection.
    @discardableResult public func authorize(_ directory: URL, replacing id: UUID? = nil) throws -> URL {
        guard directory.isFileURL, isDirectory(directory) else { throw FMError.message(L10n.tr("Choose an accessible folder.")) }
        let data = try bookmarks.create(directory)
        let resolved = try bookmarks.resolve(data)
        guard bookmarks.start(resolved.url) else { throw FMError.message(L10n.tr("Folder access could not be saved. Please choose the folder again.")) }
        guard isDirectory(resolved.url) else {
            bookmarks.stop(resolved.url); throw FMError.message(L10n.tr("This folder is currently unavailable."))
        }
        let existing = records.first { $0.id == id } ?? records.first { canonicalPath(active[$0.id] ?? URL(fileURLWithPath: $0.path)) == canonicalPath(resolved.url) }
        let recordID = existing?.id ?? UUID()
        if let previous = active[recordID] { bookmarks.stop(previous) }
        active[recordID] = resolved.url
        let record = Record(id: recordID, bookmark: data, path: resolved.url.path)
        if let index = records.firstIndex(where: { $0.id == recordID }) { records[index] = record }
        else { records.append(record) }
        save(); return resolved.url
    }
    public func refreshUnavailable() {
        for id in Array(active.keys) {
            guard let url = active[id], !isDirectory(url) else { continue }
            active.removeValue(forKey: id); bookmarks.stop(url)
        }
        for index in records.indices where active[records[index].id] == nil {
            do {
                let resolved = try bookmarks.resolve(records[index].bookmark)
                guard bookmarks.start(resolved.url) else { continue }
                guard isDirectory(resolved.url) else { bookmarks.stop(resolved.url); continue }
                active[records[index].id] = resolved.url; records[index].path = resolved.url.path
                if resolved.stale, let renewed = try? bookmarks.create(resolved.url) { records[index].bookmark = renewed }
            } catch { /* Keep unavailable grants visible so the user can renew or remove them. */ }
        }
        save()
    }
    public func remember(_ directory: URL) {
        guard let root = active.filter({ Self.contains(directory, in: $0.value) })
            .max(by: { $0.value.pathComponents.count < $1.value.pathComponents.count }) else { return }
        guard let base = Self.canonicalURL(root.value), let current = Self.canonicalURL(directory) else { return }
        let path = current.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
        if let data = try? JSONEncoder().encode(LastLocation(rootID: root.key, relativePath: path)) { defaults.set(data, forKey: locationKey) }
    }
    public func restoreLastDirectory() -> URL? {
        guard let data = defaults.data(forKey: locationKey), let saved = try? JSONDecoder().decode(LastLocation.self, from: data),
              let root = active[saved.rootID] else { return nil }
        let url = saved.relativePath.isEmpty ? root : root.appendingPathComponent(saved.relativePath, isDirectory: true)
        guard Self.contains(url, in: root), isDirectory(url) else { return nil }
        return url
    }
    public func remove(_ ids: Set<UUID>) {
        let last = restoreLastDirectory()
        let removed = records.filter { ids.contains($0.id) }.map { active[$0.id] ?? URL(fileURLWithPath: $0.path) }
        for id in ids { if let url = active.removeValue(forKey: id) { bookmarks.stop(url) } }
        records.removeAll { ids.contains($0.id) }
        // Explicitly selected files under a revoked folder must not keep its contents usable.
        for key in Array(selectedFiles.keys) {
            guard let url = selectedFiles[key], removed.contains(where: { Self.contains(url, in: $0) }) else { continue }
            selectedFiles.removeValue(forKey: key); bookmarks.stop(url)
        }
        if let last = last, allows(last) { remember(last) }
        else if let data = defaults.data(forKey: locationKey), let saved = try? JSONDecoder().decode(LastLocation.self, from: data), ids.contains(saved.rootID) {
            defaults.removeObject(forKey: locationKey)
        }
        save()
    }
    /// Single-file selections remain usable for this session without granting access
    /// to siblings or silently adding the parent folder to authorization history.
    public func retainSelectedFile(_ file: URL) throws {
        guard !canReadFile(file) else { return }
        let resolved = try bookmarks.resolve(bookmarks.create(file))
        guard bookmarks.start(resolved.url) else { throw FMError.message(L10n.tr("File access could not be retained. Please select the file again.")) }
        selectedFiles[canonicalPath(resolved.url)] = resolved.url
    }
    public func close() {
        for url in active.values { bookmarks.stop(url) }
        for url in selectedFiles.values { bookmarks.stop(url) }
        active.removeAll(); selectedFiles.removeAll()
    }
}
#endif
