import XCTest
@testable import Vishot

final class RegionSelectionTests: XCTestCase {
    private let expected = CGRect(x: 10, y: 20, width: 30, height: 40)

    func testTwoCornersFromTheKeyboardMakeARegionInAnyDirection() {
        var selection = RegionSelection()
        XCTAssertTrue(selection.corner(at: CGPoint(x: 40, y: 60)))
        XCTAssertEqual(selection.rect(to: CGPoint(x: 10, y: 20)), expected)
        XCTAssertNil(selection.region)
        XCTAssertTrue(selection.corner(at: CGPoint(x: 10, y: 20)))
        XCTAssertEqual(selection.region, expected)
        XCTAssertNil(selection.anchor)
        // The finished region stays put while the cursor moves on.
        XCTAssertEqual(selection.rect(to: CGPoint(x: 500, y: 500)), expected)
    }

    func testCornersAreRoundedToWholePoints() {
        var selection = RegionSelection()
        _ = selection.corner(at: CGPoint(x: 10.4, y: 19.6))
        _ = selection.corner(at: CGPoint(x: 39.5, y: 60.2))
        XCTAssertEqual(selection.region, expected)
    }

    func testAnEmptyRegionIsDroppedAndKeepsTheOldOne() {
        var selection = RegionSelection()
        _ = selection.corner(at: CGPoint(x: 10, y: 20))
        _ = selection.corner(at: CGPoint(x: 40, y: 60))
        _ = selection.corner(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(selection.corner(at: CGPoint(x: 100, y: 300)))
        XCTAssertNil(selection.anchor)
        XCTAssertEqual(selection.region, expected)
    }

    func testANewRegionReplacesTheOldOne() {
        var selection = RegionSelection()
        _ = selection.corner(at: CGPoint(x: 0, y: 0))
        _ = selection.corner(at: CGPoint(x: 5, y: 5))
        _ = selection.corner(at: CGPoint(x: 10, y: 20))
        XCTAssertTrue(selection.finish(at: CGPoint(x: 40, y: 60)))
        XCTAssertEqual(selection.region, expected)
    }

    func testFinishWithNothingBeingDrawnKeepsTheRegion() {
        var selection = RegionSelection()
        XCTAssertTrue(selection.finish(at: CGPoint(x: 1, y: 1)))
        XCTAssertNil(selection.region)
    }

    func testCancelDropsOnlyTheRegionBeingDrawn() {
        var selection = RegionSelection()
        _ = selection.corner(at: CGPoint(x: 10, y: 20))
        _ = selection.corner(at: CGPoint(x: 40, y: 60))
        _ = selection.corner(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(selection.cancel())
        XCTAssertEqual(selection.rect(to: CGPoint(x: 200, y: 200)), expected)
        XCTAssertFalse(selection.cancel())
        XCTAssertEqual(selection.region, expected)
    }

    func testADragDrawsFromWhereThePressStarted() {
        var selection = RegionSelection()
        selection.press(at: CGPoint(x: 10, y: 20))
        XCTAssertFalse(selection.isIdle)
        selection.drag(to: CGPoint(x: 11, y: 21))
        XCTAssertNil(selection.anchor, "a move shorter than a click doesn't start a region")
        selection.drag(to: CGPoint(x: 30, y: 30))
        XCTAssertEqual(selection.anchor, CGPoint(x: 10, y: 20))
        XCTAssertEqual(selection.release(at: CGPoint(x: 40, y: 60)), .finished)
        XCTAssertEqual(selection.region, expected)
        XCTAssertTrue(selection.isIdle)
    }

    func testAClickInsideTheRegionAsksToCopyIt() {
        var selection = RegionSelection()
        _ = selection.corner(at: CGPoint(x: 10, y: 20))
        _ = selection.corner(at: CGPoint(x: 40, y: 60))
        selection.press(at: CGPoint(x: 20, y: 30))
        XCTAssertEqual(selection.release(at: CGPoint(x: 21, y: 30)), .clickInRegion)
        selection.press(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(selection.release(at: CGPoint(x: 100, y: 100)), .none)
        XCTAssertEqual(selection.region, expected)
    }

    func testAClickFinishesARegionAnchoredFromTheKeyboard() {
        var selection = RegionSelection()
        _ = selection.corner(at: CGPoint(x: 10, y: 20))
        selection.press(at: CGPoint(x: 40, y: 60))
        XCTAssertEqual(selection.release(at: CGPoint(x: 40, y: 60)), .finished)
        XCTAssertEqual(selection.region, expected)
    }

    func testADragBackToItsStartIsEmpty() {
        var selection = RegionSelection()
        selection.press(at: CGPoint(x: 10, y: 20))
        selection.drag(to: CGPoint(x: 50, y: 50))
        XCTAssertEqual(selection.release(at: CGPoint(x: 10, y: 20)), .empty)
        XCTAssertNil(selection.region)
    }
}
