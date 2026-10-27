import Foundation
import XCTest
@testable import VibeZipCore

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "zh-Hans", "ja", "ko"]

    private func localizedBundle(_ language: String) throws -> Bundle {
        let localization = try XCTUnwrap(L10n.bundle.localizations.first { $0.lowercased() == language.lowercased() })
        let path = try XCTUnwrap(L10n.bundle.path(forResource: localization, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func table(_ language: String) throws -> [String: String] {
        let bundle = try localizedBundle(language)
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func argumentIndices(_ format: String) throws -> [Int] {
        let pattern = try NSRegularExpression(pattern: #"%%|%(?:(\d+)\$)?@"#)
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        let remainder = pattern.stringByReplacingMatches(in: format, range: range, withTemplate: "")
        XCTAssertFalse(remainder.contains("%"), "Unsupported format specifier: \(format)")
        var next = 1
        var indices: [Int] = []
        for match in pattern.matches(in: format, range: range) {
            let token = (format as NSString).substring(with: match.range)
            if token == "%%" { continue }
            if match.range(at: 1).location != NSNotFound {
                indices.append(try XCTUnwrap(Int((format as NSString).substring(with: match.range(at: 1)))))
            } else {
                indices.append(next); next += 1
            }
        }
        return indices.sorted()
    }

    func testTranslationCoverageAndFormatArguments() throws {
        let english = try table("en")
        XCTAssertGreaterThan(english.count, 350)
        for language in languages {
            let translated = try table(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in translated {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(try argumentIndices(value), try argumentIndices(key), "\(language): \(key)")
            }
        }
    }

    func testLanguageSelectionWithRegionalPreferencesAndFallback() {
        let available = languages
        for (preference, expected) in [("zh-CN", "zh-Hans"), ("zh-Hans-SG", "zh-Hans"),
                                       ("ja-JP", "ja"), ("ko-KR", "ko"), ("fr-FR", "en")] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: available, forPreferences: [preference]).first, expected)
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: available, forPreferences: ["fr-FR", "ja-JP"]).first, "ja")
    }

    func testTranslatedControlsAndReorderedArguments() throws {
        let filename = "Cancel 100% %@ 日本語.zip"
        let message: L10n.Message = "\(3) matches in \(filename)"
        for (language, title, expected) in [
            ("en", "Add", "3 matches in \(filename)"),
            ("zh-Hans", "添加", "在 \(filename) 中找到 3 个匹配项"),
            ("ja", "追加", "\(filename) 内に 3 件の一致"),
            ("ko", "추가", "\(filename)에서 3개 일치")
        ] {
            let bundle = try localizedBundle(language)
            XCTAssertEqual(L10n.render("Add", in: bundle), title)
            XCTAssertEqual(L10n.render(message, in: bundle), expected)
        }
    }

    func testPercentSignsAndUnknownMessagesPreserveArguments() throws {
        let japanese = try localizedBundle("ja")
        let progress: L10n.Message = "\(50)% · \("2 MB") of \("4 MB")"
        XCTAssertEqual(L10n.render(progress, in: japanese), "50% · 2 MB / 4 MB")
        XCTAssertEqual(L10n.render("100% unchanged", in: japanese), "100% unchanged")
        let name = "檔案/100% %@.zip"
        XCTAssertEqual(L10n.render("Untranslated file: \(name)", in: japanese), "Untranslated file: \(name)")
        XCTAssertEqual(L10n.render("Path does not exist: \(name)", in: japanese), "パスが存在しません：\(name)")
    }

    func testHelpAndPrivacyAreBundledForEveryLanguage() throws {
        for language in languages {
            let bundle = try localizedBundle(language)
            for document in ["Help", "Privacy"] {
                let url = try XCTUnwrap(bundle.url(forResource: document, withExtension: "txt"))
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(text.contains("VibeZip"))
                XCTAssertGreaterThan(text.count, 300)
            }
        }
        let english = try localizedBundle("en")
        let privacy = try XCTUnwrap(english.url(forResource: "Privacy", withExtension: "txt"))
        let source = appProjectURL.appendingPathComponent("Resources/Privacy.txt")
        XCTAssertEqual(try Data(contentsOf: privacy), try Data(contentsOf: source))
    }
}

private var appProjectURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

final class AppConfigurationTests: XCTestCase {
    func testSupportedLanguagesMatchResources() throws {
        let data = try Data(contentsOf: appProjectURL.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let languages = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(languages.map { $0.lowercased() }), Set(L10n.bundle.localizations.map { $0.lowercased() }))
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en")
    }

    func testSandboxDisablesIncomingAndOutgoingNetworkAccess() throws {
        let data = try Data(contentsOf: appProjectURL.appendingPathComponent("Resources/VibeZip.entitlements"))
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, false)
        XCTAssertEqual(entitlements["com.apple.security.network.server"] as? Bool, false)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true)
    }
}
