import Foundation
import Observation

enum OperationKind: String {
    case copying = "Copying", moving = "Moving", extracting = "Extracting", compressing = "Compressing"
    case testing = "Testing", updating = "Updating", splitting = "Splitting", combining = "Combining"
}

/// A running archive job, shown in 7-Zip's progress window.
/// The design build simulates progress; a real engine would report bytes as it works.
@MainActor @Observable
final class OperationModel: Identifiable {
    let id = UUID()
    let kind: OperationKind
    let title: String
    let detail: String
    let totalBytes: Int64
    let totalFiles: Int
    let ratio: Double
    private let duration: Double

    private(set) var fraction = 0.0
    private(set) var elapsed = 0.0
    var isPaused = false
    var isCancelled = false

    init(kind: OperationKind, title: String, detail: String, bytes: Int64, files: Int, ratio: Double, speed: Double) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.totalBytes = bytes
        self.totalFiles = max(files, 1)
        self.ratio = ratio
        self.duration = min(5.5, max(1.4, Double(bytes) / speed))
    }

    var processed: Int64 { Int64(Double(totalBytes) * fraction) }
    var packed: Int64 { Int64(Double(processed) * ratio) }
    var filesDone: Int { Int((Double(totalFiles) * fraction).rounded()) }
    var remaining: Double? { fraction > 0.02 ? elapsed / fraction - elapsed : nil }
    var speed: Double? { elapsed > 0.1 ? Double(processed) / elapsed : nil }

    /// Returns false if the user cancelled.
    func run() async -> Bool {
        let step = 0.09
        while fraction < 1 {
            try? await Task.sleep(for: .seconds(step))
            if isCancelled { return false }
            if isPaused { continue }
            elapsed += step
            fraction = min(1, elapsed / duration)
        }
        return true
    }
}
