import XCTest
@testable import Vishot

final class NavigatorTests: XCTestCase {
    private func target(_ frame: CGRect) -> CaptureTarget {
        CaptureTarget(kind: .window(0), frame: frame, anchor: CGPoint(x: frame.midX, y: frame.midY), label: "")
    }

    func testTiledNeighborBeatsCloserDiagonalOne() {
        let targets = [
            target(CGRect(x: 0, y: 0, width: 400, height: 400)),
            // Diagonal: closer along the axis, but no vertical overlap.
            target(CGRect(x: 420, y: 420, width: 100, height: 100)),
            // Tiled: farther, but shares rows with the current target.
            target(CGRect(x: 700, y: 0, width: 400, height: 400)),
        ]
        XCTAssertEqual(Navigator.neighbor(of: 0, in: targets, toward: .right), 2)
    }

    func testReturnsNilWithoutCandidateInDirection() {
        let targets = [
            target(CGRect(x: 0, y: 0, width: 400, height: 400)),
            target(CGRect(x: 500, y: 0, width: 400, height: 400)),
        ]
        XCTAssertNil(Navigator.neighbor(of: 0, in: targets, toward: .left))
        XCTAssertNil(Navigator.neighbor(of: 0, in: targets, toward: .up))
        XCTAssertNil(Navigator.neighbor(of: 0, in: targets, toward: .down))
    }

    func testMovesBetweenDisplaysOfDifferentHeights() {
        let targets = [
            target(CGRect(x: 0, y: 0, width: 1512, height: 982)),
            target(CGRect(x: 1512, y: -200, width: 1920, height: 1080)),
        ]
        XCTAssertEqual(Navigator.neighbor(of: 0, in: targets, toward: .right), 1)
        XCTAssertEqual(Navigator.neighbor(of: 1, in: targets, toward: .left), 0)
    }

    func testMovesBetweenElementRegionsOfAWindow() {
        let sidebar = target(CGRect(x: 0, y: 0, width: 250, height: 900))
        let header = target(CGRect(x: 250, y: 0, width: 950, height: 60))
        let content = target(CGRect(x: 250, y: 60, width: 950, height: 840))
        let targets = [sidebar, header, content]

        // The sidebar's centre is closer, but the header sits directly above the content.
        XCTAssertEqual(Navigator.neighbor(of: 2, in: targets, toward: .up), 1)
        XCTAssertEqual(Navigator.neighbor(of: 1, in: targets, toward: .left), 0)
        XCTAssertNil(Navigator.neighbor(of: 2, in: targets, toward: .down))
    }
}
