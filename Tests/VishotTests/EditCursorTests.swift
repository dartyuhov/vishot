import XCTest
@testable import Vishot

final class EditCursorTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)

    func testStartsAtTheCenter() {
        XCTAssertEqual(EditCursor(size: size).position, CGPoint(x: 100, y: 50))
    }

    func testStepsAreEightTenPointFourAndSixtyFourPoints() {
        var cursor = EditCursor(size: size)
        cursor.move(.right, speed: .normal)
        assertPosition(cursor, 110.4, 50)
        cursor.move(.left, speed: .fast)
        assertPosition(cursor, 46.4, 50)
        cursor.move(.down, speed: .slow)
        assertPosition(cursor, 46.4, 58)
        cursor.move(.up, speed: .normal)
        assertPosition(cursor, 46.4, 47.6)
    }

    private func assertPosition(_ cursor: EditCursor, _ x: CGFloat, _ y: CGFloat, line: UInt = #line) {
        XCTAssertEqual(cursor.position.x, x, accuracy: 0.001, line: line)
        XCTAssertEqual(cursor.position.y, y, accuracy: 0.001, line: line)
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
