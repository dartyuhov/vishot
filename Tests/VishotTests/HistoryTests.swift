import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Vishot

final class HistoryTests: XCTestCase {
    func testBrowserPreviewIsBoundedWithoutChangingCopyResolution() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let entry = try store.commit(document: makeDocument(), undo: [], label: "Preview")
        let preview = try store.preview(entry, maxPixelSize: 20)
        XCTAssertEqual(preview.width, 20)
        XCTAssertEqual(preview.height, 15)
        XCTAssertEqual(try store.preview(entry).width, 40)
        XCTAssertEqual(try store.load(entry.id).document.image.width, 40)
    }
    func testEditsRenewOnlyWhenChangedAndOffKeepsLastRetention() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let entry = try store.commit(document: document, undo: [], label: "Terminal", now: start)
        let unchanged = try store.commit(document: document, undo: [], label: "ignored", id: entry.id, now: start.addingTimeInterval(86400))
        XCTAssertEqual(unchanged, entry)
        document.crop = CGRect(x: 1, y: 1, width: 10, height: 10)
        let edited = try store.commit(document: document, undo: [entry.snapshot], label: "ignored", id: entry.id, now: start.addingTimeInterval(86400))
        XCTAssertEqual(edited.id, entry.id)
        XCTAssertEqual(edited.createdAt, start)
        XCTAssertEqual(edited.modifiedAt, start.addingTimeInterval(86400))
        XCTAssertNotEqual(edited.revision, entry.revision)
        XCTAssertFalse(try store.index(entry.id, revision: entry.revision, text: "stale"))
        try store.cleanup(retention: .threeDays, now: start.addingTimeInterval(3 * 86400))
        XCTAssertEqual(try store.entries().count, 1)
        let restarted = HistoryStore(url: folder)
        try restarted.cleanup(retention: .off, holding: [entry.id], now: start.addingTimeInterval(5 * 86400))
        XCTAssertEqual(try restarted.entries().count, 1)
        try restarted.cleanup(retention: .off, now: start.addingTimeInterval(5 * 86400))
        XCTAssertTrue(try restarted.entries().isEmpty)
    }

    func testDeleteUndoAndInterruptedSessionNeverResurrectIndex() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let first = try store.commit(document: document, undo: [], label: "First")
        let second = try store.commit(document: document, undo: [], label: "Second")
        try store.delete(first.id)
        try store.delete(second.id)
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertFalse(try store.index(first.id, revision: first.revision, text: "deleted"))
        XCTAssertEqual(try store.undoDelete(), second.id)
        XCTAssertEqual(try store.undoDelete(), first.id)
        XCTAssertEqual(try store.entries().count, 2)
        try store.delete(first.id)
        let restarted = HistoryStore(url: folder)
        try restarted.recover()
        XCTAssertEqual(try restarted.entries().map(\.id), [second.id])
        XCTAssertThrowsError(try restarted.load(first.id))
    }

    func testFailedUpdateKeepsCommittedRevisionAndDamagedEntriesAreIsolated() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Good")
        document.crop = CGRect(x: 500, y: 500, width: 5, height: 5)
        XCTAssertThrowsError(try store.commit(document: document, undo: [], label: "Good", id: entry.id))
        XCTAssertEqual(try store.load(entry.id).entry, entry)
        let bad = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("broken json".utf8).write(to: bad.appendingPathComponent("entry.json"))
        var future = entry
        future.schema = 999
        let futureFolder = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: futureFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(future).write(to: futureFolder.appendingPathComponent("entry.json"))
        try store.recover()
        XCTAssertEqual(try store.entries().map(\.id), [entry.id])
        XCTAssertEqual(store.warnings.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
    }

    private func makeDocument() throws -> EditDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 1)
    }

    func testReopenedEditorUsesRestoredUndoAndMapsScaledMouseWithoutChangingOutputResolution() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let original = document.snapshot
        document.crop = CGRect(x: 5, y: 5, width: 20, height: 15)
        let entry = try store.commit(document: document, undo: [original], label: "Editor")
        let restored = try store.load(entry.id)
        let capture = Capture(image: document.image, scale: 1, frame: CGRect(x: 100, y: 200, width: 20, height: 15))
        let editor = EditorController(capture: capture, restored: restored, viewScale: 0.5)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "u", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: UInt16(kVK_ANSI_U)))
        editor.handle(event)
        XCTAssertNil(editor.document.crop)
        editor.select(.tool(.arrow))
        editor.mouseDown(at: CGPoint(x: 105, y: 205))
        editor.mouseDragged(to: CGPoint(x: 115, y: 210))
        editor.mouseUp(at: CGPoint(x: 115, y: 210))
        XCTAssertEqual(editor.document.annotations, [.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 20), color: .purple)])
        var exported: CGImage?
        editor.onFinish = { _, result in exported = result?.image }
        editor.select(.finish(.copy))
        XCTAssertEqual(exported?.width, 40)
        XCTAssertEqual(exported?.height, 30)
    }

    func testSearchCombinesFieldsAndRejectsScatteredLetters() {
        let exact = entry(label: "Safari", text: "Invoice total")
        let fuzzy = entry(label: "Slack", text: "individual voices")
        XCTAssertEqual(HistorySearch.matches("invoice", in: [fuzzy, exact]).map(\.id), [exact.id])
        XCTAssertEqual(HistorySearch.matches("INVO", in: [fuzzy, exact]).map(\.id), [exact.id])
        XCTAssertEqual(HistorySearch.matches("safari total", in: [fuzzy, exact]).map(\.id), [exact.id])
        XCTAssertTrue(HistorySearch.matches("missing", in: [exact, fuzzy]).isEmpty)
        let ghostty = entry(label: "Ghostty", text: "Terminal")
        let helium = entry(label: "Helium", text: "g h o s t t y")
        XCTAssertEqual(HistorySearch.matches("ghostty", in: [helium, ghostty]).map(\.id), [ghostty.id])
        let browserMention = entry(label: "Helium", text: "Download Ghostty")
        XCTAssertEqual(HistorySearch.matches("ghostty", in: [browserMention]).map(\.id), [browserMention.id])
    }

    func testSearchIncludesVisibleAnnotationTextBeforeOCRButNotClippedText() {
        var capture = entry(label: "Editor", text: "")
        capture.snapshot = EditSnapshot(annotations: [
            .text("Visible invoice", at: CGPoint(x: 20, y: 30), color: .purple),
            .text("Hidden password", at: CGPoint(x: 20, y: 300), color: .purple),
            .text("Partially clipped secret", at: CGPoint(x: 290, y: 80), color: .purple),
        ], crop: CGRect(x: 0, y: 0, width: 300, height: 120))
        XCTAssertEqual(HistorySearch.matches("invoice", in: [capture]).map(\.id), [capture.id])
        XCTAssertTrue(HistorySearch.matches("password", in: [capture]).isEmpty)
        XCTAssertTrue(HistorySearch.matches("secret", in: [capture]).isEmpty)
    }

    func testMalformedAnnotationCannotReachRenderer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let capture = try store.commit(document: makeDocument(), undo: [], label: "Damaged")
        var damaged = capture
        damaged.snapshot.annotations = [.arrow(from: .zero, to: CGPoint(x: 1e100, y: 0), color: .red)]
        try JSONEncoder().encode(damaged).write(to: folder.appendingPathComponent(capture.id.uuidString).appendingPathComponent("entry.json"))
        XCTAssertThrowsError(try store.load(capture.id))
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertNotNil(store.warnings.first)
    }

    func testLibraryOffSkipsNewEntriesButAllowsUpdatingExistingEntry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let capture = try store.commit(document: document, undo: [], label: "Retained")
        let library = HistoryLibrary(store: store)
        library.retention = .off
        let loaded = expectation(description: "Read retained entries")
        library.onChange = { if library.entries.count == 1 { loaded.fulfill() } }
        wait(for: [loaded], timeout: 3)
        library.onChange = nil
        library.commit(document: document, undo: [], label: "Do not record")
        var edited = document
        edited.crop = CGRect(x: 1, y: 1, width: 10, height: 10)
        let updated = expectation(description: "Update retained entry while Off")
        library.onChange = {
            if library.entries.first?.snapshot.crop == edited.crop {
                library.onChange = nil
                updated.fulfill()
            }
        }
        library.commit(document: edited, undo: [document.snapshot], label: "Retained", id: capture.id)
        wait(for: [updated], timeout: 3)
        XCTAssertEqual(library.entries.map(\.id), [capture.id])
    }

    private func entry(label: String, text: String) -> HistoryEntry {
        HistoryEntry(id: UUID(), revision: UUID(), createdAt: Date(), modifiedAt: Date(), scale: 1,
            label: label, windowTitle: "", snapshot: EditSnapshot(annotations: [], crop: nil), undo: [], recognizedText: text)
    }

    func testCommittedScreenshotSurvivesRestartWithUndoAndNativePixels() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let image = try XCTUnwrap(context.makeImage())
        var document = EditDocument(image: image, scale: 2)
        var undo = EditHistory()
        undo.push(document.snapshot)
        document.crop = CGRect(x: 5, y: 4, width: 20, height: 10)
        document.annotations = [.text("Invoice", at: CGPoint(x: 8, y: 8), color: .purple)]
        let store = HistoryStore(url: folder)
        let entry = try store.commit(document: document, undo: undo.snapshots, label: "Safari", windowTitle: "Account", now: Date(timeIntervalSince1970: 100))
        let restarted = HistoryStore(url: folder)
        XCTAssertEqual(try restarted.entries().map(\.id), [entry.id])
        let loaded = try restarted.load(entry.id)
        XCTAssertEqual(loaded.document.snapshot, document.snapshot)
        XCTAssertEqual(loaded.document.scale, 2)
        XCTAssertEqual(loaded.document.image.width, 80)
        XCTAssertEqual(loaded.document.image.height, 60)
        XCTAssertEqual(loaded.document.image.dataProvider?.data as Data?, image.dataProvider?.data as Data?)
        var restored = EditHistory(snapshots: loaded.undo)
        var state = loaded.document.snapshot
        XCTAssertFalse(restored.canRedo)
        XCTAssertTrue(restored.undo(&state))
        XCTAssertNil(state.crop)
        XCTAssertTrue(state.annotations.isEmpty)
        XCTAssertEqual(entry.createdAt, Date(timeIntervalSince1970: 100))
    }
}
