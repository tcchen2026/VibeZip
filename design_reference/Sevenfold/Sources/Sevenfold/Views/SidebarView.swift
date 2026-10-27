import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    @AppStorage(PrefKey.keyMode) private var keyMode: KeyMode = .sevenZip
    @AppStorage(PrefKey.bookmarks) private var bookmarksRaw = Prefs.defaultBookmarks
    @Environment(\.openWindow) private var openWindow

    private struct Place: Identifiable {
        let title: String
        let symbol: String
        let path: String
        var id: String { path }
    }

    private let favorites = [
        Place(title: "Applications", symbol: "app.dashed", path: "/Applications"),
        Place(title: "Desktop", symbol: "menubar.dock.rectangle", path: Paths.home + "/Desktop"),
        Place(title: "Documents", symbol: "doc", path: Paths.home + "/Documents"),
        Place(title: "Downloads", symbol: "arrow.down.circle", path: Paths.home + "/Downloads"),
        Place(title: "mira", symbol: "house", path: Paths.home)
    ]

    private let locations = [
        Place(title: "Macintosh HD", symbol: "internaldrive", path: "/"),
        Place(title: "Backup T7", symbol: "externaldrive", path: "/Volumes/Backup T7")
    ]

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(favorites) { place in
                    Label(place.title, systemImage: place.symbol).tag(place.path)
                }
            }
            Section("Locations") {
                ForEach(locations) { place in
                    Label(place.title, systemImage: place.symbol).tag(place.path)
                }
            }
            if !model.store.openArchives.isEmpty {
                Section("Open Archives") {
                    ForEach(model.store.openArchives, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "archivebox")
                            .tag(path)
                            .help(Paths.pretty(path))
                    }
                }
            }
            Section("Bookmarks") {
                ForEach(Array(bookmarks.enumerated()), id: \.offset) { index, path in
                    if !path.isEmpty {
                        Label(path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent, systemImage: "bookmark")
                            .badge(Text("⌥\(index)"))
                            .tag(path)
                            .help(Paths.pretty(path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var bookmarks: [String] {
        let list = bookmarksRaw.components(separatedBy: "\n")
        return Array((list + Array(repeating: "", count: 10)).prefix(10))
    }

    /// Selecting a place opens it in the active panel.
    private var selection: Binding<String?> {
        Binding(get: { model.active.path }, set: { path in
            if let path { model.go(model.active, to: path) }
        })
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Keys", selection: $keyMode) {
                ForEach(KeyMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(keyMode.detail)
            Button("Shortcut map for 7-Zip users") { openWindow(id: WindowID.shortcuts) }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(12)
    }
}
