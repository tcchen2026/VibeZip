#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import Darwin
import VibeZipCore

enum LocalPreview {
    case text(String, note: String)
    case image(CGImage, note: String)

    var note: String {
        switch self { case .text(_, let note), .image(_, let note): return note }
    }

    /// Reads local bytes only. HTML/scripts remain plain text; PDF pages are rasterized
    /// without links, actions, JavaScript, WebKit or Quick Look providers.
    static func load(_ url: URL, token: CancellationToken) throws -> LocalPreview {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw FMError.message(L10n.tr("Cannot read this file for preview.")) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw FMError.message(L10n.tr("Only regular files can be previewed."))
        }
        let textLimit = 4 * 1024 * 1024, documentLimit = 32 * 1024 * 1024
        var data = Data()
        func read(upTo limit: Int) throws {
            while data.count < limit {
                try token.check()
                let chunk = try handle.read(upToCount: min(64 * 1024, limit - data.count)) ?? Data()
                if chunk.isEmpty { break }; data.append(chunk)
            }
        }
        try read(upTo: textLimit + 1)
        let isPDF = data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        let type = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String }
        let rasterTypes: Set<String> = ["public.jpeg", "public.png", "public.tiff", "com.compuserve.gif",
            "com.microsoft.bmp", "com.microsoft.ico", "public.heic", "public.heif", "public.avif",
            "org.webmproject.webp", "public.jpeg-2000", "com.apple.icns"]
        let isRaster = type.map { rasterTypes.contains($0) } ?? false
        if isPDF || isRaster {
            try read(upTo: documentLimit + 1)
            guard data.count <= documentLimit else {
                return .text(L10n.tr("This document exceeds the 32 MiB built-in preview limit."), note: L10n.tr("Preview size limit"))
            }
            try token.check()
            if isPDF, let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
               let page = document.page(at: 1) {
                let bounds = page.getBoxRect(.cropBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                    throw FMError.message(L10n.tr("The PDF page has invalid dimensions."))
                }
                let scale = min(2, 1800 / max(bounds.width, bounds.height))
                let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
                if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    let rect = CGRect(x: 0, y: 0, width: width, height: height)
                    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(page)
                    if let image = context.makeImage() {
                        return .image(image, note: L10n.tr("PDF · Page 1 of \(document.numberOfPages)"))
                    }
                }
            } else if isRaster, let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                    return .image(image, note: L10n.tr("Image preview"))
                }
            }
            return .text(L10n.tr("This document could not be rendered by the built-in preview."), note: L10n.tr("Preview unavailable"))
        }
        let prefix = Data(data.prefix(textLimit))
        // A byte limit can split the final UTF-8 code point.
        for trim in 0...min(3, prefix.count) {
            if let text = String(data: prefix.dropLast(trim), encoding: .utf8), !text.contains("\0") {
                let truncated = data.count > textLimit
                return .text(text, note: truncated ? L10n.tr("Text · First 4 MiB") : L10n.tr("Text preview"))
            }
        }
        let bytes = [UInt8](data.prefix(16 * 1024)); var lines: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let block = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = block.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(block.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        return .text(lines.joined(separator: "\n"), note: L10n.tr("Binary · First 16 KiB"))
    }
}

/// Plain, read-only text with no Services, link actions or rich document import.
final class LocalTextView: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(L10n.tr("Copy"), #selector(copy(_:))), (L10n.tr("Select All"), #selector(selectAll(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
}

final class PreviewWindow: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    init(name: String, content: LocalPreview) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Preview — \(name)"); window.minSize = NSSize(width: 500, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        status.stringValue = content.note; status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail; status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let body: NSView
        switch content {
        case .text(let text, _):
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 550))
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
            let view = LocalTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            view.isEditable = false; view.isSelectable = true; view.isRichText = false
            view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textContainerInset = NSSize(width: 12, height: 12)
            view.isHorizontallyResizable = false; view.isVerticallyResizable = true; view.autoresizingMask = [.width]
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.containerSize = NSSize(width: view.bounds.width, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true; view.textContainer?.lineBreakMode = .byWordWrapping
            view.string = text; scroll.documentView = view; body = scroll; window.initialFirstResponder = view
        case .image(let image, _):
            let view = NSImageView(); view.image = NSImage(cgImage: image, size: .zero)
            view.imageScaling = .scaleProportionallyUpOrDown; view.isEditable = false; body = view
        }
        let stack = NSStackView(views: [status, body]); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
#endif
