import SwiftUI

/// Every action a browser window can perform. Menus, toolbar, context menus and the Shortcut Map read from here.
enum Command: String, CaseIterable, Identifiable {
    case open, openInside, openOutside, quickLook, edit
    case add, extract, test
    case rename, copyTo, moveTo, delete, info, comment, checksum, split, combine
    case newFolder, selectMatching, deselectMatching, invertSelection
    case viewLarge, viewSmall, viewList, viewDetails
    case sortName, sortType, sortDate, sortSize, unsorted
    case flatView, twoPanels, up, back, forward, goToFolder, refresh
    case benchmark, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .openInside: "Open Inside"
        case .openOutside: "Open Outside"
        case .quickLook: "Quick Look"
        case .edit: "Edit"
        case .add: "Add to Archive…"
        case .extract: "Extract…"
        case .test: "Test Archive"
        case .rename: "Rename"
        case .copyTo: "Copy To…"
        case .moveTo: "Move To…"
        case .delete: "Delete"
        case .info: "Info"
        case .comment: "Comment…"
        case .checksum: "Checksum…"
        case .split: "Split File…"
        case .combine: "Combine Files"
        case .newFolder: "New Folder"
        case .selectMatching: "Select…"
        case .deselectMatching: "Deselect…"
        case .invertSelection: "Invert Selection"
        case .viewLarge: "Large Icons"
        case .viewSmall: "Small Icons"
        case .viewList: "List"
        case .viewDetails: "Details"
        case .sortName: "Name"
        case .sortType: "Type"
        case .sortDate: "Date"
        case .sortSize: "Size"
        case .unsorted: "Unsorted"
        case .flatView: "Flat View"
        case .twoPanels: "2 Panels"
        case .up: "Up One Level"
        case .back: "Back"
        case .forward: "Forward"
        case .goToFolder: "Go to Folder…"
        case .refresh: "Refresh"
        case .benchmark: "Benchmark"
        case .help: "Sevenfold Help"
        }
    }

    /// Short labels for toolbar buttons, matching 7-Zip's toolbar.
    var toolbarTitle: String {
        switch self {
        case .add: "Add"
        case .extract: "Extract"
        case .test: "Test"
        case .copyTo: "Copy"
        case .moveTo: "Move"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .openInside: "arrow.down.right.square"
        case .openOutside: "arrow.up.right.square"
        case .quickLook: "eye"
        case .edit: "pencil"
        case .add: "archivebox"
        case .extract: "square.and.arrow.up.on.square"
        case .test: "checkmark.seal"
        case .rename: "character.cursor.ibeam"
        case .copyTo: "doc.on.doc"
        case .moveTo: "folder"
        case .delete: "trash"
        case .info: "info.circle"
        case .comment: "text.bubble"
        case .checksum: "number"
        case .split: "scissors"
        case .combine: "link"
        case .newFolder: "folder.badge.plus"
        case .selectMatching: "checklist"
        case .deselectMatching: "checklist.unchecked"
        case .invertSelection: "arrow.left.arrow.right"
        case .viewLarge: "square.grid.2x2"
        case .viewSmall: "square.grid.3x3"
        case .viewList: "list.bullet"
        case .viewDetails: "list.bullet.rectangle"
        case .sortName, .sortType, .sortDate, .sortSize, .unsorted: "arrow.up.arrow.down"
        case .flatView: "list.bullet.indent"
        case .twoPanels: "rectangle.split.2x1"
        case .up: "arrow.up"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .goToFolder: "arrow.right.circle"
        case .refresh: "arrow.clockwise"
        case .benchmark: "gauge.with.dots.needle.67percent"
        case .help: "questionmark.circle"
        }
    }
}

// MARK: - Keyboard shortcuts

/// A command's keys in Windows 7-Zip and in both Sevenfold key modes.
struct ShortcutSpec: Identifiable {
    let command: Command
    let menu: String
    let windows: String
    let sevenZip: KeyboardShortcut?
    let mac: KeyboardShortcut?
    var note: String? = nil
    var id: Command { command }
}

enum Shortcuts {
    static func fn(_ n: Int, _ m: EventModifiers = []) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(Unicode.Scalar(UInt32(0xF703 + n))!)), modifiers: m)
    }

    private static func k(_ c: Character, _ m: EventModifiers = .command) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(c), modifiers: m)
    }

    static let all: [ShortcutSpec] = [
        .init(command: .open, menu: "File", windows: "Enter", sevenZip: nil, mac: KeyboardShortcut(.downArrow, modifiers: .command), note: "Return and double-click open in both modes"),
        .init(command: .openInside, menu: "File", windows: "Ctrl+PgDn", sevenZip: KeyboardShortcut(.pageDown, modifiers: .command), mac: KeyboardShortcut(.downArrow, modifiers: [.command, .option])),
        .init(command: .openOutside, menu: "File", windows: "Shift+Enter", sevenZip: KeyboardShortcut(.return, modifiers: .shift), mac: k("o", [.command, .option])),
        .init(command: .quickLook, menu: "File", windows: "F3 (View)", sevenZip: fn(3), mac: k("y"), note: "Space also opens Quick Look"),
        .init(command: .edit, menu: "File", windows: "F4", sevenZip: fn(4), mac: k("e")),
        .init(command: .rename, menu: "File", windows: "F2", sevenZip: fn(2), mac: fn(2)),
        .init(command: .copyTo, menu: "File", windows: "F5", sevenZip: fn(5), mac: k("c", [.command, .shift])),
        .init(command: .moveTo, menu: "File", windows: "F6", sevenZip: fn(6), mac: k("m", [.command, .shift])),
        .init(command: .delete, menu: "File", windows: "Del", sevenZip: KeyboardShortcut(.delete, modifiers: .command), mac: KeyboardShortcut(.delete, modifiers: .command), note: "The Delete key works too. Outside archives, items go to the Trash"),
        .init(command: .info, menu: "File", windows: "Alt+Enter", sevenZip: KeyboardShortcut(.return, modifiers: .option), mac: k("i"), note: "Opens the Info inspector instead of a dialog"),
        .init(command: .comment, menu: "File", windows: "Ctrl+Z", sevenZip: k("k", [.command, .shift]), mac: k("k", [.command, .shift]), note: "Moved because ⌘Z is Undo on a Mac"),
        .init(command: .newFolder, menu: "File", windows: "F7", sevenZip: fn(7), mac: k("n", [.command, .shift])),
        .init(command: .add, menu: "File", windows: "—", sevenZip: k("a", [.command, .shift]), mac: k("a", [.command, .shift])),
        .init(command: .extract, menu: "File", windows: "—", sevenZip: k("e", [.command, .shift]), mac: k("e", [.command, .shift])),
        .init(command: .test, menu: "File", windows: "—", sevenZip: k("t", [.command, .shift]), mac: k("t", [.command, .shift])),
        .init(command: .selectMatching, menu: "Edit", windows: "Num +", sevenZip: k("="), mac: k("=")),
        .init(command: .deselectMatching, menu: "Edit", windows: "Num −", sevenZip: k("-"), mac: k("-")),
        .init(command: .invertSelection, menu: "Edit", windows: "Num *", sevenZip: k("i", [.command, .shift]), mac: k("i", [.command, .shift])),
        .init(command: .viewLarge, menu: "View", windows: "Ctrl+1", sevenZip: k("1"), mac: k("1")),
        .init(command: .viewSmall, menu: "View", windows: "Ctrl+2", sevenZip: k("2"), mac: k("2")),
        .init(command: .viewList, menu: "View", windows: "Ctrl+3", sevenZip: k("3"), mac: k("3")),
        .init(command: .viewDetails, menu: "View", windows: "Ctrl+4", sevenZip: k("4"), mac: k("4")),
        .init(command: .sortName, menu: "View", windows: "Ctrl+F3", sevenZip: fn(3, .command), mac: k("1", [.command, .option, .control])),
        .init(command: .sortType, menu: "View", windows: "Ctrl+F4", sevenZip: fn(4, .command), mac: k("2", [.command, .option, .control])),
        .init(command: .sortDate, menu: "View", windows: "Ctrl+F5", sevenZip: fn(5, .command), mac: k("3", [.command, .option, .control])),
        .init(command: .sortSize, menu: "View", windows: "Ctrl+F6", sevenZip: fn(6, .command), mac: k("4", [.command, .option, .control])),
        .init(command: .unsorted, menu: "View", windows: "Ctrl+F7", sevenZip: fn(7, .command), mac: k("5", [.command, .option, .control])),
        .init(command: .twoPanels, menu: "View", windows: "F9", sevenZip: fn(9), mac: k("2", [.command, .shift])),
        .init(command: .up, menu: "View", windows: "Backspace", sevenZip: KeyboardShortcut(.upArrow, modifiers: .command), mac: KeyboardShortcut(.upArrow, modifiers: .command), note: "⌫ is Delete on a Mac, so Up is ⌘↑ as in Finder"),
        .init(command: .back, menu: "View", windows: "Alt+←", sevenZip: k("["), mac: k("[")),
        .init(command: .forward, menu: "View", windows: "Alt+→", sevenZip: k("]"), mac: k("]")),
        .init(command: .goToFolder, menu: "View", windows: "—", sevenZip: k("l"), mac: k("g", [.command, .shift])),
        .init(command: .refresh, menu: "View", windows: "Ctrl+R", sevenZip: k("r"), mac: k("r")),
        .init(command: .benchmark, menu: "Tools", windows: "—", sevenZip: k("b", [.command, .option]), mac: k("b", [.command, .option])),
        .init(command: .help, menu: "Help", windows: "F1", sevenZip: fn(1), mac: k("?"))
    ]

    static func shortcut(_ command: Command, _ mode: KeyMode) -> KeyboardShortcut? {
        guard let spec = all.first(where: { $0.command == command }) else { return nil }
        return mode == .sevenZip ? spec.sevenZip : spec.mac
    }

    /// How a shortcut is drawn in menus, e.g. "⇧⌘E" or "F5".
    static func label(_ s: KeyboardShortcut?) -> String {
        guard let s else { return "—" }
        var out = ""
        if s.modifiers.contains(.control) { out += "⌃" }
        if s.modifiers.contains(.option) { out += "⌥" }
        if s.modifiers.contains(.shift) { out += "⇧" }
        if s.modifiers.contains(.command) { out += "⌘" }
        let c = s.key.character
        if let scalar = c.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) {
            return out + "F\(scalar.value - 0xF703)"
        }
        switch c {
        case KeyEquivalent.return.character: return out + "↩"
        case KeyEquivalent.delete.character: return out + "⌫"
        case KeyEquivalent.upArrow.character: return out + "↑"
        case KeyEquivalent.downArrow.character: return out + "↓"
        case KeyEquivalent.pageDown.character: return out + "⇟"
        default: return out + String(c).uppercased()
        }
    }
}
