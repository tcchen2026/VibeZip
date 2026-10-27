import AppKit
import Foundation
// Draw a project-specific icon using only macOS system APIs and fonts.
// No official 7-Zip artwork or distributable font files are included.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
for (pixels, name) in sizes {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Cannot create bitmap") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let size = CGFloat(pixels)
    NSColor(calibratedRed: 0.12, green: 0.23, blue: 0.34, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88),
        xRadius: size * 0.19, yRadius: size * 0.19).fill()
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.76, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.17, y: size * 0.16, width: size * 0.66, height: size * 0.10),
        xRadius: size * 0.025, yRadius: size * 0.025).fill()
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.47, weight: .bold), .foregroundColor: NSColor.white]
    let text = "VZ" as NSString; let bounds = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (size - bounds.width) / 2, y: size * 0.28), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: destination.appendingPathComponent(name))
}
// ICNS is a typed container of these PNG representations. Writing the container
// directly also works in build environments without the iconutil image service.
func block(_ type: String, _ payload: Data) -> Data {
    var length = UInt32(payload.count + 8).bigEndian
    var result = Data(type.utf8)
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(payload); return result
}
let representations = [("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")]
var payload = Data()
for (type, name) in representations { payload.append(block(type, try Data(contentsOf: destination.appendingPathComponent(name)))) }
try block("icns", payload).write(to: destination.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
