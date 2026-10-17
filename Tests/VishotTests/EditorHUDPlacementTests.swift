import XCTest
@testable import Vishot

final class EditorHUDPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func placement(_ selection: CGRect, hidden: Bool = false) -> EditorHUDPlacement {
        EditorHUDPlacement.choose(around: selection, in: bounds,
            horizontal: CGSize(width: 1100, height: 120), vertical: CGSize(width: 300, height: 600),
            compact: CGSize(width: 280, height: 50), hidden: hidden)
    }

    func testPrefersHorizontalOutsideWhenThereIsRoomBelow() {
        let selection = CGRect(x: 100, y: 300, width: 1200, height: 500)
        let result = placement(selection)
        XCTAssertEqual(result.layout, .horizontal)
        XCTAssertLessThan(result.frame.maxY, selection.minY)
        XCTAssertTrue(bounds.contains(result.frame))
    }

    func testFullHeightSelectionUsesFreeSideAndVerticalLayout() {
        for selection in [CGRect(x: 0, y: 0, width: 1000, height: 900),
                          CGRect(x: 440, y: 0, width: 1000, height: 900)] {
            let result = placement(selection)
            XCTAssertEqual(result.layout, .vertical)
            XCTAssertFalse(selection.intersects(result.frame))
            XCTAssertTrue(bounds.contains(result.frame))
        }
    }

    func testUsesAboveWhenBelowDoesNotFit() {
        let selection = CGRect(x: 0, y: 0, width: 1440, height: 650)
        let result = placement(selection)
        XCTAssertEqual(result.layout, .horizontal)
        XCTAssertGreaterThan(result.frame.minY, selection.maxY)
    }

    func testFullScreenFallsBackInsideAndHiddenHUDUsesCompactSize() {
        let full = placement(bounds)
        XCTAssertEqual(full.layout, .horizontal)
        XCTAssertTrue(bounds.contains(full.frame))
        let hidden = placement(bounds, hidden: true)
        XCTAssertEqual(hidden.layout, .compact)
        XCTAssertEqual(hidden.frame.size, CGSize(width: 280, height: 50))
        XCTAssertTrue(bounds.contains(hidden.frame))
    }

    func testNarrowDisplayUsesVerticalFallbackInsideScreen() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let result = EditorHUDPlacement.choose(around: screen, in: screen,
            horizontal: CGSize(width: 1100, height: 120), vertical: CGSize(width: 300, height: 600),
            compact: CGSize(width: 280, height: 50), hidden: false)
        XCTAssertEqual(result.layout, .vertical)
        XCTAssertTrue(screen.contains(result.frame))
    }
}
