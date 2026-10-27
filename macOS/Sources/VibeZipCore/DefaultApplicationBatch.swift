import Foundation

/// Sequences native consent requests and verifies each result before continuing.
public enum DefaultApplicationBatch {
    public struct Outcome {
        public let confirmed: [String]
        public let stoppedAt: String?
        public let error: Error?
        public let cancelled: Bool
    }

    @MainActor
    public static func apply(_ identifiers: [String], isDefault: (String) -> Bool,
                             request: (String) async throws -> Void) async -> Outcome {
        var seen = Set<String>()
        var confirmed: [String] = []
        for identifier in identifiers where seen.insert(identifier).inserted {
            if Task.isCancelled { return Outcome(confirmed: confirmed, stoppedAt: nil, error: nil, cancelled: true) }
            if isDefault(identifier) { confirmed.append(identifier); continue }
            var requestError: Error?
            do { try await request(identifier) } catch { requestError = error }
            guard isDefault(identifier) else {
                return Outcome(confirmed: confirmed, stoppedAt: identifier, error: requestError, cancelled: Task.isCancelled)
            }
            confirmed.append(identifier)
        }
        return Outcome(confirmed: confirmed, stoppedAt: nil, error: nil, cancelled: false)
    }
}
