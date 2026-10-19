import XCTest
@testable import Vishot

final class ExportTests: XCTestCase {
    func testCleanMarkupUsesSmoothUnsnappedPathsAndSharedPreviewExportAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(160 * scale), height: Int(160 * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let style = ThemeCatalog.clean.annotation
            var document = EditDocument(image: image, scale: scale, annotationStyle: .clean)
            document.annotations = [.rect(CGRect(x: 12.25, y: 12.25, width: 30, height: 30), color: .red),
                .arrow(from: CGPoint(x: 60.25, y: 60.25), to: CGPoint(x: 96.25, y: 80.25), color: .purple),
                .text("one\ntwo", at: CGPoint(x: 20.25, y: 110.25), color: .white)]
            let output = try XCTUnwrap(AnnotationRenderer.export(document))
            let bytes = output.dataProvider!.data! as Data
            let edgeAlpha = bytes[Int(12 * scale) * output.bytesPerRow + Int(20 * scale) * 4 + 3]
            XCTAssertEqual(edgeAlpha, 255, "A centered 3 pt vector stroke covers the top edge")
            let outsideAlpha = bytes[Int(10.75 * scale) * output.bytesPerRow + Int(20 * scale) * 4 + 3]
            XCTAssertGreaterThan(outsideAlpha, 0, "The fractional stroke edge is antialiased")
            XCTAssertLessThan(outsideAlpha, 255)
            let preview = try XCTUnwrap(AnnotationRenderer.imageSpaceContext(drawing: image, scale: scale))
            AnnotationRenderer.draw(document.annotations, in: preview, style: style)
            XCTAssertEqual(preview.makeImage()!.dataProvider!.data! as Data, bytes)
            let a = AnnotationRenderer.textBounds("one\ntwo", at: CGPoint(x: 20, y: 110), style: style)
            let b = AnnotationRenderer.textBounds("one\ntwo", at: CGPoint(x: 20.25, y: 110.25), style: style)
            XCTAssertEqual(b.minX - a.minX, 0.25, accuracy: 0.001)
            XCTAssertEqual(b.minY - a.minY, 0.25, accuracy: 0.001)
            let caret = AnnotationRenderer.caret(after: "one\n", at: CGPoint(x: 20.25, y: 110.25), style: style)
            let emptyCaret = AnnotationRenderer.caret(after: "", at: CGPoint(x: 20.25, y: 110.25), style: style)
            XCTAssertEqual(caret.minX, emptyCaret.minX)
            XCTAssertGreaterThan(caret.minY, emptyCaret.maxY)
            document.crop = CGRect(x: 10, y: 10, width: 100, height: 120)
            let cropped = try XCTUnwrap(AnnotationRenderer.export(document))
            XCTAssertEqual(cropped.width, Int(100 * scale))
            XCTAssertEqual(cropped.height, Int(120 * scale))
            document.annotations = []
            document.crop = nil
            XCTAssertTrue(AnnotationRenderer.export(document) === image)
        }
    }

    func testCleanMarkupAndCropPreserveOriginalPixelsAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            let image = try XCTUnwrap(Self.numberedImage())
            var document = EditDocument(image: image, scale: scale, annotationStyle: .clean)
            XCTAssertTrue(AnnotationRenderer.export(document) === image)
            // Force the markup drawing path away from the source; every numbered source pixel
            // must survive the redraw without interpolation or a coordinate-space shift.
            document.annotations = [.rect(CGRect(x: -50, y: -50, width: 1, height: 1), color: .red)]
            XCTAssertEqual(Self.redValues(of: try XCTUnwrap(AnnotationRenderer.export(document))), Array(0...15).map(UInt8.init))
            document.crop = CGRect(x: 1 / scale, y: 2 / scale, width: 2 / scale, height: 1 / scale)
            XCTAssertEqual(Self.redValues(of: try XCTUnwrap(AnnotationRenderer.export(document))), [9, 10])
            document.annotations = []
            XCTAssertEqual(Self.redValues(of: try XCTUnwrap(AnnotationRenderer.export(document))), [9, 10])
        }
    }

    func testExplicitPixelStyleMatchesLegacyPreviewExportAndTextMeasurement() throws {
        for scale in [CGFloat(1), 2] {
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(160 * scale), height: Int(160 * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            var document = EditDocument(image: image, scale: scale)
            document.annotations = [.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 45), color: .purple),
                .rect(CGRect(x: 12, y: 60, width: 40, height: 30), color: .red),
                .text("one\ntwo", at: CGPoint(x: 20, y: 110), color: .white)]
            let style = ThemeCatalog.pixel.annotation
            let legacy = try XCTUnwrap(AnnotationRenderer.export(document))
            let explicit = try XCTUnwrap(AnnotationRenderer.export(document, style: style))
            let preview = try XCTUnwrap(AnnotationRenderer.imageSpaceContext(drawing: image, scale: scale))
            AnnotationRenderer.draw(document.annotations, in: preview, style: style)
            XCTAssertEqual(explicit.dataProvider!.data! as Data, legacy.dataProvider!.data! as Data)
            XCTAssertEqual(preview.makeImage()!.dataProvider!.data! as Data, explicit.dataProvider!.data! as Data)
            let origin = CGPoint(x: 20, y: 110)
            XCTAssertEqual(AnnotationRenderer.textBounds("one\ntwo", at: origin, style: style),
                           AnnotationRenderer.textBounds("one\ntwo", at: origin))
            XCTAssertEqual(AnnotationRenderer.caret(after: "one\ntwo", at: origin, style: style),
                           AnnotationRenderer.caret(after: "one\ntwo", at: origin))
        }
    }

    func testPixelMarkupKeepsItsCellEdgesAndHardShadowAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            let image = try XCTUnwrap(CGContext(data: nil, width: Int(120 * scale), height: Int(120 * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            var document = EditDocument(image: image, scale: scale)
            document.annotations = [
                .rect(CGRect(x: 12, y: 12, width: 30, height: 30), color: .red),
                .arrow(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 96, y: 60), color: .red),
            ]
            let output = try XCTUnwrap(AnnotationRenderer.export(document))
            func alpha(_ x: Int, _ y: Int) -> UInt8 {
                let data = output.dataProvider!.data! as Data
                // Export's premultiplied-first, little-endian bitmap is BGRA.
                return data[Int(CGFloat(y) * scale) * output.bytesPerRow + Int(CGFloat(x) * scale) * 4 + 3]
            }
            XCTAssertEqual(alpha(12, 12), 0, "Pixel rectangles omit the corner cell")
            XCTAssertEqual(alpha(15, 12), 255)
            XCTAssertEqual(alpha(15, 15), 255, "The inner corner cell is filled")
            XCTAssertEqual(alpha(18, 18), 89, "The hard shadow is one cell down-right")
            XCTAssertEqual(alpha(21, 21), 0)
            XCTAssertEqual(alpha(60, 60), 255)
            XCTAssertEqual(alpha(60, 59), 0, "The shaft starts at a grid edge")
        }
    }

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
