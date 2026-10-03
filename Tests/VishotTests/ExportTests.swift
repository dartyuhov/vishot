import XCTest
@testable import Vishot

final class ExportTests: XCTestCase {
    func testPixelCropRectAtScaleOneRoundsToWholePixels() {
        let rect = AnnotationRenderer.pixelRect(
            for: CGRect(x: 0.3, y: 0.6, width: 1.4, height: 1.2), scale: 1, imageSize: CGSize(width: 4, height: 4)
        )
        // x: 0.3 … 1.7 → 0 … 2, y: 0.6 … 1.8 → 1 … 2.
        XCTAssertEqual(rect, CGRect(x: 0, y: 1, width: 2, height: 1))
    }

    func testPixelCropRectAtScaleTwo() {
        let rect = AnnotationRenderer.pixelRect(
            for: CGRect(x: 10, y: 20, width: 30, height: 40), scale: 2, imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    func testPixelCropRectIsClampedToTheImage() {
        let rect = AnnotationRenderer.pixelRect(
            for: CGRect(x: 90, y: -10, width: 50, height: 30), scale: 2, imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(rect, CGRect(x: 180, y: 0, width: 20, height: 40))
    }

    func testExportWithoutChangesKeepsTheImageSize() throws {
        let image = try XCTUnwrap(Self.numberedImage())
        let doc = EditDocument(image: image, scale: 2)
        let output = try XCTUnwrap(AnnotationRenderer.export(doc))
        XCTAssertEqual(output.width, 4)
        XCTAssertEqual(output.height, 4)
    }

    func testExportCropsAFourByFourImageToTheCropPixels() throws {
        let image = try XCTUnwrap(Self.numberedImage())
        var doc = EditDocument(image: image, scale: 1)
        doc.crop = CGRect(x: 1, y: 2, width: 2, height: 1)
        doc.annotations = [.rect(CGRect(x: -50, y: -50, width: 1, height: 1), color: .red)]

        let output = try XCTUnwrap(AnnotationRenderer.export(doc))
        XCTAssertEqual(output.width, 2)
        XCTAssertEqual(output.height, 1)
        // Pixels are numbered row by row from the top-left, so the crop starts at row 2, column 1.
        XCTAssertEqual(Self.redValues(of: output), [9, 10])
    }

    func testExportAtScaleTwoCropsInPoints() throws {
        let image = try XCTUnwrap(Self.numberedImage())
        var doc = EditDocument(image: image, scale: 2)
        doc.crop = CGRect(x: 0.5, y: 0, width: 1.5, height: 0.5)

        let output = try XCTUnwrap(AnnotationRenderer.export(doc))
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 1)
        XCTAssertEqual(Self.redValues(of: output), [1, 2, 3])
    }

    /// A 4×4 image whose red channel numbers the pixels 0…15, row by row from the top.
    private static func numberedImage() -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: 4 * 4 * 4)
        for pixel in 0..<16 {
            bytes[pixel * 4] = UInt8(pixel)
            bytes[pixel * 4 + 1] = 0
            bytes[pixel * 4 + 2] = 0
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The red channel of every pixel, row by row from the top, read back in the image's color space.
    private static func redValues(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
    }
}
