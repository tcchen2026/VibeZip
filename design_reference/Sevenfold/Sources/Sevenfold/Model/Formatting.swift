import Foundation
import SwiftUI

enum SizeStyle: String, CaseIterable, Identifiable {
    case bytes, finder
    var id: String { rawValue }
    var title: String { self == .bytes ? "Bytes (12 451 392)" : "Finder (12.5 MB)" }
}

enum TimeStyle: String, CaseIterable, Identifiable {
    case iso, finder
    var id: String { rawValue }
    var title: String { self == .iso ? "ISO 8601 (2026-09-28 14:03)" : "Finder (28 Sep 2026 at 14:03)" }
}

enum KeyMode: String, CaseIterable, Identifiable {
    case sevenZip = "7z", mac
    var id: String { rawValue }
    var title: String { self == .sevenZip ? "7-Zip" : "Mac" }
    var detail: String {
        self == .sevenZip
            ? "F-keys work as in 7-Zip File Manager. Ctrl becomes ⌘ and Alt becomes ⌥."
            : "Finder conventions: ⌘Y previews, ⌘⌫ deletes, ⌘I shows Info."
    }
}

/// UserDefaults keys shared by @AppStorage in views and by the model.
enum PrefKey {
    static let keyMode = "keyMode"
    static let sizeStyle = "sizeStyle"
    static let timeStyle = "timeStyle"
    static let showParentRow = "showParentRow"
    static let alternatingRows = "alternatingRows"
    static let showKeyTips = "showKeyTips"
    static let showArchiveToolbar = "showArchiveToolbar"
    static let showStandardToolbar = "showStandardToolbar"
    static let bookmarks = "bookmarks"
    static let excludeMetadata = "excludeMetadata"
    static let keepQuarantine = "keepQuarantine"
    static let workFolder = "workFolder"
    static let viewer = "viewer"
    static let editor = "editor"
    static let associations = "associations"
    static let shortcutMapTab = "shortcutMapTab"
}

enum Prefs {
    static let defaultBookmarks = [Paths.home + "/Downloads", Paths.home + "/Documents/Projects", "/Volumes/Backup T7/Archives", "", "", "", "", "", "", ""].joined(separator: "\n")

    static var bookmarks: [String] {
        get {
            let raw = UserDefaults.standard.string(forKey: PrefKey.bookmarks) ?? defaultBookmarks
            var list = raw.components(separatedBy: "\n")
            while list.count < 10 { list.append("") }
            return Array(list.prefix(10))
        }
        set { UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: PrefKey.bookmarks) }
    }

    static var editor: String { UserDefaults.standard.string(forKey: PrefKey.editor) ?? "TextEdit" }
}

enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"   // 7-Zip groups digits with a space
        return f
    }()

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func bytes(_ n: Int64) -> String { grouped.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func human(_ n: Int64) -> String {
        n == 0 ? "Zero bytes" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func size(_ n: Int64, _ style: SizeStyle) -> String { style == .bytes ? bytes(n) : human(n) }

    static func date(_ d: Date, _ style: TimeStyle) -> String {
        guard style == .finder else { return iso.string(from: d) }
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return "Today at \(time)" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday at \(time)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    static func dictionary(_ bytes: Int64) -> String {
        bytes >= 1 << 30 ? "\(bytes >> 30) GB" : bytes >= 1 << 20 ? "\(bytes >> 20) MB" : "\(bytes >> 10) KB"
    }

    private static let kinds: [String: String] = [
        "7z": "7-Zip archive", "zip": "ZIP archive", "rar": "RAR archive", "xz": "XZ archive", "tar": "Tape archive",
        "gz": "GZip archive", "bz2": "BZip2 archive", "iso": "ISO disk image", "dmg": "Disk image", "pdf": "PDF document",
        "png": "PNG image", "heic": "HEIF image", "mov": "QuickTime movie", "md": "Markdown", "txt": "Plain text",
        "json": "JSON", "plist": "Property list", "csv": "CSV document", "dylib": "Dynamic library", "otf": "OpenType font",
        "caf": "Core Audio file", "wav": "Waveform audio", "html": "HTML document", "js": "JavaScript", "css": "CSS",
        "key": "Keynote presentation", "001": "Split archive", "002": "Split archive", "003": "Split archive",
        "c": "C source", "cfg": "Configuration", "efi": "EFI executable", "squashfs": "SquashFS image"
    ]

    static func kind(_ n: FileNode) -> String {
        if n.kind == .folder { return "Folder" }
        if n.isApp { return "Application" }
        if n.isExecutable && n.ext.isEmpty { return "Unix executable" }
        if let k = kinds[n.ext] { return k }
        return n.ext.isEmpty ? "Document" : n.ext.uppercased() + " file"
    }

    static func app(for n: FileNode) -> String {
        switch n.ext {
        case "pdf", "png", "heic": "Preview"
        case "csv", "numbers": "Numbers"
        case "html": "Safari"
        case "wav", "mov", "caf": "QuickTime Player"
        case "otf": "Font Book"
        case "key": "Keynote"
        default: n.isExecutable ? "Terminal" : Prefs.editor
        }
    }
}

/// Text shown by Quick Look for a few sample files.
enum SampleText {
    static let preview: [String: String] = [
        "README.md": """
        # Kestrel 4.2

        Kestrel is a small, fast tile renderer for map and game tooling.

        ## What's in this archive
        - bin/     kestrel, kestrel-cli, kestrel-helper (arm64)
        - lib/     libkestrel.dylib, libkestrel-render.dylib
        - docs/    manual.pdf, quick-start.md, api/
        - assets/  icons, sounds and fonts
        - config/  defaults.plist, presets.json
        """,
        "CHANGELOG.md": """
        ## 4.2.0 (2026-09-28)
        - Added a vector tile cache with LRU eviction (--cache-mb)
        - Render pipeline now uses Metal 4 argument tables
        - Fixed wrong DPI in exported PDFs at 300 dpi
        """,
        "notes.txt": "Tram 28, recorded from the back seat with the windows open.\nRain on the studio skylight, 02:10 to 02:24.\n",
        "presets.json": "{\n  \"retina-web\": { \"scale\": 2, \"format\": \"webp\" },\n  \"print-a3\": { \"dpi\": 300, \"format\": \"pdf\" }\n}\n"
    ]
}
