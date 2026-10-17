import XCTest
import AppKit
@testable import Vishot

final class HistoryReadLifetimeTests: XCTestCase {
    func testDeletedAndExpiredRequestsCompleteWithoutDamage() throws {
        for expire in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = HistoryStore(url: folder)
            let entry = try store.commit(document: makeDocument(), undo: [], label: "Obsolete",
                now: Date().addingTimeInterval(-2 * 86400))
            if expire { try store.cleanup(retention: .oneDay) } else { try store.delete(entry.id) }
            let library = HistoryLibrary(store: store)
            let finished = expectation(description: "Obsolete read releases caller")
            library.image(entry, thumbnail: false) { image in XCTAssertNil(image); finished.fulfill() }
            wait(for: [finished], timeout: 3)
            XCTAssertNil(library.error)
        }
    }

    func testClearRetiresPendingDecodeFailureWithoutSuppressingCompletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let entry = try store.commit(document: makeDocument(), undo: [], label: "Removed")
        try store.index(entry.id, revision: entry.revision, text: "")
        let asset = folder.appendingPathComponent(entry.id.uuidString)
            .appendingPathComponent("\(entry.revision.uuidString)-preview.png")
        try Data("broken".utf8).write(to: asset)
        let reader = DispatchQueue(label: "test.history.clear.decode")
        reader.suspend()
        let library = HistoryLibrary(store: store, browserReader: reader)
        let completed = expectation(description: "Removed read finishes without image")
        library.image(entry, thumbnail: false) { image in
            XCTAssertNil(image)
            completed.fulfill()
        }
        let cleared = expectation(description: "Clear published before decode")
        library.onChange = { library.onChange = nil; cleared.fulfill() }
        library.clear()
        wait(for: [cleared], timeout: 3)
        reader.resume()
        wait(for: [completed], timeout: 3)
        drain(reader)
        XCTAssertNil(library.error, "Late decoding cannot resurrect damage for explicitly cleared storage")
    }

    func testCancelledUnreadableReadDoesNotReportDamage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let entry = try store.commit(document: makeDocument(), undo: [], label: "Cancelled")
        let asset = folder.appendingPathComponent(entry.id.uuidString)
            .appendingPathComponent("\(entry.revision.uuidString)-preview.png")
        try Data("broken".utf8).write(to: asset)
        let reader = DispatchQueue(label: "test.history.decode")
        reader.suspend()
        let library = HistoryLibrary(store: store, browserReader: reader)
        let request = library.image(entry, thumbnail: false) { _ in XCTFail("Cancelled failure delivered") }
        let fence = expectation(description: "Bytes read")
        library.load(entry.id) { _ in fence.fulfill() }
        wait(for: [fence], timeout: 3)
        reader.resume()
        reader.sync {}
        request.cancel()
        drain(reader)
        XCTAssertNil(library.error)
    }

    func testObsoleteEntriesCompleteWithoutDamageButUnreadableCurrentAssetsAreReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let old = try store.commit(document: document, undo: [], label: "A")
        document.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        let current = try store.commit(document: document, undo: [], label: "B", id: old.id)
        let reader = DispatchQueue(label: "test.history.decode")
        let library = HistoryLibrary(store: store, browserReader: reader)
        let obsolete = expectation(description: "Obsolete request completes without an image")
        library.image(old, thumbnail: false) { image in
            XCTAssertNil(image)
            obsolete.fulfill()
        }
        let fence = expectation(description: "Obsolete request processed")
        library.load(current.id) { _ in fence.fulfill() }
        wait(for: [fence, obsolete], timeout: 3)
        drain(reader)
        XCTAssertNil(library.error)
        let asset = folder.appendingPathComponent(current.id.uuidString)
            .appendingPathComponent("\(current.revision.uuidString)-preview.png")
        try Data("not an image".utf8).write(to: asset)
        let failed = expectation(description: "Actual unreadable preview reported")
        library.image(current, thumbnail: false) { image in
            XCTAssertNil(image)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        drain(reader)
        XCTAssertNotNil(library.error)
    }

    func testPendingReadsAndCancellationDoNotRetainDeletedOrExpiredAssets() throws {
        for expire in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = HistoryStore(url: folder)
            let entry = try store.commit(document: makeDocument(), undo: [], label: "Retained",
                now: Date().addingTimeInterval(-2 * 86400))
            try store.index(entry.id, revision: entry.revision, text: "")
            let reader = DispatchQueue(label: "test.history.decode")
            reader.suspend()
            let library = HistoryLibrary(store: store, browserReader: reader)
            let read = expectation(description: "Already requested bytes remain readable")
            library.image(entry, thumbnail: false) { image in
                XCTAssertEqual(image?.width, 80)
                read.fulfill()
            }
            let cancelled = library.image(entry, thumbnail: true) { _ in XCTFail("Cancelled read delivered") }
            cancelled.cancel()
            let removed = expectation(description: "Assets removed before decoding")
            removed.expectedFulfillmentCount = expire ? 1 : 2
            var publications = 0
            library.onChange = {
                publications += 1
                if publications == (expire ? 1 : 2) { library.onChange = nil }
                removed.fulfill()
            }
            if expire {
                library.retention = .oneDay
            } else {
                library.delete(entry.id)
                library.finishSession()
            }
            wait(for: [removed], timeout: 3)
            XCTAssertTrue(library.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.id.uuidString).path))
            reader.resume()
            wait(for: [read], timeout: 3)
            drain(reader)
            XCTAssertNil(library.error)
            XCTAssertTrue(library.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.id.uuidString).path))
        }
    }

    func testSelectionReplacementCancelsAlreadyDecodedCallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let first = try store.commit(document: makeDocument(), undo: [], label: "First")
        var secondDocument = try makeDocument()
        secondDocument.crop = CGRect(x: 0, y: 0, width: 10, height: 5)
        let second = try store.commit(document: secondDocument, undo: [], label: "Second")
        let reader = DispatchQueue(label: "test.history.decode")
        reader.suspend()
        let library = HistoryLibrary(store: store, browserReader: reader)
        let request = library.image(first, thumbnail: false) { _ in XCTFail("Old selection callback delivered") }
        // Fence the worker, then finish decoding while main-queue delivery is blocked.
        let loaded = expectation(description: "Read queued")
        library.load(first.id) { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 3)
        reader.resume()
        reader.sync {}
        request.cancel()
        let selected = expectation(description: "New selection displayed")
        library.image(second, thumbnail: false) { image in
            XCTAssertEqual(image?.width, 20)
            XCTAssertEqual(image?.height, 10)
            selected.fulfill()
        }
        wait(for: [selected], timeout: 3)
        drain(reader)
        XCTAssertNil(library.error)
    }

    private func drain(_ queue: DispatchQueue) {
        let drained = expectation(description: "All decoded callbacks delivered")
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 3)
    }

    func testRevisionAReadsSurvivePublicationOfB() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        let document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "A")
        // Prevent OCR from adding unrelated publications to this controlled interleaving.
        try store.index(entry.id, revision: entry.revision, text: "")
        let reader = DispatchQueue(label: "test.history.decode")
        reader.suspend()
        let library = HistoryLibrary(store: store, browserReader: reader)
        let thumbnail = expectation(description: "A thumbnail finishes after B publication")
        let preview = expectation(description: "A preview finishes after B publication")
        library.image(entry, thumbnail: true) { image in
            XCTAssertEqual(image?.width, 80)
            XCTAssertEqual(image?.height, 60)
            thumbnail.fulfill()
        }
        library.image(entry, thumbnail: false, maxPixelSize: 20) { image in
            XCTAssertEqual(image?.width, 20)
            XCTAssertEqual(image?.height, 15)
            preview.fulfill()
        }
        var edited = document
        edited.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        let published = expectation(description: "B published while A reads pending")
        library.onChange = {
            if library.entries.first?.snapshot.crop == edited.crop {
                library.onChange = nil
                published.fulfill()
            }
        }
        library.commit(document: edited, undo: [], label: "B", id: entry.id)
        wait(for: [published], timeout: 3)
        reader.resume()
        wait(for: [thumbnail, preview], timeout: 3)
        XCTAssertNil(library.error)
        let loaded = expectation(description: "Native editable source retained")
        library.load(entry.id) { result in
            XCTAssertEqual(result?.document.image.width, 80)
            XCTAssertEqual(result?.document.scale, 2)
            XCTAssertEqual(result?.entry.id, entry.id)
            XCTAssertEqual(result?.entry.createdAt, entry.createdAt)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
    }

    private func makeDocument() throws -> EditDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 2)
    }
}
