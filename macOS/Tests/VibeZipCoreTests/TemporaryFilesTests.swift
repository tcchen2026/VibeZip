import Foundation
import XCTest
@testable import VibeZipCore

final class TemporaryFilesTests: XCTestCase {
    private var fixture: ScratchDirectory!
    private var directory: URL!

    override func setUpWithError() throws {
        fixture = try ScratchDirectory(parent: FileManager.default.temporaryDirectory, label: "cleanup-tests")
        directory = fixture.url.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDown() { directory = nil; fixture = nil }

    private func abandonedDirectory() throws -> URL {
        let scratch = try ScratchDirectory(temporaryParent: directory, label: "preview")
        try Data("temporary content".utf8).write(to: scratch.url.appendingPathComponent("preview.txt"))
        return scratch.retainOnDisk()
    }

    func testCleanupKeepsLiveFilesAndRemovesAbandonedCopies() throws {
        var active: ScratchDirectory? = try ScratchDirectory(temporaryParent: directory, label: "nested")
        let activeURL = try XCTUnwrap(active?.url)
        let file = activeURL.appendingPathComponent("inner.zip")
        try Data("active archive".utf8).write(to: file)
        let stale = try abandonedDirectory()
        XCTAssertEqual(try TemporaryFiles.usageBytes(in: directory), UInt64("active archive".utf8.count + "temporary content".utf8.count))
        XCTAssertEqual(try TemporaryFiles.cleanUnused(in: directory), 1)
        XCTAssertFalse(SafeFileSystem.exists(stale))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "active archive")
        XCTAssertEqual(try TemporaryFiles.usageBytes(in: directory), UInt64("active archive".utf8.count))
        _ = active?.retainOnDisk(); active = nil
        XCTAssertEqual(try TemporaryFiles.cleanUnused(in: directory), 1)
        XCTAssertFalse(SafeFileSystem.exists(activeURL))
        XCTAssertEqual(try TemporaryFiles.usageBytes(in: directory), 0)
    }

    func testCleanupDoesNotTouchUnrelatedFilesOrSiblingTransactions() throws {
        let ordinary = directory.appendingPathComponent("personal-files")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("VibeZip-not-a-temporary-folder")
        try Data("keep".utf8).write(to: file)
        let sibling = try ScratchDirectory(parent: fixture.url, label: "transaction")
        let backup = fixture.url.appendingPathComponent("original.zip.bak")
        try Data("backup".utf8).write(to: backup)
        _ = try abandonedDirectory()
        XCTAssertEqual(try TemporaryFiles.cleanUnused(in: directory), 1)
        for url in [ordinary, file, sibling.url, backup] { XCTAssertTrue(SafeFileSystem.exists(url)) }
    }

    func testCleanupDoesNotFollowSymbolicLinks() throws {
        let outside = fixture.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let original = outside.appendingPathComponent("original.txt")
        try Data("keep".utf8).write(to: original)
        let link = directory.appendingPathComponent("VibeZip-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let stale = try abandonedDirectory()
        try FileManager.default.createSymbolicLink(at: stale.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertEqual(try TemporaryFiles.cleanUnused(in: directory), 1)
        XCTAssertEqual(SafeFileSystem.type(of: link), .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")
        XCTAssertThrowsError(try TemporaryFiles.cleanUnused(in: link))
    }

    func testCancellationLeavesPendingCopiesIntact() throws {
        let stale = try abandonedDirectory()
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try TemporaryFiles.cleanUnused(in: directory, token: token)) { error in
            guard case FMError.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(SafeFileSystem.exists(stale.appendingPathComponent("preview.txt")))
    }

    func testScratchDirectoryIsPrivateAndRemovedWhenReleased() throws {
        var scratch: ScratchDirectory? = try ScratchDirectory(temporaryParent: directory, label: "extract")
        let url = try XCTUnwrap(scratch?.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try TemporaryFiles.cleanUnused(in: directory), 0)
        scratch = nil
        XCTAssertFalse(SafeFileSystem.exists(url))
    }

    func testDefaultScratchUsesDedicatedTemporaryFolder() throws {
        let scratch = try ScratchDirectory(label: "location-test")
        XCTAssertEqual(scratch.url.deletingLastPathComponent().standardizedFileURL, TemporaryFiles.directory.standardizedFileURL)
        XCTAssertFalse(scratch.url.lastPathComponent.hasPrefix("."))
        let attributes = try FileManager.default.attributesOfItem(atPath: TemporaryFiles.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testUsageCountsLargeFilesAndHiddenDescendantsWithoutFollowingLinks() throws {
        let scratch = try ScratchDirectory(temporaryParent: directory, label: "usage")
        let nested = scratch.url.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let large = nested.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 5_000_000_000)
        let outside = fixture.url.appendingPathComponent("outside.txt")
        try Data("not temporary".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: scratch.url.appendingPathComponent("file-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("directory-link"), withDestinationURL: fixture.url)
        XCTAssertEqual(try TemporaryFiles.usageBytes(in: directory), 5_000_000_000)
        XCTAssertThrowsError(try TemporaryFiles.usageBytes(in: directory.appendingPathComponent("directory-link")))
    }

    func testUsageCanBeCancelledWithoutChangingFiles() throws {
        let stale = try abandonedDirectory()
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try TemporaryFiles.usageBytes(in: directory, token: token)) { error in
            guard case FMError.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(SafeFileSystem.exists(stale.appendingPathComponent("preview.txt")))
    }
}
