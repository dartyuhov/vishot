import XCTest
@testable import Vishot

final class ThemeOutlineTests: XCTestCase {
    func testCropOutlineAndNonzeroShadowKeepTheRetainedImageHollow() throws {
        let crop = CGRect(x: 30, y: 30, width: 120, height: 90)
        for id in ThemeID.allCases {
            let style = ThemeCatalog.resolve(id).editor
            let path = style.cropOutline.cropPath(around: crop, width: style.cropWidth)
            let samples: [(CGPoint, Bool)] = [
                (CGPoint(x: 90, y: 75), false), // Retained center.
                (CGPoint(x: 31, y: 75), false), // Retained pixels near the edge.
                (CGPoint(x: 20, y: 75), false), // Outside the outline.
                (CGPoint(x: 28.5, y: 75), true),
                (CGPoint(x: 151.5, y: 75), true),
                (CGPoint(x: 90, y: 28.5), true),
                (CGPoint(x: 90, y: 121.5), true),
                (CGPoint(x: 28, y: 28), id == .clean), // Rounded vs. missing pixel corner.
            ]
            for scale: CGFloat in [1, 2] {
                // EditorLayer flips image space into y-up layer coordinates.
                var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                                 tx: 0, ty: 180 * scale)
                let ring = try XCTUnwrap(path.copy(using: &transform))
                for (point, expected) in samples {
                    let local = point.applying(transform)
                    XCTAssertEqual(ring.contains(local, using: .evenOdd), expected,
                                   "\(id) visible outline at \(scale)x, \(point)")
                    XCTAssertEqual(ring.contains(local, using: .winding), expected,
                                   "\(id) shadow at \(scale)x, \(point)")
                }
            }
        }
    }
}
