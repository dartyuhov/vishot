import XCTest
@testable import Vishot

final class SetupTests: XCTestCase {
    func testDoneDoesNotCaptureAndLostAccessCannotCompleteTheGuide() {
        var screen = true
        var accessibility = true
        var complete = false
        var dismissals = 0
        let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true },
                             readAccess: { (screen, accessibility) })
        flow.continueToGuide()
        accessibility = false
        flow.finish(dismiss: { dismissals += 1 })
        XCTAssertFalse(complete, "Losing optional access requires an explicit choice")
        XCTAssertFalse(flow.isShowingGuide)
        flow.continueToGuide(withoutAccessibility: true)
        screen = false
        flow.finish(dismiss: { dismissals += 1 })
        XCTAssertFalse(complete)
        XCTAssertEqual(dismissals, 0)
        screen = true
        flow.continueToGuide(withoutAccessibility: true)
        flow.finish(dismiss: { dismissals += 1 })
        XCTAssertTrue(complete)
        XCTAssertEqual(dismissals, 1)
    }

    func testDismissalUsesFreshRequiredAccessAndNeverCompletesSetup() {
        var screen = true
        var quits = 0
        let flow = SetupFlow(isComplete: { false }, rememberCompletion: { XCTFail("Closing is not completion") },
                             readAccess: { (screen, false) })
        flow.continueToGuide(withoutAccessibility: true)
        flow.dismissIncomplete(quit: { quits += 1 })
        XCTAssertEqual(quits, 0)
        XCTAssertFalse(flow.isShowingGuide)
        XCTAssertTrue(flow.needsSetup)
        screen = false
        flow.dismissIncomplete(quit: { quits += 1 })
        XCTAssertEqual(quits, 1)
    }

    func testOnlyFinishingGuideCompletesSetupAndDismissesBeforeCapture() {
        var complete = false
        var effects: [String] = []
        let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true; effects.append("remember") },
                             readAccess: { (true, false) })
        XCTAssertTrue(flow.needsSetup)
        flow.finish(dismiss: { effects.append("dismiss") }, capture: { effects.append("capture") })
        XCTAssertTrue(effects.isEmpty)
        flow.continueToGuide(withoutAccessibility: true)
        XCTAssertFalse(complete)
        flow.finish(dismiss: { effects.append("dismiss") }, capture: { effects.append("capture") })
        XCTAssertEqual(effects, ["remember", "dismiss", "capture"])
        XCTAssertFalse(flow.needsSetup)
        let relaunched = SetupFlow(isComplete: { complete }, rememberCompletion: {}, readAccess: { (false, false) })
        XCTAssertFalse(relaunched.needsSetup, "Revocation after completion does not introduce a new recovery policy")
    }

    func testRequiredAccessAndExplicitOptionalChoiceGateTheGuide() {
        var screen = false
        var accessibility = false
        let flow = SetupFlow(isComplete: { false }, rememberCompletion: {},
                             readAccess: { (screen, accessibility) })
        flow.continueToGuide(withoutAccessibility: true)
        XCTAssertFalse(flow.isShowingGuide)
        screen = true
        flow.refresh()
        flow.continueToGuide()
        XCTAssertFalse(flow.isShowingGuide)
        flow.continueToGuide(withoutAccessibility: true)
        XCTAssertTrue(flow.isShowingGuide)
        accessibility = true
        flow.refresh()
        XCTAssertTrue(flow.accessibilityAllowed)
    }
}
