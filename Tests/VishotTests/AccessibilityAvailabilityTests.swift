import XCTest
@testable import Vishot

final class AccessibilityAvailabilityTests: XCTestCase {
    func testBackgroundRefreshRecognizesGrantAndRevocationWithoutPickerReads() {
        let granted = expectation(description: "Existing grant is cached")
        let revoked = expectation(description: "Later revocation is cached")
        var reads = 0 // Only accessed by the service's serial worker.
        let availability = AccessibilityAvailability(interval: 0.02, readAccess: {
            XCTAssertFalse(Thread.isMainThread)
            reads += 1
            return reads == 1
        })
        defer { availability.stop(); availability.onChange = nil }
        availability.onChange = { allowed in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(availability.isAllowed, allowed)
            if allowed { granted.fulfill() } else { revoked.fulfill(); availability.stop() }
        }
        XCTAssertFalse(availability.isAllowed)
        availability.start()
        availability.start() // Starting twice must not create another poller.
        wait(for: [granted, revoked], timeout: 2, enforceOrder: true)
    }

    func testStoppingDiscardsInFlightResultAndRestartRefreshes() {
        let reading = expectation(description: "Background read started")
        let release = DispatchSemaphore(value: 0)
        let restarted = expectation(description: "Restart publishes current access")
        var reads = 0
        let availability = AccessibilityAvailability(interval: 60, readAccess: {
            reads += 1
            if reads == 1 { reading.fulfill() }
            release.wait()
            return true
        })
        defer { availability.stop(); availability.onChange = nil }
        availability.start()
        wait(for: [reading], timeout: 2)
        availability.stop()
        availability.onChange = { _ in XCTFail("Stopped reads must not publish") }
        release.signal()
        let drained = expectation(description: "Stopped completion drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(availability.isAllowed)
        // A separate lifetime can start after the cancelled read finishes.
        availability.onChange = { allowed in
            XCTAssertTrue(allowed)
            availability.stop()
            restarted.fulfill()
        }
        release.signal()
        availability.start()
        wait(for: [restarted], timeout: 2)
    }
}
