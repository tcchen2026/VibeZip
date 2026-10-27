import XCTest
@testable import VibeZipCore

final class CoreTests: XCTestCase {
    func testArchivePathAcceptsUnicodeAndWildcards() throws {
        for name in ["目录/你好 world.txt", "file = value.txt", "a*.txt", "@file.txt", "-file.txt", ".hidden"] {
            XCTAssertEqual(try ArchivePath.validate(name), name)
        }
    }
    func testArchivePathRejectsTraversalAndControlCharacters() {
        for name in ["", "../escape", "/absolute", "a/../../b", "a//b", "a/./b", "C:/file", "\\\\server\\file", "a\\b", "line\nbreak", "tab\tname", "nul\0", "folder/"] {
            XCTAssertThrowsError(try ArchivePath.validate(name), name)
        }
    }
    func testPrefixIsComponentAware() {
        XCTAssertTrue(ArchivePath.isWithin("a/file", parent: "a"))
        XCTAssertFalse(ArchivePath.isWithin("abc/file", parent: "a"))
        XCTAssertEqual(ArchivePath.parent(of: "a/b/c"), "a/b")
    }
    func testSyntheticDirectoriesAndSelection() {
        let listing = ArchiveListing(entries: [.init(path: "a/b/c.txt", size: 5), .init(path: "a/one.txt", size: 10), .init(path: "ab/file", size: 4)])
        XCTAssertEqual(Set(listing.children(of: "").map(\.path)), ["a", "ab"])
        XCTAssertEqual(Set(listing.children(of: "a").map(\.path)), ["a/b", "a/one.txt"])
        XCTAssertEqual(listing.selected(["a"]).count, 2)
        XCTAssertEqual(listing.totalSize, 19)
    }
    func testDuplicateEntriesKeepTheirNativeIdentity() {
        let listing = ArchiveListing(entries: [.init(path: "same.txt", size: 1, index: 0), .init(path: "same.txt", size: 2, index: 1)])
        XCTAssertEqual(listing.children(of: "").map(\.index), [0, 1])
    }
    func testDirectoryIndexHandlesExplicitParentsInAnyOrder() {
        let listing = ArchiveListing(entries: [.init(path: "a/b", isDirectory: true), .init(path: "a/b/file", size: 1), .init(path: "a", isDirectory: true)])
        XCTAssertEqual(listing.children(of: "").map(\.path), ["a"])
        XCTAssertEqual(listing.children(of: "a").map(\.path), ["a/b"])
        XCTAssertEqual(listing.children(of: "a/b").map(\.path), ["a/b/file"])
    }
    func testArchiveSearchFindsFilesAcrossDirectoriesAndPreservesIdentity() {
        let listing = ArchiveListing(entries: [
            .init(path: "README.md", index: 0),
            .init(path: "Documents/readme.txt", index: 1),
            .init(path: "Source/parser/README.md", index: 2),
            .init(path: "Source/parser/README.md", index: 3),
            .init(path: "Source/parser/code.swift", index: 4),
            .init(path: "Notes/你好 🚀.txt", index: 5)
        ])
        XCTAssertEqual(Set(listing.search("  readme\n").compactMap(\.index)), [0, 1, 2, 3])
        XCTAssertEqual(Set(listing.search("source/parser/").compactMap(\.index)), [2, 3, 4])
        XCTAssertEqual(listing.search("你好 🚀").map(\.index), [5])
        XCTAssertTrue(listing.search("parser").contains { $0.path == "Source/parser" && $0.isDirectory })
        XCTAssertTrue(listing.search("missing").isEmpty)
        XCTAssertTrue(listing.search(" \n").isEmpty)
    }
    func testInvalidOptionsAndSizeOverflowRejected() throws {
        var options = CompressionOptions(); options.volumeSize = "100m -delete"; XCTAssertThrowsError(try options.validate())
        options.volumeSize = ""; options.format = "rar"; XCTAssertThrowsError(try options.validate())
        options.format = "tar"; options.password = "secret"; XCTAssertThrowsError(try options.validate())
        XCTAssertEqual(try CompressionOptions.byteCount("4g"), 4 * 1024 * 1024 * 1024)
        XCTAssertThrowsError(try CompressionOptions.byteCount("18446744073709551615g"))
        XCTAssertThrowsError(try Engine.validatePassword("nul\0password"))
        XCTAssertNoThrow(try Engine.validatePassword("line\nbreak"))
        var zip = CompressionOptions(); zip.format = "zip"; zip.password = "Unicode 🔐"
        XCTAssertThrowsError(try zip.validate())
        zip.password = String(repeating: "p", count: 100); XCTAssertThrowsError(try zip.validate())
    }
    func testProgressUses64BitCountsAndUnknownTotals() {
        let value = ArchiveProgress(phase: .extract, completed: 5 * 1024 * 1024 * 1024, total: 10 * 1024 * 1024 * 1024, path: "large.bin")
        XCTAssertEqual(value.fraction, 0.5)
        XCTAssertNil(ArchiveProgress(phase: .open, completed: 1, total: 0, path: "").fraction)
    }
    func testCancelledTokenStopsImmediately() {
        let token = CancellationToken(); token.cancel(); XCTAssertThrowsError(try token.check())
    }
    func testTotalSizeSaturatesInsteadOfOverflow() {
        let listing = ArchiveListing(entries: [.init(path: "a", size: .max), .init(path: "b", size: 1)])
        XCTAssertEqual(listing.totalSize, .max)
    }

    func testCopyRenameAndSkip() throws {
        let scratch = try ScratchDirectory(label: "test-copy")
        let source = scratch.url.appendingPathComponent("source"); let destination = scratch.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("file.txt")
        try Data("new".utf8).write(to: file); try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
        let renamed = try FileOperations.copy([file], to: destination, move: false, policy: .rename, token: CancellationToken())
        XCTAssertEqual(renamed.written, 1); XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file (2).txt")), "new")
        let skipped = try FileOperations.copy([file], to: destination, move: true, policy: .skip, token: CancellationToken())
        XCTAssertEqual(skipped.skipped, 1); XCTAssertTrue(SafeFileSystem.exists(file))
    }
    func testCopyRefusesSelfRecursion() throws {
        let scratch = try ScratchDirectory(label: "test-recursion")
        XCTAssertThrowsError(try FileOperations.copy([scratch.url], to: scratch.url.appendingPathComponent("inner"),
            move: false, policy: .replace, token: CancellationToken()))
    }
    func testCopyRefusesDestinationSymlink() throws {
        let scratch = try ScratchDirectory(label: "test-link")
        let source = scratch.url.appendingPathComponent("source.txt")
        let outside = scratch.url.appendingPathComponent("outside.txt")
        let destination = scratch.url.appendingPathComponent("dest")
        try Data("new".utf8).write(to: source); try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("source.txt"), withDestinationURL: outside)
        XCTAssertThrowsError(try FileOperations.copy([source], to: destination, move: false, policy: .replace, token: CancellationToken()))
        XCTAssertEqual(try String(contentsOf: outside), "untouched")
    }
    func testSplitCombineRoundTripAndNoOverwrite() throws {
        let scratch = try ScratchDirectory(label: "test-split")
        let data = Data((0..<13_117).map { UInt8($0 % 251) }); let source = scratch.url.appendingPathComponent("input.bin")
        try data.write(to: source)
        let base = scratch.url.appendingPathComponent("part")
        let parts = try FileOperations.split(source, to: base, volumeBytes: 2048, token: CancellationToken())
        XCTAssertEqual(parts.count, 7)
        XCTAssertThrowsError(try FileOperations.split(source, to: base, volumeBytes: 2048, token: CancellationToken()))
        let combined = scratch.url.appendingPathComponent("combined.bin")
        _ = try FileOperations.combine(parts[0], to: combined, token: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: combined), data)
        try FileManager.default.removeItem(at: parts[1])
        XCTAssertThrowsError(try FileOperations.combine(parts[0], to: scratch.url.appendingPathComponent("missing.bin"), token: CancellationToken()))
    }
}
