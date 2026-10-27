import XCTest
@testable import Vishot

final class PixelArtTests: XCTestCase {
    private typealias Cell = PixelArt.Cell

    func testCellsAreThreePointSquaresFromTheImageTopLeft() {
        XCTAssertEqual(PixelArt.cell(at: CGPoint(x: 2.9, y: 3)), Cell(x: 0, y: 1))
        XCTAssertEqual(PixelArt.cell(at: CGPoint(x: -0.1, y: 0)), Cell(x: -1, y: 0))
        XCTAssertEqual(PixelArt.rect(of: Cell(x: 2, y: 1)), CGRect(x: 6, y: 3, width: 3, height: 3))
    }

    func testLineIncludesBothEndsAndSharesAnEdgeAtEveryStep() {
        let cells = PixelArt.line(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 31, y: 13))
        XCTAssertEqual(cells.first, Cell(x: 0, y: 0))
        XCTAssertEqual(cells.last, Cell(x: 10, y: 4))
        // 10 steps across and 4 down, one cell each.
        XCTAssertEqual(cells.count, 15)
        for (a, b) in zip(cells, cells.dropFirst()) {
            XCTAssertEqual(abs(a.x - b.x) + abs(a.y - b.y), 1)
        }
    }

    func testLineRunsBackwards() {
        let cells = PixelArt.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 1, y: 10))
        XCTAssertEqual(cells, [Cell(x: 3, y: 3), Cell(x: 2, y: 3), Cell(x: 1, y: 3), Cell(x: 0, y: 3)])
    }

    func testTriangleKeepsItsTipAndFillsItsMiddle() {
        let cells = Set(PixelArt.triangle(CGPoint(x: 30, y: 15), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 30)))
        XCTAssertTrue(cells.contains(Cell(x: 10, y: 5)))
        XCTAssertTrue(cells.contains(Cell(x: 3, y: 5)))
        XCTAssertFalse(cells.contains(Cell(x: 9, y: 0)))
    }

    func testOutlineLeavesOutTheOuterCornersAndFillsTheInnerOnes() {
        let cells = Set(PixelArt.outline(CGRect(x: 0, y: 0, width: 15, height: 15)))
        XCTAssertFalse(cells.contains(Cell(x: 0, y: 0)))
        XCTAssertFalse(cells.contains(Cell(x: 4, y: 4)))
        XCTAssertTrue(cells.contains(Cell(x: 1, y: 0)))
        XCTAssertTrue(cells.contains(Cell(x: 1, y: 1)))
        XCTAssertTrue(cells.contains(Cell(x: 3, y: 3)))
        XCTAssertFalse(cells.contains(Cell(x: 2, y: 2)))
    }

    func testTinyOutlineIsFilled() {
        XCTAssertEqual(Set(PixelArt.outline(CGRect(x: 0, y: 0, width: 5, height: 5))).count, 4)
    }

    func testSmallOutlinesLeaveInteriorCellsWhenThereIsRoom() {
        for size: CGFloat in [9, 12] {
            let cells = Set(PixelArt.outline(CGRect(x: 0, y: 0, width: size, height: size)))
            XCTAssertTrue(cells.contains(Cell(x: 1, y: 0)))
            XCTAssertTrue(cells.contains(Cell(x: 0, y: 1)))
            XCTAssertFalse(cells.contains(Cell(x: 1, y: 1)), "A small rectangle is still an outline")
        }
        let narrow = Set(PixelArt.outline(CGRect(x: 0, y: 0, width: 9, height: 30)))
        XCTAssertFalse(narrow.contains(Cell(x: 1, y: 5)))
        XCTAssertTrue(narrow.contains(Cell(x: 0, y: 5)))
    }
}
