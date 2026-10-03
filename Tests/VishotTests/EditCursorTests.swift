import XCTest
@testable import Vishot

final class EditCursorTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)

    func testStartsAtTheCenter() {
        XCTAssertEqual(EditCursor(size: size).position, CGPoint(x: 100, y: 50))
    }

    func testStepsAreOneEightAndSixtyFourPoints() {
        var cursor = EditCursor(size: size)
        cursor.move(.right, speed: .normal)
        XCTAssertEqual(cursor.position, CGPoint(x: 108, y: 50))
        cursor.move(.left, speed: .fast)
        XCTAssertEqual(cursor.position, CGPoint(x: 44, y: 50))
        cursor.move(.down, speed: .fine)
        XCTAssertEqual(cursor.position, CGPoint(x: 44, y: 51))
        cursor.move(.up, speed: .normal)
        XCTAssertEqual(cursor.position, CGPoint(x: 44, y: 43))
    }

    func testStepsStopAtTheImageEdges() {
        var cursor = EditCursor(size: size)
        cursor.move(.left, speed: .fast)
        cursor.move(.left, speed: .fast)
        cursor.move(.down, speed: .fast)
        XCTAssertEqual(cursor.position, CGPoint(x: 0, y: 100))
    }

    func testMoveToAPointIsClampedToTheImage() {
        var cursor = EditCursor(size: size)
        cursor.move(to: CGPoint(x: 250, y: -20))
        XCTAssertEqual(cursor.position, CGPoint(x: 200, y: 0))
        cursor.move(to: CGPoint(x: 12.5, y: 30))
        XCTAssertEqual(cursor.position, CGPoint(x: 12.5, y: 30))
    }

    func testJumpsToEdgesKeepTheOtherCoordinate() {
        var cursor = EditCursor(size: size)
        cursor.move(to: CGPoint(x: 30, y: 70))
        cursor.jump(.left)
        XCTAssertEqual(cursor.position, CGPoint(x: 0, y: 70))
        cursor.jump(.right)
        XCTAssertEqual(cursor.position, CGPoint(x: 200, y: 70))
        cursor.jump(.top)
        XCTAssertEqual(cursor.position, CGPoint(x: 200, y: 0))
        cursor.jump(.bottom)
        XCTAssertEqual(cursor.position, CGPoint(x: 200, y: 100))
        cursor.jump(.center)
        XCTAssertEqual(cursor.position, CGPoint(x: 100, y: 50))
    }
}
