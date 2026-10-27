import XCTest
import ImageIO
import UniformTypeIdentifiers
import VishotCLIExecution
import VishotAgent
import VishotRendering
import CoreText

final class AnnotationCLITests: XCTestCase {
    func testVersionFollowsActualInstallationThroughSymlinksAndUnrelatedWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = fixture.executable.deletingLastPathComponent().deletingLastPathComponent()
        let link = fixture.root.appendingPathComponent("relative helper link")
        try FileManager.default.createSymbolicLink(atPath: link.path,
            withDestinationPath: "Vishot.app/Contents/Helpers/vishot")
        let workspace = fixture.root.appendingPathComponent("unrelated workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // A plausible CWD resource tree must never override the containing installation.
        try Data("not an installation".utf8).write(to: workspace.appendingPathComponent("Info.plist"))
        for version in ["9.8.7", "9.8.8"] {
            let metadata: [String: Any] = ["CFBundleIdentifier": "com.dartsiukhou.vishot",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let result = try fixture.run(["--version"], executable: link, workspace: workspace)
            XCTAssertEqual(result.status, 0)
            let json = try decode(result.data)
            XCTAssertEqual(json["schemaVersion"] as? Int, 1)
            XCTAssertEqual(json["ok"] as? Bool, true)
            XCTAssertEqual(json["version"] as? String, version)
            XCTAssertNil(json["image"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".vishot").path))
        }
    }

    func testMissingBundledFontsFailBeforePublishingInsteadOfUsingFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = fixture.executable.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.removeItem(at: contents.appendingPathComponent("Resources/Fonts"))
        let input = fixture.root.appendingPathComponent("source.png")
        let original = try fixture.png()
        try original.write(to: input)
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"text","x":20,"y":30,"text":"Hi"}]}"#])
        XCTAssertEqual(result.status, 9)
        XCTAssertEqual((try decode(result.data)["error"] as? [String: Any])?["code"] as? String, "rendering_failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testSymlinkedHelperUsesContainingFontsWithoutGUIBinaryOrCaptureEndpoint() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try AgentEndpoint.containingApp(executableURL: fixture.executable)
        let endpoint = AgentEndpoint(appURL: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.directory))
        let link = fixture.root.appendingPathComponent("linked helper")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.executable)
        let input = fixture.root.appendingPathComponent("font source.png")
        let original = try fixture.png()
        try original.write(to: input)
        let workspace = fixture.root.appendingPathComponent("unrelated workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"text","x":20,"y":30,"text":"Hi"}]}"#], executable: link, workspace: workspace)
        XCTAssertEqual(result.status, 0, String(decoding: result.data, as: UTF8.self))
        let annotation = try XCTUnwrap(try decode(result.data)["annotation"] as? [String: Any])
        XCTAssertTrue((annotation["path"] as? String ?? "").hasPrefix(workspace.path + "/.vishot/"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: try XCTUnwrap(annotation["path"] as? String)) as CFURL, nil))
        let actual = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        Fonts.register(resourceDirectory: app.appendingPathComponent("Contents/Resources"))
        var style = AnnotationCatalog.annotation(.pixel)
        XCTAssertEqual(CTFontCopyPostScriptName(style.font) as String, "Silkscreen-Regular")
        style.snapsTextToGrid = false
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
        let anchor = AnnotationRenderer.textAnchor(topLeft: CGPoint(x: 20, y: 30), text: "Hi", style: style)
        let expected = try XCTUnwrap(AnnotationRenderer.export(EditDocument(image: image, scale: 1,
            annotations: [.text("Hi", at: anchor, color: .purple)], resolvedStyle: style)))
        XCTAssertEqual(actual, try rgba(expected), "The helper must resolve the bundled font before drawing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.directory))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testCompiledCLIValidatesWholeConfigurationWithoutRewritingIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.png")
        try fixture.png().write(to: input)
        let config = fixture.root.appendingPathComponent(".config/vishot/config.toml")
        let arguments = ["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"rect","x":6,"y":6,"width":12,"height":12}]}"#]
        for invalid in ["[shortcut]\nkey = 'banana'", "[history]\nretention_days = 2", "watermark = 'yes'", "watermark = ["] {
            let text = "style = 'smooth'\n" + invalid
            try text.write(to: config, atomically: true, encoding: .utf8)
            let result = try fixture.run(arguments)
            XCTAssertEqual(result.status, 2)
            let error = try XCTUnwrap(try decode(result.data)["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_arguments")
            XCTAssertTrue((error["message"] as? String ?? "").hasPrefix(
                "Could not resolve the selected annotation style from \(config.path): "))
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
        }
        for (text, expected) in [("# preserved\ntheme = 'clean'", "smooth"),
                                  ("theme = 'clean'\nstyle = 'pixel'", "pixel")] {
            try text.write(to: config, atomically: true, encoding: .utf8)
            let result = try fixture.run(arguments)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual((try decode(result.data)["annotation"] as? [String: Any])?["style"] as? String, expected)
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".config"))
        let result = try fixture.run(arguments)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual((try decode(result.data)["annotation"] as? [String: Any])?["style"] as? String, "pixel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".config").path))
    }

    func testWriteFailuresAndInvalidSettingsPreservePriorFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        let original = try fixture.png()
        try original.write(to: input)
        let arguments = ["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"text","x":0,"y":0,"text":"Hi"}]}"#]
        let folder = fixture.root.appendingPathComponent(".vishot")
        try Data("keep".utf8).write(to: folder)
        XCTAssertEqual(try fixture.run(arguments).status, 10)
        XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertEqual(try fixture.run(arguments).status, 10)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        try fixture.configure("unknown")
        let result = try fixture.run(arguments)
        XCTAssertEqual(result.status, 2)
        XCTAssertEqual((try decode(result.data)["error"] as? [String: Any])?["code"] as? String, "invalid_arguments")
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testEveryColorDefaultPurpleAndBudgetsThroughCompiledCLI() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        try fixture.png().write(to: input)
        var defaults: [[UInt8]] = []
        for color in [nil, "purple", "red", "yellow", "green", "white", "black"] as [String?] {
            var item: [String: Any] = ["type": "text", "x": 0, "y": 0, "text": "Hi"]
            if let color { item["color"] = color }
            let batch = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "annotations": [item]])
            let result = try fixture.run(["annotate", "--input", input.path, "--annotations", String(decoding: batch, as: UTF8.self)])
            XCTAssertEqual(result.status, 0)
            let annotation = try XCTUnwrap(try decode(result.data)["annotation"] as? [String: Any])
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: try XCTUnwrap(annotation["path"] as? String)) as CFURL, nil))
            let pixels = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
            if color == nil || color == "purple" { defaults.append(pixels) }
        }
        XCTAssertEqual(defaults[0], defaults[1])
        let item: [String: Any] = ["type": "text", "x": 0, "y": 0, "text": "Hi"]
        let bigText: [String: Any] = ["type": "text", "x": 0, "y": 0, "text": String(repeating: "a", count: 16385)]
        let aggregate: [String: Any] = ["type": "text", "x": 0, "y": 0, "text": String(repeating: "a", count: 16384)]
        let folder = fixture.root.appendingPathComponent(".vishot")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for items in [[bigText], Array(repeating: item, count: 257), Array(repeating: aggregate, count: 17)] {
            let batch = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "annotations": items])
            let file = fixture.root.appendingPathComponent("large batch.json")
            try batch.write(to: file)
            let result = try fixture.run(["annotate", "--input", input.path, "--annotations-file", file.path])
            XCTAssertEqual(result.status, 2)
            let error = try XCTUnwrap(try decode(result.data)["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_annotations")
            XCTAssertFalse(try XCTUnwrap(error["problems"] as? [Any]).isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
    }

    func testMissingAndNonSquareDPIFallBackAndOutputPreservesSourcePixels() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        let batch = #"{"schemaVersion":1,"annotations":[{"type":"text","x":20,"y":30,"text":"Hi"}]}"#
        for dpi in [CGFloat(0), 144] {
            let png = try fixture.png(dpi: dpi, dpiY: dpi == 144 ? 72 : dpi, marker: true)
            try png.write(to: input)
            let result = try fixture.run(["annotate", "--input", input.path, "--annotations", batch])
            XCTAssertEqual(result.status, 0)
            let annotation = try XCTUnwrap(try decode(result.data)["annotation"] as? [String: Any])
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: try XCTUnwrap(annotation["path"] as? String)) as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Double), 72, accuracy: 0.03)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let output = try rgba(image)
            let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let original = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(originalSource, 0, nil)))
            // Fixture contains an opaque, asymmetric marker far from text. Its exact bytes
            // and placement survive export; the opposite corner remains transparent/unmarked.
            for y in 200..<240 { for x in 0..<320 {
                let i = (y * 320 + x) * 4
                XCTAssertEqual(Array(output[i..<(i + 4)]), Array(original[i..<(i + 4)]))
            } }
        }
    }
    func testUnsupportedSquareDPIExplicitlyFailsWithoutPublishing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        for dpi: CGFloat in [1, 8, 2305, 100000] {
            try fixture.png(dpi: dpi).write(to: input)
            let result = try fixture.run(["annotate", "--input", input.path, "--annotations",
                #"{"schemaVersion":1,"annotations":[{"type":"rect","x":0,"y":0,"width":320,"height":240}]}"#])
            XCTAssertEqual(result.status, 2)
            let error = try XCTUnwrap(try decode(result.data)["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_image")
            XCTAssertTrue((error["message"] as? String ?? "").contains("DPI"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
    }
    func testFileBatchUsesSelectedSmoothStyleAndDPISizingWithoutResizingOrMovingAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.configure("smooth")
        let batch = #"{"schemaVersion":1,"annotations":[{"type":"text","x":20,"y":30,"text":"Hi","color":"red"}]}"#
        let file = fixture.root.appendingPathComponent("batch with spaces.json")
        try Data(batch.utf8).write(to: file)
        var counts: [Int] = []
        for dpi: CGFloat? in [nil, 72, 144, 1200, 2304, 9] {
            let input = fixture.root.appendingPathComponent("input.png")
            try fixture.png(dpi: dpi).write(to: input)
            let result = try fixture.run(["annotate", "--input", input.path, "--annotations-file", file.path])
            XCTAssertEqual(result.status, 0, String(decoding: result.data, as: UTF8.self))
            let json = try decode(result.data)
            let annotation = try XCTUnwrap(json["annotation"] as? [String: Any])
            XCTAssertEqual(annotation["style"] as? String, "smooth")
            let path = try XCTUnwrap(annotation["path"] as? String)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 320)
            XCTAssertEqual(image.height, 240)
            let pixels = try rgba(image)
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<240 { for x in 0..<320 where pixels[(y * 320 + x) * 4 + 3] > 0 {
                xs.append(x); ys.append(y)
            } }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(xs.min()), 19)
            // The public anchor is the typographic box, not the glyph's ink. Its left/top
            // bearings grow with DPI, and very large text can be clipped by this small canvas.
            let scale = Double(dpi ?? 72) / 72
            XCTAssertLessThan(Double(try XCTUnwrap(xs.min())), 20 + 6 * max(1, scale))
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(ys.min()), 30)
            XCTAssertLessThan(Double(try XCTUnwrap(ys.min())), 30 + 15 * max(1, scale))
            counts.append(xs.count)
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(props[kCGImagePropertyDPIWidth] as? Double), Double(dpi ?? 72), accuracy: 0.03)
        }
        XCTAssertEqual(counts[0], counts[1], "Missing DPI is 1x")
        XCTAssertGreaterThan(counts[2], counts[1] * 2, "2x DPI draws larger theme text, without resizing source pixels")
        XCTAssertGreaterThan(counts[3], counts[2], "1200 DPI is supported and retains point-based theme sizing")
        XCTAssertGreaterThan(counts[4], 0, "The maximum supported DPI renders clipped text")
    }

    func testAllParseableProblemsAreIndexedAndNoOutputIsPublished() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        try fixture.png().write(to: input)
        let batch = #"{"schemaVersion":2,"extra":true,"annotations":[{"type":"circle","x":-1,"y":240,"text":" ","color":"blue","size":8},{"type":"text","x":true,"text":12,"color":null},42]}"#
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations", batch])
        XCTAssertEqual(result.status, 2)
        let error = try XCTUnwrap(try decode(result.data)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_annotations")
        let problems = try XCTUnwrap(error["problems"] as? [[String: Any]])
        let paths = Set(problems.compactMap { $0["field"] as? String })
        XCTAssertEqual(paths, Set(["schemaVersion", "extra", "annotations[0].type", "annotations[0].x",
            "annotations[0].y", "annotations[0].text", "annotations[0].color", "annotations[0].size",
            "annotations[1].x", "annotations[1].y", "annotations[1].text", "annotations[1].color", "annotations[2]"]))
        XCTAssertEqual(problems.filter { $0["index"] as? Int == 0 }.count, 6)
        XCTAssertTrue(problems.contains { ($0["reason"] as? String)?.contains("320") == true })
        XCTAssertTrue(problems.contains { ($0["reason"] as? String)?.contains("purple") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
    }

    func testArgumentJSONImageAndBudgetFailuresNeverPublish() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        try fixture.png().write(to: input)
        let valid = #"{"schemaVersion":1,"annotations":[{"type":"text","x":0,"y":0,"text":"Hi"}]}"#
        let prefix = ["annotate", "--input", input.path]
        for args in [["annotate"], prefix, prefix + ["--annotations"],
                     prefix + ["--annotations", valid, "--annotations-file", "x"],
                     prefix + ["--annotations", valid, "--input", input.path],
                     prefix + ["--annotations", valid, "--open", "--open"],
                     prefix + ["--annotations", valid, "--timeout", "1"]] {
            XCTAssertEqual(try fixture.run(args).status, 2)
        }
        for (json, code) in [("{", "invalid_json"), ("[]", "invalid_annotations"),
                              (#"{"schemaVersion":true,"annotations":[]}"#, "invalid_annotations")] {
            let result = try fixture.run(prefix + ["--annotations", json])
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual((try decode(result.data)["error"] as? [String: Any])?["code"] as? String, code)
        }
        let oversized = fixture.root.appendingPathComponent("large.json")
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: oversized)
        XCTAssertEqual(try fixture.run(prefix + ["--annotations-file", oversized.path]).status, 2)
        for bytes in [Data("not png".utf8), Data(try fixture.png().prefix(40))] {
            try bytes.write(to: input)
            let result = try fixture.run(prefix + ["--annotations", valid])
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual((try decode(result.data)["error"] as? [String: Any])?["code"] as? String, "invalid_image")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".vishot").path))
    }

    func testConcurrentOrderedBatchesPreserveExistingOutputAndRefuseSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("input.png")
        let original = try fixture.png()
        try original.write(to: input)
        let batch = #"{"schemaVersion":1,"annotations":[{"type":"text","x":319.5,"y":239.5,"text":"clipped"},{"type":"text","x":20,"y":30,"text":"Hi","color":"red"},{"type":"text","x":20,"y":30,"text":"Hi","color":"green"}]}"#
        let folder = fixture.root.appendingPathComponent(".vishot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("previous.png")
        try original.write(to: old)
        let lock = NSLock()
        var paths: [String] = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                let result = try fixture.run(["annotate", "--input", input.path, "--annotations", batch])
                XCTAssertEqual(result.status, 0)
                let annotation = try XCTUnwrap(try self.decode(result.data)["annotation"] as? [String: Any])
                let path = try XCTUnwrap(annotation["path"] as? String)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
                let pixels = try self.rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
                var green = 0, red = 0
                for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
                    if Int(pixels[i + 1]) > Int(pixels[i]) + 20 { green += 1 }
                    if Int(pixels[i]) > Int(pixels[i + 1]) + 20 { red += 1 }
                }
                XCTAssertGreaterThan(green, 10)
                XCTAssertEqual(red, 0, "Later annotation is painted over earlier one")
                lock.lock(); paths.append(path); lock.unlock()
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(Set(paths).count, 4)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: old), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 5)
        try FileManager.default.removeItem(at: folder)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertEqual(try fixture.run(["annotate", "--input", input.path, "--annotations", batch]).status, 10)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func testInlineBatchRendersWithoutServiceAndPreservesInput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.png()
        let input = fixture.root.appendingPathComponent("source image.png")
        try original.write(to: input)
        let result = try fixture.run(["annotate", "--input", input.path, "--annotations",
            #"{"schemaVersion":1,"annotations":[{"type":"text","x":20,"y":30,"text":"Hello\nworld"}]}"#])
        XCTAssertEqual(result.status, 0, String(decoding: result.data, as: UTF8.self))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let annotation = try XCTUnwrap(json["annotation"] as? [String: Any])
        XCTAssertEqual(annotation["width"] as? Int, 320)
        XCTAssertEqual(annotation["height"] as? Int, 240)
        XCTAssertEqual(annotation["style"] as? String, "pixel")
        XCTAssertEqual(annotation["openingStatus"] as? String, "not_requested")
        let path = try XCTUnwrap(annotation["path"] as? String)
        XCTAssertTrue(path.hasPrefix(fixture.root.path + "/.vishot/"))
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(output, 0, nil))
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertNil(json["image"])
    }

    final class Fixture {
        let root: URL
        let executable: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation CLI \(UUID())")
            let contents = root.appendingPathComponent("Vishot.app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
            let bin = Bundle(for: AnnotationCLITests.self).bundleURL.deletingLastPathComponent()
            executable = contents.appendingPathComponent("Helpers/vishot")
            try FileManager.default.copyItem(at: bin.appendingPathComponent("VishotCLI"), to: executable)
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: repo.appendingPathComponent("site/fonts"), to: resources.appendingPathComponent("Fonts"))
            try FileManager.default.copyItem(at: repo.appendingPathComponent("Resources/Info.plist"), to: contents.appendingPathComponent("Info.plist"))
            try configure("pixel")
        }
        func configure(_ style: String) throws {
            let folder = root.appendingPathComponent(".config/vishot")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("style = \"\(style)\"\n".utf8).write(to: folder.appendingPathComponent("config.toml"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func png(dpi: CGFloat? = nil, dpiY: CGFloat? = nil, marker: Bool = false) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if marker {
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 270, y: 10, width: 10, height: 7))
            }
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            let properties: CFDictionary? = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: dpiY ?? $0] as CFDictionary }
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func run(_ arguments: [String], executable: URL? = nil, workspace: URL? = nil) throws -> (status: Int32, data: Data) {
            let process = Process()
            process.executableURL = executable ?? self.executable
            process.currentDirectoryURL = workspace ?? root
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = root.path
            environment["HOME"] = root.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }
    }
}
