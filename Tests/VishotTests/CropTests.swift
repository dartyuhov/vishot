import XCTest
@testable import Vishot

final class CropTests: XCTestCase {
    private let window = CGRect(x: 100, y: 200, width: 1000, height: 800)
    private let retinaImage = CGSize(width: 2000, height: 1600)

    func testConvertsElementToPixelsRelativeToTheWindowOnRetina() {
        let crop = Capturer.cropRect(
            for: CGRect(x: 110, y: 220, width: 50, height: 30),
            in: window, scale: 2, imageSize: retinaImage
        )
        XCTAssertEqual(crop, CGRect(x: 20, y: 40, width: 100, height: 60))
    }

    func testRoundsFractionalEdgesOutward() {
        let crop = Capturer.cropRect(
            for: CGRect(x: 110.25, y: 220, width: 50, height: 30.5),
            in: window, scale: 2, imageSize: retinaImage
        )
        // x: 20.5 … 120.5 → 20 … 121, y: 40 … 101.
        XCTAssertEqual(crop, CGRect(x: 20, y: 40, width: 101, height: 61))
    }

    func testClampsElementPartlyOutsideTheWindow() {
        let crop = Capturer.cropRect(
            for: CGRect(x: 1050, y: 150, width: 200, height: 100),
            in: window, scale: 2, imageSize: retinaImage
        )
        // x: 1900 … 2300 → 1900 … 2000, y: -100 … 100 → 0 … 100.
        XCTAssertEqual(crop, CGRect(x: 1900, y: 0, width: 100, height: 100))
    }

    func testReturnsNilForElementFullyOutsideTheWindow() {
        let crop = Capturer.cropRect(
            for: CGRect(x: 1200, y: 200, width: 200, height: 100),
            in: window, scale: 2, imageSize: retinaImage
        )
        XCTAssertNil(crop)
    }
}
