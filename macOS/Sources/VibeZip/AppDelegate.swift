#if os(macOS)
import AppKit
import VibeZipCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainWindowController?
    private var aboutWindow: AboutWindow?
    private var pendingURLs: [URL] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showHidden": false, "keepBackups": true,
            "extractionLimitGiB": 100, "showKeyTips": true, "browserViewStyle": BrowserViewStyle.details.rawValue])
        do {
            let engine = try Engine(libraryURL: Engine.locate())
            let controller = MainWindowController(service: ArchiveService(engine: engine))
            self.controller = controller
            controller.onIdle = { [weak self] in self?.drainPendingURLs() }
            buildMenus(controller)
            controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
            drainPendingURLs()
        } catch { UIFormat.error(error); NSApp.terminate(nil) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        pendingURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        drainPendingURLs(); sender.reply(toOpenOrPrint: .success)
    }
    private func drainPendingURLs() {
        guard let controller = controller, controller.canAcceptCommands, !pendingURLs.isEmpty else { return }
        let url = pendingURLs.removeFirst(); controller.showWindow(nil)
        controller.openURL(url, in: controller.activePane, userSelected: true)
        if controller.canAcceptCommands { DispatchQueue.main.async { [weak self] in self?.drainPendingURLs() } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller?.hasActiveOperations == true {
            if UIFormat.confirm("An operation is still running", "Wait for the current operation or cancel it before quitting.", action: "Cancel Operation") { controller?.cancelCurrent(nil) }
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.cleanupTemporaryFiles() }
    @objc private func about(_ sender: Any?) {
        if aboutWindow == nil { aboutWindow = AboutWindow() }
        aboutWindow?.showWindow(nil)
    }
    private func buildMenus(_ c: MainWindowController) {
        let main = NSMenu(); NSApp.mainMenu = main
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let menu = NSMenu(title: title)
            item.submenu = menu; main.addItem(item); return menu
        }
        let app = submenu("VibeZip")
        let about = NSMenuItem(title: "About VibeZip", action: #selector(self.about), keyEquivalent: ""); about.target = self; app.addItem(about)
        app.addItem(.separator()); app.addItem(c.menuItem("Settings…", #selector(c.showPreferences), key: ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide VibeZip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "Quit VibeZip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        file.addItem(c.menuItem("Browse…", #selector(c.chooseOpen), key: "o"))
        file.addItem(c.menuItem("Allow Folder Access…", #selector(c.chooseFolder)))
        file.addItem(c.menuItem("Open as Archive", #selector(c.openAsArchive)))
        file.addItem(.separator())
        file.addItem(c.menuItem("Add to Archive…", #selector(c.addArchive), key: "a", modifiers: [.command, .shift]))
        file.addItem(c.menuItem("Extract…", #selector(c.extractArchive), key: "e", modifiers: [.command, .shift]))
        file.addItem(c.menuItem("Test archive", #selector(c.testArchive), key: "t", modifiers: [.command, .shift]))
        file.addItem(c.menuItem("New Folder…", #selector(c.newFolder), key: "n", modifiers: [.command, .shift]))
        file.addItem(.separator()); file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(c.menuItem("Cut", #selector(c.cutSelection), key: "x")); edit.addItem(c.menuItem("Copy", #selector(c.copySelection), key: "c"))
        edit.addItem(c.menuItem("Paste", #selector(c.pasteSelection), key: "v")); edit.addItem(c.menuItem("Select All", #selector(c.selectAllItems), key: "a"))
        edit.addItem(c.menuItem("Invert Selection", #selector(c.invertSelection)))
        edit.addItem(.separator()); edit.addItem(c.menuItem("Copy To…  F5", #selector(c.copyTo))); edit.addItem(c.menuItem("Move To…  F6", #selector(c.moveTo)))
        edit.addItem(c.menuItem("Rename…  F2", #selector(c.renameSelected)))
        edit.addItem(c.menuItem("Delete / Move to Trash…", #selector(c.deleteSelected), key: "\u{8}"))
        let view = submenu("View")
        view.addItem(c.menuItem("Show Sidebar", #selector(c.togglePlaces), key: "s", modifiers: [.command, .control]))
        view.addItem(c.menuItem("Show Key Tips", #selector(c.toggleKeyTips)))
        view.addItem(c.menuItem("2 Panels  F9", #selector(c.toggleTwoPanels)))
        view.addItem(.separator())
        for (index, title) in ["Icons", "List", "Details"].enumerated() {
            let item = c.menuItem(title, #selector(c.changeViewStyle), key: String(index + 1)); item.tag = index; view.addItem(item)
        }
        view.addItem(.separator())
        view.addItem(c.menuItem("Preview  Space / F3", #selector(c.previewSelected), key: "y"))
        view.addItem(c.menuItem("Info", #selector(c.properties), key: "i"))
        view.addItem(c.menuItem("Reveal in Finder", #selector(c.revealInFinder), key: "r", modifiers: [.command, .shift]))
        view.addItem(c.menuItem("Show Hidden Files", #selector(c.toggleHidden), key: ".", modifiers: [.command, .shift]))
        view.addItem(c.menuItem("Refresh", #selector(c.refreshAll), key: "r"))
        view.addItem(c.menuItem("Search", #selector(c.focusSearch), key: "f"))
        let go = submenu("Go")
        go.addItem(c.menuItem("Up", #selector(c.goUp), key: "\u{f700}")); go.addItem(c.menuItem("Back", #selector(c.goBack), key: "["))
        go.addItem(c.menuItem("Forward", #selector(c.goForward), key: "]")); go.addItem(c.menuItem("Go to Path", #selector(c.focusAddress), key: "l"))
        let tools = submenu("Tools")
        let hashes = NSMenuItem(title: "Checksums", action: nil, keyEquivalent: ""); let hashMenu = NSMenu(title: "Checksums")
        for algorithm in ["CRC32", "CRC64", "SHA1", "SHA256", "SHA512", "BLAKE2sp", "XXH64"] {
            let item = c.menuItem(algorithm, #selector(c.hashSelected)); item.representedObject = algorithm; hashMenu.addItem(item)
        }
        hashes.submenu = hashMenu; tools.addItem(hashes)
        tools.addItem(c.menuItem("Split File…", #selector(c.splitFile))); tools.addItem(c.menuItem("Combine .001 Volumes…", #selector(c.combineFiles)))
        tools.addItem(c.menuItem("7-Zip Formats", #selector(c.engineInformation))); tools.addItem(c.menuItem("Last operation log", #selector(c.showLastLog)))
        tools.addItem(c.menuItem("Clear Passwords", #selector(c.forgetPasswords)))
        let windows = submenu("Window"); NSApp.windowsMenu = windows
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let help = submenu("Help"); help.addItem(c.menuItem("VibeZip Help", #selector(c.showHelp))); NSApp.helpMenu = help
        help.addItem(c.menuItem("Privacy", #selector(c.showPrivacyPolicy)))
        help.addItem(c.menuItem("Shortcut Map", #selector(c.showShortcuts)))
    }
}
#endif
