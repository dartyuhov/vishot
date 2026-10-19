import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Vishot

final class AnnotationStyleHistoryTests: XCTestCase {
    func testCleanSearchExcludesAccentedGlyphsClippedAboveTheTypographicLineBox() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let image = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let text = "A\u{030d}\u{030d}\u{030d}\u{030d}"
        var document = EditDocument(image: image, scale: 1,
            annotations: [.text(text, at: CGPoint(x: 50, y: 80), color: .purple)],
            crop: CGRect(x: 10, y: 55, width: 250, height: 120), annotationStyle: .clean)
        let entry = try store.commit(document: document, undo: [], label: "Clipped marks")
        let preview = try store.preview(entry)
        let uncropped = try XCTUnwrap(AnnotationRenderer.export(EditDocument(image: image, scale: 1,
            annotations: document.annotations, annotationStyle: .clean)))
        let aboveCrop = try XCTUnwrap(uncropped.cropping(to: CGRect(x: 10, y: 0, width: 250, height: 55)))
        XCTAssertTrue(try pixels(aboveCrop).contains { $0 != 0 }, "The crop really removes rendered marks")
        XCTAssertEqual(preview.height, 120)
        XCTAssertFalse(entry.searchFields.contains { $0.contains(text) }, "Clipped glyphs must rely on visible OCR")
        document.crop = CGRect(x: 10, y: 0, width: 250, height: 180)
        let visible = try store.commit(document: document, undo: [], label: "Visible marks", id: entry.id)
        XCTAssertTrue(visible.searchFields.contains { $0.contains(text) })
    }

    func testCleanSearchExcludesTextWhoseReadabilityHaloIsCroppedAndStyleChangesRevise() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let image = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let at = CGPoint(x: 40.25, y: 60.25)
        let text = "Readable\nmarkup"
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        // Independent typographic left edge: Clean does not grid-snap. Cropping here cuts its halo.
        var document = EditDocument(image: image, scale: 1,
            annotations: [.text(text, at: at, color: .purple)],
            crop: CGRect(x: at.x, y: 10, width: 200, height: 150), annotationStyle: .clean)
        let clipped = try store.commit(document: document, undo: [], label: "Search")
        XCTAssertFalse(clipped.searchFields.contains { $0.contains(text) })
        document.crop = CGRect(x: 10, y: 10, width: 250, height: 180)
        let visible = try store.commit(document: document, undo: [], label: "Search", id: clipped.id)
        XCTAssertTrue(visible.searchFields.contains { $0.contains(text) })
        XCTAssertGreaterThan(AnnotationRenderer.textBounds(text, at: at, style: ThemeCatalog.clean.annotation).height,
                             font.ascender - font.descender)
        let pixel = EditDocument(image: image, scale: 1, annotations: document.annotations, crop: document.crop)
        let changed = try store.commit(document: pixel, undo: [], label: "Search", id: clipped.id)
        XCTAssertNotEqual(changed.revision, visible.revision)
        XCTAssertEqual(try store.load(changed.id).document.annotationStyle, .pixel)
    }

    func testLegacyMetadataDefaultsToPixelAndUnsupportedStylesAreIsolated() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let image = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let entry = try store.commit(document: EditDocument(image: image, scale: 1), undo: [], label: "Legacy")
        let metadata = folder.appendingPathComponent(entry.id.uuidString).appendingPathComponent("entry.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        json.removeValue(forKey: "annotationStyle")
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let legacyBytes = try Data(contentsOf: metadata)
        let legacy = try store.load(entry.id)
        XCTAssertEqual(legacy.document.annotationStyle, .pixel)
        XCTAssertEqual(try store.commit(document: legacy.document, undo: [], label: "Legacy", id: entry.id).revision, entry.revision)
        XCTAssertEqual(try Data(contentsOf: metadata), legacyBytes, "Reading or unchanged commits never bulk-migrate metadata")
        for unsupported: Any in ["future", "", 17, NSNull()] {
            json["annotationStyle"] = unsupported
            try JSONSerialization.data(withJSONObject: json).write(to: metadata)
            XCTAssertThrowsError(try store.load(entry.id)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsupported History entry"))
            }
            XCTAssertTrue(try store.entries().isEmpty)
            XCTAssertEqual(store.warnings.count, 1)
            try store.recover()
            XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        }
    }

    func testNewCleanEditorMeasuresMultilineCaretAndFinishesUsingDocumentStyle() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = Capture(image: try XCTUnwrap(context.makeImage()), scale: 2,
            frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let editor = EditorController(capture: capture, theme: ThemeCatalog.clean)
        func key(_ code: Int, _ characters: String, flags: NSEvent.ModifierFlags = []) throws {
            editor.handle(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: UInt16(code))))
        }
        try key(kVK_ANSI_T, "t")
        try key(kVK_ANSI_H, "Hello")
        try key(kVK_Return, "\n", flags: .shift)
        try key(kVK_ANSI_W, "World")
        XCTAssertEqual(editor.makeScene().caret,
            AnnotationRenderer.caret(after: "Hello\nWorld", at: CGPoint(x: 80, y: 60), style: ThemeCatalog.clean.annotation))
        var result: CGImage?
        editor.onFinish = { _, output in result = output?.image }
        editor.select(.finish(.copy))
        let expected = try XCTUnwrap(AnnotationRenderer.export(editor.document))
        XCTAssertEqual(try pixels(XCTUnwrap(result)), try pixels(expected))
    }

    func testCleanRoundTripReeditUndoRedoAndPreviewRetainDocumentStyle() throws {
        for scale in [CGFloat(1), 2] {
            try assertCleanRoundTrip(scale: scale)
        }
    }

    private func assertCleanRoundTrip(scale: CGFloat) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(160 * scale), height: Int(120 * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160 * scale, height: 120 * scale))
        var document = EditDocument(image: try XCTUnwrap(context.makeImage()), scale: scale, annotationStyle: .clean)
        let original = document.snapshot
        document.annotations = [.arrow(from: CGPoint(x: 20.5, y: 30.5), to: CGPoint(x: 100.5, y: 70.5), color: .purple)]
        let entry = try store.commit(document: document, undo: [original], label: "Clean")
        let loaded = try HistoryStore(url: folder).load(entry.id)
        XCTAssertEqual(loaded.document.annotationStyle, .clean)
        XCTAssertEqual(loaded.document.snapshot, document.snapshot)
        XCTAssertEqual(try pixels(loaded.document.image), try pixels(document.image))
        let capture = Capture(image: document.image, scale: scale, frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let editor = EditorController(capture: capture, restored: loaded, theme: ThemeCatalog.pixel)
        editor.select(.undo)
        XCTAssertEqual(editor.document.snapshot, original)
        XCTAssertEqual(editor.document.annotationStyle, .clean)
        editor.select(.redo)
        XCTAssertEqual(editor.document.snapshot, document.snapshot)
        XCTAssertEqual(editor.document.annotationStyle, .clean)
        editor.select(.tool(.rect))
        editor.mouseDown(at: CGPoint(x: 30.5, y: 35.5))
        editor.mouseDragged(to: CGPoint(x: 70.5, y: 80.5))
        editor.mouseUp(at: CGPoint(x: 70.5, y: 80.5))
        XCTAssertEqual(editor.document.annotations.count, 2)
        XCTAssertEqual(editor.document.annotationStyle, .clean)
        let expected = try XCTUnwrap(AnnotationRenderer.export(document))
        let preview = try store.preview(entry)
        XCTAssertEqual(try pixels(preview), try pixels(expected))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(AnnotationRenderer.imageSpaceContext(drawing: image, scale: 1))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}
