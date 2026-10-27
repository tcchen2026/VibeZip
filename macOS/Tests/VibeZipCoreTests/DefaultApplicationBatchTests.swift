import XCTest
@testable import VibeZipCore

final class DefaultApplicationBatchTests: XCTestCase {
    @MainActor
    func testGroupSkipsExistingDefaultsAndRequestsEachTypeOnceInOrder() async {
        var defaults: Set<String> = ["zip"]
        var requests: [String] = []
        var inFlight = 0
        let result = await DefaultApplicationBatch.apply(["zip", "7z", "rar", "7z"], isDefault: { defaults.contains($0) }, request: { type in
            inFlight += 1; XCTAssertEqual(inFlight, 1)
            requests.append(type)
            await Task.yield()
            defaults.insert(type); inFlight -= 1
        })
        XCTAssertEqual(requests, ["7z", "rar"])
        XCTAssertEqual(result.confirmed, ["zip", "7z", "rar"])
        XCTAssertNil(result.stoppedAt); XCTAssertFalse(result.cancelled)
    }

    @MainActor
    func testDeclinedRequestStopsTheBatchAndPreservesEarlierChanges() async {
        enum Declined: Error { case consent }
        var defaults = Set<String>()
        var requests: [String] = []
        let result = await DefaultApplicationBatch.apply(["zip", "7z", "rar"], isDefault: { defaults.contains($0) }, request: { type in
            requests.append(type)
            if type == "7z" { throw Declined.consent }
            defaults.insert(type)
        })
        XCTAssertEqual(requests, ["zip", "7z"])
        XCTAssertEqual(defaults, ["zip"])
        XCTAssertEqual(result.confirmed, ["zip"])
        XCTAssertEqual(result.stoppedAt, "7z"); XCTAssertNotNil(result.error)
    }

    @MainActor
    func testSuccessfulCallbackAloneDoesNotReportAnUnchangedDefaultAsSuccess() async {
        var requests: [String] = []
        let result = await DefaultApplicationBatch.apply(["zip", "rar"], isDefault: { _ in false }, request: { requests.append($0) })
        XCTAssertEqual(requests, ["zip"])
        XCTAssertTrue(result.confirmed.isEmpty)
        XCTAssertEqual(result.stoppedAt, "zip")
    }

    @MainActor
    func testCancelledBatchDoesNotRequestChanges() async {
        var requests: [String] = []
        let task = Task { @MainActor in
            await DefaultApplicationBatch.apply(["zip", "7z", "rar"], isDefault: { _ in false }, request: { requests.append($0) })
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled); XCTAssertTrue(requests.isEmpty)
    }
}
