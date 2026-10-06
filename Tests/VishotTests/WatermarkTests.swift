import XCTest
@testable import Vishot

final class WatermarkTests: XCTestCase {
    func testBadgeSitsInTheBottomRightCorner() throws {
        let size = CGSize(width: 800, height: 600)
        let badge = try XCTUnwrap(Watermark.badgeRect(in: size))
        XCTAssertEqual(badge.maxX, size.width - Watermark.margin, accuracy: 0.001)
        XCTAssertEqual(badge.maxY, size.height - Watermark.margin, accuracy: 0.001)
        XCTAssertGreaterThan(badge.width, badge.height)
    }

    func testBadgeIsLeftOutOfSmallImages() {
        XCTAssertNil(Watermark.badgeRect(in: CGSize(width: 120, height: 40)))
    }

    func testApplyKeepsThePixelSize() throws {
        let image = try XCTUnwrap(Self.whiteImage(width: 400, height: 300))
        let output = Watermark.apply(to: image, scale: 1)
        XCTAssertEqual(output.width, 400)
        XCTAssertEqual(output.height, 300)
    }

    func testApplyDrawsTheBadgeAndNothingElse() throws {
        let image = try XCTUnwrap(Self.whiteImage(width: 400, height: 300))
        let badge = try XCTUnwrap(Watermark.badgeRect(in: CGSize(width: 400, height: 300)))
        let output = Watermark.apply(to: image, scale: 1)
        // Inside the pill's left padding: the dark fill, not the text.
        XCTAssertLessThan(Self.red(of: output, x: Int(badge.minX) + 4, y: Int(badge.midY)), 100)
        XCTAssertEqual(Self.red(of: output, x: 0, y: 0), 255)
        XCTAssertEqual(Self.red(of: output, x: Int(badge.minX) - 2, y: Int(badge.midY)), 255)
    }

    func testApplyAtScaleTwoDrawsInPoints() throws {
        let image = try XCTUnwrap(Self.whiteImage(width: 800, height: 600))
        let badge = try XCTUnwrap(Watermark.badgeRect(in: CGSize(width: 400, height: 300)))
        let output = Watermark.apply(to: image, scale: 2)
        XCTAssertLessThan(Self.red(of: output, x: Int(badge.minX + 4) * 2, y: Int(badge.midY) * 2), 100)
        XCTAssertEqual(Self.red(of: output, x: Int(badge.minX - 2) * 2, y: Int(badge.midY) * 2), 255)
    }

    func testApplyReturnsSmallImagesUnchanged() throws {
        let image = try XCTUnwrap(Self.whiteImage(width: 120, height: 40))
        XCTAssertTrue(Watermark.apply(to: image, scale: 1) === image)
    }

    private static func whiteImage(width: Int, height: Int) -> CGImage? {
        let bytes = [UInt8](repeating: 255, count: width * height * 4)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The red channel of the pixel at `x`, `y`, counted from the top-left.
    private static func red(of image: CGImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes[(y * image.width + x) * 4]
    }
}
