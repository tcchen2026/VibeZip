#if os(macOS)
import XCTest
@testable import VibeZipCore

private final class MemoryAccessPreferences: DirectoryAccessPreferences {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

/// Models the OS bookmark broker so authorization policy can be checked without
/// UI automation or granting the test process access to personal folders.
private final class BookmarkBroker: DirectoryBookmarkProvider {
    var unavailable = Set<String>()
    var moved: [String: URL] = [:]
    var starts = 0, stops = 0, creations = 0
    func create(_ url: URL) throws -> Data { creations += 1; return Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        let path = String(decoding: data, as: UTF8.self)
        return (moved[path] ?? URL(fileURLWithPath: path), moved[path] != nil)
    }
    func start(_ url: URL) -> Bool {
        guard !unavailable.contains(url.path) else { return false }; starts += 1; return true
    }
    func stop(_ url: URL) { stops += 1 }
}

final class DirectoryAccessStoreTests: XCTestCase {
    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testFreshLaunchDoesNotTrustLegacyPathOrChooseAHomeDirectory() throws {
        let prefs = MemoryAccessPreferences(); prefs.set("/Users/someone", forKey: "lastDirectory")
        let store = DirectoryAccessStore(defaults: prefs, bookmarks: BookmarkBroker())
        XCTAssertNil(store.restoreLastDirectory()); XCTAssertTrue(store.directories.isEmpty)
        XCTAssertFalse(store.allows(URL(fileURLWithPath: "/Users/someone")))
    }
    func testGrantCoversChildrenButNotSimilarNamesOrEscapingSymlinks() throws {
        let scratch = try ScratchDirectory(label: "access-boundaries")
        let root = try folder("Work", in: scratch.url), child = try folder("Work/Child", in: scratch.url)
        let other = try folder("Work-other", in: scratch.url)
        let store = DirectoryAccessStore(defaults: MemoryAccessPreferences(), bookmarks: BookmarkBroker())
        try store.authorize(root)
        XCTAssertTrue(store.allows(root)); XCTAssertTrue(store.allows(child)); XCTAssertFalse(store.allows(other))
        let link = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertFalse(store.allows(link.appendingPathComponent("file.txt")))
        let dangling = root.appendingPathComponent("future")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: other.appendingPathComponent("not-created"))
        XCTAssertFalse(store.allows(dangling.appendingPathComponent("new.txt")))
        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        XCTAssertFalse(store.allows(loop))
    }
    func testRestoresLastSubdirectoryAfterRestartAndBalancesScopes() throws {
        let scratch = try ScratchDirectory(label: "access-restart")
        let child = try folder("Work/Child", in: scratch.url)
        let prefs = MemoryAccessPreferences(), broker = BookmarkBroker()
        let first = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        try first.authorize(scratch.url); first.remember(child); first.close()
        let second = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        XCTAssertEqual(second.restoreLastDirectory(), child)
        second.close(); XCTAssertEqual(broker.starts, broker.stops)
    }
    func testRevokingLastGrantClearsStartupLocationAndDoesNotRestoreIt() throws {
        let scratch = try ScratchDirectory(label: "access-remove")
        let prefs = MemoryAccessPreferences(), broker = BookmarkBroker()
        let store = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        try store.authorize(scratch.url); store.remember(scratch.url)
        store.remove(Set(store.directories.map(\.id)))
        XCTAssertFalse(store.allows(scratch.url)); XCTAssertNil(store.restoreLastDirectory())
        let restarted = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        XCTAssertTrue(restarted.directories.isEmpty); XCTAssertNil(restarted.restoreLastDirectory())
        XCTAssertEqual(broker.starts, broker.stops)
    }
    func testRemovingOverlappingGrantPreservesRemainingExplicitAccess() throws {
        let scratch = try ScratchDirectory(label: "access-overlap")
        let child = try folder("Child", in: scratch.url)
        let store = DirectoryAccessStore(defaults: MemoryAccessPreferences(), bookmarks: BookmarkBroker())
        try store.authorize(scratch.url); try store.authorize(child); store.remember(child)
        let childID = try XCTUnwrap(store.directories.first { $0.url == child }?.id)
        store.remove([childID])
        XCTAssertTrue(store.allows(child)); XCTAssertEqual(store.restoreLastDirectory(), child)
    }
    func testOfflineGrantStaysInSettingsAndCanRecoverWithoutLosingHistory() throws {
        let scratch = try ScratchDirectory(label: "access-offline")
        let prefs = MemoryAccessPreferences(), broker = BookmarkBroker()
        let first = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        try first.authorize(scratch.url); first.remember(scratch.url); first.close()
        broker.unavailable.insert(scratch.url.path)
        let second = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        XCTAssertEqual(second.directories.count, 1); XCTAssertFalse(second.directories[0].isAvailable)
        XCTAssertNil(second.restoreLastDirectory()); XCTAssertFalse(second.allows(scratch.url))
        broker.unavailable.removeAll(); second.refreshUnavailable()
        XCTAssertTrue(second.directories[0].isAvailable); XCTAssertEqual(second.restoreLastDirectory(), scratch.url)
    }
    func testStaleBookmarkRenewsAndFollowsMovedRoot() throws {
        let scratch = try ScratchDirectory(label: "access-moved")
        let old = try folder("Before", in: scratch.url), child = try folder("Before/Child", in: scratch.url)
        let prefs = MemoryAccessPreferences(), broker = BookmarkBroker()
        let first = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        try first.authorize(old); first.remember(child); first.close()
        let renamed = scratch.url.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: renamed); broker.moved[old.path] = renamed
        let second = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        XCTAssertEqual(second.directories[0].url, renamed)
        XCTAssertEqual(second.restoreLastDirectory(), renamed.appendingPathComponent("Child", isDirectory: true))
        XCTAssertEqual(broker.creations, 2)
    }
    func testDeniedGrantDoesNotPersistAndIndividualFileDoesNotGrantItsParent() throws {
        let scratch = try ScratchDirectory(label: "access-file")
        let prefs = MemoryAccessPreferences(), broker = BookmarkBroker()
        broker.unavailable.insert(scratch.url.path)
        let store = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        XCTAssertThrowsError(try store.authorize(scratch.url)); XCTAssertTrue(store.directories.isEmpty)
        let file = scratch.url.appendingPathComponent("selected.zip")
        try Data().write(to: file); try store.retainSelectedFile(file)
        XCTAssertTrue(store.canReadFile(file)); XCTAssertFalse(store.allows(scratch.url)); XCTAssertNil(store.restoreLastDirectory())
        store.close()
        let restarted = DirectoryAccessStore(defaults: prefs, bookmarks: broker)
        XCTAssertFalse(restarted.canReadFile(file)); XCTAssertEqual(broker.starts, broker.stops)
    }
}
#endif
