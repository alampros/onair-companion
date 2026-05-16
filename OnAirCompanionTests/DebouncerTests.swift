import XCTest
@testable import OnAirCompanion

@MainActor
final class DebouncerTests: XCTestCase {

    func testActionFiresAfterDelay() async throws {
        let debouncer = Debouncer(duration: .milliseconds(50))
        let expectation = XCTestExpectation(description: "Action fires")
        debouncer.debounce {
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testNewCallCancelsPrevious() async throws {
        let debouncer = Debouncer(duration: .milliseconds(50))
        var callCount = 0
        let expectation = XCTestExpectation(description: "Only last action fires")
        debouncer.debounce {
            callCount += 1
        }
        debouncer.debounce {
            callCount += 1
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(callCount, 1, "Only the last debounced action should fire")
    }

    func testExplicitCancelPreventsExecution() async throws {
        let debouncer = Debouncer(duration: .milliseconds(50))
        var fired = false
        debouncer.debounce {
            fired = true
        }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fired, "Cancelled action should not fire")
    }
}
