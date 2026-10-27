import XCTest
import ImageIO
import VishotAgent
@testable import Vishot

final class OpeningTests: XCTestCase {
    func testValidationRenderingEncodingAndWriteFailuresNeverOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var opened: [URL] = []
        let opener: (URL) -> Bool = { opened.append($0); return true }
        let arguments = fixture.arguments + ["--open"]
        func check(_ response: AgentResponse, _ code: String, _ exit: Int32) {
            XCTAssertFalse(response.ok)
            XCTAssertNil(response.annotation)
            XCTAssertEqual(response.error?.code.rawValue, code)
            XCTAssertEqual(response.error?.exitStatus, exit)
            XCTAssertTrue(opened.isEmpty)
        }
        check(AnnotationCommand.execute(["--open"], workspace: fixture.root,
            styleSnapshot: { .pixel }, opener: opener), "invalid_arguments", 2)
        for (json, code) in [("{", "invalid_json"),
                              (#"{"schemaVersion":1,"annotations":[]}"#, "invalid_annotations")] {
            check(AnnotationCommand.execute(["--input", fixture.input.path, "--annotations", json, "--open"],
                workspace: fixture.root, styleSnapshot: { .pixel }, opener: opener), code, 2)
        }
        try Data("broken PNG".utf8).write(to: fixture.input)
        check(AnnotationCommand.execute(arguments, workspace: fixture.root,
            styleSnapshot: { .pixel }, opener: opener), "invalid_image", 2)
        try fixture.original.write(to: fixture.input)
        check(AnnotationCommand.execute(arguments, workspace: fixture.root,
            styleSnapshot: { throw AgentFailure(.invalidArguments, "Invalid settings") }, opener: opener), "invalid_arguments", 2)
        check(AnnotationCommand.execute(arguments, workspace: fixture.root,
            styleSnapshot: { .pixel }, render: { _ in nil }, opener: opener), "rendering_failed", 9)
        check(AnnotationCommand.execute(arguments, workspace: fixture.root,
            styleSnapshot: { .pixel }, encode: { _, _ in nil }, opener: opener), "encoding_failed", 9)
        let folder = fixture.root.appendingPathComponent(".vishot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try Data("preserve prior output".utf8).write(to: folder)
        check(AnnotationCommand.execute(arguments, workspace: fixture.root,
            styleSnapshot: { .pixel }, opener: opener), "output_write_failed", 10)
        XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), "preserve prior output")
    }

    func testFailedOpeningRetainsAnnotationAndReturnsStructuredExit11Failure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var opened: [URL] = []
        let response = AnnotationCommand.execute(fixture.arguments + ["--open"], workspace: fixture.root,
            styleSnapshot: { .pixel }, opener: { opened.append($0); return false })
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(response))
        XCTAssertFalse(decoded.ok)
        let error = try XCTUnwrap(decoded.error)
        XCTAssertEqual(error.code.rawValue, "opening_failed")
        XCTAssertEqual(error.exitStatus, 11)
        let annotation = try XCTUnwrap(decoded.annotation)
        XCTAssertEqual(annotation.openingStatus, "failed")
        XCTAssertEqual(opened.map(\.path), [annotation.path])
        XCTAssertTrue(error.message.contains(annotation.path))
        XCTAssertTrue(error.message.contains("default"))
        try fixture.assertPublished(annotation)
    }

    func testAcceptedOpenReceivesOnlyTheExactCompletelyPublishedResult() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent(".vishot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("older.png")
        try fixture.original.write(to: old)
        var opened: [URL] = []
        let response = AnnotationCommand.execute(fixture.arguments + ["--open"], workspace: fixture.root,
            styleSnapshot: { .pixel }, opener: { url in
                opened.append(url)
                do {
                    try fixture.assertPublished(AgentAnnotationFile(path: url.path, width: 320, height: 240, style: "pixel"))
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
                } catch { XCTFail("The opener must receive an already readable PNG: \(error)") }
                return true
            })
        // Check the machine-readable envelope, not just the in-memory result.
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(response))
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
        let annotation = try XCTUnwrap(decoded.annotation)
        XCTAssertEqual(opened.map(\.path), [annotation.path])
        XCTAssertEqual(annotation.openingStatus, "accepted")
        XCTAssertEqual(try Data(contentsOf: old), fixture.original)
        try fixture.assertPublished(annotation)
    }

    func testDefaultSavesACompletePNGWithoutCallingOpener() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var opened: [URL] = []
        let response = AnnotationCommand.execute(fixture.arguments, workspace: fixture.root,
            styleSnapshot: { .pixel }, opener: { opened.append($0); return true })
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        XCTAssertTrue(opened.isEmpty)
        let annotation = try XCTUnwrap(response.annotation)
        XCTAssertEqual(annotation.openingStatus, "not_requested")
        try fixture.assertPublished(annotation)
    }

    func testOpenIsAnExplicitAnnotationOnlySwitch() throws {
        let arguments = ["--input", "input.png", "--annotations", "{}"]
        XCTAssertFalse(try AgentAnnotationArguments(arguments).open)
        for values in [["--open"] + arguments, arguments + ["--open"]] {
            XCTAssertTrue(try AgentAnnotationArguments(values).open)
        }
        XCTAssertThrowsError(try AgentAnnotationArguments(arguments + ["--open", "--open"]))
        XCTAssertThrowsError(try AgentAnnotationArguments(arguments + ["--open", "true"]))
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation opening \(UUID())")
        let original: Data
        var input: URL { root.appendingPathComponent("source image.png") }
        var arguments: [String] {
            ["--input", input.path, "--annotations",
             #"{"schemaVersion":1,"annotations":[{"type":"text","x":20,"y":30,"text":"Hi"}]}"#]
        }
        init() throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            original = try XCTUnwrap(ImageEncoding.data(try XCTUnwrap(context.makeImage()), scale: 1, type: .png))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original.write(to: input)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func assertPublished(_ annotation: AgentAnnotationFile, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertTrue(annotation.path.hasPrefix(root.path + "/.vishot/annotation-"), file: file, line: line)
            XCTAssertNotEqual(annotation.path, input.path, file: file, line: line)
            XCTAssertEqual(annotation.width, 320, file: file, line: line)
            XCTAssertEqual(annotation.height, 240, file: file, line: line)
            XCTAssertEqual(annotation.style, "pixel", file: file, line: line)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: annotation.path) as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete, file: file, line: line)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
            XCTAssertEqual(image.width, 320, file: file, line: line)
            XCTAssertEqual(image.height, 240, file: file, line: line)
            XCTAssertEqual(CGImageSourceGetStatusAtIndex(source, 0), .statusComplete, file: file, line: line)
            XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: annotation.path)), original, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: input), original, file: file, line: line)
        }
    }
}
