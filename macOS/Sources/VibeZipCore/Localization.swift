import Foundation

/// Shared by AppKit, SwiftUI and operation feedback. File names and engine identifiers
/// are passed as arguments, never used as translation keys.
public enum L10n {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("VibeZip_VibeZipCore.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()

    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        public init(stringLiteral value: String) { key = value; arguments = [] }
        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key; arguments = stringInterpolation.arguments
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            public init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
            }
            public mutating func appendLiteral(_ literal: String) {
                key += literal.replacingOccurrences(of: "%", with: "%%")
            }
            public mutating func appendInterpolation<T>(_ value: T) {
                key += "%@"; arguments.append(String(describing: value))
            }
        }
    }

    public static func tr(_ message: Message) -> String { render(message, in: bundle) }

    /// For a fixed metadata label or a menu title selected from an app-owned list.
    public static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func render(_ message: Message, in bundle: Bundle) -> String {
        let format = bundle.localizedString(forKey: message.key, value: message.key, table: "Localizable")
        guard !message.arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: message.arguments.map { $0 as CVarArg })
    }

    public static func resourceURL(_ name: String, extension ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext)
    }
}
