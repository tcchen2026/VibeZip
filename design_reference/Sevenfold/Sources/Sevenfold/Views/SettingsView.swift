import SwiftUI

/// Sevenfold ▸ Settings (⌘,). Covers the tabs of 7-Zip's Tools ▸ Options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationSettings()
                .tabItem { Label("Integration", systemImage: "contextualmenu.and.cursorarrow") }
            FileTypeSettings()
                .tabItem { Label("File Types", systemImage: "doc.on.doc") }
            FolderSettings()
                .tabItem { Label("Folders", systemImage: "folder") }
            KeyboardSettings()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .frame(width: 560)
    }
}

private struct SevenZipNote: View {
    let text: String
    var body: some View {
        Text("In 7-Zip: \(text)").font(.caption).foregroundStyle(.secondary)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.showParentRow) private var showParentRow = true
    @AppStorage(PrefKey.alternatingRows) private var alternatingRows = true
    @AppStorage(PrefKey.sizeStyle) private var sizeStyle: SizeStyle = .bytes
    @AppStorage(PrefKey.timeStyle) private var timeStyle: TimeStyle = .iso
    @AppStorage(PrefKey.showArchiveToolbar) private var showArchiveToolbar = true
    @AppStorage(PrefKey.showStandardToolbar) private var showStandardToolbar = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showParentRow) {
                    Text("Show “..” item")
                    Text("Go up a level from the top of the list")
                }
                Toggle("Alternating row colors", isOn: $alternatingRows)
                Picker("Sizes", selection: $sizeStyle) {
                    ForEach(SizeStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Dates", selection: $timeStyle) {
                    ForEach(TimeStyle.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("File List")
            } footer: {
                SevenZipNote(text: "Options ▸ Settings, View ▸ Time")
            }
            Section {
                Toggle("Archive toolbar (Add, Extract, Test)", isOn: $showArchiveToolbar)
                Toggle("Standard toolbar (Copy, Move, Delete, Info)", isOn: $showStandardToolbar)
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Right-click the toolbar to show button labels. Glass appearance follows System Settings ▸ Appearance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

private struct IntegrationSettings: View {
    @AppStorage("qa.extractHere") private var extractHere = true
    @AppStorage("qa.extractTo") private var extractTo = true
    @AppStorage("qa.addTo7z") private var addTo7z = true
    @AppStorage("qa.addToZip") private var addToZip = true
    @AppStorage("qa.test") private var test = false
    @AppStorage("qa.checksum") private var checksum = true

    var body: some View {
        Form {
            Section {
                Toggle("Extract Here", isOn: $extractHere)
                Toggle("Extract to “Folder/”", isOn: $extractTo)
                Toggle("Test Archive", isOn: $test)
                Toggle("Add to “Archive.7z”", isOn: $addTo7z)
                Toggle("Add to “Archive.zip”", isOn: $addToZip)
                Toggle("Checksum", isOn: $checksum)
            } header: {
                Text("Finder Quick Actions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These appear when you Control-click files in Finder.").font(.caption).foregroundStyle(.secondary)
                    SevenZipNote(text: "Options ▸ 7-Zip (context menu items)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
    }
}

private struct FileTypeSettings: View {
    private static let types = ["7z", "zip", "rar", "tar", "gz", "bz2", "xz", "zst", "iso", "dmg", "cab", "wim", "arj", "lzh", "cpio", "rpm", "deb", "001"]
    @AppStorage(PrefKey.associations) private var associations = "7z,rar,tar,gz,bz2,xz,zst,cab,wim,arj,lzh,cpio,rpm,deb,001"

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(Self.types, id: \.self) { type in
                        Toggle(".\(type)", isOn: binding(type)).toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Button("Select All") { associations = Self.types.joined(separator: ",") }
                    Button("Clear") { associations = "" }
                }
            } header: {
                Text("Open These Types in Sevenfold")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS asks you to confirm each change of default app.").font(.caption).foregroundStyle(.secondary)
                    SevenZipNote(text: "Options ▸ System")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
    }

    private func binding(_ type: String) -> Binding<Bool> {
        Binding(get: { associations.split(separator: ",").contains(Substring(type)) }, set: { on in
            var set = Set(associations.split(separator: ",").map(String.init))
            if on { set.insert(type) } else { set.remove(type) }
            associations = Self.types.filter(set.contains).joined(separator: ",")
        })
    }
}

private struct FolderSettings: View {
    @AppStorage(PrefKey.workFolder) private var workFolder = "system"
    @AppStorage(PrefKey.viewer) private var viewer = "Quick Look"
    @AppStorage(PrefKey.editor) private var editor = "TextEdit"
    @AppStorage(PrefKey.keepQuarantine) private var keepQuarantine = true

    var body: some View {
        Form {
            Section {
                Picker("Working folder", selection: $workFolder) {
                    Text("System temporary folder").tag("system")
                    Text("Current folder").tag("current")
                    Text("~/Library/Caches/Sevenfold").tag("caches")
                }
                Toggle(isOn: $keepQuarantine) {
                    Text("Keep the quarantine flag on extracted files")
                    Text("Gatekeeper still checks apps that came from the internet")
                }
            } header: {
                Text("Folders")
            } footer: {
                SevenZipNote(text: "Options ▸ Folders")
            }
            Section {
                Picker("Viewer", selection: $viewer) {
                    ForEach(["Quick Look", "TextEdit", "BBEdit", "Visual Studio Code"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Editor", selection: $editor) {
                    ForEach(["TextEdit", "BBEdit", "Visual Studio Code", "Nova"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Viewer and Editor")
            } footer: {
                SevenZipNote(text: "Options ▸ Editor")
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}

private struct KeyboardSettings: View {
    @AppStorage(PrefKey.keyMode) private var keyMode: KeyMode = .sevenZip
    @AppStorage(PrefKey.showKeyTips) private var showKeyTips = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Picker("Key bindings", selection: $keyMode) {
                    ForEach(KeyMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(keyMode.detail).font(.callout).foregroundStyle(.secondary)
                Toggle("Show key tips above the file list", isOn: $showKeyTips)
            } footer: {
                Button("Open Shortcut Map") { openWindow(id: WindowID.shortcuts) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}
