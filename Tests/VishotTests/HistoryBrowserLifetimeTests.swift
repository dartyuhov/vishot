import XCTest
import VishotRendering
import AppKit
@testable import Vishot

final class HistoryBrowserLifetimeTests: XCTestCase {
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
