import XCTest
@testable import Vishot

final class EditAreaTests: XCTestCase {
    func testCornerHitTestingTakesPriorityOverEdges() {
        let area = EditArea(rect: CGRect(x: 20, y: 30, width: 200, height: 100),
                            bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(area.hitTest(CGPoint(x: 18, y: 32)), .topLeft)
        XCTAssertEqual(area.hitTest(CGPoint(x: 100, y: 30)), .top)
        XCTAssertNil(area.hitTest(CGPoint(x: 100, y: 80)))
        XCTAssertEqual(EditArea.Handle.topLeft.cycled(by: -1), .bottomLeft)
        XCTAssertEqual(EditArea.Handle.bottomLeft.cycled(by: 1), .topLeft)
    }

    func testDisplayChoiceUsesLargestIntersectionAndLocalCropCoordinates() throws {
        let target = CGRect(x: -100, y: 50, width: 400, height: 200)
        let displays = [CGRect(x: -800, y: 0, width: 800, height: 600),
                        CGRect(x: 0, y: 0, width: 1000, height: 700)]
        let selection = try XCTUnwrap(EditArea.displaySelection(for: target, displays: displays))
        XCTAssertEqual(selection.index, 1)
        XCTAssertEqual(selection.crop, CGRect(x: 0, y: 50, width: 300, height: 200))
        XCTAssertNil(EditArea.displaySelection(for: CGRect(x: 2000, y: 0, width: 50, height: 50), displays: displays))
    }

    func testCornerExpansionKeepsOppositeCornerAndClampsToDisplay() {
        var area = EditArea(rect: CGRect(x: 100, y: 100, width: 200, height: 150),
                            bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        area.resize(.topLeft, to: CGPoint(x: -50, y: 20))
        XCTAssertEqual(area.rect, CGRect(x: 0, y: 20, width: 300, height: 230))
        area.resize(.topLeft, to: CGPoint(x: 500, y: 500))
        XCTAssertEqual(area.rect, CGRect(x: 299, y: 249, width: 1, height: 1))
    }
}
