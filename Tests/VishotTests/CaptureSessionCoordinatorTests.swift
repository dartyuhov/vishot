import XCTest
@testable import Vishot

final class CaptureSessionCoordinatorTests: XCTestCase {
    func testQuitDuringHistoryExportRepliesWhenCopyFinishesWithoutNeedingBrowserClose() {
        let coordinator = CaptureSessionCoordinator()
        var replies = 0
        coordinator.onHistory = { _ in true }
        coordinator.onQuitReady = { replies += 1 }
        coordinator.showHistory()
        coordinator.beginFileOperation()
        XCTAssertFalse(coordinator.requestQuit())
        coordinator.endFileOperation()
        XCTAssertEqual(replies, 1)
    }
    func testHistoryCannotReplaceSessionWhileAnOwnedFileOperationIsPending() {
        let coordinator = CaptureSessionCoordinator()
        var id = 0, captures = 0
        coordinator.onHistory = { id = $0; return true }
        coordinator.onCapture = { _ in captures += 1; return true }
        coordinator.showHistory()
        coordinator.beginFileOperation()
        coordinator.replaceWithCapture(id)
        XCTAssertEqual(captures, 0)
        coordinator.endFileOperation()
        coordinator.replaceWithCapture(id)
        XCTAssertEqual(captures, 1)
    }
    func testQuitAndSettingsWaitForFileOperationEvenWithVisibleHistory() {
        let coordinator = CaptureSessionCoordinator()
        var id = 0, replies = 0
        coordinator.onHistory = { id = $0; return true }
        coordinator.onQuitReady = { replies += 1 }
        coordinator.showHistory()
        coordinator.beginFileOperation()
        XCTAssertFalse(coordinator.requestQuit())
        coordinator.finish(id)
        XCTAssertTrue(coordinator.isSessionActive)
        XCTAssertEqual(replies, 0)
        coordinator.endFileOperation()
        XCTAssertFalse(coordinator.isSessionActive)
        XCTAssertEqual(replies, 1)
    }

    func testFailedQuitCanBeCancelledForRescueWithoutReleasingSession() {
        let coordinator = CaptureSessionCoordinator()
        var id = 0, cancellations = 0
        coordinator.onCapture = { id = $0; return true }
        coordinator.onQuitCancelled = { cancellations += 1 }
        coordinator.capture()
        coordinator.dismissPresentation(id)
        XCTAssertFalse(coordinator.requestQuit())
        coordinator.cancelQuit()
        XCTAssertTrue(coordinator.isSessionActive)
        XCTAssertEqual(cancellations, 1)
        coordinator.finish(id)
        coordinator.capture()
        XCTAssertTrue(coordinator.isSessionActive)
    }
    func testShortcutAndRetentionStayFrozenUntilCurrentSessionFinishes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var registrations: [CaptureShortcut] = []
        let settings = SettingsStore(url: url) { registrations.append($0); return NSObject() }
        settings.start(watching: false)
        let coordinator = CaptureSessionCoordinator()
        coordinator.onSessionChange = { settings.setSessionActive($0) }
        var old = 0, current = 0
        coordinator.onHistory = { old = $0; return true }
        coordinator.onCapture = { current = $0; return true }
        coordinator.onCaptureAgain = { coordinator.replaceWithCapture($0) }
        coordinator.showHistory()
        let shortcut = CaptureShortcut(key: "K", modifiers: ["control"])
        settings.update(shortcut: shortcut, historyRetention: .off)
        coordinator.capture()
        coordinator.finish(old)
        coordinator.dismissPresentation(current)
        XCTAssertEqual(settings.active.shortcut, .defaults)
        XCTAssertEqual(settings.active.historyRetention, AppSettings.defaults.historyRetention)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertTrue(settings.isSessionActive)
        coordinator.finish(current)
        XCTAssertEqual(settings.active.shortcut, shortcut)
        XCTAssertEqual(settings.active.historyRetention, .off)
        XCTAssertEqual(registrations.count, 2)
        XCTAssertFalse(settings.isSessionActive)
    }

    func testRepeatedCaptureRoutesOnlyToCurrentPresentation() {
        let coordinator = CaptureSessionCoordinator()
        var id = 0, repeated: [Int] = []
        coordinator.onCapture = { id = $0; return true }
        coordinator.onCaptureAgain = { repeated.append($0) }
        coordinator.capture()
        coordinator.capture()
        XCTAssertEqual(repeated, [id])
        coordinator.dismissPresentation(id)
        coordinator.capture()
        XCTAssertEqual(repeated, [id])
    }

    func testQuitWaitsForDetachedOperationAndRejectsNewEntries() throws {
        let coordinator = CaptureSessionCoordinator()
        var id = 0, presentations = 0, replies = 0
        coordinator.onCapture = { id = $0; presentations += 1; return true }
        coordinator.onQuitReady = { replies += 1 }
        coordinator.capture()
        coordinator.dismissPresentation(id)
        XCTAssertFalse(coordinator.requestQuit())
        XCTAssertFalse(coordinator.requestQuit())
        coordinator.capture()
        XCTAssertEqual(presentations, 1)
        coordinator.finish(id + 1)
        XCTAssertEqual(replies, 0)
        coordinator.finish(id)
        XCTAssertEqual(replies, 1)
        coordinator.finish(id)
        XCTAssertEqual(replies, 1)
    }

    func testQuitFromPickerAndIdleKeepsImmediateScreenshotBehavior() {
        let coordinator = CaptureSessionCoordinator()
        XCTAssertTrue(coordinator.requestQuit())
        let picking = CaptureSessionCoordinator()
        picking.onCapture = { _ in true }
        picking.capture()
        XCTAssertTrue(picking.requestQuit())
    }

    func testFailedPresentationReleasesAvailability() {
        let coordinator = CaptureSessionCoordinator()
        coordinator.onCapture = { _ in false }
        coordinator.capture()
        XCTAssertFalse(coordinator.isSessionActive)
        coordinator.onHistory = { _ in false }
        coordinator.showHistory()
        XCTAssertFalse(coordinator.isSessionActive)
    }

    func testHistoryReplacementNeverAppliesSettingsBetweenPresentationsAndFencesOldCompletion() throws {
        let coordinator = CaptureSessionCoordinator()
        var old = 0, current = 0
        var activity: [Bool] = []
        coordinator.onSessionChange = { activity.append($0) }
        coordinator.onHistory = { old = $0; return true }
        coordinator.onCapture = { current = $0; return true }
        coordinator.showHistory()
        coordinator.onCaptureAgain = {
            coordinator.dismissPresentation($0)
            coordinator.replaceWithCapture($0)
        }
        coordinator.capture()
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(coordinator.acceptsCallbacks(old))
        XCTAssertTrue(coordinator.acceptsCallbacks(current))
        coordinator.finish(old)
        XCTAssertTrue(coordinator.isSessionActive)
        XCTAssertFalse(activity.contains(false))
        coordinator.finish(current)
        XCTAssertEqual(activity.last, false)
    }

    func testCaptureAndHistoryShareAvailabilityThroughPresentationDismissal() throws {
        let coordinator = CaptureSessionCoordinator()
        var captures: [Int] = []
        var histories: [Int] = []
        coordinator.onCapture = { captures.append($0); return true }
        coordinator.onHistory = { histories.append($0); return true }
        coordinator.capture()
        let id = try XCTUnwrap(captures.first)
        coordinator.showHistory()
        XCTAssertTrue(histories.isEmpty)
        XCTAssertTrue(coordinator.isSessionActive)

        // Panels disappearing is not completion: callbacks are invalidated, but
        // availability stays reserved until the owning operation finishes.
        coordinator.dismissPresentation(id)
        coordinator.capture()
        coordinator.showHistory()
        XCTAssertEqual(captures.count, 1)
        XCTAssertTrue(histories.isEmpty)
        XCTAssertFalse(coordinator.acceptsCallbacks(id))
        XCTAssertTrue(coordinator.isSessionActive)
        coordinator.finish(id)
        coordinator.showHistory()
        XCTAssertEqual(histories.count, 1)
    }
}
