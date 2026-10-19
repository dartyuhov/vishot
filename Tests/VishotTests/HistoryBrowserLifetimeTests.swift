import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Vishot

final class HistoryBrowserLifetimeTests: XCTestCase {
    func testThemedBrowsingKeepsNavigationSearchErrorsAndStoredPreview() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let older = try store.commit(document: makeDocument(), undo: [], label: "Older",
            now: Date(timeIntervalSinceNow: -60))
        let newer = try store.commit(document: makeDocument(), undo: [], label: "Newer")
        let bytes = try store.previewData(newer, thumbnail: false)
        let library = HistoryLibrary(store: store)
        let published = expectation(description: "History published")
        library.onChange = { if library.entries.count == 2 { published.fulfill() } }
        library.cleanup()
        wait(for: [published], timeout: 3)
        library.onChange = nil
        let browser = HistoryBrowser(library: library)
        defer { browser.close() }
        for theme in [ThemeCatalog.pixel, ThemeCatalog.clean] {
            browser.prepare(theme: theme)
            browser.show(on: screen)
            browser.refresh()
            let panel = try XCTUnwrap(NSApp.windows.first {
                $0.isVisible && $0.contentView?.accessibilityLabel() == "Capture History"
            })
            let view = try XCTUnwrap(panel.contentView)
            func press(_ code: Int, _ text: String = "") throws {
                panel.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code))))
            }
            var edited: UUID?
            browser.onEdit = { id, _ in edited = id }
            try press(kVK_ANSI_L)
            try press(kVK_ANSI_E)
            XCTAssertEqual(edited, older.id)
            try press(kVK_ANSI_Slash)
            try press(kVK_ANSI_N, "Newer")
            try press(kVK_Return)
            try press(kVK_ANSI_E)
            XCTAssertEqual(edited, newer.id)
            let failed = expectation(description: "Read error delivered")
            library.load(UUID()) { _ in failed.fulfill() }
            wait(for: [failed], timeout: 3)
            browser.libraryChanged()
            _ = try background(of: view, scale: 1)
            let error = try XCTUnwrap(library.error)
            XCTAssertTrue((view.accessibilityValue() as? String ?? "").contains(error),
                "Read errors must remain visible alongside populated history")
            try press(kVK_ANSI_Slash)
            try press(kVK_ANSI_X, "no matching capture")
            _ = try background(of: view, scale: 2)
            XCTAssertTrue((view.accessibilityValue() as? String ?? "").contains("No matches"))
            XCTAssertTrue((view.accessibilityValue() as? String ?? "").contains(error))
            try press(kVK_Escape)
            let copied = expectation(description: "Stored preview still available")
            browser.yank(newer) { image in
                XCTAssertEqual(image?.width, 40)
                XCTAssertEqual(image?.height, 30)
                copied.fulfill()
            }
            wait(for: [copied], timeout: 3)
            browser.close()
            XCTAssertEqual(try store.previewData(newer, thumbnail: false), bytes)
        }
    }

    func testPreparedAppearanceAppliesOnOpenAndStaysFixedThroughEditorContinuation() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let browser = HistoryBrowser(library: HistoryLibrary(store: HistoryStore(url: folder)))
        defer { browser.close() }
        browser.prepare(theme: ThemeCatalog.clean)
        browser.show(on: screen)
        let view = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && $0.contentView?.accessibilityLabel() == "Capture History"
        }?.contentView)
        for scale in [1, 2] {
            let color = try background(of: view, scale: scale)
            XCTAssertEqual(color.redComponent, 0.11, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, 0.13, accuracy: 0.01)
        }
        browser.prepare(theme: ThemeCatalog.pixel)
        browser.suspend()
        browser.resume(select: UUID())
        XCTAssertEqual(try background(of: view, scale: 1).redComponent, 0.11, accuracy: 0.01)
        browser.close()
        browser.prepare(theme: ThemeCatalog.pixel)
        browser.show(on: screen)
        XCTAssertEqual(try background(of: view, scale: 1).redComponent, 0, accuracy: 0.01)
    }

    private func background(of view: NSView, scale: Int) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        view.draw(view.bounds)
        return try XCTUnwrap(bitmap.colorAt(x: 2 * scale, y: 2 * scale)?.usingColorSpace(.deviceRGB))
    }

    func testObsoleteYankReleasesBusyStateForNextYank() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let old = try store.commit(document: document, undo: [], label: "Old")
        document.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        let current = try store.commit(document: document, undo: [], label: "Current", id: old.id)
        let library = HistoryLibrary(store: store)
        let browser = HistoryBrowser(library: library)
        let obsolete = expectation(description: "Obsolete yank finishes")
        let copied = expectation(description: "Next yank is accepted")
        browser.yank(old) { image in
            XCTAssertNil(image)
            obsolete.fulfill()
            browser.yank(current) { image in
                XCTAssertEqual(image?.width, 10)
                copied.fulfill()
            }
        }
        wait(for: [obsolete, copied], timeout: 3)
        XCTAssertNil(library.error)
    }

    func testCloseAndReopenCancelsPendingYankWithoutDisruptingNewYank() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let entry = try store.commit(document: makeDocument(), undo: [], label: "Pending")
        let reader = DispatchQueue(label: "test.browser.decode")
        reader.suspend()
        let library = HistoryLibrary(store: store, browserReader: reader)
        let browser = HistoryBrowser(library: library)
        defer { browser.close() }
        browser.show(on: screen)
        browser.yank(entry) { _ in XCTFail("Old session must not copy or close the reopened browser") }
        let queued = expectation(description: "Old yank bytes queued")
        library.load(entry.id) { _ in queued.fulfill() }
        wait(for: [queued], timeout: 3)
        browser.close()
        browser.show(on: screen)
        let copied = expectation(description: "Reopened session can yank")
        browser.yank(entry) { image in
            XCTAssertEqual(image?.width, 40)
            copied.fulfill()
        }
        reader.resume()
        wait(for: [copied], timeout: 3)
        let drained = expectation(description: "Late callbacks drained")
        reader.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 3)
    }

    private func makeDocument() throws -> EditDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 1)
    }
}
