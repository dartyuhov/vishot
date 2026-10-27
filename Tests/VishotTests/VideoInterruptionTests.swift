import XCTest
import CoreMedia
@testable import Vishot

/// Recorder results are injected at the validated-output boundary. Actual MP4
/// decoding is covered by HistoryVideoActionsTests' real H.264 fixture.
@MainActor final class VideoInterruptionTests: XCTestCase {
    private let rectangle = VideoRectangle(display: VideoDisplay(id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1),
        rect: CGRect(x: 0, y: 0, width: 100, height: 100))

    func testStopWhileStartIsSuspendedWaitsForStartupOwnerAndIgnoresDelayedStartFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var recorder: Recorder!
        var resumeStart: CheckedContinuation<Void, Error>?
        var ready = 0
        fixture.sessions.onQuitReady = { ready += 1 }
        let video = makeSession(fixture, prepare: { directory in
            recorder = try Recorder(directory: directory)
            recorder.startBody = { try await withCheckedThrowingContinuation { resumeStart = $0 } }
            return recorder
        })
        try begin(video, fixture)
        try await eventually { resumeStart != nil }
        video.prepareToQuit()
        XCTAssertFalse(fixture.sessions.requestQuit())
        try await eventually { recorder.stops == 1 && !video.isActive }
        XCTAssertTrue(fixture.sessions.isSessionActive, "Pending startup still owns resources")
        XCTAssertEqual(ready, 0)
        resumeStart?.resume(throwing: SettingsError(message: "Delayed start failed"))
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(try fixture.store.entries().count, 1)
        XCTAssertFalse(video.error?.contains("Delayed") == true)
    }

    func testImmediateStopFromStartingCallbackNeverStartsStreamAfterStop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var recorder: Recorder!
        let video = makeSession(fixture, prepare: { directory in
            recorder = try Recorder(directory: directory)
            return recorder
        })
        video.onChange = { if video.canStop { video.stop() } }
        try begin(video, fixture)
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(recorder.stops, 1)
        video.onChange = nil
    }

    func testFailedRescueDuringPendingQuitCancelsTerminationAndPreservesCompletedMovie() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var recorder: Recorder!
        var ready = 0, cancelled = 0
        fixture.sessions.onQuitReady = { ready += 1 }
        fixture.sessions.onQuitCancelled = { cancelled += 1 }
        let video = makeSession(fixture, prepare: { directory in
            recorder = try Recorder(directory: directory)
            recorder.stopFailure = SettingsError(message: "Thumbnail failed")
            return recorder
        })
        try begin(video, fixture)
        try await eventually { video.canStop && recorder.starts == 1 }
        video.stop()
        try await eventually { video.error != nil }
        let movie = try XCTUnwrap(video.completedUnpublishedMovie)
        let failed = expectation(description: "Rescue failure cancels quit")
        video.rescue(to: fixture.root.appendingPathComponent("missing/clip.mp4")) { success in
            XCTAssertFalse(success); failed.fulfill()
        }
        video.prepareToQuit()
        XCTAssertFalse(fixture.sessions.requestQuit())
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(ready, 0)
        XCTAssertTrue(fixture.sessions.isSessionActive)
        XCTAssertEqual(video.completedUnpublishedMovie, movie)
        XCTAssertEqual(try Data(contentsOf: movie), Data([1, 2, 3]))
        video.prepareToQuit() // Explicit subsequent Quit can exit idle rescue.
        XCTAssertTrue(fixture.sessions.requestQuit())
    }

    func testPermissionDenialOffersRecoveryReleasesSessionAndDoesNotStart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var permissionAction = false
        let video = makeSession(fixture, prepare: { _ in throw VideoPermissionError() })
        video.onPermissionSettings = { permissionAction = true }
        try begin(video, fixture)
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertNotNil(video.error)
        XCTAssertNil(video.completedUnpublishedMovie)
        video.openPermissionRecovery()
        XCTAssertTrue(permissionAction)
        XCTAssertTrue(try fixture.store.entries().isEmpty)
    }

    func testThumbnailFailureRetainsCompletedFileButInvalidMovieFailureReleasesSession() async throws {
        for completed in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            var recorder: Recorder!
            let video = makeSession(fixture, prepare: { directory in
                recorder = try Recorder(directory: directory)
                recorder.stopFailure = SettingsError(message: completed ? "Thumbnail failed" : "No playable frames")
                recorder.completes = completed
                return recorder
            })
            try begin(video, fixture)
            try await eventually { video.canStop && recorder.starts == 1 }
            video.stop()
            try await eventually { video.error != nil }
            XCTAssertEqual(fixture.sessions.isSessionActive, completed)
            XCTAssertEqual(video.completedUnpublishedMovie != nil, completed)
            XCTAssertTrue(try fixture.store.entries().isEmpty)
            if completed { video.prepareToQuit() }
        }
    }

    func testInterruptionPublishesAcceptedContentOnceAndLateErrorCannotAffectNextSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var recorder: Recorder!
        var reports: [String] = []
        let video = makeSession(fixture, prepare: { directory in
            recorder = try Recorder(directory: directory)
            return recorder
        }, report: { reports.append($0) })
        try begin(video, fixture)
        try await eventually { video.canStop && recorder?.starts == 1 }
        let lateFailure = recorder.onFailure
        video.stop(because: SettingsError(message: "The screen was locked."))
        video.stop(because: SettingsError(message: "sleep duplicate"))
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(try fixture.store.entries().count, 1)
        XCTAssertNil(video.completedUnpublishedMovie)
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].contains("locked"))
        try begin(video, fixture)
        try await eventually { recorder.starts == 1 && video.canStop }
        lateFailure?(SettingsError(message: "stale source error"))
        await Task.yield()
        XCTAssertTrue(video.canStop)
        XCTAssertEqual(recorder.stops, 0)
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(try fixture.store.entries().count, 2)
    }

    func testPublicationFailureCancelsQuitAndRetainsRescueAcrossCancelFailureAndSuccessfulExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var recorder: Recorder!
        var ready = 0, cancelled = 0
        fixture.sessions.onQuitReady = { ready += 1 }
        fixture.sessions.onQuitCancelled = { cancelled += 1 }
        let video = makeSession(fixture, prepare: { directory in
            recorder = try Recorder(directory: directory)
            return recorder
        })
        try begin(video, fixture)
        try await eventually { video.canStop && recorder.starts == 1 }
        try Data().write(to: fixture.store.url) // History publication disk fault.
        video.prepareToQuit()
        XCTAssertFalse(fixture.sessions.requestQuit())
        try await eventually { video.completedUnpublishedMovie != nil && video.error != nil }
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(fixture.sessions.isSessionActive)
        let movie = try XCTUnwrap(video.completedUnpublishedMovie)
        video.rescue(to: nil)
        XCTAssertEqual(video.completedUnpublishedMovie, movie)
        let failed = expectation(description: "Rescue copy fails")
        video.rescue(to: fixture.root.appendingPathComponent("missing/export.mp4")) { success in
            XCTAssertFalse(success); failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(fixture.sessions.isSessionActive)
        XCTAssertEqual(try Data(contentsOf: movie), Data([1, 2, 3]))
        let saved = expectation(description: "Rescue copy completes")
        let destination = fixture.root.appendingPathComponent("saved.mp4")
        video.rescue(to: destination) { success in XCTAssertTrue(success); saved.fulfill() }
        video.prepareToQuit() // Must not abandon the sole copy during export.
        XCTAssertFalse(fixture.sessions.requestQuit())
        XCTAssertEqual(video.completedUnpublishedMovie, movie)
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(ready, 1)
        XCTAssertFalse(fixture.sessions.isSessionActive)
        XCTAssertNil(video.completedUnpublishedMovie)
        XCTAssertNil(video.error)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
    }

    func testQuitDuringPreparationWaitsForCancellationCleanupAndCannotStartLater() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var preparation: CheckedContinuation<VideoRecording, Error>?
        var directory: URL?
        var ready = 0
        fixture.sessions.onQuitReady = { ready += 1 }
        let video = makeSession(fixture, prepare: { url in
            directory = url
            return try await withCheckedThrowingContinuation { preparation = $0 }
        })
        try begin(video, fixture)
        try await eventually { preparation != nil }
        video.prepareToQuit()
        XCTAssertFalse(fixture.sessions.requestQuit())
        XCTAssertTrue(fixture.sessions.isSessionActive)
        let recorder = try Recorder(directory: XCTUnwrap(directory))
        preparation?.resume(returning: recorder)
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(recorder.cancellations, 1)
        XCTAssertTrue(try fixture.store.entries().isEmpty)
    }

    private func makeSession(_ fixture: Fixture,
                             prepare: @escaping (URL) async throws -> VideoRecording,
                             report: @escaping (String) -> Void = { _ in }) -> VideoSession {
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            prepare: { _, directory in try await prepare(directory) }, resolve: { _ in self.rectangle },
            countdownTick: {}, presentsControls: false, reportError: { message, _ in report(message) })
        video.onDismissPicker = { fixture.sessions.dismissPresentation(fixture.id) }
        return video
    }

    private func begin(_ video: VideoSession, _ fixture: Fixture) throws {
        fixture.sessions.capture()
        let target = CaptureTarget(kind: .display(1), frame: rectangle.rect, anchor: .zero, label: "Display")
        video.begin(selection: try VideoSelection(target: target, windowFrame: nil), session: fixture.id, label: "Display")
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Session did not reach expected state", file: file, line: line)
        throw CancellationError()
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = CaptureSessionCoordinator()
        let store: HistoryStore
        let history: HistoryLibrary
        var id = 0
        init() throws {
            store = HistoryStore(url: root.appendingPathComponent("History"))
            history = HistoryLibrary(store: store)
            sessions.onCapture = { [weak self] id in self?.id = id; return true }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Recorder: VideoRecording {
        let directory: URL
        var movie: URL { directory.appendingPathComponent("clip.mp4") }
        let displayID: UInt32 = 1
        let displayFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var hasCompletedMovie = false
        var onFailure: ((Error) -> Void)?
        var starts = 0, stops = 0, cancellations = 0
        var stopFailure: Error?
        var completes = true
        var startBody: (() async throws -> Void)?
        init(directory: URL) throws {
            self.directory = directory
            try Data([1, 2, 3]).write(to: movie)
            try Data([4]).write(to: directory.appendingPathComponent("thumbnail.png"))
        }
        func start() async throws { starts += 1; try await startBody?() }
        func stop(at endpoint: CMTime) async throws -> VideoRecorder.Output {
            stops += 1
            hasCompletedMovie = completes
            if let stopFailure { throw stopFailure }
            return VideoRecorder.Output(directory: directory, movie: movie, video: HistoryVideo(movie: "clip.mp4",
                thumbnail: "thumbnail.png", duration: 1, width: 100, height: 100, displayID: 1, frame: displayFrame, scale: 1))
        }
        func closeIntake(at endpoint: CMTime) {}
        func cancelPreparation() async { cancellations += 1 }
    }
}
