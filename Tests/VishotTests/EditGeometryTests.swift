import XCTest
@testable import Vishot

final class EditGeometryTests: XCTestCase {
    private let expected = CGRect(x: 10, y: 20, width: 30, height: 40)

    func testRectFromCornersIsTheSameForAllFourDrawingDirections() {
        XCTAssertEqual(CGRect(corners: CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)), expected)
        XCTAssertEqual(CGRect(corners: CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20)), expected)
        XCTAssertEqual(CGRect(corners: CGPoint(x: 40, y: 20), CGPoint(x: 10, y: 60)), expected)
        XCTAssertEqual(CGRect(corners: CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 20)), expected)
    }

    func testAMoveShorterThanThreePointsIsAClick() {
        let start = CGPoint(x: 100, y: 100)
        XCTAssertTrue(Drag.isClick(from: start, to: start))
        XCTAssertTrue(Drag.isClick(from: start, to: CGPoint(x: 102, y: 102)))
        XCTAssertFalse(Drag.isClick(from: start, to: CGPoint(x: 103, y: 100)))
        XCTAssertFalse(Drag.isClick(from: start, to: CGPoint(x: 97, y: 98)))
    }
}
