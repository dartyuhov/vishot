import XCTest
import AppKit
@testable import Vishot

final class HistoryPersistenceTests: XCTestCase {
    func testNewCaptureStagingAndCleanupFailuresRecoverIndependently() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? files.removeItem(at: folder)
        }
        let store = HistoryStore(url: folder)
        let library = HistoryLibrary(store: store)
        let document = try makeDocument()
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        changed(library, until: { library.error != nil }) {
            library.commit(document: document, undo: [], label: "Cannot stage")
        }
        let stagingError = try XCTUnwrap(library.error)
        XCTAssertTrue(try store.entries().isEmpty)
        changed(library, until: { library.error != stagingError }) { library.cleanup() }
        let bothErrors = try XCTUnwrap(library.error)
        XCTAssertTrue(bothErrors.contains(stagingError))
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        changed(library, until: { library.entries.count == 1 }) {
            library.commit(document: document, undo: [], label: "Equivalent new capture")
        }
        XCTAssertNotNil(library.error, "A successful new capture cannot clear failed retention persistence")
        XCTAssertNotEqual(library.error, bothErrors)
        changed(library, until: { library.error == nil }) { library.cleanup() }
        XCTAssertEqual(try store.load(try XCTUnwrap(library.entries.first).id).document.snapshot, document.snapshot)
    }

    func testDiskWriteErrorsSurviveUnrelatedRecoveryAndOCR() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let first = try store.commit(document: document, undo: [], label: "First")
        let second = try store.commit(document: document, undo: [], label: "Second")
        let library = HistoryLibrary(store: store)
        document.crop = CGRect(x: 2, y: 2, width: 10, height: 10)
        let firstFolder = folder.appendingPathComponent(first.id.uuidString)
        let secondMetadata = folder.appendingPathComponent(second.id.uuidString).appendingPathComponent("entry.json")
        defer {
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstFolder.path)
            try? files.setAttributes([.immutable: false], ofItemAtPath: secondMetadata.path)
        }
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: firstFolder.path)
        changed(library, until: { library.error != nil }) {
            library.commit(document: document, undo: [], label: "Asset failure", id: first.id)
        }
        let assetError = try XCTUnwrap(library.error)
        try files.setAttributes([.immutable: true], ofItemAtPath: secondMetadata.path)
        changed(library, until: { library.error != assetError }) {
            library.commit(document: document, undo: [], label: "Metadata failure", id: second.id)
        }
        XCTAssertTrue(try XCTUnwrap(library.error).contains(assetError))
        XCTAssertEqual(try store.load(first.id).document.snapshot, first.snapshot)
        XCTAssertEqual(try store.load(second.id).document.snapshot, second.snapshot)

        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstFolder.path)
        try files.setAttributes([.immutable: false], ofItemAtPath: secondMetadata.path)
        changed(library, until: { library.entries.first(where: { $0.id == second.id })?.snapshot == document.snapshot }) {
            library.commit(document: document, undo: [], label: "Metadata recovery", id: second.id)
        }
        XCTAssertEqual(library.error, assetError, "Recovering another entry must retain the failed asset write")
        changed(library, until: { library.entries.count == 2 && library.entries.allSatisfy { $0.recognizedText != nil } }) {
            library.cleanup()
        }
        XCTAssertEqual(library.error, assetError, "Successful cleanup and OCR cannot recover a commit")
        changed(library, until: { library.entries.count == 3 }) {
            library.commit(document: document, undo: [], label: "Unrelated new capture")
        }
        XCTAssertEqual(library.error, assetError)
        changed(library, until: { library.error == nil }) {
            library.commit(document: document, undo: [], label: "Asset recovery", id: first.id)
        }
        XCTAssertEqual(try store.load(first.id).document.snapshot, document.snapshot)
    }

    private func changed(_ library: HistoryLibrary, until predicate: @escaping () -> Bool, action: () -> Void,
                         file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "History state changes")
        library.onChange = {
            if predicate() { library.onChange = nil; done.fulfill() }
        }
        action()
        wait(for: [done], timeout: 10)
        library.onChange = nil
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testDiskFailuresPreserveCommittedPixelsMetadataAndUndo() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let original = document.snapshot
        document.crop = CGRect(x: 1, y: 2, width: 20, height: 15)
        let entry = try store.commit(document: document, undo: [original], label: "Committed")
        let directory = folder.appendingPathComponent(entry.id.uuidString)
        let metadata = directory.appendingPathComponent("entry.json")
        let committedMetadata = try Data(contentsOf: metadata)
        let committedPreview = try store.preview(entry).dataProvider?.data as Data?
        let committedOriginal = document.image.dataProvider?.data as Data?
        let committedFiles = Set(try files.contentsOfDirectory(atPath: directory.path))
        document.crop = CGRect(x: 3, y: 4, width: 10, height: 8)

        // A non-writable directory fails an actual revision asset write. An immutable
        // entry.json lets assets stage, but rejects the atomic metadata switch.
        for metadataFault in [false, true] {
            if metadataFault {
                try files.setAttributes([.immutable: true], ofItemAtPath: metadata.path)
            } else {
                try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            }
            do {
                defer {
                    try? files.setAttributes([.immutable: false], ofItemAtPath: metadata.path)
                    try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
                }
                XCTAssertThrowsError(try store.commit(document: document, undo: [original, entry.snapshot],
                    label: "Edited", id: entry.id))
            }
            XCTAssertEqual(try Data(contentsOf: metadata), committedMetadata)
            let restored = try HistoryStore(url: folder).load(entry.id)
            XCTAssertEqual(restored.entry, entry)
            XCTAssertEqual(restored.undo, [original])
            XCTAssertEqual(restored.document.image.dataProvider?.data as Data?, committedOriginal)
            XCTAssertEqual(try store.preview(entry).dataProvider?.data as Data?, committedPreview)
            XCTAssertEqual(Set(try files.contentsOfDirectory(atPath: directory.path)), committedFiles)
        }
        let updated = try store.commit(document: document, undo: [entry.snapshot], label: "Retry", id: entry.id)
        XCTAssertEqual(try store.load(entry.id).document.snapshot, document.snapshot)
        XCTAssertEqual(updated.createdAt, entry.createdAt)
        XCTAssertNotEqual(updated.revision, entry.revision)
    }

    func testFailedUpdateSurvivesCleanupReadsAndOCRUntilEquivalentCommitRecovers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder)
        var document = try makeDocument()
        let entry = try store.commit(document: document, undo: [], label: "Committed")
        let library = HistoryLibrary(store: store)
        document.crop = CGRect(x: 100, y: 100, width: 10, height: 10)
        let failed = expectation(description: "Failed update is reported")
        library.onChange = {
            if library.error != nil { library.onChange = nil; failed.fulfill() }
        }
        library.commit(document: document, undo: [], label: "Failed", id: entry.id)
        wait(for: [failed], timeout: 3)
        let failure = library.error

        let indexed = expectation(description: "Cleanup and OCR finish")
        library.onChange = {
            if library.entries.first?.recognizedText != nil { library.onChange = nil; indexed.fulfill() }
        }
        library.cleanup()
        wait(for: [indexed], timeout: 10)
        XCTAssertEqual(library.error, failure)
        let loaded = expectation(description: "Committed document remains readable")
        library.load(entry.id) { result in
            XCTAssertEqual(result?.document.snapshot, entry.snapshot)
            loaded.fulfill()
        }
        let preview = expectation(description: "Committed preview remains readable")
        library.image(try XCTUnwrap(library.entries.first), thumbnail: false) { image in
            XCTAssertEqual(image?.width, 40)
            preview.fulfill()
        }
        wait(for: [loaded, preview], timeout: 3)
        XCTAssertEqual(library.error, failure)

        let recovered = expectation(description: "Equivalent successful update clears failure")
        library.onChange = {
            if library.error == nil { library.onChange = nil; recovered.fulfill() }
        }
        library.commit(document: try makeDocument(), undo: [], label: "Retry", id: entry.id)
        wait(for: [recovered], timeout: 3)
    }

    private func makeDocument() throws -> EditDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditDocument(image: try XCTUnwrap(context.makeImage()), scale: 1)
    }
}
