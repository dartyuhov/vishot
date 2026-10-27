import XCTest
import ImageIO
import UniformTypeIdentifiers
import VishotCLIExecution

final class PNGPrecisionCLITests: XCTestCase {
    func testSixteenBitRGBPNGPreservesUnmarkedLowBitsThroughCompiledCLI() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let samples: [UInt16] = [0x1234, 0x5678, 0x9abc, 0xffff]
        let pixels = (0..<(64 * 64)).flatMap { _ in samples }
        let data = pixels.withUnsafeBytes { Data($0) }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 16,
            bitsPerPixel: 64, bytesPerRow: 64 * 8, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: try XCTUnwrap(CGDataProvider(data: data as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for style in ["pixel", "smooth"] {
            try fixture.configure(style)
            let output = try annotate(image, fixture: fixture)
            XCTAssertEqual(output.bitsPerComponent, 16)
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 16,
                bytesPerRow: 64 * 8, space: space, bitmapInfo: info))
            context.draw(output, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let words = context.data!.assumingMemoryBound(to: UInt16.self)
            // These literal values are not representable at 8 bits. Check the entire unmarked
            // bottom band, not merely the output's declared bit depth or one selected pixel.
            let band = Array(UnsafeBufferPointer(start: words + 56 * 64 * 4, count: 8 * 64 * 4))
            XCTAssertEqual(Set(stride(from: 0, to: band.count, by: 4).map {
                Array(band[$0..<($0 + 4)])
            }), [samples])
            XCTAssertTrue((0..<(64 * 64)).contains {
                Int(words[$0 * 4]) > Int(words[$0 * 4 + 1]) + 10000
            }, "The colored annotation must also be present")
        }
    }

    func testGrayscalePNGAcceptsColoredAnnotationsThroughCompiledCLI() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let image = try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(repeating: 128, count: 64 * 64) as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = try annotate(image, fixture: fixture)
        XCTAssertEqual(output.colorSpace?.model, .rgb)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(output, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertTrue((0..<(64 * 64)).contains { Int(bytes[$0 * 4]) > Int(bytes[$0 * 4 + 1]) + 50 })
        let untouched = (60 * 64 + 60) * 4
        XCTAssertEqual(bytes[untouched], bytes[untouched + 1])
        XCTAssertEqual(bytes[untouched + 1], bytes[untouched + 2])
        XCTAssertEqual(bytes[untouched + 3], 255)
    }

    private func annotate(_ image: CGImage, fixture: AnnotationCLITests.Fixture) throws -> CGImage {
        let input = fixture.root.appendingPathComponent("source.png")
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: input)
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"rect","x":6,"y":6,"width":30,"height":30,"color":"red"}]}"#])
        XCTAssertEqual(result.status, 0, String(decoding: result.data, as: UTF8.self))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let annotation = try XCTUnwrap(json["annotation"] as? [String: Any])
        let path = try XCTUnwrap(annotation["path"] as? String)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
