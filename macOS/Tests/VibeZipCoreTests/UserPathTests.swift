import Foundation
import XCTest
@testable import VibeZipCore

final class UserPathTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    func testHomePathsRoundTripIncludingNestedArchives() {
        for (full, short) in [
            ("/Users/example", "~"),
            ("/Users/example/Downloads", "~/Downloads"),
            ("/Users/example/Downloads/日本語.zip ▸ nested.tar ▸ /folder", "~/Downloads/日本語.zip ▸ nested.tar ▸ /folder")
        ] {
            XCTAssertEqual(UserPath.abbreviate(full, home: home), short)
            XCTAssertEqual(UserPath.expand(short, home: home), full)
        }
    }

    func testAbbreviationRespectsHomePathBoundary() {
        for path in ["/", "/Users", "/Users/example-backup/Downloads", "/Users/another/Downloads", "/Volumes/Drive/Users/example"] {
            XCTAssertEqual(UserPath.abbreviate(path, home: home), path)
        }
        XCTAssertEqual(UserPath.expand("Downloads", home: home), "Downloads")
    }
}
