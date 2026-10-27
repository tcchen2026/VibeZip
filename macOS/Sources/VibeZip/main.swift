#if os(macOS)
import AppKit
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#else
import Foundation
print("VibeZip requires macOS 13 or later. VibeZipCore tests can run on this platform.")
#endif
