import AppKit
import XCTest
@testable import Vishot

final class ScreenshotCompletionTests: XCTestCase {
    func testCopyRecordsOneEditableScreenshotAndIgnoresRepeatedCompletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        var copied: [(CGImage, CGFloat, Bool)] = []
        let completion = ScreenshotCompletion(history: library) { copied.append(($0, $1, $2)) }
        var document = try makeDocument()
        let original = document.snapshot
        document.crop = CGRect(x: 2, y: 3, width: 12, height: 8)
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [original],
            label: "Terminal", windowTitle: "Build", session: 1, watermark: false))

        XCTAssertEqual(request.copy(currentSession: 1), .close)
        XCTAssertNil(request.copy(currentSession: 1))
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied.first?.0.width, 24)
        XCTAssertEqual(copied.first?.0.height, 16)
        XCTAssertEqual(copied.first?.1, 2)
        XCTAssertEqual(copied.first?.2, false)
        awaitPublication(library) { $0.entries.count == 1 }
        let entry = try XCTUnwrap(library.entries.first)
        let loaded = expectation(description: "Editable screenshot recorded")
        library.load(entry.id) {
            XCTAssertEqual($0?.document.snapshot, document.snapshot)
            XCTAssertEqual($0?.document.image.width, 80)
            XCTAssertEqual($0?.undo, [original])
            XCTAssertEqual($0?.entry.windowTitle, "Build")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
    }

    func testChangedHistoryCopyKeepsIdentityCaptureTimeAndDeletionUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let original = document.snapshot
        let start = Date().addingTimeInterval(-3600)
        let entry = try store.commit(document: document, undo: [], label: "Original", now: start)
        let deleted = try store.commit(document: document, undo: [], label: "Deleted")
        try store.delete(deleted.id)
        let library = HistoryLibrary(store: store)
        library.retention = .off
        let completion = ScreenshotCompletion(history: library) { _, _, _ in }
        document.crop = CGRect(x: 1, y: 2, width: 10, height: 12)
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [original], label: "Ignored",
            id: entry.id, session: 3, watermark: true))
        XCTAssertEqual(request.copy(currentSession: 3), .history(entry.id))
        awaitPublication(library) { $0.entries.first?.snapshot == document.snapshot }
        let updated = try XCTUnwrap(library.entries.first)
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.createdAt, start)
        XCTAssertGreaterThan(updated.modifiedAt, start)
        XCTAssertNotEqual(updated.revision, entry.revision)
        XCTAssertEqual(updated.undo, [original])
        let undone = expectation(description: "Browser deletion undo survives copy")
        library.undoDelete { XCTAssertEqual($0, deleted.id); undone.fulfill() }
        wait(for: [undone], timeout: 3)
    }

    func testUnchangedHistoryCopyDoesNotRenewRetention() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let start = Date().addingTimeInterval(-3600)
        let entry = try store.commit(document: document, undo: [], label: "Original", now: start)
        let library = HistoryLibrary(store: store)
        let completion = ScreenshotCompletion(history: library) { _, _, _ in }
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Ignored",
            id: entry.id, session: 3, watermark: true))
        XCTAssertEqual(request.copy(currentSession: 3), .history(entry.id))
        awaitPublication(library) { $0.entries.count == 1 }
        XCTAssertEqual(library.entries.first?.revision, entry.revision)
        XCTAssertEqual(library.entries.first?.modifiedAt, start)
        XCTAssertEqual(library.entries.first?.createdAt, start)
    }

    func testLateCopyKeepsRequestedDocumentAndPreferencesWithoutChangingNewSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        var watermark = false
        var copied: [(Int, Bool)] = []
        let completion = ScreenshotCompletion(history: library) { image, _, marked in copied.append((image.width, marked)) }
        var document = try makeDocument()
        document.crop = CGRect(x: 0, y: 0, width: 10, height: 8)
        let requested = document.snapshot
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Requested",
            session: 1, watermark: watermark))
        document.crop = nil
        watermark = true
        library.retention = .off
        var presentation = ScreenshotCompletion.Presentation.history(UUID())
        let newerPresentation = presentation
        if let result = request.copy(currentSession: 2) { presentation = result }
        XCTAssertEqual(presentation, newerPresentation)
        XCTAssertEqual(copied.first?.0, 20)
        XCTAssertEqual(copied.first?.1, false)
        awaitPublication(library) { $0.entries.count == 1 }
        XCTAssertEqual(library.entries.first?.snapshot, requested)
        XCTAssertEqual(library.entries.first?.label, "Requested")
    }

    func testCancellationReleasesOnlyItsOwnHoldOnceAndDoesNotCopyOrRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Expired",
            now: Date().addingTimeInterval(-40 * 86400))
        let library = HistoryLibrary(store: store)
        var copies = 0
        let completion = ScreenshotCompletion(history: library) { _, _, _ in copies += 1 }
        // Another owner (the editor) must survive repeated cancellation of this request.
        library.hold(entry.id)
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Expired",
            id: entry.id, session: 1, watermark: false))
        request.cancel()
        request.cancel()
        XCTAssertNil(request.copy(currentSession: 1))
        awaitPublication(library) { $0.entries.count == 1 }
        XCTAssertEqual(library.entries.first?.revision, entry.revision)
        XCTAssertEqual(copies, 0)
        library.release(entry.id)
        awaitPublication(library) { $0.entries.isEmpty }
    }

    func testUnchangedCompletionReleasesOutputHoldSoExpiredEntryCanBeRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Expired",
            now: Date().addingTimeInterval(-40 * 86400))
        let library = HistoryLibrary(store: store)
        library.hold(entry.id)
        let completion = ScreenshotCompletion(history: library) { _, _, _ in }
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Expired",
            id: entry.id, session: 1, watermark: false))
        library.release(entry.id)
        awaitPublication(library) { $0.entries.count == 1 }
        XCTAssertEqual(request.copy(currentSession: 1), .history(entry.id))
        request.cancel()
        awaitPublication(library) { $0.entries.isEmpty }
    }

    func testHistoryWriteFailureDoesNotPreventCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file at the history root forces a real persistence failure.
        try Data("unwritable history root".utf8).write(to: folder)
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        var copies = 0
        let completion = ScreenshotCompletion(history: library) { _, _, _ in copies += 1 }
        let request = try XCTUnwrap(completion.prepare(document: makeDocument(), undo: [], label: "Copy",
            session: 1, watermark: false))
        XCTAssertEqual(request.copy(currentSession: 1), .close)
        XCTAssertEqual(copies, 1)
        awaitPublication(library) { $0.error != nil }
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testHistoryOffRequestDoesNotStartRecordingWhenPreferenceChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        library.retention = .off
        var copies = 0
        let completion = ScreenshotCompletion(history: library) { _, _, _ in copies += 1 }
        let request = try XCTUnwrap(completion.prepare(document: makeDocument(), undo: [], label: "Off",
            session: 1, watermark: false))
        library.retention = .sevenDays
        XCTAssertEqual(request.copy(currentSession: 1), .close)
        XCTAssertEqual(copies, 1)
        // A queued read is a barrier after all previously requested history writes.
        let drained = expectation(description: "History worker drained")
        library.load(UUID()) { _ in drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testAbandonedRequestReleasesItsHoldWithoutRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Expired",
            now: Date().addingTimeInterval(-40 * 86400))
        let library = HistoryLibrary(store: store)
        let completion = ScreenshotCompletion(history: library) { _, _, _ in XCTFail("Abandoned request copied") }
        var request = completion.prepare(document: document, undo: [], label: "Expired",
            id: entry.id, session: 1, watermark: false)
        XCTAssertNotNil(request)
        library.cleanup()
        awaitPublication(library) { $0.entries.count == 1 }
        request = nil
        awaitPublication(library) { $0.entries.isEmpty }
    }

    func testEditorCopyCompletesPendingAnnotationAndRecordsItsUndoSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        let document = try makeDocument()
        let editor = EditorController(capture: Capture(image: document.image, scale: document.scale,
            frame: CGRect(x: 100, y: 200, width: 40, height: 30)))
        var copies = 0
        let completion = ScreenshotCompletion(history: library) { image, scale, watermark in
            XCTAssertEqual(image.width, 80)
            XCTAssertEqual(scale, 2)
            XCTAssertFalse(watermark)
            copies += 1
        }
        editor.onFinish = { finish, output in
            XCTAssertEqual(finish, .copy)
            let request = completion.prepare(document: editor.document, undo: editor.history.snapshots,
                label: "Editor", session: 1, watermark: false, exported: output?.image)
            XCTAssertEqual(request?.copy(currentSession: 1), .close)
        }
        editor.select(.tool(.arrow))
        editor.mouseDown(at: CGPoint(x: 112, y: 212))
        editor.mouseDragged(to: CGPoint(x: 125, y: 218))
        // Copy finishes the action even without a mouse-up.
        editor.select(.finish(.copy))
        XCTAssertEqual(copies, 1)
        awaitPublication(library) { $0.entries.count == 1 }
        XCTAssertEqual(library.entries.first?.snapshot.annotations,
            [.arrow(from: CGPoint(x: 12, y: 12), to: CGPoint(x: 25, y: 18), color: .purple)])
        XCTAssertEqual(library.entries.first?.undo, [document.snapshot])
    }

    private func makeDocument() throws -> EditDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        return EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 2)
    }

    private func awaitPublication(_ library: HistoryLibrary, matching predicate: @escaping (HistoryLibrary) -> Bool) {
        if predicate(library) { return }
        let published = expectation(description: "History publication")
        library.onChange = {
            if predicate(library) {
                library.onChange = nil
                published.fulfill()
            }
        }
        wait(for: [published], timeout: 3)
        library.onChange = nil
    }
}
