import XCTest
import VishotRendering
import VishotConfiguration
@testable import VishotCLIExecution

final class RenderingIntegrationTests: XCTestCase {
    func testCLIArrowAndRectangleGeometryStyleAndDPIThroughSharedExport() throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let json = Data(#"{"schemaVersion":1,"annotations":[{"type":"arrow","from":{"x":30,"y":60},"to":{"x":150,"y":60},"color":"red"},{"type":"rect","x":30,"y":120,"width":120,"height":60,"color":"green"}]}"#.utf8)
        var shaftThickness: [String: [Int]] = [:]
        for scale: CGFloat in [1, 2] {
            var styles: [Data] = []
            for style in VisualStyle.allCases {
                let document = try AnnotationCommand.document(json: json, image: image, scale: scale, style: style)
                // Public pixels convert once into the editor model's point geometry, in array order.
                XCTAssertEqual(document.annotations, [
                    .arrow(from: CGPoint(x: 30 / scale, y: 60 / scale), to: CGPoint(x: 150 / scale, y: 60 / scale), color: .red),
                    .rect(CGRect(x: 30 / scale, y: 120 / scale, width: 120 / scale, height: 60 / scale), color: .green)])
                let output = try XCTUnwrap(AnnotationRenderer.export(document))
                XCTAssertEqual(output.width, 320)
                XCTAssertEqual(output.height, 240)
                let data = output.dataProvider!.data! as Data
                func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * output.bytesPerRow + x * 4 + 3] }
                XCTAssertGreaterThan(alpha(90, 60), 200, "Arrow shaft uses public pixel coordinates at either DPI")
                shaftThickness[style.rawValue, default: []].append((40..<80).filter { alpha(90, $0) > 200 }.count)
                XCTAssertGreaterThan(alpha(90, 120), 200, "Rectangle top edge stays in place")
                XCTAssertEqual(alpha(90, 150), 0, "Rectangle is an outline")
                XCTAssertEqual(alpha(310, 230), 0, "No watermark")
                let nearTail = (45..<57).flatMap { y in (30..<55).map { x in alpha(x, y) } }.filter { $0 > 0 }.count
                let nearHead = (45..<57).flatMap { y in (125..<150).map { x in alpha(x, y) } }.filter { $0 > 0 }.count
                XCTAssertGreaterThan(nearHead, nearTail, "Arrowhead belongs at to, not from")
                styles.append(data)
            }
            XCTAssertNotEqual(styles[0], styles[1], "Pixel cells and Smooth strokes retain their treatments")
        }
        for thickness in shaftThickness.values {
            XCTAssertGreaterThan(thickness[1], thickness[0], "Retina scales theme-defined arrow thickness without moving endpoints")
        }
    }
}
