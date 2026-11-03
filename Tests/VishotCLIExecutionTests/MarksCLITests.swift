import XCTest
import ImageIO
import VishotCLIExecution

final class MarksCLITests: XCTestCase {
    func testSmallPixelRectangleKeepsAnUnmarkedInteriorThroughCompiledCLI() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        try fixture.png().write(to: input)
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"rect","x":6,"y":6,"width":12,"height":12,"color":"red"}]}"#])
        XCTAssertEqual(result.status, 0)
        let annotation = try XCTUnwrap(try object(result.data)["annotation"] as? [String: Any])
        let url = URL(fileURLWithPath: try XCTUnwrap(annotation["path"] as? String))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let pixels = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        XCTAssertEqual(pixels[(13 * 320 + 13) * 4 + 3], 0, "The rectangle and its shadow leave interior visible")
        let border = (7 * 320 + 10) * 4
        XCTAssertGreaterThan(Int(pixels[border]), Int(pixels[border + 1]) + 50)
        XCTAssertEqual(pixels[border + 3], 255)
    }

    func testInvalidMixedBatchReportsEveryIdentifiableIndexedFieldAndPublishesNothing() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        let original = try fixture.png()
        try original.write(to: input)
        let batch = #"{"schemaVersion":1,"annotations":[{"type":"text","x":0,"y":0,"text":"valid"},{"type":"arrow","from":{"x":-1,"y":true,"z":0},"to":{"x":320,"y":"NaN"},"color":"blue","width":3},{"type":"arrow","from":{"x":3,"y":4},"to":{"x":3,"y":4}},{"type":"rect","x":300,"y":230,"width":21,"height":11,"color":false,"text":"extra"},{"type":"rect","x":null,"y":-1,"width":0,"height":-2},{"type":"arrow","from":[],"to":{}},{"type":"circle","x":0,"y":0,"text":"valid"}]}"#
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations", batch])
        XCTAssertEqual(result.status, 2)
        let error = try XCTUnwrap(try object(result.data)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_annotations")
        let problems = try XCTUnwrap(error["problems"] as? [[String: Any]])
        let expected = [1: ["from.x", "from.y", "from.z", "to.x", "to.y", "color", "width"],
                        2: ["to"], 3: ["width", "height", "color", "text"],
                        4: ["x", "y", "width", "height"], 5: ["from", "to.x", "to.y"], 6: ["type"]]
        XCTAssertEqual(problems.count, 20)
        for (index, fields) in expected {
            let indexed = problems.filter { $0["index"] as? Int == index }
            XCTAssertEqual(Set(indexed.compactMap { $0["field"] as? String }),
                           Set(fields.map { "annotations[\(index)].\($0)" }))
            XCTAssertTrue(indexed.allSatisfy { !($0["reason"] as? String ?? "").isEmpty })
        }
        XCTAssertTrue(problems.contains { ($0["reason"] as? String)?.contains("320") == true })
        XCTAssertTrue(problems.contains { ($0["reason"] as? String)?.contains("purple") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testMarksRejectNonfiniteJSONNumbersAndNonNumericGeometry() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        try fixture.png().write(to: input)
        for value in ["1e400", "NaN", "Infinity", "-Infinity", "true", "null", #""1""#, "[]", "{}"] {
            let batch = "{\"schemaVersion\":1,\"annotations\":[{\"type\":\"arrow\",\"from\":{\"x\":\(value),\"y\":0},\"to\":{\"x\":10,\"y\":10}},{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":\(value),\"height\":10}]}"
            let result = try fixture.run(["annotate", "--input", input.path, "--annotations", batch])
            XCTAssertEqual(result.status, 2, value)
            let error = try XCTUnwrap(try object(result.data)["error"] as? [String: Any])
            XCTAssertTrue(["invalid_json", "invalid_annotations"].contains(error["code"] as? String ?? ""))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
    }

    func testOutOfImageAndMissingMarkGeometryNeverGetsClampedOrSkipped() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        try fixture.png().write(to: input)
        let batch = #"{"schemaVersion":1,"annotations":[{"type":"arrow","from":{"x":0,"y":240},"to":{"x":-1,"y":0}},{"type":"rect","x":320,"y":240,"width":1,"height":1},{"type":"rect","x":0,"y":0},{"type":"arrow"},{"type":42,"x":0,"y":0,"text":"Hi"}]}"#
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations", batch])
        XCTAssertEqual(result.status, 2)
        let error = try XCTUnwrap(try object(result.data)["error"] as? [String: Any])
        let problems = try XCTUnwrap(error["problems"] as? [[String: Any]])
        XCTAssertEqual(Set(problems.compactMap { $0["field"] as? String }), Set([
            "annotations[0].from.y", "annotations[0].to.x", "annotations[1].x", "annotations[1].y",
            "annotations[2].width", "annotations[2].height", "annotations[3].from", "annotations[3].to", "annotations[4].type"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
    }

    func testMarksAcceptAllSixColorsDefaultPurpleAndExactImageEdges() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        try fixture.png().write(to: input)
        for type in ["arrow", "rect"] {
            var outputs: [[UInt8]] = []
            for color in [nil, "purple", "red", "yellow", "green", "white", "black"] as [String?] {
                var mark: [String: Any] = type == "arrow"
                    ? ["type": type, "from": ["x": 0, "y": 0], "to": ["x": 319.5, "y": 239.5]]
                    : ["type": type, "x": 0, "y": 0, "width": 320, "height": 240]
                if let color { mark["color"] = color }
                let json = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "annotations": [mark]])
                let result = try fixture.run(["annotate", "--input", input.path, "--annotations", String(decoding: json, as: UTF8.self)])
                XCTAssertEqual(result.status, 0, String(decoding: result.data, as: UTF8.self))
                let annotation = try XCTUnwrap(try object(result.data)["annotation"] as? [String: Any])
                let url = URL(fileURLWithPath: try XCTUnwrap(annotation["path"] as? String))
                let png = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let pixels = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(png, 0, nil)))
                XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
                outputs.append(pixels)
            }
            XCTAssertEqual(outputs[0], outputs[1])
            XCTAssertEqual(Set(outputs.dropFirst().map { Data($0) }).count, 6)
        }
    }

    func testMixedBatchThroughBothJSONInputsPreservesOrderDimensionsAndSource() throws {
        let fixture = try AnnotationCLITests.Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        let original = try fixture.png(dpi: 144, marker: true)
        try original.write(to: input)
        let batch = #"{"schemaVersion":1,"annotations":[{"type":"text","x":10,"y":10,"text":"Hi"},{"type":"arrow","from":{"x":30,"y":100},"to":{"x":150,"y":100},"color":"red"},{"type":"rect","x":30,"y":100,"width":120,"height":60,"color":"green"}]}"#
        let file = fixture.root.appendingPathComponent("marks.json")
        try Data(batch.utf8).write(to: file)
        for style in ["pixel", "smooth"] {
            try fixture.configure(style)
            var outputs: [[UInt8]] = []
            for source in [["--annotations", batch], ["--annotations-file", file.path]] {
                let result = try fixture.run(["annotate", "--input", input.path] + source)
                XCTAssertEqual(result.status, 0, String(decoding: result.data, as: UTF8.self))
                let response = try object(result.data)
                let annotation = try XCTUnwrap(response["annotation"] as? [String: Any])
                XCTAssertEqual(annotation["style"] as? String, style)
                XCTAssertEqual(annotation["openingStatus"] as? String, "not_requested")
                let url = URL(fileURLWithPath: try XCTUnwrap(annotation["path"] as? String))
                let png = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(png, 0, nil))
                XCTAssertEqual(image.width, 320)
                XCTAssertEqual(image.height, 240)
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(png, 0, nil) as? [CFString: Any])
                XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Double), 144, accuracy: 0.03)
                let pixels = try rgba(image)
                // Later green rectangle crosses the red arrow's shaft at public pixel (90,100).
                let i = (100 * 320 + 90) * 4
                XCTAssertGreaterThan(Int(pixels[i + 1]), Int(pixels[i]) + 20)
                XCTAssertEqual(Array(pixels[((230 * 320 + 310) * 4)..<((230 * 320 + 310) * 4 + 4)]), [0, 0, 0, 0])
                outputs.append(pixels)
            }
            XCTAssertEqual(outputs[0], outputs[1])
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}
