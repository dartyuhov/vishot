import XCTest
@testable import Vishot

final class MicrophonePermissionTests: XCTestCase {
    func testDecidedStatesNeverRepromptAndQueuedResultsCanBeCancelled() {
        for state in [MicrophoneAuthorization.authorized, .denied, .restricted] {
            let permission = MicrophonePermission(readStatus: { state }, requestAccess: { _ in XCTFail("Must not reprompt") })
            let completed = expectation(description: "Existing decision")
            permission.request { XCTAssertEqual($0, state); completed.fulfill() }
            let abandoned = permission.request { _ in XCTFail("Cancelled caller") }
            permission.cancel(abandoned)
            wait(for: [completed], timeout: 1)
        }
    }

    func testPromptIsSharedAndDuplicateRepliesCannotReviveAbandonedCallers() {
        var state = MicrophoneAuthorization.notDetermined
        var replies: [(Bool) -> Void] = []
        let permission = MicrophonePermission(readStatus: { state }, requestAccess: { replies.append($0) })
        let abandoned = permission.request { _ in XCTFail("Abandoned caller") }
        permission.cancel(abandoned)
        let completed = expectation(description: "Current caller")
        permission.request { XCTAssertEqual($0, .denied); completed.fulfill() }
        XCTAssertEqual(replies.count, 1)
        state = .denied
        let reply = replies[0]
        DispatchQueue.global().async { reply(false); reply(false) }
        wait(for: [completed], timeout: 1)
    }

    func testExplicitRequestDeliversLiveStatusOnMainAndReadingDoesNotPrompt() {
        var state = MicrophoneAuthorization.notDetermined
        var prompts = 0
        var reply: ((Bool) -> Void)?
        let permission = MicrophonePermission(readStatus: { state }, requestAccess: { prompts += 1; reply = $0 })
        XCTAssertEqual(permission.status, .notDetermined)
        XCTAssertEqual(permission.refresh(), .notDetermined)
        XCTAssertEqual(prompts, 0)
        let completed = expectation(description: "Live status")
        permission.request {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual($0, .authorized)
            completed.fulfill()
        }
        XCTAssertEqual(prompts, 1)
        state = .authorized
        reply?(false) // A stale Boolean must not replace the current system state.
        wait(for: [completed], timeout: 1)
        state = .denied
        XCTAssertEqual(permission.refresh(), .denied)
    }
}
