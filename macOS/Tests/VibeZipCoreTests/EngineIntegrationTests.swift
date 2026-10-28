import XCTest
@testable import VibeZipCore

final class EngineIntegrationTests: XCTestCase {
    var scratch: ScratchDirectory!
    var service: ArchiveService!
    var source: URL!
    override func setUpWithError() throws {
        service = try ArchiveService(engine: Engine(libraryURL: Engine.locate()))
        scratch = try ScratchDirectory(label: "integration")
        source = scratch.url.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    }
    override func tearDown() { scratch = nil; service = nil; source = nil }
    @discardableResult
    func file(_ name: String, _ contents: String = "hello 世界") throws -> URL {
        let url = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url); return url
    }
    func archive(_ ext: String = "7z") -> URL { scratch.url.appendingPathComponent("archive." + ext) }
    func output(_ name: String = "output") -> URL { scratch.url.appendingPathComponent(name) }

    func testReal7zRoundTrip() throws {
        try file("目录/你好 world.txt"); try file("empty.txt", "")
        _ = try service.create([source], output: archive(), options: CompressionOptions())
        let listing = try service.list(archive())
        XCTAssertEqual(listing.format, "7z"); XCTAssertTrue(listing.entries.contains { $0.path == "input/目录/你好 world.txt" }, "Entries: \(listing.entries.map(\.path))")
        try service.extract(archive(), to: output())
        XCTAssertEqual(try String(contentsOf: output().appendingPathComponent("input/目录/你好 world.txt")), "hello 世界")
    }
    func testLiteralWildcardAndAtSignSelection() throws {
        let star = try file("a*.txt", "literal"); let normal = try file("abc.txt", "must not extract")
        let at = try file("@names.txt"); let dash = try file("-option.txt")
        _ = try service.create([star, normal, at, dash], output: archive(), options: CompressionOptions())
        try service.extract(archive(), paths: ["a*.txt"], to: output())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output().path), ["a*.txt"])
        try service.extract(archive(), paths: ["@names.txt", "-option.txt"], to: output("special"))
        XCTAssertTrue(SafeFileSystem.exists(output("special").appendingPathComponent("@names.txt")))
    }
    func testRelativeFolderAndFlatExtraction() throws {
        try file("dir/sub/file.txt"); try file("directory/not-selected.txt")
        _ = try service.create([source], output: archive(), options: CompressionOptions())
        try service.extract(archive(), paths: ["input/dir"], to: output(), layout: .relativeTo("input"))
        XCTAssertTrue(SafeFileSystem.exists(output().appendingPathComponent("dir/sub/file.txt")))
        XCTAssertFalse(SafeFileSystem.exists(output().appendingPathComponent("directory")))
        try service.extract(archive(), to: output("flat"), layout: .flat)
        XCTAssertTrue(SafeFileSystem.exists(output("flat").appendingPathComponent("file.txt")))
    }
    func testEncryptedHeaderAndWrongPassword() throws {
        let file = try file("secret.txt")
        var options = CompressionOptions(); options.password = "秘密 SuperSecret"
        _ = try service.create([file], output: archive(), options: options)
        XCTAssertThrowsError(try service.list(archive()))
        XCTAssertThrowsError(try service.list(archive(), password: "wrong"))
        XCTAssertEqual(try service.list(archive(), password: options.password).entries.count, 1)
        try service.extract(archive(), to: output(), password: options.password)
        XCTAssertEqual(try String(contentsOf: output().appendingPathComponent("secret.txt")), "hello 世界")
    }
    func testNonBMPFileNamesAndPasswordsRoundTrip() throws {
        for format in ["7z", "zip"] {
            let input = try file("你好 🚀.txt", "non-BMP content")
            var options = CompressionOptions(); options.format = format
            options.password = format == "7z" ? "secret 🔐🚀" : "ZIP ASCII password"
            let target = archive(format)
            _ = try service.create([input], output: target, options: options)
            XCTAssertEqual(try service.list(target, password: options.password).entries[0].path, "你好 🚀.txt")
            _ = try service.rename("你好 🚀.txt", to: "renamed 🌍.txt", in: target, password: options.password, backup: false)
            let destination = output(format)
            try service.extract(target, to: destination, password: options.password)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("renamed 🌍.txt")), "non-BMP content")
        }
    }
    func testZIPAESRoundTrip() throws {
        let file = try file("secret.txt")
        var options = CompressionOptions(); options.format = "zip"; options.password = "Secret"; options.zipAES = true
        _ = try service.create([file], output: archive("zip"), options: options)
        XCTAssertTrue(try service.list(archive("zip")).entries[0].isEncrypted)
        XCTAssertThrowsError(try service.extract(archive("zip"), to: output(), password: "wrong"))
        try service.extract(archive("zip"), to: output(), password: "Secret")
        XCTAssertTrue(SafeFileSystem.exists(output().appendingPathComponent("secret.txt")))
    }
    func testAddRenameDeleteAndBackup() throws {
        let one = try file("one.txt", "original")
        _ = try service.create([one], output: archive(), options: CompressionOptions())
        let original = try Data(contentsOf: archive())
        let two = try file("two.txt", "new")
        let added = try service.add([two], to: archive(), backup: true)
        XCTAssertNotNil(added.backup); XCTAssertEqual(try Data(contentsOf: added.backup!), original)
        XCTAssertEqual(try service.list(archive()).entries.count, 2)
        _ = try service.rename("two.txt", to: "renamed.txt", in: archive())
        XCTAssertTrue(try service.list(archive()).entries.contains { $0.path == "renamed.txt" })
        _ = try service.delete(["one.txt"], from: archive())
        XCTAssertEqual(try service.list(archive()).entries.map(\.path), ["renamed.txt"])
        _ = try service.test(archive())
    }
    func testAddInsideFolderAndEmptyFolder() throws {
        let one = try file("one.txt")
        _ = try service.create([one], output: archive(), options: CompressionOptions())
        let two = try file("two.txt")
        _ = try service.add([two], to: archive(), prefix: "nested/sub")
        let empty = source.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        _ = try service.add([empty], to: archive(), prefix: "nested")
        let listing = try service.list(archive())
        XCTAssertTrue(listing.entries.contains { $0.path == "nested/sub/two.txt" })
        XCTAssertTrue(listing.entries.contains { $0.path == "nested/empty" && $0.isDirectory })
    }
    func testEncryptedAddPreservesEncryption() throws {
        for format in ["7z", "zip"] {
            let one = try file("one.txt"); var options = CompressionOptions()
            options.format = format; options.password = "Secret"; options.encryptHeaders = false
            let target = archive(format)
            _ = try service.create([one], output: target, options: options)
            let two = try file("two.txt")
            _ = try service.add([two], to: target, password: "Secret")
            let listing = try service.list(target, password: "Secret")
            XCTAssertTrue(listing.entries.first { $0.path == "two.txt" }!.isEncrypted, format)
        }
    }
    func testUpdateFileAndDetectExternalChanges() throws {
        let one = try file("dir/one.txt", "old")
        _ = try service.create([source], output: archive(), options: CompressionOptions())
        let before = try FileFingerprint(archive()); try Data("edited".utf8).write(to: one)
        _ = try service.updateFile(one, path: "input/dir/one.txt", in: archive(), expectedFingerprint: before)
        try service.extract(archive(), to: output())
        XCTAssertEqual(try String(contentsOf: output().appendingPathComponent("input/dir/one.txt")), "edited")
        XCTAssertThrowsError(try service.updateFile(one, path: "input/dir/one.txt", in: archive(), expectedFingerprint: before))
    }
    func testGzipBzip2XZTarAndWim() throws {
        let one = try file("one.txt", String(repeating: "abc", count: 2000))
        for (format, ext) in [("gzip", "gz"), ("bzip2", "bz2"), ("xz", "xz"), ("tar", "tar"), ("wim", "wim")] {
            var options = CompressionOptions(); options.format = format
            _ = try service.create([one], output: archive(ext), options: options)
            _ = try service.test(archive(ext))
            XCTAssertFalse(try service.list(archive(ext)).entries.isEmpty, format)
        }
    }
    func testMultivolumeRoundTripAndReadOnlyMutation() throws {
        let one = try file("large.txt", String(repeating: "uncompressed text 世界\n", count: 3000))
        var options = CompressionOptions(); options.level = 0; options.volumeSize = "10k"
        let parts = try service.create([one], output: archive(), options: options)
        XCTAssertGreaterThan(parts.count, 1)
        try service.extract(parts[0], to: output())
        XCTAssertEqual(try Data(contentsOf: output().appendingPathComponent("large.txt")), try Data(contentsOf: one))
        XCTAssertThrowsError(try service.delete(["large.txt"], from: parts[0]))
    }
    #if os(macOS)
    func testUnreadableVolumeReportsAccessFailureAndRecovers() throws {
        let one = try file("large.txt", String(repeating: "volume access\n", count: 3000))
        var options = CompressionOptions(); options.level = 0; options.volumeSize = "10k"
        let parts = try service.create([one], output: archive(), options: options)
        XCTAssertGreaterThan(parts.count, 1)
        let blocked = parts[1]
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
        XCTAssertThrowsError(try service.open(parts[0])) { error in
            guard case FMError.fileAccessRequired = error else { return XCTFail("Expected an access error, received \(error)") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path)
        try service.extract(parts[0], to: output())
        XCTAssertEqual(try Data(contentsOf: output().appendingPathComponent("large.txt")), try Data(contentsOf: one))
    }
    #endif
    func testLimitCancelsBeforeDestinationWrite() throws {
        let one = try file("large.txt", String(repeating: "a", count: 10000))
        _ = try service.create([one], output: archive(), options: CompressionOptions())
        service.extractionLimit = 100
        XCTAssertThrowsError(try service.extract(archive(), to: output()))
        XCTAssertFalse(SafeFileSystem.exists(output()))
    }
    func testNoOverwriteAndCancelledCreate() throws {
        let one = try file("one.txt")
        _ = try service.create([one], output: archive(), options: CompressionOptions())
        let original = try Data(contentsOf: archive())
        XCTAssertThrowsError(try service.create([one], output: archive(), options: CompressionOptions()))
        XCTAssertEqual(try Data(contentsOf: archive()), original)
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try service.create([one], output: output("cancel.7z"), options: CompressionOptions(), token: token))
        XCTAssertFalse(SafeFileSystem.exists(output("cancel.7z")))
    }
    func testHashSHA256() throws {
        let one = try file("abc.txt", "abc")
        let result = try service.hash([one])
        XCTAssertTrue(result.output.uppercased().contains("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
    }
    func testUnsafeArchivePathIsNotExtracted() throws {
        let one = try file("safe.txt")
        _ = try service.create([one], output: archive("zip"), options: { var o = CompressionOptions(); o.format = "zip"; return o }())
        try unsafeRename(archive("zip"), from: "safe.txt", to: "../escape.txt")
        XCTAssertThrowsError(try service.extract(archive("zip"), to: output()))
        XCTAssertFalse(SafeFileSystem.exists(scratch.url.appendingPathComponent("escape.txt")))
    }
    func testNativeCancellationBeforeCommit() throws {
        let input = try file("large.bin", String(repeating: "data", count: 1_000_000))
        let token = CancellationToken()
        token.observeProgress { value in if value.phase == .update && !value.path.isEmpty { token.cancel() } }
        XCTAssertThrowsError(try service.create([input], output: archive(), options: CompressionOptions(), token: token)) { error in
            guard case FMError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertFalse(SafeFileSystem.exists(archive()))
    }
    func testRawStreamsCanBeSelectedAndExtracted() throws {
        let one = try file("one.txt", "raw stream")
        for (format, ext) in [("xz", "xz"), ("bzip2", "bz2")] {
            var options = CompressionOptions(); options.format = format
            _ = try service.create([one], output: archive(ext), options: options)
            let row = try service.list(archive(ext)).entries[0]
            XCTAssertEqual(row.path, "archive")
            try service.extract(archive(ext), paths: [row.path], to: output(ext))
            XCTAssertEqual(try String(contentsOf: output(ext).appendingPathComponent("archive")), "raw stream")
        }
    }
    func testHeaderEncryptionSurvivesUpdateAndRename() throws {
        let one = try file("one.txt"); var options = CompressionOptions(); options.password = "Secret"
        _ = try service.create([one], output: archive(), options: options)
        let two = try file("two.txt")
        _ = try service.add([two], to: archive(), password: "Secret")
        _ = try service.rename("two.txt", to: "renamed.txt", in: archive(), password: "Secret")
        XCTAssertThrowsError(try service.list(archive()))
        XCTAssertTrue(try service.list(archive(), password: "Secret").entries.allSatisfy { $0.isEncrypted })
    }
    func testEncryptedEditDoesNotLeakPlaintextEntry() throws {
        let one = try file("one.txt", "old"); var options = CompressionOptions(); options.password = "Secret"; options.encryptHeaders = false
        _ = try service.create([one], output: archive(), options: options)
        try Data("modified".utf8).write(to: one)
        _ = try service.updateFile(one, path: "one.txt", in: archive(), password: "Secret")
        XCTAssertTrue(try service.list(archive()).entries[0].isEncrypted)
        try service.extract(archive(), to: output(), password: "Secret")
        XCTAssertEqual(try String(contentsOf: output().appendingPathComponent("one.txt")), "modified")
    }
    func testSymbolicLinkArchiveIsRejected() throws {
        var data = tarHeader(name: "link.txt", size: 0, type: 50, link: "../outside")
        data.append(Data(repeating: 0, count: 1024)); try data.write(to: archive("tar"))
        let listing = try service.list(archive("tar"))
        XCTAssertTrue(listing.entries.contains { $0.isLink })
        XCTAssertThrowsError(try service.extract(archive("tar"), to: output()))
        XCTAssertFalse(SafeFileSystem.exists(output()))
    }
    func testCaseCollisionIsRejectedBeforeExtracting() throws {
        let one = try file("a.txt"); let two = try file("other.txt")
        _ = try service.create([one, two], output: archive(), options: CompressionOptions())
        try unsafeRename(archive(), from: "other.txt", to: "A.txt")
        XCTAssertThrowsError(try service.extract(archive(), to: output()))
        XCTAssertFalse(SafeFileSystem.exists(output()))
    }
    func testRenameMissingAndCollisionKeepOriginal() throws {
        let one = try file("one.txt"); let two = try file("two.txt")
        _ = try service.create([one, two], output: archive(), options: CompressionOptions())
        let original = try Data(contentsOf: archive())
        XCTAssertThrowsError(try service.rename("missing.txt", to: "renamed.txt", in: archive()))
        XCTAssertThrowsError(try service.rename("one.txt", to: "two.txt", in: archive()))
        XCTAssertEqual(try Data(contentsOf: archive()), original)
    }
    func testExactOutputNameWithoutExtension() throws {
        let one = try file("one.txt")
        let target = output("no-extension")
        let outputs = try service.create([one], output: target, options: CompressionOptions())
        XCTAssertEqual(outputs, [target]); XCTAssertTrue(SafeFileSystem.exists(target))
    }
    func testMissingInputIsAnError() {
        XCTAssertThrowsError(try service.hash([source.appendingPathComponent("missing.txt")]))
    }

    func testPersistentSessionAndNativeFormatEnumeration() throws {
        let input = try file("a = b.txt")
        _ = try service.create([input], output: archive(), options: CompressionOptions())
        let first = try service.open(archive()); let bytes = first.bytesRead
        XCTAssertTrue(first === (try service.open(archive())))
        for _ in 0..<100 { XCTAssertEqual(first.listing.children(of: "").first?.path, "a = b.txt") }
        XCTAssertEqual(first.bytesRead, bytes)
        let formats = service.engine.formats()
        for name in ["7z", "zip", "Rar", "Iso", "Dmg"] { XCTAssertTrue(formats.localizedCaseInsensitiveContains(name), name) }
    }

    func testCorruptZIPDataFailsBeforeDestinationCommit() throws {
        let input = try file("payload.txt", String(repeating: "corruption fixture ", count: 1000))
        var options = CompressionOptions(); options.format = "zip"; options.level = 0
        _ = try service.create([input], output: archive("zip"), options: options)
        var data = try Data(contentsOf: archive("zip"))
        func little16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        let payloadOffset = 30 + little16(26) + little16(28)
        data[payloadOffset + 100] ^= 1; try data.write(to: archive("zip"))
        XCTAssertThrowsError(try service.test(archive("zip")))
        XCTAssertThrowsError(try service.extract(archive("zip"), to: output()))
        XCTAssertFalse(SafeFileSystem.exists(output()))
    }

    func testLegacyZIPEncryptionSurvivesUpdates() throws {
        let first = try file("first.txt")
        var options = CompressionOptions(); options.format = "zip"; options.password = "legacy secret"; options.zipAES = false
        _ = try service.create([first], output: archive("zip"), options: options)
        let second = try file("second.txt", "new")
        _ = try service.add([second], to: archive("zip"), password: options.password, backup: false)
        let entries = try service.list(archive("zip")).entries
        XCTAssertTrue(entries.allSatisfy { $0.isEncrypted && $0.method.contains("ZipCrypto") })
        try service.extract(archive("zip"), to: output(), password: options.password)
        XCTAssertEqual(try String(contentsOf: output().appendingPathComponent("second.txt")), "new")
    }

    func testNestedArchiveThroughSplitParentIsReadOnly() throws {
        let text = try file("note.txt", String(repeating: "test", count: 1000))
        var innerOptions = CompressionOptions(); innerOptions.level = 0
        let inner = output("inner.7z"); _ = try service.create([text], output: inner, options: innerOptions)
        var outerOptions = CompressionOptions(); outerOptions.level = 0; outerOptions.volumeSize = "1k"
        let volumes = try service.create([inner], output: archive(), options: outerOptions)
        let root = try service.open(volumes[0]); let child = try service.openNested(in: root, index: root.listing.entries[0].index!)
        XCTAssertFalse(child.canModify)
        let originals = try volumes.map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try service.delete(["note.txt"], from: child.url))
        XCTAssertEqual(try volumes.map { try Data(contentsOf: $0) }, originals)
        try service.extract(child.url, to: output("read-only-child"))
        XCTAssertEqual(try Data(contentsOf: output("read-only-child").appendingPathComponent("note.txt")), try Data(contentsOf: text))
    }

    func testThreeLevelNestedEditingWithDifferentPasswords() throws {
        let text = try file("note.txt", "original")
        var zip = CompressionOptions(); zip.format = "zip"; zip.password = "inner secret"
        let inner = output("inner.zip"); _ = try service.create([text], output: inner, options: zip)
        var tar = CompressionOptions(); tar.format = "tar"
        let middle = output("middle.tar"); _ = try service.create([inner], output: middle, options: tar)
        var seven = CompressionOptions(); seven.password = "outer secret"
        let outer = output("outer.7z"); _ = try service.create([middle], output: outer, options: seven)
        let original = try Data(contentsOf: outer)
        let root = try service.open(outer, password: seven.password)
        let mid = try service.openNested(in: root, index: root.listing.entries[0].index!)
        XCTAssertFalse(mid.usesDirectStream)
        XCTAssertTrue(SafeFileSystem.exists(mid.url))
        let leaf = try service.openNested(in: mid, index: mid.listing.entries[0].index!, password: zip.password)
        XCTAssertTrue(leaf.usesDirectStream); XCTAssertTrue(leaf.canModify)
        XCTAssertFalse(SafeFileSystem.exists(leaf.url.deletingLastPathComponent()))
        try Data("edited through three levels".utf8).write(to: text)
        let result = try service.updateFile(text, path: "note.txt", in: leaf.url, password: zip.password, backup: true)
        XCTAssertEqual(try Data(contentsOf: result.backup!), original)
        XCTAssertTrue(result.log.contains(L10n.tr("Changes committed. \(3) archive level(s) verified.\n")))
        try service.extract(leaf.url, to: output("edited"), password: zip.password)
        XCTAssertEqual(try String(contentsOf: output("edited").appendingPathComponent("note.txt")), "edited through three levels")
        _ = try service.rename("note.txt", to: "renamed.txt", in: leaf.url, password: zip.password, backup: false)
        XCTAssertEqual(leaf.listing.entries.map(\.path), ["renamed.txt"])
        // Reopen independently to prove the physical outer file contains the edits.
        let fresh = try ArchiveService(engine: Engine(libraryURL: Engine.locate()))
        XCTAssertThrowsError(try fresh.open(outer))
        let freshRoot = try fresh.open(outer, password: seven.password)
        let freshMid = try fresh.openNested(in: freshRoot, index: freshRoot.listing.entries[0].index!)
        let freshLeaf = try fresh.openNested(in: freshMid, index: freshMid.listing.entries[0].index!, password: zip.password)
        XCTAssertEqual(freshLeaf.listing.entries.map(\.path), ["renamed.txt"])
        XCTAssertTrue(freshLeaf.listing.entries[0].isEncrypted)
        try fresh.extract(freshLeaf.url, to: output("reopened"), password: zip.password)
        XCTAssertEqual(try String(contentsOf: output("reopened").appendingPathComponent("renamed.txt")), "edited through three levels")
    }

    func testNestedCancellationAndExternalChangeKeepOuterArchive() throws {
        let text = try file("note.txt", "old")
        var zip = CompressionOptions(); zip.format = "zip"
        let inner = output("inner.zip"); _ = try service.create([text], output: inner, options: zip)
        _ = try service.create([inner], output: archive(), options: CompressionOptions())
        let root = try service.open(archive()); let nested = try service.openNested(in: root, index: root.listing.entries[0].index!)
        let original = try Data(contentsOf: archive()); try Data("new".utf8).write(to: text)
        let token = CancellationToken()
        token.observeProgress { value in if value.phase == .test { token.cancel() } }
        XCTAssertThrowsError(try service.updateFile(text, path: "note.txt", in: nested.url, token: token))
        XCTAssertEqual(try Data(contentsOf: archive()), original)
        let replacement = output("replacement.7z"); _ = try service.create([text], output: replacement, options: CompressionOptions())
        try SafeFileSystem.atomicReplace(replacement, destination: archive())
        let changed = try Data(contentsOf: archive())
        XCTAssertThrowsError(try service.openNested(in: root, index: root.listing.entries[0].index!))
        XCTAssertThrowsError(try service.updateFile(text, path: "note.txt", in: nested.url))
        XCTAssertEqual(try Data(contentsOf: archive()), changed)
    }

    func testNestedSpoolLimitAndPasswordRetry() throws {
        let text = try file("secret.txt", "secret")
        var innerOptions = CompressionOptions(); innerOptions.password = "inner"
        let inner = output("inner.7z"); _ = try service.create([text], output: inner, options: innerOptions)
        _ = try service.create([inner], output: archive(), options: CompressionOptions())
        let root = try service.open(archive()); let index = root.listing.entries[0].index!
        service.extractionLimit = 1
        XCTAssertThrowsError(try service.openNested(in: root, index: index, password: "inner"))
        service.extractionLimit = 1024 * 1024
        XCTAssertThrowsError(try service.openNested(in: root, index: index, password: "wrong"))
        let nested = try service.openNested(in: root, index: index, password: "inner")
        XCTAssertEqual(nested.listing.entries[0].path, "secret.txt")
    }

    func testNestedPasswordErrorIdentifiesContainingArchiveAndCanRetryAfterClearing() throws {
        let text = try file("note.txt")
        let inner = output("inner.7z"); _ = try service.create([text], output: inner, options: CompressionOptions())
        var options = CompressionOptions(); options.format = "zip"; options.password = "outer secret"
        _ = try service.create([inner], output: archive("zip"), options: options)
        let root = try service.open(archive("zip")); root.password = "wrong"
        XCTAssertThrowsError(try service.openNested(in: root, index: root.listing.entries[0].index!)) { error in
            guard case FMError.passwordForArchive(let url, _) = error else { return XCTFail("Wrong password target: \(error)") }
            XCTAssertEqual(url, root.url)
        }
        root.password = options.password
        let child = try service.openNested(in: root, index: root.listing.entries[0].index!)
        service.forgetPasswords()
        XCTAssertTrue(child.canModify)
        XCTAssertThrowsError(try service.list(child.url))
        root.password = options.password
        XCTAssertEqual(try service.list(child.url).entries[0].path, "note.txt")
    }

    func testRuntimeOutputLimitIsEnforcedByStream() throws {
        let input = try file("payload.bin", String(repeating: "x", count: 100_000))
        _ = try service.create([input], output: archive(), options: CompressionOptions())
        let native = try service.engine.open(archive(), password: nil, token: CancellationToken())
        let destination = output("limited.bin")
        XCTAssertThrowsError(try native.extract([(0, destination)], limit: 1024, password: nil, token: CancellationToken()))
        XCTAssertLessThanOrEqual((try? FileFingerprint(destination).size) ?? 0, 1024)
    }

    func testDuplicateArchivePathsCanBeReadByIndex() throws {
        let first = try file("first.txt", "first"); let second = try file("second.txt", "second")
        var zip = CompressionOptions(); zip.format = "zip"
        _ = try service.create([first, second], output: archive("zip"), options: zip)
        try unsafeRename(archive("zip"), from: "second.txt", to: "first.txt")
        let listing = try service.list(archive("zip"))
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.children(of: "").count, 2)
        XCTAssertThrowsError(try service.extract(archive("zip"), to: output()))
        var contents = Set<String>()
        for entry in listing.entries {
            let directory = output("entry-\(entry.index!)")
            try service.extract(archive("zip"), indices: [entry.index!], to: directory)
            contents.insert(try String(contentsOf: directory.appendingPathComponent(entry.path)))
        }
        XCTAssertEqual(contents, ["first", "second"])
    }

    func testTarXZNestedStreamDoesNotKeepAnEmptyTemporaryFolder() throws {
        let text = try file("note.txt", "streamed TAR contents")
        var tar = CompressionOptions(); tar.format = "tar"
        let inner = output("contents.tar")
        _ = try service.create([text], output: inner, options: tar)
        var xz = CompressionOptions(); xz.format = "xz"
        let outer = archive("tar.xz")
        _ = try service.create([inner], output: outer, options: xz)
        let root = try service.open(outer)
        let entry = try XCTUnwrap(root.listing.entries.first)
        let child = try service.openNested(in: root, index: try XCTUnwrap(entry.index))
        XCTAssertTrue(child.usesDirectStream)
        XCTAssertEqual(child.listing.format, "tar")
        XCTAssertFalse(SafeFileSystem.exists(child.url.deletingLastPathComponent()))
        try service.extract(child.url, to: output("tar-xz"))
        XCTAssertEqual(try String(contentsOf: output("tar-xz/note.txt"), encoding: .utf8), "streamed TAR contents")
        service.forgetPasswords()
        XCTAssertEqual(try service.list(child.url).entries.first?.path, "note.txt")
        XCTAssertTrue(child.usesDirectStream)
    }

    func testSparseFiveGiBArchiveUsesSeekableNestedStream() throws {
        let text = try file("tiny.txt", "read beyond 4 GiB")
        var zip = CompressionOptions(); zip.format = "zip"
        let inner = output("inner.zip"); _ = try service.create([text], output: inner, options: zip)
        let data = try Data(contentsOf: inner)
        let outer = archive("tar")
        FileManager.default.createFile(atPath: outer.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outer)
        let huge: UInt64 = 5 * 1024 * 1024 * 1024
        try handle.write(contentsOf: tarHeader(name: "large.bin", size: huge))
        try handle.seek(toOffset: huge + 512)
        try handle.write(contentsOf: tarHeader(name: "inner.zip", size: UInt64(data.count)))
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data(repeating: 0, count: (512 - data.count % 512) % 512 + 1024)); try handle.close()
        let root = try service.open(outer)
        XCTAssertEqual(root.listing.entries.first { $0.path == "large.bin" }?.size, huge)
        let entry = try XCTUnwrap(root.listing.entries.first { $0.path == "inner.zip" })
        let child = try service.openNested(in: root, index: entry.index!)
        XCTAssertTrue(child.usesDirectStream)
        XCTAssertFalse(SafeFileSystem.exists(child.url.deletingLastPathComponent()))
        try service.extract(child.url, to: output("large-offset"))
        XCTAssertEqual(try String(contentsOf: output("large-offset").appendingPathComponent("tiny.txt")), "read beyond 4 GiB")
        XCTAssertLessThan(root.bytesRead, 4 * 1024 * 1024)
    }

    func testLargeEntryCountHasNoTextCaptureLimit() throws {
        let target = archive("tar"); FileManager.default.createFile(atPath: target.path, contents: nil)
        let file = try FileHandle(forWritingTo: target)
        for index in 0..<25_000 { try file.write(contentsOf: tarHeader(name: "folder-\(index / 100)/file-\(index).txt", size: 0)) }
        try file.write(contentsOf: Data(repeating: 0, count: 1024)); try file.close()
        let session = try service.open(target)
        XCTAssertEqual(session.listing.entries.count, 25_000)
        XCTAssertEqual(session.listing.children(of: "").count, 250)
        XCTAssertEqual(session.listing.children(of: "folder-249").count, 100)
        let before = session.bytesRead
        for _ in 0..<1000 { XCTAssertEqual(session.listing.children(of: "folder-100").count, 100) }
        XCTAssertEqual(session.bytesRead, before)
    }

    private func unsafeRename(_ url: URL, from: String, to: String) throws {
        let native = try service.engine.open(url, password: nil, token: CancellationToken())
        let items = try native.listing(token: CancellationToken()).entries.map { entry in
            NativeUpdateItem(existingIndex: entry.index!, path: entry.path == from ? to : nil)
        }
        let staged = output("unsafe." + url.pathExtension)
        try service.engine.rewrite(native, output: staged, items: items, options: nil, password: nil, token: CancellationToken())
        try SafeFileSystem.atomicReplace(staged, destination: url)
    }
    private func tarHeader(name: String, size: UInt64, type: UInt8 = 48, link: String = "") -> Data {
        var header = Data(repeating: 0, count: 512)
        func field(_ offset: Int, _ width: Int, _ string: String) {
            let bytes = Array(string.utf8.prefix(width)); header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        field(0, 100, name); field(100, 8, "0000644\0"); field(108, 8, "0000000\0"); field(116, 8, "0000000\0")
        field(124, 12, String(format: "%011llo", size) + "\0"); field(136, 12, "00000000000\0")
        field(148, 8, "        "); header[156] = type; field(157, 100, link)
        field(257, 6, "ustar\0"); field(263, 2, "00")
        field(148, 8, String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ")
        return header
    }
}
