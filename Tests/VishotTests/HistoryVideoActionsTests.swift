import XCTest
import AppKit
import AVFoundation
@testable import Vishot

final class HistoryVideoActionsTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HistoryStore(url: root.appendingPathComponent("History"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testValidationCacheAvoidsRepeatedDecodeAndDetectsDamageMissingAndReplacement() throws {
        let bytes = try playableMovie()
        let entry = try publish(movie: bytes)
        var decodes = 0
        let cached = HistoryStore(url: store.url, validateMovie: { url, width, height in
            decodes += 1
            try await VideoRecorder.validateMovie(at: url, width: width, height: height)
        })
        let movie = try store.movieURL(entry)
        XCTAssertFalse(try XCTUnwrap(cached.entries().first).unavailable)
        _ = try cached.validatedMovieURL(entry)
        _ = try cached.entries()
        XCTAssertEqual(decodes, 1)
        // Same inode, same length, restored mtime: ctime must still invalidate.
        let attributes = try FileManager.default.attributesOfItem(atPath: movie.path)
        try Data(repeating: 0, count: bytes.count).write(to: movie)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: movie.path)
        XCTAssertTrue(try XCTUnwrap(cached.entries().first).unavailable)
        XCTAssertTrue(try XCTUnwrap(cached.entries().first).unavailable)
        XCTAssertEqual(decodes, 2, "Known corruption is cached as well")
        try FileManager.default.removeItem(at: movie)
        XCTAssertTrue(try XCTUnwrap(cached.entries().first).unavailable)
        XCTAssertEqual(decodes, 2, "Missing files need no decoder")
        try bytes.write(to: movie, options: .atomic)
        XCTAssertFalse(try XCTUnwrap(cached.entries().first).unavailable)
        XCTAssertEqual(decodes, 3)
        try bytes.write(to: movie, options: .atomic)
        _ = try cached.validatedMovieURL(entry)
        XCTAssertEqual(decodes, 4, "Replacing a movie invalidates a successful result")
    }

    func testCompletedRescueProducesPlayableIndependentMovieAndClearCannotRemoveStaging() async throws {
        let directory = try store.stageVideo()
        let movie = directory.appendingPathComponent("completed.mp4")
        try playableMovie().write(to: movie)
        try store.clear()
        let destination = root.appendingPathComponent("rescued.mp4")
        try store.exportCompletedVideo(movie, to: destination)
        try store.recover()
        try await VideoRecorder.validateMovie(at: destination, width: 16, height: 16)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertTrue(try store.entries().isEmpty)
    }

    func testCorruptMovieRemainsUnavailableAndDeletableAfterRestart() throws {
        let entry = try publish(movie: Data("not an MP4".utf8))
        try store.recover()
        let restarted = HistoryStore(url: store.url)
        let listed = try XCTUnwrap(restarted.entries().first)
        XCTAssertEqual(listed.id, entry.id)
        XCTAssertTrue(listed.unavailable, "Nonempty corrupt media must not advertise playback/copy/export")
        XCTAssertFalse(restarted.warnings.isEmpty)
        try restarted.delete(entry.id)
        XCTAssertTrue(try restarted.entries().isEmpty)
        XCTAssertEqual(try restarted.undoDelete(), entry.id)
        XCTAssertTrue(try XCTUnwrap(restarted.entries().first).unavailable)
    }

    func testUnavailableVideoActionsExposeOnlyBrowsingAndDeletion() throws {
        var entry = try publish(movie: Data([1]))
        entry.unavailable = true
        XCTAssertFalse(entry.canUseVideo)
        XCTAssertFalse(HistoryBrowser.keys(for: entry).contains { ["open video", "copy file", "Reveal", "Save As"].contains($0.action) })
        XCTAssertTrue(HistoryBrowser.keys(for: entry).contains { $0.action == "delete" })
        entry.unavailable = false
        XCTAssertTrue(entry.canUseVideo)
        XCTAssertTrue(HistoryBrowser.keys(for: entry).contains { $0.action == "copy file" })
        XCTAssertTrue(HistoryBrowser.keys(for: entry).contains { $0.action == "Save As" })
    }

    func testOwnedMovieCannotResolveThroughAnEntryDirectorySymlink() throws {
        let entry = try publish(movie: Data([1, 2, 3]))
        let directory = store.url.appendingPathComponent(entry.id.uuidString)
        let outside = root.appendingPathComponent("external")
        try FileManager.default.moveItem(at: directory, to: outside)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        XCTAssertThrowsError(try store.movieURL(entry))
    }

    func testRestartOffRetentionAndDeleteUndoLeaveIndependentPlayableExportIntact() throws {
        let entry = try publish(movie: playableMovie())
        let source = try store.movieURL(entry)
        let export = root.appendingPathComponent("saved.mp4")
        try store.exportVideo(entry, to: export)
        let abandoned = try store.stageVideo()
        try Data([0]).write(to: abandoned.appendingPathComponent("partial.mp4"))
        let restarted = HistoryStore(url: store.url)
        try restarted.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        let listed = try XCTUnwrap(restarted.entries().first)
        XCTAssertFalse(listed.unavailable)
        XCTAssertEqual(listed.video?.durationLabel, "0:01")
        XCTAssertEqual(HistorySearch.matches("Demo vishot-test", in: [listed]).map(\.id), [entry.id])
        XCTAssertNotNil(try restarted.preview(listed, thumbnail: true))
        XCTAssertFalse(try restarted.index(entry.id, revision: entry.revision, text: "video OCR"))
        try restarted.delete(entry.id)
        XCTAssertTrue(try restarted.entries().isEmpty)
        XCTAssertEqual(try restarted.undoDelete(), entry.id)
        XCTAssertEqual(try restarted.movieURL(listed), source)
        try restarted.cleanup(retention: .threeDays)
        try restarted.cleanup(retention: .off, now: Date().addingTimeInterval(2 * 86400))
        XCTAssertEqual(try restarted.entries().count, 1)
        try restarted.cleanup(retention: .off, now: Date().addingTimeInterval(4 * 86400))
        XCTAssertTrue(try restarted.entries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: export), try playableBytes)
    }

    func testMissingAndCorruptMediaRejectFileActionsWithoutLosingMetadataOrExporting() throws {
        for missing in [false, true] {
            let entry = try publish(movie: Data([1, 2, 3]))
            if missing { try FileManager.default.removeItem(at: store.movieURL(entry)) }
            let library = HistoryLibrary(store: store)
            let unavailable = expectation(description: "Unavailable reference rejected")
            library.videoFile(entry) { result in
                if case .success = result { XCTFail("Invalid media was handed to AppKit") }
                unavailable.fulfill()
            }
            let exported = expectation(description: "Unavailable export rejected")
            let destination = root.appendingPathComponent("invalid-export.mp4")
            library.exportVideo(entry, to: destination) { result in
                if case .success = result { XCTFail("Invalid media exported") }
                exported.fulfill()
            }
            wait(for: [unavailable, exported], timeout: 5)
            XCTAssertNotNil(library.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(try XCTUnwrap(store.entries().first { $0.id == entry.id }).unavailable)
        }
    }

    func testUnknownSchemaAssetsAndDeletionMarkerSurviveRecoveryExpiryButNotExplicitClear() throws {
        let directory = store.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unknown = Data("{\"schema\":999}".utf8)
        let owned = Data([7, 8, 9])
        try unknown.write(to: directory.appendingPathComponent("entry.json"))
        try owned.write(to: directory.appendingPathComponent("future.asset"))
        try Data().write(to: directory.appendingPathComponent("deleted"))
        try store.recover()
        try store.cleanup(retention: .oneDay, now: Date().addingTimeInterval(100 * 86400))
        XCTAssertFalse(store.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("entry.json")), unknown)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("future.asset")), owned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("deleted").path))
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAtomicExportReplacesOnlyOnSuccessAndSurvivesPrivateClear() throws {
        let entry = try publish(movie: Data([1, 2, 3]))
        let source = try store.movieURL(entry)
        let destination = root.appendingPathComponent("export.mp4")
        try Data([9]).write(to: destination)
        try store.exportVideo(entry, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        try Data([4]).write(to: destination)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]), "Export is not a hard link")
        try store.clear()
        XCTAssertEqual(try Data(contentsOf: destination), Data([4]))
    }

    func testFailedAndCancelledCopiesNeverPublishPartialDestinations() throws {
        let entry = try publish(movie: Data([1, 2, 3]))
        let source = try store.movieURL(entry)
        for existing in [false, true] {
            let destination = root.appendingPathComponent("export.mp4")
            if existing { try Data([9]).write(to: destination) }
            for cancel in [false, true] {
                var copied = false
                XCTAssertThrowsError(try store.exportVideo(entry, to: destination, cancelled: { cancel && copied }, copy: { _, temporary in
                    XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), existing)
                    try Data([5]).write(to: temporary)
                    copied = true
                    if !cancel { throw CocoaError(.fileWriteOutOfSpace) }
                }))
                if existing { XCTAssertEqual(try Data(contentsOf: destination), Data([9])) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
                XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".vishot-export-") })
            }
        }
        let directory = root.appendingPathComponent("directory.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data([8]).write(to: directory.appendingPathComponent("keep"))
        XCTAssertThrowsError(try store.exportVideo(entry, to: directory), "Atomic publication can fail after a successful copy")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), Data([8]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".vishot-export-") })
    }

    func testExportRejectsSourceAliasesAndEveryPrivateDestination() throws {
        let entry = try publish(movie: Data([1, 2, 3]))
        let source = try store.movieURL(entry)
        let symlink = root.appendingPathComponent("alias.mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let hardlink = root.appendingPathComponent("hardlink.mp4")
        try FileManager.default.linkItem(at: source, to: hardlink)
        for destination in [source, symlink, hardlink, source.deletingLastPathComponent().appendingPathComponent("another.mp4"),
                            store.stagingURL.appendingPathComponent("export.mp4")] {
            XCTAssertThrowsError(try store.exportVideo(entry, to: destination))
            XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        }
    }

    func testActiveFileOperationHoldsSourceAgainstClearAndFinalDeletion() throws {
        for clear in [false, true] {
            let entry = try publish(movie: Data([1, 2, 3]))
            let source = try store.movieURL(entry)
            let library = HistoryLibrary(store: store)
            library.hold(entry.id)
            if clear { library.clear() } else { library.delete(entry.id); library.finishSession() }
            let fence = expectation(description: "Mutation serialized")
            library.load(entry.id) { _ in fence.fulfill() }
            wait(for: [fence], timeout: 3)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Active file operation owns a live source")
            library.release(entry.id)
            let released = expectation(description: "Deferred removal finished")
            library.load(entry.id) { _ in released.fulfill() }
            wait(for: [released], timeout: 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testVideoFileReferenceAndExportUseValidatedOwnedMovieWithoutPinningClipboard() throws {
        let entry = try publish(movie: playableMovie(), now: Date().addingTimeInterval(-2 * 86400))
        let source = try store.movieURL(entry)
        XCTAssertFalse(try XCTUnwrap(store.entries().first).unavailable)
        let library = HistoryLibrary(store: store)
        let resolved = expectation(description: "Direct owned reference")
        library.videoFile(entry) { result in
            XCTAssertEqual(try? result.get(), source)
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 5)
        let destination = root.appendingPathComponent("independent.mp4")
        let exported = expectation(description: "Validated export")
        library.exportVideo(entry, to: destination) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            exported.fulfill()
        }
        wait(for: [exported], timeout: 5)
        let expired = expectation(description: "Ordinary expiry invalidates copied reference")
        library.onChange = {
            if library.entries.isEmpty { library.onChange = nil; expired.fulfill() }
        }
        library.retention = .oneDay
        wait(for: [expired], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), try playableBytes)
    }

    func testCancelledExportCompletesWithoutDestinationOrErrorAndReleasesItsHold() throws {
        let entry = try publish(movie: playableMovie(), now: Date().addingTimeInterval(-2 * 86400))
        let source = try store.movieURL(entry)
        let library = HistoryLibrary(store: store)
        // A separate hold keeps expiry away until the canceled operation has released its own.
        library.hold(entry.id)
        let destination = root.appendingPathComponent("cancelled.mp4")
        let finished = expectation(description: "Cancellation delivered")
        let request = library.exportVideo(entry, to: destination) { result in
            guard case .failure(let error) = result else { XCTFail("Canceled export succeeded"); return }
            XCTAssertTrue(error is CancellationError)
            finished.fulfill()
        }
        request.cancel()
        library.retention = .oneDay
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(library.error)
        let expired = expectation(description: "All operation holds released")
        library.onChange = {
            if library.entries.isEmpty { library.onChange = nil; expired.fulfill() }
        }
        library.release(entry.id)
        wait(for: [expired], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    private var playableBytes: Data { get throws { try Data(contentsOf: root.appendingPathComponent("fixture.mp4")) } }

    private func playableMovie() throws -> Data {
        let url = root.appendingPathComponent("fixture.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 0, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = Date().addingTimeInterval(3)
        while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(adaptor.append(pixel, withPresentationTime: .zero))
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        let finished = expectation(description: "Playable fixture finalized")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        return try Data(contentsOf: url)
    }

    private func publish(movie: Data, now: Date = Date()) throws -> HistoryEntry {
        let stage = try store.stageVideo()
        try movie.write(to: stage.appendingPathComponent("vishot-test.mp4"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let png = try XCTUnwrap(ImageEncoding.data(try XCTUnwrap(context.makeImage()), scale: 1, type: .png))
        try png.write(to: stage.appendingPathComponent("thumbnail.png"))
        let video = HistoryVideo(movie: "vishot-test.mp4", thumbnail: "thumbnail.png", duration: 1,
            width: 16, height: 16, displayID: 1, frame: CGRect(x: 0, y: 0, width: 16, height: 16), scale: 1)
        return try store.publishVideo(staging: stage, video: video, label: "Display", windowTitle: "Demo", now: now)
    }
}
