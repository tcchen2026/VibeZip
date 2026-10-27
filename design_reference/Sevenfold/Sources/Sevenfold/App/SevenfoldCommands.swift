import SwiftUI

/// The menu bar. Menu names and order follow 7-Zip File Manager; shortcuts follow the chosen key mode.
struct SevenfoldCommands: Commands {
    @FocusedValue(\.browser) private var browser: BrowserModel?
    @AppStorage(PrefKey.keyMode) private var keyMode: KeyMode = .sevenZip
    @AppStorage(PrefKey.sizeStyle) private var sizeStyle: SizeStyle = .bytes
    @AppStorage(PrefKey.timeStyle) private var timeStyle: TimeStyle = .iso
    @AppStorage(PrefKey.showArchiveToolbar) private var showArchiveToolbar = true
    @AppStorage(PrefKey.showStandardToolbar) private var showStandardToolbar = true
    @AppStorage(PrefKey.showKeyTips) private var showKeyTips = true
    @AppStorage(PrefKey.bookmarks) private var bookmarksRaw = Prefs.defaultBookmarks
    @AppStorage(PrefKey.shortcutMapTab) private var shortcutTab = "keys"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sevenfold") { AboutPanel.show() }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Group { item(.open); item(.openInside); item(.openOutside); item(.quickLook); item(.edit) }
            Divider()
            Group { item(.add); item(.extract); item(.test) }
            Divider()
            Group { item(.rename); item(.copyTo); item(.moveTo); item(.delete); item(.newFolder) }
            Divider()
            Group { item(.info); item(.comment); item(.checksum); item(.split); item(.combine) }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item(.selectMatching)
            item(.deselectMatching)
            item(.invertSelection)
        }
        CommandGroup(before: .toolbar) { viewItems }
        CommandMenu("Favorites") { favoriteItems }
        CommandMenu("Tools") {
            SettingsLink { Text("Options…") }
            Button { openWindow(id: WindowID.benchmark) } label: {
                Label(Command.benchmark.title, systemImage: Command.benchmark.symbol)
            }
            .keyboardShortcut(Shortcuts.shortcut(.benchmark, keyMode))
            Divider()
            Picker("Key Bindings", selection: $keyMode) {
                ForEach(KeyMode.allCases) { Text($0.title).tag($0) }
            }
            Button("Shortcut Map…") { shortcutTab = "keys"; openWindow(id: WindowID.shortcuts) }
        }
        CommandGroup(replacing: .help) {
            item(.help)
            Button("Shortcut Map for 7-Zip Users") { shortcutTab = "keys"; openWindow(id: WindowID.shortcuts) }
            Button("What Moved from 7-Zip") { shortcutTab = "moved"; openWindow(id: WindowID.shortcuts) }
        }
    }

    // MARK: View menu

    @ViewBuilder
    private var viewItems: some View {
        let pane = browser?.active
        Group {
            check(.viewLarge, pane?.style == .largeIcons)
            check(.viewSmall, pane?.style == .smallIcons)
            check(.viewList, pane?.style == .list)
            check(.viewDetails, pane?.style == .details)
        }
        Divider()
        Menu("Sort By") {
            check(.sortName, pane?.isSorted(by: \FileRow.name) ?? false)
            check(.sortType, pane?.isSorted(by: \FileRow.type) ?? false)
            check(.sortDate, pane?.isSorted(by: \FileRow.modified) ?? false)
            check(.sortSize, pane?.isSorted(by: \FileRow.size) ?? false)
            check(.unsorted, pane?.sortOrder.isEmpty ?? false)
        }
        Divider()
        Group {
            check(.flatView, pane?.flat ?? false)
            check(.twoPanels, browser?.twoPanels ?? false)
        }
        Divider()
        Group { item(.up); item(.back); item(.forward); item(.goToFolder); item(.refresh) }
        Divider()
        Group {
            Menu("Toolbars") {
                Toggle("Archive Toolbar", isOn: $showArchiveToolbar)
                Toggle("Standard Toolbar", isOn: $showStandardToolbar)
            }
            Picker("Sizes", selection: $sizeStyle) {
                ForEach(SizeStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Dates", selection: $timeStyle) {
                ForEach(TimeStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show Key Tips", isOn: $showKeyTips)
        }
        Divider()
    }

    // MARK: Favorites menu (7-Zip bookmarks 0–9)

    @ViewBuilder
    private var favoriteItems: some View {
        let marks = bookmarks
        Menu("Add Folder to Favorites As") {
            ForEach(0..<10, id: \.self) { i in
                Button("Bookmark \(i)" + (marks[i].isEmpty ? "" : "  ·  " + Paths.pretty(marks[i]))) {
                    browser?.setBookmark(i)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: [.command, .option])
            }
        }
        .disabled(browser == nil)
        Divider()
        ForEach(0..<10, id: \.self) { i in
            Button(marks[i].isEmpty ? "Bookmark \(i)" : Paths.pretty(marks[i])) {
                browser?.openBookmark(i)
            }
            .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .option)
            .disabled(marks[i].isEmpty || browser == nil)
        }
    }

    private var bookmarks: [String] {
        Array((bookmarksRaw.components(separatedBy: "\n") + Array(repeating: "", count: 10)).prefix(10))
    }

    // MARK: Helpers

    private func item(_ command: Command) -> some View {
        Button { browser?.perform(command) } label: {
            Label(command.title, systemImage: command.symbol)
        }
        .keyboardShortcut(Shortcuts.shortcut(command, keyMode))
        .disabled(!(browser?.isEnabled(command) ?? false))
    }

    private func check(_ command: Command, _ isOn: Bool) -> some View {
        Toggle(command.title, isOn: Binding(get: { isOn }, set: { _ in browser?.perform(command) }))
            .keyboardShortcut(Shortcuts.shortcut(command, keyMode))
            .disabled(browser == nil)
    }
}
