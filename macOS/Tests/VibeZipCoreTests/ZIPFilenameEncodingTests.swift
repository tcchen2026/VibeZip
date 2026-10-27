#if os(macOS)
import CoreFoundation
import XCTest
@testable import VibeZipCore

final class ZIPFilenameEncodingTests: XCTestCase {
    private var scratch: ScratchDirectory!
    private var service: ArchiveService!
    override func setUpWithError() throws {
        scratch = try ScratchDirectory(label: "zip-encoding")
        service = try ArchiveService(engine: Engine(libraryURL: Engine.locate()))
    }
    override func tearDown() { service = nil; scratch = nil }

    func testWindowsGBKNamesAreUsedForListingAndExtraction() throws {
        let names = ["中文目录/测试文件.txt", "报告.docx"]
        let url = try zip(names.map { Entry(name: try encoded($0, page: 936)) })
        let original = try Data(contentsOf: url)
        XCTAssertEqual(try service.list(url).entries.map(\.path), names)
        let destination = scratch.url.appendingPathComponent("extracted")
        try service.extract(url, to: destination)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), Data("content".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUTF8NamesRemainIntact() throws {
        let name = "中文/你好 🚀.txt"
        let url = try zip([Entry(name: Data(name.utf8), flags: 0x800)])
        XCTAssertEqual(try service.list(url).entries.map(\.path), [name])
    }

    func testOtherLegacyCodePages() throws {
        for (page, name): (UInt32, String) in [(950, "繁體中文/測試文件.txt"), (932, "日本語/テストとソフト.txt"), (437, "café.txt")] {
            let url = try zip([Entry(name: try encoded(name, page: page))], name: "\(page).zip")
            XCTAssertEqual(try service.list(url).entries.map(\.path), [name], "Code page \(page)")
        }
    }

    func testUnicodeMetadataAndUnmarkedUTF8TakePrecedence() throws {
        let legacy = try encoded("旧名字.txt", page: 936)
        let names = ["正确名字 🚀.txt", "UTF8目录/文件.txt", "中文目录/测试文件.txt"]
        let url = try zip([
            Entry(name: legacy, extra: unicodeExtra(legacy, name: names[0])),
            Entry(name: Data(names[1].utf8)),
            Entry(name: try encoded(names[2], page: 936))
        ])
        XCTAssertEqual(try service.list(url).entries.map(\.path), names)
    }

    func testInvalidUnicodeExtraFallsBackToLegacyBytes() throws {
        let name = "中文目录/测试文件.txt", bytes = try encoded(name, page: 936)
        let url = try zip([Entry(name: bytes, extra: unicodeExtra(bytes, name: "wrong.txt", validCRC: false))])
        XCTAssertEqual(try service.list(url).entries.map(\.path), [name])
    }

    func testLegacyNamesSurviveRenameAndAddingUTF8Files() throws {
        let names = ["中文目录/测试文件.txt", "报告.docx"]
        let url = try zip(names.map { Entry(name: try encoded($0, page: 936)) })
        _ = try service.rename(names[1], to: "新报告 🚀.docx", in: url, backup: false)
        let added = scratch.url.appendingPathComponent("新增.txt"); try Data("new".utf8).write(to: added)
        _ = try service.add([added], to: url, backup: false)
        XCTAssertEqual(Set(try service.list(url).entries.map(\.path)), [names[0], "新报告 🚀.docx", "新增.txt"])
        let destination = scratch.url.appendingPathComponent("changed")
        try service.extract(url, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(names[0])), Data("content".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("新报告 🚀.docx")), Data("content".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("新增.txt")), Data("new".utf8))
    }

    func testNestedLegacyZIPNamesAndWriteback() throws {
        let leaf = "中文目录/测试文件.txt", member = "中文压缩包.zip"
        let inner = try zip([Entry(name: try encoded(leaf, page: 936))], name: "inner.zip")
        let outer = try zip([Entry(name: try encoded(member, page: 936), content: Data(contentsOf: inner))])
        let root = try service.open(outer)
        XCTAssertEqual(root.listing.entries[0].path, member)
        let child = try service.openNested(in: root, index: root.listing.entries[0].index!)
        XCTAssertEqual(child.listing.entries[0].path, leaf)
        let destination = scratch.url.appendingPathComponent("nested")
        try service.extract(child.url, indices: [child.listing.entries[0].index!], to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(leaf)), Data("content".utf8))
        _ = try service.rename(leaf, to: "中文目录/新文件.txt", in: child.url, backup: false)
        let fresh = try ArchiveService(engine: Engine(libraryURL: Engine.locate()))
        let freshRoot = try fresh.open(outer)
        let reopened = try fresh.openNested(in: freshRoot, index: freshRoot.listing.entries[0].index!)
        XCTAssertEqual(reopened.listing.entries.map(\.path), ["中文目录/新文件.txt"])
    }

    func testDecodedUnsafePathsStillCannotEscapeDestination() throws {
        let url = try zip([Entry(name: try encoded("../中文逃逸.txt", page: 936))])
        XCTAssertEqual(try service.list(url).entries[0].path, "../中文逃逸.txt")
        XCTAssertThrowsError(try service.extract(url, to: scratch.url.appendingPathComponent("safe")))
        XCTAssertFalse(SafeFileSystem.exists(scratch.url.appendingPathComponent("中文逃逸.txt")))
        let invalid = try zip([Entry(name: Data([0x61, 0, 0x62]))], name: "null.zip")
        XCTAssertThrowsError(try service.list(invalid))
    }

    private func unicodeExtra(_ raw: Data, name: String, validCRC: Bool = true) -> Data {
        var field = Data(); field.le(UInt16(0x7075)); field.le(UInt16(5 + name.utf8.count))
        field.append(1); field.le(crc32(raw) ^ (validCRC ? 0 : 1)); field.append(contentsOf: name.utf8)
        return field
    }

    private struct Entry {
        var name: Data
        var flags: UInt16 = 0
        var extra = Data()
        var content = Data("content".utf8)
    }
    private func encoded(_ name: String, page: UInt32) throws -> Data {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(page))
        return try XCTUnwrap(name.data(using: String.Encoding(rawValue: encoding)))
    }
    // Construct DOS-host ZIP records directly; using the engine to create these
    // fixtures would only exercise its UTF-8 writer, not Windows legacy names.
    private func zip(_ entries: [Entry], name: String = "windows.zip") throws -> URL {
        var data = Data(), central = Data()
        for entry in entries {
            let offset = UInt32(data.count), crc = crc32(entry.content)
            data.le(UInt32(0x04034b50)); data.le(UInt16(20)); data.le(entry.flags)
            data.le(UInt16(0)); data.le(UInt16(0)); data.le(UInt16(0))
            data.le(crc); data.le(UInt32(entry.content.count)); data.le(UInt32(entry.content.count))
            data.le(UInt16(entry.name.count)); data.le(UInt16(entry.extra.count))
            data.append(entry.name); data.append(entry.extra); data.append(entry.content)
            central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(entry.flags)
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(crc); central.le(UInt32(entry.content.count)); central.le(UInt32(entry.content.count))
            central.le(UInt16(entry.name.count)); central.le(UInt16(entry.extra.count)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(offset)
            central.append(entry.name); central.append(entry.extra)
        }
        let centralOffset = UInt32(data.count); data.append(central)
        data.le(UInt32(0x06054b50)); data.le(UInt16(0)); data.le(UInt16(0))
        data.le(UInt16(entries.count)); data.le(UInt16(entries.count))
        data.le(UInt32(central.count)); data.le(centralOffset); data.le(UInt16(0))
        let url = scratch.url.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func crc32(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
#endif
