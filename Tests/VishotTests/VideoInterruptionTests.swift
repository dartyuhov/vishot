import XCTest
import VishotConfiguration
import CoreMedia
import ScreenCaptureKit
@testable import Vishot

/// Orchestration faults use injected results; stalled stream operations also
/// exercise the production recorder. VideoWriterTests covers actual MP4 output.
@MainActor final class VideoInterruptionTests: XCTestCase {
    private let rectangle = VideoRectangle(display: VideoDisplay(id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1),
        rect: CGRect(x: 0, y: 0, width: 100, height: 100))

    func testScreenGrantPrecedesCountdownAndRecoveryRetainsSelection() async throws {
        for options in [VideoAudioOptions(), VideoAudioOptions(microphoneEnabled: true), VideoAudioOptions(systemEnabled: true), VideoAudioOptions(microphoneEnabled: true, systemEnabled: true)] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let clock = CountdownTestClock()
            var granted = false
            var prepared: [RecordingAudioSnapshot] = []
            var rectangles: [VideoRectangle] = []
            var dismissed = 0
            let permission = MicrophonePermission(readStatus: {
                XCTAssertTrue(granted, "Screen denial must be resolved before microphone work")
                return .authorized
            }, requestAccess: { _ in XCTFail("No prompt") })
            let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
                resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
                presentsControls: false, reportError: { _, _ in XCTFail("Retain the picker for preflight recovery") },
                screenCaptureGranted: { granted },
                microphonePreflight: MicrophonePreflight(permission: permission,
                    devices: { [.init(id: "input", name: "Input")] }, defaultDevice: { "input" }),
                prepareWithAudio: { rectangle, directory, snapshot in
                    rectangles.append(rectangle); prepared.append(snapshot)
                    return try Recorder(directory: directory)
                })
            video.audioOptions = { options }
            video.onDismissPicker = { dismissed += 1 }
            var returned = ""
            video.onReturnToPicker = { returned = $0 }
            fixture.sessions.capture()
            let target = CaptureTarget(kind: .region(displayID: 1, rect: rectangle.rect),
                frame: rectangle.rect, anchor: .zero, label: "Region")
            let selection = try VideoSelection(target: target, windowFrame: nil)
            video.begin(selection: selection, session: fixture.id, label: "Region")
            try await eventually { !video.isActive || clock.hasJobs }
            XCTAssertFalse(clock.hasJobs)
            XCTAssertFalse(video.isActive)
            XCTAssertTrue(returned.contains("Screen Recording"))
            XCTAssertTrue(returned.contains("Settings"))
            XCTAssertEqual(dismissed, 0)
            XCTAssertTrue(fixture.sessions.acceptsCallbacks(fixture.id))
            XCTAssertTrue(prepared.isEmpty)
            video.cancelCountdown() // Also release a failed implementation's countdown.
            granted = true
            video.begin(selection: selection, session: fixture.id, label: "Region")
            try await eventually { clock.hasJobs }
            clock.advance(to: 3)
            try await eventually { prepared.count == 1 }
            XCTAssertEqual(rectangles, [rectangle])
            XCTAssertEqual(prepared[0].systemEnabled, options.systemEnabled)
            XCTAssertEqual(prepared[0].microphone?.id, options.microphoneEnabled ? "input" : nil)
            video.stop()
            try await eventually { !fixture.sessions.isSessionActive }
        }
    }

    func testScreenRevocationDuringMicrophonePromptRechecksAndCancellationFencesReply() async throws {
        for cancel in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let clock = CountdownTestClock()
            var granted = true
            var status = MicrophoneAuthorization.notDetermined
            var reply: ((Bool) -> Void)?
            let permission = MicrophonePermission(readStatus: { status }, requestAccess: { reply = $0 })
            let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
                prepare: { _, directory in XCTFail("Revoked/canceled preflight must not prepare"); return try Recorder(directory: directory) },
                resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
                presentsControls: false, reportError: { _, _ in XCTFail("Keep picker") },
                screenCaptureGranted: { granted },
                microphonePreflight: MicrophonePreflight(permission: permission,
                    devices: { [.init(id: "one", name: "Input")] }, defaultDevice: { "one" }))
            video.microphoneOptions = { (true, "") }
            var returns: [String] = []
            video.onReturnToPicker = { returns.append($0) }
            try begin(video, fixture)
            try await eventually { reply != nil }
            granted = false
            if cancel { video.cancelCountdown() }
            status = .authorized
            reply?(true)
            try await eventually { !video.isActive }
            // Queue behind the delayed permission delivery and startup continuation.
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertFalse(clock.hasJobs)
            XCTAssertEqual(returns.count, 1)
            XCTAssertEqual(returns.first?.contains("Screen Recording"), !cancel)
            XCTAssertTrue(fixture.sessions.acceptsCallbacks(fixture.id))
        }
    }

    func testScreenRevocationDuringCountdownOrPreparationNeverDismissesPicker() async throws {
        for duringPreparation in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let clock = CountdownTestClock()
            var granted = true
            var preparation: CheckedContinuation<VideoRecording, Error>?
            var recorder: Recorder?
            let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
                prepare: { _, directory in
                    XCTAssertTrue(duringPreparation)
                    recorder = try Recorder(directory: directory)
                    return try await withCheckedThrowingContinuation { preparation = $0 }
                }, resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
                presentsControls: false, reportError: { _, _ in XCTFail("Keep picker") },
                screenCaptureGranted: { granted })
            video.onDismissPicker = { XCTFail("Revoked grant must retain picker") }
            var returned = ""
            video.onReturnToPicker = { returned = $0 }
            try begin(video, fixture)
            try await eventually { clock.hasJobs }
            if !duringPreparation { granted = false }
            clock.advance(to: 3)
            if duringPreparation {
                try await eventually { preparation != nil }
                granted = false
                preparation?.resume(returning: try XCTUnwrap(recorder))
            }
            try await eventually { !video.isActive }
            XCTAssertTrue(returned.contains("Screen Recording"))
            XCTAssertTrue(fixture.sessions.acceptsCallbacks(fixture.id))
            XCTAssertEqual(recorder?.starts ?? 0, 0)
            XCTAssertEqual(recorder?.cancellations ?? 0, duringPreparation ? 1 : 0)
        }
    }

    func testEveryPictureTargetPreparesWholeSystemAudioWithoutMicrophoneAccess() async throws {
        let kinds: [CaptureTarget.Kind] = [.window(42), .element(windowID: 42, rect: rectangle.rect),
            .display(1), .region(displayID: 1, rect: rectangle.rect)]
        for kind in kinds {
            let fixture = try Fixture()
            defer { fixture.remove() }
            var prepared: [RecordingAudioSnapshot] = []
            var pictures: [VideoRectangle] = []
            let permission = MicrophonePermission(readStatus: {
                XCTFail("System-only recording must not access the microphone"); return .denied
            }, requestAccess: { _ in XCTFail("No microphone prompt") })
            let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
                resolve: { selection in
                    try selection.resolve(displays: [self.rectangle.display], windowFrame: self.rectangle.rect)
                }, countdown: immediateCountdown(), presentsControls: false,
                reportError: { message, _ in XCTFail(message) }, screenCaptureGranted: { true },
                microphonePreflight: MicrophonePreflight(permission: permission),
                prepareWithAudio: { picture, directory, audio in
                    pictures.append(picture); prepared.append(audio)
                    return try Recorder(directory: directory)
                })
            video.audioOptions = { VideoAudioOptions(systemEnabled: true) }
            fixture.sessions.capture()
            let target = CaptureTarget(kind: kind, frame: rectangle.rect, anchor: .zero, label: "Picture")
            video.begin(selection: try VideoSelection(target: target, windowFrame: rectangle.rect),
                session: fixture.id, label: "Picture")
            try await eventually { video.canStop && prepared.count == 1 }
            XCTAssertEqual(prepared, [RecordingAudioSnapshot(microphone: nil, systemEnabled: true)])
            XCTAssertEqual(pictures, [rectangle], "Audio must not change the picture rectangle")
            video.stop()
            try await eventually { !fixture.sessions.isSessionActive }
        }
    }

    func testCombinedAudioSnapshotFreezesBothSourcesAndMicrophoneIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        let permission = MicrophonePermission(readStatus: { .authorized }, requestAccess: { _ in XCTFail("No prompt") })
        var options = VideoAudioOptions(microphoneEnabled: true, systemEnabled: true)
        var prepared: [RecordingAudioSnapshot] = []
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in },
            screenCaptureGranted: { true },
            microphonePreflight: MicrophonePreflight(permission: permission,
                devices: { [.init(id: "frozen-input", name: "Input")] }, defaultDevice: { "frozen-input" }),
            prepareWithAudio: { _, directory, snapshot in
                prepared.append(snapshot)
                return try Recorder(directory: directory)
            })
        video.audioOptions = { options }
        fixture.sessions.capture()
        let target = CaptureTarget(kind: .window(42), frame: rectangle.rect, anchor: .zero, label: "App")
        let selection = try VideoSelection(target: target, windowFrame: nil)
        video.begin(selection: selection, session: fixture.id, label: "App")
        try await eventually { clock.hasJobs }
        options.systemEnabled = false
        options.microphoneEnabled = false
        options.microphoneDevice = "different-input"
        clock.advance(to: 3)
        try await eventually { prepared.count == 1 }
        XCTAssertEqual(prepared[0], RecordingAudioSnapshot(microphone: .init(id: "frozen-input", name: "Input"), systemEnabled: true))
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
    }

    func testDelayedMicrophoneAuthorizationRevalidatesSystemChoiceBeforeCountdown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var status = MicrophoneAuthorization.notDetermined
        var reply: ((Bool) -> Void)?
        let permission = MicrophonePermission(readStatus: { status }, requestAccess: { reply = $0 })
        var options = VideoAudioOptions(microphoneEnabled: true)
        var prepared: [RecordingAudioSnapshot] = []
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in },
            screenCaptureGranted: { true },
            microphonePreflight: MicrophonePreflight(permission: permission, devices: { [.init(id: "one", name: "Input")] }, defaultDevice: { "one" }),
            prepareWithAudio: { _, directory, snapshot in
                prepared.append(snapshot)
                return try Recorder(directory: directory)
            })
        video.audioOptions = { options }
        try begin(video, fixture)
        try await eventually { reply != nil }
        options.systemEnabled = true
        status = .authorized
        reply?(true)
        try await eventually { clock.hasJobs }
        clock.advance(to: 3)
        try await eventually { prepared.count == 1 }
        XCTAssertEqual(prepared[0], RecordingAudioSnapshot(microphone: .init(id: "one", name: "Input"), systemEnabled: true))
        XCTAssertTrue(fixture.sessions.isSessionActive)
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
    }

    func testMicrophonePermissionPrecedesCountdownAndCancellationFencesDelayedGrant() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var status = MicrophoneAuthorization.notDetermined
        var reply: ((Bool) -> Void)?
        let permission = MicrophonePermission(readStatus: { status }, requestAccess: { reply = $0 })
        let preflight = MicrophonePreflight(permission: permission,
            devices: { XCTAssertTrue(Thread.isMainThread); return [.init(id: "frozen", name: "Input")] }, defaultDevice: { "frozen" })
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            prepare: { _, directory in try Recorder(directory: directory) },
            resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true }, microphonePreflight: preflight)
        video.microphoneOptions = { (true, "") }
        var returned = ""
        video.onReturnToPicker = { returned = $0 }
        try begin(video, fixture)
        try await eventually { reply != nil }
        XCTAssertFalse(clock.hasJobs)
        XCTAssertTrue(video.isCheckingMicrophone)
        video.cancelCountdown()
        status = .authorized
        reply?(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(clock.hasJobs)
        XCTAssertFalse(video.isActive)
        XCTAssertTrue(fixture.sessions.isSessionActive)
        status = .denied
        try begin(video, fixture)
        try await eventually { !video.isActive }
        XCTAssertTrue(returned.contains("denied"))
        XCTAssertTrue(fixture.sessions.isSessionActive)
        XCTAssertFalse(clock.hasJobs)
    }

    func testPreflightRechecksChangedOptionsThenFreezesResolvedUIDThroughPreparation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var status = MicrophoneAuthorization.notDetermined
        var reply: ((Bool) -> Void)?
        var options = (enabled: true, device: "")
        var defaultID = "one"
        let permission = MicrophonePermission(readStatus: { status }, requestAccess: { reply = $0 })
        let preflight = MicrophonePreflight(permission: permission,
            devices: { [.init(id: "one", name: "Input"), .init(id: "two", name: "Input")] }, defaultDevice: { defaultID })
        var prepared: MicrophoneDevice?
        var starts = 0
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true }, microphonePreflight: preflight,
            prepareWithMicrophone: { _, directory, device in
                prepared = device; starts += 1
                return try Recorder(directory: directory)
            })
        video.microphoneOptions = { options }
        try begin(video, fixture)
        try await eventually { reply != nil }
        options = (false, "")
        status = .denied
        reply?(false)
        try await eventually { clock.hasJobs || !video.isActive }
        XCTAssertTrue(clock.hasJobs, "A changed source-off choice must supersede the delayed denial")
        video.cancelCountdown()
        clock.advance(to: 3) // Discard canceled ticks before observing the new countdown.
        status = .authorized
        options = (true, "")
        try begin(video, fixture)
        try await eventually { clock.hasJobs }
        defaultID = "two"
        options = (true, "two")
        clock.advance(to: 6)
        try await eventually { starts == 1 }
        XCTAssertEqual(prepared?.id, "one", "Default identity freezes before countdown, not at preparation")
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
    }

    func testChangedBoundsBeforeAndAfterPreparationRestartFullCountdownAndFreezeLatestRectangle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var current = rectangle
        var outlines: [CGRect] = []
        var numbers: [Int] = []
        var recorders: [Recorder] = []
        var preparedRects: [VideoRectangle] = []
        let moved = VideoRectangle(display: rectangle.display, rect: CGRect(x: 1, y: 2, width: 90, height: 80))
        let scaled = VideoRectangle(display: VideoDisplay(id: 1, frame: rectangle.display.frame, scale: 2), rect: moved.rect)
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            prepare: { rect, url in
                preparedRects.append(rect)
                let recorder = try Recorder(directory: url)
                recorders.append(recorder)
                if recorders.count == 1 { current = scaled }
                return recorder
            }, resolve: { _ in current }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true })
        video.onRectangle = { outlines.append($0) }
        video.onCountdownFrame = { XCTAssertTrue(Thread.isMainThread); if let frame = $0 { numbers.append(frame.number) } }
        try begin(video, fixture)
        try await eventually { numbers == [3] }
        current = moved
        clock.advance(to: 3)
        try await eventually { numbers == [3, 2, 1, 3] }
        XCTAssertTrue(recorders.isEmpty)
        XCTAssertEqual(outlines, [rectangle.rect, moved.rect])
        clock.advance(to: 6)
        try await eventually { numbers.count == 7 }
        XCTAssertEqual(numbers, [3, 2, 1, 3, 2, 1, 3])
        XCTAssertEqual(recorders[0].starts, 0)
        XCTAssertEqual(recorders[0].cancellations, 1)
        XCTAssertEqual(outlines, [rectangle.rect, moved.rect, moved.rect])
        clock.advance(to: 8.999)
        XCTAssertEqual(recorders.count, 1)
        clock.advance(to: 9)
        try await eventually { recorders.count == 2 && recorders[1].starts == 1 }
        XCTAssertEqual(preparedRects, [moved, scaled])
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
    }

    func testCancelledPendingPreparationCannotReviveOrChangeReplacementCountdown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var preparation: CheckedContinuation<VideoRecording, Error>?
        var directory: URL?
        var numbers: [Int] = []
        var returns = 0
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            prepare: { _, url in
                directory = url
                return try await withCheckedThrowingContinuation { preparation = $0 }
            }, resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true })
        video.onCountdownFrame = { if let frame = $0 { numbers.append(frame.number) } }
        video.onReturnToPicker = { _ in returns += 1 }
        try begin(video, fixture)
        try await eventually { numbers == [3] }
        clock.advance(to: 3)
        try await eventually { preparation != nil }
        video.cancelCountdown()
        video.cancelCountdown()
        XCTAssertEqual(returns, 1)
        try begin(video, fixture)
        try await eventually { numbers.count == 4 }
        let stale = try Recorder(directory: XCTUnwrap(directory))
        preparation?.resume(returning: stale)
        try await eventually { stale.cancellations == 1 }
        XCTAssertEqual(stale.starts, 0)
        XCTAssertEqual(numbers, [3, 2, 1, 3])
        XCTAssertTrue(video.isCountingDown)
        video.cancelCountdown()
        XCTAssertEqual(returns, 2)
        clock.advance(to: 20)
        await Task.yield()
        XCTAssertFalse(video.isActive)
        XCTAssertTrue(try fixture.store.entries().isEmpty)
    }

    func testCancelFromPreparingFeedbackCannotBeginPendingPreparation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var preparations = 0, returns = 0
        var number: Int?
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            prepare: { _, directory in preparations += 1; return try Recorder(directory: directory) },
            resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true })
        video.onCountdownFrame = { number = $0?.number }
        video.onReturnToPicker = { _ in returns += 1 }
        video.onCountdown = { if $0.contains("Preparing") { video.cancelCountdown() } }
        try begin(video, fixture)
        try await eventually { number == 3 }
        clock.advance(to: 3)
        try await eventually { returns == 1 }
        await Task.yield()
        XCTAssertEqual(preparations, 0)
        XCTAssertFalse(video.isActive)
        XCTAssertTrue(fixture.sessions.isSessionActive, "Same picker keeps its session and target")
        video.onCountdown = nil
    }

    func testSharedCountdownEndsBeforePreparationAndSlowPreparationShowsSeparateFeedback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = CountdownTestClock()
        var preparation: CheckedContinuation<VideoRecording, Error>?
        var directory: URL?
        var numbers: [Int] = []
        var feedback: [String] = []
        var dismissed = false
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            prepare: { urlRect, url in
                XCTAssertEqual(urlRect, self.rectangle)
                directory = url
                return try await withCheckedThrowingContinuation { preparation = $0 }
            }, resolve: { _ in self.rectangle }, countdown: CaptureCountdown(schedule: clock.schedule),
            presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true })
        video.onCountdownFrame = { if let frame = $0 { numbers.append(frame.number) } }
        video.onCountdown = { feedback.append($0) }
        video.onDismissPicker = { dismissed = true }
        try begin(video, fixture)
        try await eventually { numbers == [3] }
        XCTAssertNil(preparation)
        clock.advance(to: 1)
        clock.advance(to: 2)
        XCTAssertEqual(numbers, [3, 2, 1])
        XCTAssertNil(preparation)
        clock.advance(to: 3)
        try await eventually { preparation != nil }
        XCTAssertTrue(feedback.last?.contains("Preparing") == true)
        XCTAssertFalse(dismissed)
        let recorder = try Recorder(directory: XCTUnwrap(directory))
        preparation?.resume(returning: recorder)
        try await eventually { recorder.starts == 1 }
        XCTAssertTrue(dismissed)
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
    }

    func testSDKPermissionDenialDuringSuspendedPreparationOffersPersistentRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var preparation: CheckedContinuation<VideoRecording, Error>?
        let video = makeSession(fixture, prepare: { _ in
            try await withCheckedThrowingContinuation { preparation = $0 }
        })
        try begin(video, fixture)
        try await eventually { preparation != nil }
        // The preflight succeeded, then permission was revoked while the SDK
        // awaited shareable content. It returns its own error, not our wrapper.
        preparation?.resume(throwing: NSError(domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue))
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertTrue(video.isErrorPresented)
        XCTAssertTrue(video.isPermissionRecoveryPresented)
        var opened = false
        video.onPermissionSettings = { opened = true }
        video.openPermissionRecovery()
        XCTAssertTrue(opened)
        video.dismissError()
        XCTAssertFalse(video.isPermissionRecoveryPresented)
        XCTAssertTrue(try fixture.store.entries().isEmpty)
    }

    func testProductionRecorderStalledStartTimesOutAndLateCompletionCannotReviveIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = try fixture.store.stageVideo()
        var completion: ((Error?) -> Void)?
        var stops = 0
        let recorder = try await VideoRecorder.preparedWriter(rectangle: rectangle, directory: directory,
            startupTimeout: 0.05, startCapture: { completion = $0 }, stopCapture: { done in stops += 1; done(nil) })
        do { try await recorder.start(); XCTFail("Stalled OS startup must time out") } catch {}
        do { _ = try await recorder.stop(at: .zero); XCTFail("No frames cannot succeed") } catch {}
        completion?(nil)
        try await eventually { stops == 2 }
        XCTAssertFalse(recorder.hasCompletedMovie)
    }

    func testProductionRecorderStartedStreamWithoutFramesAlsoTimesOutAndStalledStopIsBounded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recorder = try await VideoRecorder.preparedWriter(rectangle: rectangle,
            directory: fixture.store.stageVideo(), startupTimeout: 0.05, stopCapture: { _ in })
        do { try await recorder.start(); XCTFail("No-frame startup must time out") } catch {}
        do { _ = try await recorder.stop(at: .zero); XCTFail("No frames cannot succeed") } catch {}
        XCTAssertFalse(recorder.hasCompletedMovie)
    }

    func testTargetResolutionFailurePresentsPersistentErrorAndReleasesPickerOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var reports = 0
        let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
            resolve: { _ in throw SettingsError(message: "Target disappeared") },
            countdown: immediateCountdown(), presentsControls: false, reportError: { _, _ in reports += 1 }, screenCaptureGranted: { true })
        video.onDismissPicker = { fixture.sessions.dismissPresentation(fixture.id) }
        try begin(video, fixture)
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(reports, 1)
        XCTAssertTrue(video.isErrorPresented)
        XCTAssertEqual(video.error, "Target disappeared")
    }

    func testProductionStopAndQuitReleaseStalledOSStartWithoutWaitingForCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var completion: ((Error?) -> Void)?
        let video = makeSession(fixture, prepare: { directory in
            try await VideoRecorder.preparedWriter(rectangle: self.rectangle, directory: directory,
                startupTimeout: 0.2, startCapture: { completion = $0 }, stopCapture: { $0(nil) })
        })
        try begin(video, fixture)
        try await eventually { completion != nil }
        video.prepareToQuit()
        _ = fixture.sessions.requestQuit()
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertNotNil(video.error)
        completion?(nil)
        await Task.yield()
        XCTAssertFalse(video.canStop)
        XCTAssertTrue(try fixture.store.entries().isEmpty)
    }

    func testOrdinaryStartupFailurePersistsUntilDismissedOrNextSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var fail = true
        var reports: [String] = []
        let video = makeSession(fixture, prepare: { directory in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            return try Recorder(directory: directory)
        }, report: { reports.append($0) })
        try begin(video, fixture)
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(video.isErrorPresented)
        video.dismissError()
        XCTAssertFalse(video.isErrorPresented)
        XCTAssertNil(video.error)
        try begin(video, fixture)
        try await eventually { video.isErrorPresented }
        fail = false
        try begin(video, fixture)
        XCTAssertFalse(video.isErrorPresented)
        XCTAssertNil(video.error)
        try await eventually { video.canStop }
        video.stop()
        try await eventually { !fixture.sessions.isSessionActive }
        XCTAssertFalse(video.isErrorPresented)
        XCTAssertNil(video.error)
    }

    func testWindowAndElementTitlesSurviveSessionPublicationAndAreSearchable() async throws {
        for kind in [CaptureTarget.Kind.window(42), .element(windowID: 42, rect: rectangle.rect)] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let video = makeSession(fixture, prepare: { try Recorder(directory: $0) })
            fixture.sessions.capture()
            let target = CaptureTarget(kind: kind, frame: rectangle.rect, anchor: .zero, label: "Editor")
            video.begin(selection: try VideoSelection(target: target, windowFrame: rectangle.rect),
                session: fixture.id, label: target.label, windowTitle: "Unique document 934")
            try await eventually { video.canStop }
            video.stop()
            try await eventually { !fixture.sessions.isSessionActive }
            let entries = try fixture.store.entries()
            XCTAssertEqual(HistorySearch.matches("Unique document 934", in: entries).count, 1)
        }
    }

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

    func testPermissionDenialDuringPreparationRetainsPickerAndOffersRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var permissionAction = false
        let video = makeSession(fixture, prepare: { _ in throw VideoPermissionError() })
        var returned = ""
        video.onReturnToPicker = { returned = $0 }
        video.onPermissionSettings = { permissionAction = true }
        try begin(video, fixture)
        try await eventually { !video.isActive }
        XCTAssertTrue(fixture.sessions.acceptsCallbacks(fixture.id))
        XCTAssertTrue(returned.contains("Screen Recording"))
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
            countdown: immediateCountdown(), presentsControls: false, reportError: { message, _ in report(message) }, screenCaptureGranted: { true })
        video.onDismissPicker = { fixture.sessions.dismissPresentation(fixture.id) }
        return video
    }

    private func immediateCountdown() -> CaptureCountdown {
        CaptureCountdown(schedule: { _, action in
            CaptureCountdown.scheduleOnMain(0, action)
        })
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
