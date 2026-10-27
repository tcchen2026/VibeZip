import SwiftUI
import AppKit

@main
struct SevenfoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ArchiveStore.sample()

    var body: some Scene {
        WindowGroup("Sevenfold", id: WindowID.browser) {
            BrowserWindow(store: store)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { SevenfoldCommands() }

        Window("Benchmark", id: WindowID.benchmark) {
            BenchmarkView()
        }
        .windowResizability(.contentSize)

        Window("Shortcut Map for 7-Zip Users", id: WindowID.shortcuts) {
            ShortcutMapView()
        }
        .defaultSize(width: 860, height: 620)

        Settings {
            SettingsView()
        }
    }
}

enum WindowID {
    static let browser = "browser"
    static let benchmark = "benchmark"
    static let shortcuts = "shortcuts"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts the app without a bundle; this makes it a normal Dock app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension FocusedValues {
    /// The browser window that has focus. Menu commands act on it.
    @Entry var browser: BrowserModel?
}

enum AboutPanel {
    @MainActor static func show() {
        let credits = NSAttributedString(
            string: "Compression engine: 7-Zip by Igor Pavlov, GNU LGPL with the unRAR restriction.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Sevenfold",
            .applicationVersion: "1.0 (design build)",
            .credits: credits
        ])
        NSApp.activate()
    }
}
