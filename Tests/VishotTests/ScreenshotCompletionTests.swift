import AppKit
import XCTest
@testable import Vishot

final class ScreenshotCompletionTests: XCTestCase {
    func testBackgroundSaveFallbackRetainsBothThemesAndEnabledStates() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try XCTUnwrap(context.makeImage())
        let capturer = Capturer()
        for theme in [ThemeCatalog.pixel, ThemeCatalog.clean] {
            for enabled in [false, true] {
                var settings = OutputStyle(watermark: enabled, style: theme.watermark)
                let done = expectation(description: "Themed fallback")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("missing/output.png")
                capturer.save(image, scale: 1, to: url, output: settings) { done.fulfill() }
                settings = OutputStyle(watermark: !enabled, style: ThemeCatalog.pixel.watermark)
                wait(for: [done], timeout: 3)
                let expected = enabled ? Watermark.apply(to: image, scale: 1, style: theme.watermark) : image
                for type in [NSPasteboard.PasteboardType.png, .tiff] {
                    XCTAssertEqual(NSPasteboard.general.data(forType: type),
                        ImageEncoding.data(expected, scale: 1, type: type == .png ? .png : .tiff))
                }
            }
        }
    }

    func testCancelledSaveAsThenResumedCopyAndSaveKeepSessionStyleAndUnmarkedHistory() throws {
        for theme in [ThemeCatalog.pixel, ThemeCatalog.clean] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = HistoryStore(url: folder.appendingPathComponent("history"))
            let library = HistoryLibrary(store: store)
            let capturer = Capturer()
            let saved = expectation(description: "Resumed themed save")
            let completion = ScreenshotCompletion(history: library, save: { image, scale, url, output, done in
                capturer.save(image, scale: scale, to: url, output: output) { done(); saved.fulfill() }
            }) { capturer.copy($0, scale: $1, output: $2) }
            let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            let document = EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 2)
            var settings = OutputStyle(watermark: true, style: theme.watermark)
            let sessionOutput = settings
            let cancelled = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Cancelled",
                session: 1, output: sessionOutput))
            cancelled.saveAs(to: nil, currentSession: { 1 }) { _ in XCTFail("Cancelled Save As presented") }
            settings = OutputStyle(watermark: false, style: ThemeCatalog.pixel.watermark)
            XCTAssertFalse(settings.watermark)
            let resumed = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Resumed",
                session: 1, output: sessionOutput))
            let url = folder.appendingPathComponent("saved.png")
            resumed.save(to: url, copying: true, currentSession: { 2 }) { XCTAssertNil($0) }
            // Copy stays on the pasteboard after its originating session has been replaced.
            let expected = try XCTUnwrap(ImageEncoding.data(Watermark.apply(to: document.image, scale: 2,
                style: theme.watermark), scale: 2, type: .png))
            XCTAssertEqual(NSPasteboard.general.data(forType: .png), expected)
            wait(for: [saved], timeout: 3)
            XCTAssertEqual(try Data(contentsOf: url), expected)
            drain(library)
            XCTAssertEqual(library.entries.count, 1)
            let preview = try XCTUnwrap(store.preview(try XCTUnwrap(library.entries.first)))
            let badge = try XCTUnwrap(Watermark.badgeRect(in: CGSize(width: 400, height: 300), style: theme.watermark))
            // The preview remains white where output places its plate.
            let sample = try XCTUnwrap(preview.cropping(to: CGRect(x: (badge.midX / 400) * CGFloat(preview.width),
                y: (badge.midY / 300) * CGFloat(preview.height), width: 1, height: 1)))
            let bitmap = NSBitmapImageRep(cgImage: sample)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).redComponent, 0.95)
        }
    }

    func testNewSaveKeepsRequestedPreferencesAndDocumentWhenSettingsChange() throws {
        for theme in [ThemeCatalog.pixel, ThemeCatalog.clean] {
            for recording in [false, true] {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                let library = HistoryLibrary(store: HistoryStore(url: folder))
                library.retention = recording ? .sevenDays : .off
                var finishSave: (() -> Void)?
                var output = OutputStyle(watermark: false, style: theme.watermark)
                let completion = ScreenshotCompletion(history: library, save: { image, _, _, marked, done in
                    XCTAssertEqual(image.width, 20)
                    XCTAssertFalse(marked.watermark)
                    switch (theme.watermark.treatment, marked.style.treatment) {
                    case (.pixelGlyphs, .pixelGlyphs), (.systemText, .systemText): break
                    default: XCTFail("Pending save lost its originating theme")
                    }
                    finishSave = done
                }) { _, _, _ in XCTFail("Save-only copied") }
                var document = try makeDocument()
                document.crop = CGRect(x: 0, y: 0, width: 10, height: 8)
                let requested = document.snapshot
                let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Requested",
                    session: 1, output: output))
                document.crop = nil
                output = OutputStyle(watermark: true, style: ThemeCatalog.pixel.watermark)
                library.retention = recording ? .off : .sevenDays
                request.save(to: folder.appendingPathComponent("output.png"), currentSession: { 2 }) { XCTAssertNil($0) }
                try XCTUnwrap(finishSave)()
                drain(library)
                XCTAssertEqual(library.entries.count, recording ? 1 : 0)
                if recording { XCTAssertEqual(library.entries.first?.snapshot, requested) }
            }
        }
    }

    func testCopyAdapterCannotReenterAndCompleteTheSameRequestTwice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        var request: ScreenshotCompletion.Request?
        var copies = 0
        let completion = ScreenshotCompletion(history: library) { _, _, _ in
            copies += 1
            if copies == 1 { XCTAssertNil(request?.copy(currentSession: 1)) }
        }
        request = completion.prepare(document: try makeDocument(), undo: [], label: "Copy", session: 1, output: pixelOutput(false))
        XCTAssertEqual(request?.copy(currentSession: 1), .close)
        XCTAssertEqual(copies, 1)
        drain(library)
        XCTAssertEqual(library.entries.count, 1)
    }

    func testAcceptedSaveAsKeepsSnapshotAndHoldAcrossReplacementSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let original = document.snapshot
        let capturedAt = Date().addingTimeInterval(-40 * 86400)
        let entry = try store.commit(document: document, undo: [], label: "Original", now: capturedAt)
        let library = HistoryLibrary(store: store)
        library.hold(entry.id)
        document.crop = CGRect(x: 1, y: 2, width: 10, height: 8)
        let requested = document.snapshot
        var finishSave: (() -> Void)?
        let url = folder.appendingPathComponent("chosen.png")
        let completion = ScreenshotCompletion(history: library, save: { image, scale, destination, watermark, done in
            XCTAssertEqual(image.width, 20)
            XCTAssertEqual(image.height, 16)
            XCTAssertEqual(scale, 2)
            XCTAssertEqual(destination, url)
            XCTAssertFalse(watermark.watermark)
            finishSave = done
        }) { _, _, _ in XCTFail("Save-only copied") }
        var session = 1
        var presentations: [ScreenshotCompletion.Presentation?] = []
        var request = completion.prepare(document: document, undo: [original], label: "Ignored",
            id: entry.id, session: session, output: pixelOutput(false))
        try XCTUnwrap(request).saveAs(to: url, currentSession: { session }) { presentations.append($0) }
        request?.cancel() // An accepted output survives UI cancellation.
        request = nil // The output adapter retains the request.
        library.release(entry.id)
        document.crop = nil
        library.retention = .off
        session = 2
        drain(library)
        XCTAssertEqual(library.entries.first?.revision, entry.revision)
        let done = try XCTUnwrap(finishSave)
        done()
        done()
        drain(library)
        XCTAssertEqual(presentations.count, 1)
        XCTAssertNil(presentations.first!)
        let updated = try XCTUnwrap(library.entries.first)
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.createdAt, capturedAt)
        XCTAssertEqual(updated.snapshot, requested)
        XCTAssertEqual(updated.undo, [original])
    }

    func testUnchangedSaveReleasesOnlyOutputHoldAndDoesNotRenewRetention() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Expired",
            now: Date().addingTimeInterval(-40 * 86400))
        let library = HistoryLibrary(store: store)
        library.hold(entry.id)
        var finishSave: (() -> Void)?
        let completion = ScreenshotCompletion(history: library, save: { _, _, _, _, done in finishSave = done }) {
            _, _, _ in XCTFail("Save copied")
        }
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Expired",
            id: entry.id, session: 1, output: pixelOutput(true)))
        request.save(to: folder.appendingPathComponent("output.png"), currentSession: { 1 }) {
            XCTAssertEqual($0, .history(entry.id))
        }
        let done = try XCTUnwrap(finishSave)
        done()
        done()
        request.cancel()
        drain(library)
        XCTAssertEqual(library.entries.first?.revision, entry.revision)
        XCTAssertEqual(library.entries.first?.modifiedAt, entry.modifiedAt)
        library.release(entry.id)
        drain(library)
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testRealFileSaveCompletesDespiteHistoryFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("blocked-history")
        try Data("file blocks history directory".utf8).write(to: root)
        let library = HistoryLibrary(store: HistoryStore(url: root))
        let completion = ScreenshotCompletion(history: library) { _, _, _ in XCTFail("Successful save copied") }
        let request = try XCTUnwrap(completion.prepare(document: makeDocument(), undo: [], label: "Saved",
            session: 1, output: pixelOutput(false)))
        let url = folder.appendingPathComponent("saved.png")
        let saved = expectation(description: "File save completed")
        request.save(to: url, currentSession: { 1 }) {
            XCTAssertEqual($0, .close)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 3)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(image.size.width, 40)
        XCTAssertEqual(image.size.height, 30)
        awaitPublication(library) { $0.error != nil }
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testFailedSaveFallsBackToClipboardAndRecordsOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        let capturer = Capturer()
        let completion = ScreenshotCompletion(history: library, save: {
            capturer.save($0, scale: $1, to: $2, output: $3, completion: $4)
        }) { _, _, _ in XCTFail("Save-only performed an early copy") }
        var document = try makeDocument()
        document.crop = CGRect(x: 0, y: 0, width: 10, height: 8)
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Fallback",
            session: 1, output: pixelOutput(false)))
        let saved = expectation(description: "Clipboard fallback completed")
        request.save(to: folder.appendingPathComponent("missing/output.png"), currentSession: { 1 }) {
            XCTAssertEqual($0, .close)
            let data = NSPasteboard.general.data(forType: .png)
            let image = data.flatMap(NSImage.init(data:))
            XCTAssertEqual(image?.size.width, 10)
            XCTAssertEqual(image?.size.height, 8)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 3)
        XCTAssertNil(request.copy(currentSession: 1))
        drain(library)
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(library.entries.first?.snapshot, document.snapshot)
    }

    func testCancelledSaveAsPreservesEditableStateDeletionUndoAndEditorHold() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Expired",
            now: Date().addingTimeInterval(-40 * 86400))
        let deleted = try store.commit(document: document, undo: [], label: "Deleted")
        try store.delete(deleted.id)
        let library = HistoryLibrary(store: store)
        library.hold(entry.id)
        var changed = document
        changed.crop = CGRect(x: 1, y: 2, width: 10, height: 8)
        let completion = ScreenshotCompletion(history: library, save: { _, _, _, _, _ in
            XCTFail("Cancelled Save As wrote a file")
        }) { _, _, _ in XCTFail("Cancelled Save As copied") }
        let request = try XCTUnwrap(completion.prepare(document: changed, undo: [document.snapshot], label: "Expired",
            id: entry.id, session: 1, output: pixelOutput(false)))
        request.saveAs(to: nil, currentSession: { 1 }) { _ in XCTFail("Cancellation completed presentation") }
        request.cancel()
        drain(library)
        XCTAssertEqual(library.entries.first?.snapshot, document.snapshot)
        XCTAssertEqual(library.entries.first?.revision, entry.revision)
        XCTAssertEqual(changed.crop, CGRect(x: 1, y: 2, width: 10, height: 8))
        let undone = expectation(description: "Deletion undo preserved")
        library.undoDelete { XCTAssertEqual($0, deleted.id); undone.fulfill() }
        wait(for: [undone], timeout: 3)
        library.release(entry.id)
        drain(library)
        XCTAssertFalse(library.entries.contains { $0.id == entry.id })
    }

    func testSaveAndCopyPresentsBeforeWriteFinishesAndNeverRecordsAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        var copies = 0
        var finishSave: (() -> Void)?
        var presentations: [ScreenshotCompletion.Presentation?] = []
        let completion = ScreenshotCompletion(history: library, save: { _, _, _, _, done in
            XCTAssertEqual(copies, 1)
            XCTAssertEqual(presentations, [.close])
            finishSave = done
        }) { _, _, _ in copies += 1 }
        let request = try XCTUnwrap(completion.prepare(document: makeDocument(), undo: [], label: "Save and copy",
            session: 1, output: pixelOutput(false)))
        request.save(to: folder.appendingPathComponent("output.png"), copying: true, currentSession: { 1 }) {
            presentations.append($0)
        }
        XCTAssertEqual(copies, 1)
        awaitPublication(library) { $0.entries.count == 1 }
        let entry = try XCTUnwrap(library.entries.first)
        let done = try XCTUnwrap(finishSave)
        done()
        done()
        request.cancel()
        drain(library)
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(library.entries.first?.revision, entry.revision)
        XCTAssertEqual(presentations, [.close])
    }

    func testSaveWaitsForOutputBeforeRecordingAndPresentingExactlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        let url = folder.appendingPathComponent("result.png")
        var finishSave: (() -> Void)?
        var presentations: [ScreenshotCompletion.Presentation?] = []
        let completion = ScreenshotCompletion(history: library, save: { image, scale, destination, watermark, done in
            XCTAssertEqual(image.width, 80)
            XCTAssertEqual(scale, 2)
            XCTAssertEqual(destination, url)
            XCTAssertFalse(watermark.watermark)
            finishSave = done
        }) { _, _, _ in XCTFail("Save-only must not copy on success") }
        let request = try XCTUnwrap(completion.prepare(document: makeDocument(), undo: [], label: "Saved",
            session: 1, output: pixelOutput(false)))
        request.save(to: url, currentSession: { 1 }) { presentations.append($0) }
        XCTAssertTrue(presentations.isEmpty)
        XCTAssertTrue(library.entries.isEmpty)
        let done = try XCTUnwrap(finishSave)
        done()
        done()
        XCTAssertNil(request.copy(currentSession: 1))
        XCTAssertEqual(presentations, [.close])
        awaitPublication(library) { $0.entries.count == 1 }
        XCTAssertEqual(library.entries.first?.label, "Saved")
    }

    func testCopyRecordsOneEditableScreenshotAndIgnoresRepeatedCompletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HistoryLibrary(store: HistoryStore(url: folder))
        var copied: [(CGImage, CGFloat, Bool)] = []
        let completion = ScreenshotCompletion(history: library) { copied.append(($0, $1, $2.watermark)) }
        var document = try makeDocument()
        let original = document.snapshot
        document.crop = CGRect(x: 2, y: 3, width: 12, height: 8)
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [original],
            label: "Terminal", windowTitle: "Build", session: 1, output: pixelOutput(false)))

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
            id: entry.id, session: 3, output: pixelOutput(true)))
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
            id: entry.id, session: 3, output: pixelOutput(true)))
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
        let completion = ScreenshotCompletion(history: library) { image, _, marked in copied.append((image.width, marked.watermark)) }
        var document = try makeDocument()
        document.crop = CGRect(x: 0, y: 0, width: 10, height: 8)
        let requested = document.snapshot
        let request = try XCTUnwrap(completion.prepare(document: document, undo: [], label: "Requested",
            session: 1, output: pixelOutput(watermark)))
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
            id: entry.id, session: 1, output: pixelOutput(false)))
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
            id: entry.id, session: 1, output: pixelOutput(false)))
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
            session: 1, output: pixelOutput(false)))
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
            session: 1, output: pixelOutput(false)))
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
            id: entry.id, session: 1, output: pixelOutput(false))
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
            XCTAssertFalse(watermark.watermark)
            copies += 1
        }
        editor.onFinish = { finish, output in
            XCTAssertEqual(finish, .copy)
            let request = completion.prepare(document: editor.document, undo: editor.history.snapshots,
                label: "Editor", session: 1, output: self.pixelOutput(false), exported: output?.image)
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

    private func pixelOutput(_ enabled: Bool) -> OutputStyle {
        OutputStyle(watermark: enabled, style: ThemeCatalog.pixel.watermark)
    }

    private func makeDocument() throws -> EditDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        return EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 2)
    }

    private func drain(_ library: HistoryLibrary) {
        let drained = expectation(description: "History worker drained")
        library.load(UUID()) { _ in drained.fulfill() }
        wait(for: [drained], timeout: 3)
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
