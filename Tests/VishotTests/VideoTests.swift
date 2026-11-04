import XCTest
import VishotRendering
import CoreMedia
@testable import Vishot

final class VideoTests: XCTestCase {
    func testCadencePreservesRoundedAndJitteredNominalThirtyWithoutHalvingRate() {
        for jitter in [false, true] {
            var timeline = VideoTimeline()
            var accepted = 0
            for index in 0..<301 {
                let offset = jitter && index > 0 ? (index.isMultiple(of: 2) ? 400 : -400) : 0
                let time = CMTime(value: Int64(index * 33_333 + offset), timescale: 1_000_000)
                if let relative = timeline.admit(time) {
                    accepted += 1
                    XCTAssertEqual(relative, time, "Cadence must preserve sample times")
                }
            }
            XCTAssertEqual(accepted, 301, "Rounding/jitter must not reduce nominal 30fps to 15fps")
        }
    }

    func testCadenceRejectsSustainedExcessRateWithoutCatchupBurstAfterGap() {
        for rate in [31, 60, 120, 600] {
            var limited = VideoTimeline()
            let count = (0..<(rate * 10)).filter {
                limited.admit(CMTime(value: Int64($0), timescale: Int32(rate))) != nil
            }.count
            XCTAssertEqual(count, 300, "A bounded early allowance must not accumulate at \(rate)fps")
        }
        var timeline = VideoTimeline()
        var accepted = 0
        for index in 0..<600 {
            if timeline.admit(CMTime(value: Int64(index), timescale: 60)) != nil { accepted += 1 }
        }
        XCTAssertEqual(accepted, 300)
        XCTAssertEqual(timeline.admit(CMTime(value: 20, timescale: 1)), CMTime(value: 20, timescale: 1))
        XCTAssertNil(timeline.admit(CMTime(value: 20_001, timescale: 1000)), "Idle time cannot bank a burst")
        var rapid = VideoTimeline()
        XCTAssertEqual(rapid.admit(.zero), .zero)
        XCTAssertEqual(rapid.endpoint(host: CMTime(value: 1, timescale: 600)), CMTime(value: 1, timescale: 30))
    }
    func testStartingCannotRegressOrBeginAgainAndTerminalCallbacksAreFenced() {
        var state = VideoSessionState()
        let token = state.begin()
        XCTAssertTrue(state.advance(token, to: .starting))
        XCTAssertFalse(state.advance(token, to: .countdown))
        XCTAssertEqual(state.begin(), token, "An active session cannot be replaced")
        XCTAssertTrue(state.stop())
        XCTAssertFalse(state.stop())
        XCTAssertFalse(state.advance(token, to: .recording))
        state.finish(failed: true)
        XCTAssertFalse(state.advance(token, to: .recording))
        XCTAssertEqual(state.begin(), token, "Rescue keeps exclusive ownership")
        state.finish()
        let next = state.begin()
        XCTAssertNotEqual(next, token)
        XCTAssertFalse(state.advance(token, to: .recording))
    }
    func testCompletedRescueRetainsSoleCopyOnCancellationAndDiskFailureThenExportsIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(url: root.appendingPathComponent("History"))
        let directory = try store.stageVideo()
        let movie = directory.appendingPathComponent("completed.mp4")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: movie)
        let destination = root.appendingPathComponent("saved.mp4")
        try Data([9]).write(to: destination)
        XCTAssertThrowsError(try store.exportCompletedVideo(movie, to: destination, cancelled: { true }))
        XCTAssertThrowsError(try store.exportCompletedVideo(movie, to: destination, copy: { _, temporary in
            try Data([0]).write(to: temporary)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertEqual(try Data(contentsOf: movie), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        XCTAssertThrowsError(try store.exportCompletedVideo(movie, to: movie))
        let alias = root.appendingPathComponent("alias.mp4")
        try FileManager.default.linkItem(at: movie, to: alias)
        XCTAssertThrowsError(try store.exportCompletedVideo(movie, to: alias))
        try store.exportCompletedVideo(movie, to: destination)
        try store.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".vishot-export-") })
    }
    func testSchemaOneScreenshotLoadsAndMigratesOnlyOnWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(url: root.appendingPathComponent("History"))
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let document = EditDocument(image: context.makeImage()!, scale: 1)
        var entry = try store.commit(document: document, undo: [], label: "Legacy")
        entry.schema = 1
        let metadata = store.url.appendingPathComponent(entry.id.uuidString).appendingPathComponent("entry.json")
        let legacy = try JSONEncoder().encode(entry)
        try legacy.write(to: metadata)
        try store.recover()
        XCTAssertEqual(try Data(contentsOf: metadata), legacy)
        XCTAssertEqual(try store.load(entry.id).document.size, CGSize(width: 4, height: 4))
        XCTAssertEqual(try store.commit(document: document, undo: [], label: "", id: entry.id).schema, 2)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
        XCTAssertNotNil(json["payload"])
        XCTAssertNil(json["snapshot"])
    }

    func testFailedPublicationRetainsStagingAndNeverExposesPartialEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(url: root.appendingPathComponent("History"))
        let staging = try store.stageVideo()
        let movie = staging.appendingPathComponent("clip.mp4")
        try Data([1]).write(to: movie)
        try Data([2]).write(to: staging.appendingPathComponent("thumbnail.png"))
        let video = HistoryVideo(movie: "clip.mp4", thumbnail: "thumbnail.png", duration: 1, width: 100, height: 100,
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
        // A regular file where History must be forces the same publication disk failure.
        try Data().write(to: store.url)
        XCTAssertThrowsError(try store.publishVideo(staging: staging, video: video, label: "Display"))
        XCTAssertEqual(try Data(contentsOf: movie), Data([1]))
        try FileManager.default.removeItem(at: store.url)
        XCTAssertTrue(try store.entries().isEmpty)
        var unsafe = video
        unsafe = HistoryVideo(movie: "../clip.mp4", thumbnail: "thumbnail.png", duration: 1, width: 100, height: 100,
            displayID: 1, frame: video.frame, scale: 1)
        XCTAssertThrowsError(try store.publishVideo(staging: staging, video: unsafe, label: "Display"))
        try store.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testUnknownSchemaAndVideoDeleteUndoHoldSurviveCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(url: root.appendingPathComponent("History"))
        let staging = try store.stageVideo()
        try Data([1]).write(to: staging.appendingPathComponent("clip.mp4"))
        try Data([2]).write(to: staging.appendingPathComponent("thumbnail.png"))
        let video = HistoryVideo(movie: "clip.mp4", thumbnail: "thumbnail.png", duration: 1, width: 100, height: 100,
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
        let entry = try store.publishVideo(staging: staging, video: video, label: "Monitor")
        XCTAssertEqual(HistorySearch.matches("clip.mp4", in: try store.entries()).count, 1)
        try store.delete(entry.id)
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertEqual(try store.undoDelete(), entry.id)
        try store.cleanup(retention: .oneDay, holding: [entry.id], now: Date().addingTimeInterval(172800))
        XCTAssertEqual(try store.entries().count, 1)
        let directory = store.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unknown = Data("{\"schema\":99}".utf8)
        try unknown.write(to: directory.appendingPathComponent("entry.json"))
        try Data().write(to: directory.appendingPathComponent("deleted"))
        try store.recover()
        try store.cleanup(retention: .oneDay, now: Date().addingTimeInterval(172800))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("entry.json")), unknown)
        XCTAssertFalse(store.warnings.isEmpty)
    }
    func testIntakeBoundsAndStopCutoff() {
        let intake = VideoIntake()
        XCTAssertTrue(intake.admit(.zero))
        XCTAssertTrue(intake.admit(.zero))
        XCTAssertTrue(intake.admit(.zero))
        XCTAssertFalse(intake.admit(.zero))
        intake.release()
        XCTAssertTrue(intake.admit(.zero))
        intake.close(at: CMTime(value: 2, timescale: 1))
        XCTAssertFalse(intake.admit(.zero))
        XCTAssertTrue(intake.allows(CMTime(value: 2, timescale: 1)))
        XCTAssertFalse(intake.allows(CMTime(value: 3, timescale: 1)))
    }

    func testCountdownCancellationFencesPreparedCallbackAndStopIsIdempotent() {
        var state = VideoSessionState()
        let first = state.begin()
        XCTAssertTrue(state.cancel(first))
        let second = state.begin()
        XCTAssertFalse(state.advance(first, to: .starting))
        XCTAssertTrue(state.advance(second, to: .starting))
        XCTAssertTrue(state.stop())
        XCTAssertFalse(state.stop())
        XCTAssertFalse(state.advance(second, to: .recording))
    }
    func testVideoPublicationRecoveryAndMissingMediaRemainOwned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(url: root.appendingPathComponent("History"))
        let staging = try store.stageVideo()
        let movie = staging.appendingPathComponent("vishot-test.mp4")
        try Data([1, 2, 3]).write(to: movie)
        let video = HistoryVideo(movie: movie.lastPathComponent, thumbnail: "thumbnail.png", duration: 11,
            width: 1920, height: 1080, displayID: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        try Data([4]).write(to: staging.appendingPathComponent("thumbnail.png"))
        let entry = try store.publishVideo(staging: staging, video: video, label: "Display 1")
        XCTAssertEqual(entry.schema, 2)
        try store.recover()
        XCTAssertEqual(try store.entries().first?.video, video)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.movieURL(entry).path))
        try FileManager.default.removeItem(at: try store.movieURL(entry))
        XCTAssertEqual(try store.entries().count, 1)
        XCTAssertThrowsError(try store.movieURL(entry))
        try store.cleanup(retention: .oneDay, now: Date().addingTimeInterval(172800))
        XCTAssertTrue(try store.entries().isEmpty)
    }
    func testCanvasFitsNativePixelsAndPadsOddEdges() throws {
        let small = try VideoCanvas(native: CGSize(width: 101, height: 55))
        XCTAssertEqual(small.width, 102)
        XCTAssertEqual(small.height, 56)
        XCTAssertEqual(small.contentSize, CGSize(width: 101, height: 55))
        let large = try VideoCanvas(native: CGSize(width: 5120, height: 2880))
        XCTAssertEqual(large.width, 3840)
        XCTAssertEqual(large.height, 2160)
    }

    func testTimelineRejectsStaleFramesAndPreservesStaticStopTail() {
        var clock = VideoTimeline()
        XCTAssertEqual(clock.admit(CMTime(value: 100, timescale: 1)), .zero)
        XCTAssertNil(clock.admit(CMTime(value: 99, timescale: 1)))
        XCTAssertEqual(clock.admit(CMTime(value: 101, timescale: 1)), CMTime(value: 1, timescale: 1))
        XCTAssertEqual(clock.endpoint(host: CMTime(value: 111, timescale: 1)), CMTime(value: 11, timescale: 1))
    }
}
