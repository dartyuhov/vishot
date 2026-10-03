import XCTest
@testable import Vishot

final class EditCursorTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)

    func testStartsAtTheCenter() {
        XCTAssertEqual(EditCursor(size: size).position, CGPoint(x: 100, y: 50))
    }

    func testTapStepsAreEightTwentyAndSixtyFourPoints() {
        var cursor = EditCursor(size: size)
        cursor.move(.right, speed: .normal)
        assertPosition(cursor, 120, 50)
        cursor.move(.left, speed: .fast)
        assertPosition(cursor, 56, 50)
        cursor.move(.down, speed: .slow)
        assertPosition(cursor, 56, 58)
        cursor.move(.up, speed: .normal)
        assertPosition(cursor, 56, 38)
    }

    func testMoveByAVectorIsClampedToTheImage() {
        var cursor = EditCursor(size: size)
        cursor.move(by: CGVector(dx: 12.5, dy: -7))
        assertPosition(cursor, 112.5, 43)
        cursor.move(by: CGVector(dx: 500, dy: 500))
        assertPosition(cursor, 200, 100)
    }

    func testHeldDirectionsCombineIntoADiagonal() {
        XCTAssertEqual(CursorGlide.vector([.up, .right]), CGVector(dx: 1, dy: -1))
        XCTAssertEqual(CursorGlide.vector([.down, .left]), CGVector(dx: -1, dy: 1))
        XCTAssertEqual(CursorGlide.vector([.left, .right, .down]), CGVector(dx: 0, dy: 1))
        // h and ← held together are one direction, not double speed.
        XCTAssertEqual(CursorGlide.vector([.left, .left]), CGVector(dx: -1, dy: 0))
    }

    func testGlideStartsAfterAShortHoldAndSpeedsUp() {
        XCTAssertEqual(CursorGlide.speed(.normal, heldFor: 0.1), 0)
        XCTAssertEqual(CursorGlide.speed(.normal, heldFor: 0.15), 700, accuracy: 0.001)
        XCTAssertEqual(CursorGlide.speed(.normal, heldFor: 0.5), 1550, accuracy: 0.001)
        XCTAssertEqual(CursorGlide.speed(.normal, heldFor: 0.85), 2400, accuracy: 0.001)
        XCTAssertEqual(CursorGlide.speed(.normal, heldFor: 5), 2400, accuracy: 0.001)
    }

    func testSlowAndFastGlidesKeepOneSpeed() {
        XCTAssertEqual(CursorGlide.speed(.slow, heldFor: 0.1), 0)
        XCTAssertEqual(CursorGlide.speed(.slow, heldFor: 0.2), 160)
        XCTAssertEqual(CursorGlide.speed(.slow, heldFor: 3), 160)
        XCTAssertEqual(CursorGlide.speed(.fast, heldFor: 0.2), 3200)
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
