import Foundation
#if os(macOS)
import CoreFoundation
#endif

enum ZIPFilenameEncoding {
    /// Only names without authoritative Unicode metadata reach this detector.
    /// The native bridge samples whole names, then caches one decoding per entry.
    static func detect(_ sample: Data) -> UInt32 {
        guard !sample.isEmpty else { return 437 }
        #if os(macOS)
        let pages: [UInt32] = [936, 54936, 950, 932, 949, 437]
        let encodings = pages.map { CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding($0)) }
        var text: NSString?, lossy = ObjCBool(false)
        let encoding = NSString.stringEncoding(for: sample, encodingOptions: [
            .suggestedEncodingsKey: encodings,
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
            .fromWindowsKey: true
        ], convertedString: &text, usedLossyConversion: &lossy)
        guard encoding != 0, text != nil, !lossy.boolValue else { return 437 }
        let page = CFStringConvertEncodingToWindowsCodepage(CFStringConvertNSStringEncodingToEncoding(encoding))
        return pages.contains(page) ? page : 437
        #else
        return 437
        #endif
    }
}
