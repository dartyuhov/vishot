import XCTest
import AVFoundation
import CoreImage
import ScreenCaptureKit
@testable import Vishot

@MainActor final class VideoWriterTests: XCTestCase {
    func testNonSampleAlignedStopCompletesAudioWithoutFalseDrainInterruption() async throws {
        for ids in [["mic"], ["system"], ["mic", "system"]] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sources = ids.map { MixingFixtureSource(id: $0) }
            let origin = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
            var host = origin
            let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
            let recorder = try await VideoRecorder.preparedWriter(rectangle:
                VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
                directory: directory, audioSources: sources, hostTime: { host })
            let start = Task { try await recorder.start() }
            let image = try buffer(width: 16, height: 16)
            var accepted = false
            for _ in 0..<100 where !accepted {
                accepted = await recorder.receiveFrame(image, at: origin, host: origin)
                if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            try await start.value
            for index in 0..<10 {
                host = origin + CMTime(value: Int64(index), timescale: 10)
                for source in sources {
                    source.deliver?(try audio(at: host.seconds, frames: 4800, amplitude: 0.4))
                    await recorder.receiveTime(host)
                }
            }
            // Host-clock Stop has sub-sample precision; exactly 48,000 complete
            // audio frames fit, with 7us left over that cannot form another frame.
            host = origin + CMTime(value: 1_000_007, timescale: 1_000_000)
            let output = try await recorder.stop(at: host)
            XCTAssertNil(output.interruption, "Normal \(ids) Stop must not report a fractional PCM frame as undrained")
            let decoded = try await decodedAudio(output.movie)
            XCTAssertEqual(rms(decoded, from: 0.8, to: 0.95), 0.28284, accuracy: 0.02)
            XCTAssertGreaterThan(decoded.last?.time ?? 0, 0.99)
            XCTAssertEqual(output.video.duration, 1.000007, accuracy: 0.002)
        }
    }
    func testSourceRateChangesAndGapsKeepDecodedEventsOnElapsedTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "quiet-system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var host = origin
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        let rates = [8000, 16000, 32000, 44100, 48000, 96000, 192000]
        for (segment, rate) in rates.enumerated() {
            let began = Double(segment)
            for index in 0..<60 {
                let offset = Double(index) / 100
                host = origin + CMTime(seconds: began + offset, preferredTimescale: 48_000)
                sources[0].deliver?(try audio(at: host.seconds, frames: rate / 100, amplitude: 0.6,
                    rate: Double(rate), channels: segment.isMultiple(of: 2) ? 1 : 2,
                    frequency: 700, phase: offset))
                await recorder.receiveTime(host)
            }
            host = origin + CMTime(value: Int64(segment + 1), timescale: 1)
            await recorder.receiveTime(host)
        }
        let output = try await recorder.stop(at: origin + CMTime(value: 7, timescale: 1))
        let decoded = try await decodedAudio(output.movie)
        for segment in 0..<7 {
            let time = Double(segment)
            XCTAssertEqual(rms(decoded, from: time + 0.03, to: time + 0.12), 0.21213, accuracy: 0.015)
            XCTAssertEqual(rms(decoded, from: time + 0.48, to: time + 0.57), 0.21213, accuracy: 0.015)
            XCTAssertLessThan(rms(decoded, from: time + 0.65, to: time + 0.95), 0.002)
        }
        XCTAssertEqual(output.video.duration, 7, accuracy: 0.002)
        XCTAssertNil(output.interruption)
    }
    func testDestructiveAudioOverflowReportsInterruptionAndRetainsDecodedPortion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "quiet-system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var host = origin
        var ready = true
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, audioWriterReady: { ready }, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        let failed = expectation(description: "Destructive overflow is explained")
        recorder.onFailure = { error in
            XCTAssertTrue(error.localizedDescription.contains("overflow"))
            failed.fulfill()
        }
        for index in 0..<350 {
            host = origin + CMTime(value: Int64(index), timescale: 100)
            ready = index < 100
            sources[0].deliver?(try audio(at: host.seconds, frames: 480, amplitude: 0.6, phase: Double(index) / 100))
            await recorder.receiveTime(host)
        }
        await fulfillment(of: [failed], timeout: 2)
        ready = true
        let output = try await recorder.stop(at: host)
        XCTAssertNotNil(output.interruption)
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.1, to: 0.3), 0.21213, accuracy: 0.015)
        XCTAssertLessThan(output.video.duration, 3.3, "Failure freezes its endpoint rather than silently dropping ongoing audio")
    }
    func testBandlimitedConversionRejectsUltrasonicAliasAndPreservesPacketContinuity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var host = origin
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        // 30kHz at 96kHz must not fold to an audible 18kHz tone. A second
        // source exercises nonintegral 44.1k->48k conversion across 512 frames.
        for index in 0..<200 {
            host = origin + CMTime(value: Int64(index * 512), timescale: 44_100)
            sources[0].deliver?(try audio(at: 100 + Double(index * 960) / 96_000,
                frames: 960, amplitude: 0.8, rate: 96_000, frequency: 30_000,
                phase: Double(index * 960) / 96_000))
            await recorder.receiveTime(host)
            sources[1].deliver?(try audio(at: host.seconds, frames: 512, amplitude: 0.4,
                rate: 44_100, channels: 2, frequency: 997, phase: Double(index * 512) / 44_100))
            await recorder.receiveTime(host)
        }
        let end = Double(200 * 512) / 44_100
        let output = try await recorder.stop(at: origin + CMTime(seconds: end, preferredTimescale: 48_000))
        let decoded = try await decodedAudio(output.movie)
        for window in [0.2..<0.8, 1.2..<1.8] {
            let samples = decoded.filter { window.contains($0.time) }
            func magnitude(_ frequency: Double) -> Double {
                let real = samples.reduce(0) { $0 + $1.value * cos(2 * .pi * frequency * $1.time) }
                let imaginary = samples.reduce(0) { $0 + $1.value * sin(2 * .pi * frequency * $1.time) }
                return 2 * hypot(real, imaginary) / Double(samples.count)
            }
            XCTAssertLessThan(magnitude(18_000), 0.003, "Bandlimited downsampling must reject 30kHz, not alias it")
            XCTAssertEqual(magnitude(997), 0.2, accuracy: 0.015, "Packet boundaries must not reset converter phase")
            XCTAssertEqual(rms(decoded, from: window.lowerBound, to: window.upperBound), 0.14142, accuracy: 0.015)
        }
        XCTAssertEqual(output.video.duration, end, accuracy: 0.003)
        XCTAssertNil(output.interruption)
    }
    func testPreVideoSourcePacketRetainsOnlyItsTrailingAdmittedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, hostTime: { origin })
        let start = Task { try await recorder.start() }
        for _ in 0..<100 where sources.contains(where: { $0.deliver == nil }) { try await Task.sleep(nanoseconds: 2_000_000) }
        for source in sources {
            source.deliver?(try audio(at: 99.8, frames: 4800, amplitude: 0.9, frequency: 880))
            await recorder.receiveTime(origin)
            // A 100ms buffer delivered before the first video overlaps it by 50ms.
            source.deliver?(try audio(at: 99.95, frames: 4800, amplitude: 0.4))
            await recorder.receiveTime(origin)
        }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        let output = try await recorder.stop(at: origin + CMTime(value: 1, timescale: 5))
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.01, to: 0.04), 0.28284, accuracy: 0.02)
        XCTAssertLessThan(rms(decoded, from: 0.08, to: 0.18), 0.002, "No pre-video packet may be concatenated onto the movie")
        XCTAssertNil(output.interruption)
    }
    func testSmallSourcePacketsSurviveSilentPeerAndEncoderBackpressure() async throws {
        for frames in [480, 512] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "quiet-system")]
            let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
            var host = origin
            var ready = true
            let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
            let recorder = try await VideoRecorder.preparedWriter(rectangle:
                VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
                directory: directory, audioSources: sources, audioWriterReady: { ready }, hostTime: { host })
            let start = Task { try await recorder.start() }
            let image = try buffer(width: 16, height: 16)
            var accepted = false
            for _ in 0..<100 where !accepted {
                accepted = await recorder.receiveFrame(image, at: origin, host: origin)
                if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            try await start.value
            // The other required source is ready but never delivers a callback.
            // Encoder pressure adds 300ms to the normal 500ms late-arrival tail.
            for index in 0..<200 {
                let offset = Double(index * frames) / 48_000
                host = origin + CMTime(value: Int64(index * frames), timescale: 48_000)
                ready = !(0.7..<1.0).contains(offset)
                sources[0].deliver?(try audio(at: host.seconds, frames: frames, amplitude: 0.6,
                    phase: Double(index * frames) / 48_000))
                await recorder.receiveTime(host)
            }
            ready = true
            host = origin + CMTime(value: Int64(200 * frames), timescale: 48_000)
            let output = try await recorder.stop(at: host)
            XCTAssertNil(output.interruption)
            let decoded = try await decodedAudio(output.movie)
            for window in [0.1..<0.3, 0.45..<0.65, 0.8..<0.95, 1.2..<1.4, 1.7..<1.9] {
                XCTAssertEqual(rms(decoded, from: window.lowerBound, to: window.upperBound), 0.21213,
                    accuracy: 0.015, "No dropped unrendered \(frames)-frame packets in \(window)")
            }
        }
    }
    func testCombinedSourcesDecodeIndependentTimingRatesGapsAndHeadroom() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mic = SystemAudioCapture()
        let system = MixingFixtureSource(id: "system-fixture")
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var host = origin
        var ready = true
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: [mic, system], audioWriterReady: { ready }, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        // Distinct frequencies, formats and source gaps; source delivery is not
        // synchronized. Ten seconds also exceeds the retained PCM queue bound.
        for index in 0..<100 {
            host = origin + CMTime(value: Int64(index), timescale: 10)
            ready = !(20..<23).contains(index)
            if index < 20 || index >= 40 {
                mic.receive(try audio(at: host.seconds, frames: 4410, amplitude: 0.8, rate: 44_100, channels: 2, frequency: 440))
            }
            await recorder.receiveTime(host)
            if index < 40 || index >= 60 {
                system.deliver?(try audio(at: host.seconds, frames: 3200, amplitude: 0.8, rate: 32_000, frequency: 880))
            }
            await recorder.receiveTime(host)
        }
        host = origin + CMTime(value: 10, timescale: 1)
        let output = try await recorder.stop(at: host)
        XCTAssertNil(output.interruption)
        try await VideoRecorder.validateMovie(at: output.movie, width: 16, height: 16, audioExpected: true)
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.2, to: 1.8), 0.4, accuracy: 0.025)
        XCTAssertEqual(rms(decoded, from: 2.4, to: 3.8), 0.2828, accuracy: 0.025)
        XCTAssertEqual(rms(decoded, from: 4.2, to: 5.8), 0.2828, accuracy: 0.025)
        XCTAssertEqual(rms(decoded, from: 8.2, to: 9.8), 0.4, accuracy: 0.025)
        func magnitude(_ frequency: Double, _ start: Double, _ end: Double) -> Double {
            let window = decoded.filter { $0.time >= start && $0.time < end }
            let real = window.reduce(0) { $0 + $1.value * cos(2 * .pi * frequency * $1.time) }
            let imaginary = window.reduce(0) { $0 + $1.value * sin(2 * .pi * frequency * $1.time) }
            return 2 * hypot(real, imaginary) / Double(window.count)
        }
        XCTAssertEqual(magnitude(440, 0.2, 1.8), 0.4, accuracy: 0.03)
        XCTAssertEqual(magnitude(880, 0.2, 1.8), 0.4, accuracy: 0.03)
        XCTAssertLessThan(magnitude(440, 2.4, 3.8), 0.01)
        XCTAssertLessThan(magnitude(880, 4.2, 5.8), 0.01)
        XCTAssertLessThan(decoded.map { abs($0.value) }.max() ?? 2, 0.95)
        XCTAssertEqual(output.video.duration, 10, accuracy: 0.002)
        let history = HistoryStore(url: directory.appendingPathComponent("History"))
        let staging = try history.stageVideo()
        try FileManager.default.copyItem(at: output.movie, to: staging.appendingPathComponent(output.video.movie))
        try FileManager.default.copyItem(at: directory.appendingPathComponent("thumbnail.png"), to: staging.appendingPathComponent("thumbnail.png"))
        let entry = try history.publishVideo(staging: staging, video: output.video, label: "System + Mic")
        let reopened = HistoryStore(url: history.url)
        let movie = try reopened.validatedMovieURL(entry)
        let export = directory.appendingPathComponent("combined-export.mp4")
        try reopened.exportVideo(entry, to: export)
        XCTAssertEqual(try Data(contentsOf: output.movie), try Data(contentsOf: export))
        XCTAssertFalse(try XCTUnwrap(reopened.entries().first).unavailable)
    }

    private final class MixingFixtureSource: RecordingAudioSource {
        let id: String
        var deliver: ((CMSampleBuffer) -> Void)?
        var failed: ((Error) -> Void)?
        var stops = 0
        init(id: String) { self.id = id }
        func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws { self.deliver = deliver; self.failed = failed }
        func stop() async { stops += 1; deliver = nil }
    }

    func testCombinedStartupTimeoutClosesAndCleansAlreadyStartedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MixingFixtureSource(id: "ready")
        let stalled = StalledAudioSource(starts: true)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, startupTimeout: 0.1, audioSources: [source, stalled])
        do { try await recorder.start(); XCTFail("Both required sources and picture must become ready") } catch {}
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertGreaterThan(source.stops, 0, "Failure must clean an already-started peer without requiring a caller Stop")
        stalled.resume()
        await recorder.cancelPreparation()
    }

    func testCombinedStopTrimsBothSourcesAndRejectsLateDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, hostTime: { origin })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        for source in sources {
            source.deliver?(try audio(at: 99.9, frames: 4800, amplitude: 0.9))
            await recorder.receiveTime(origin)
            source.deliver?(try audio(at: 100.01, frames: 4800, amplitude: 0.8))
            await recorder.receiveTime(origin)
        }
        let late = sources.compactMap(\.deliver)
        recorder.closeIntake(at: origin + CMTime(value: 1, timescale: 100))
        for callback in late { callback(try audio(at: 100, frames: 4800, amplitude: 0.9)) }
        let output = try await recorder.stop(at: origin + CMTime(value: 1, timescale: 100))
        let decoded = try await decodedAudio(output.movie)
        XCTAssertLessThan(rms(decoded, from: 0.002, to: 0.028), 0.002)
        XCTAssertNil(output.interruption)
    }

    func testCombinedCoherentPeaksUseFixedHeadroomEvenWhenOneSourceIsSilent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var host = origin
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        for index in 0..<20 {
            host = origin + CMTime(value: Int64(index), timescale: 10)
            for source in sources.prefix(index < 10 ? 2 : 1) {
                source.deliver?(try audio(at: host.seconds, frames: 4800, amplitude: 0.95))
                await recorder.receiveTime(host)
            }
        }
        let output = try await recorder.stop(at: origin + CMTime(value: 2, timescale: 1))
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.2, to: 0.8), 0.67175, accuracy: 0.02)
        XCTAssertEqual(rms(decoded, from: 1.2, to: 1.8), 0.33588, accuracy: 0.02)
        let active = decoded.filter { $0.time > 0.2 && $0.time < 0.8 }
        XCTAssertLessThan(active.map { abs($0.value) }.max() ?? 2, 0.99)
        XCTAssertNil(output.interruption)
    }

    func testCombinedTenMinuteSilenceLateReplayAndFailureRetainPlayableTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [MixingFixtureSource(id: "mic"), MixingFixtureSource(id: "system")]
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var host = origin
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSources: sources, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        for index in 0..<2400 {
            host = origin + CMTime(value: Int64(index), timescale: 4)
            if index < 4 || index >= 2396 {
                for (offset, source) in sources.enumerated() {
                    source.deliver?(try audio(at: host.seconds, frames: offset == 0 ? 4410 : 4800,
                        amplitude: 0.6, rate: offset == 0 ? 44_100 : 48_000,
                        channels: offset == 0 ? 2 : 1, frequency: offset == 0 ? 440 : 880))
                    await recorder.receiveTime(host)
                }
            }
            if index == 1200 {
                // In-clock but already rendered late source data cannot replace
                // silence or push any subsequent narration forward.
                sources[0].deliver?(try audio(at: host.seconds - 2, frames: 4800, amplitude: 0.9))
            }
            await recorder.receiveTime(host)
        }
        host = origin + CMTime(value: 600, timescale: 1)
        let failure = expectation(description: "Required frozen source failed")
        recorder.onFailure = { error in
            XCTAssertTrue(error.localizedDescription.contains("system fixture disconnected"))
            failure.fulfill()
        }
        sources[1].failed?(NSError(domain: "system fixture disconnected", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "system fixture disconnected"]))
        await fulfillment(of: [failure], timeout: 2)
        let began = ProcessInfo.processInfo.systemUptime
        let output = try await recorder.stop(at: host)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
        XCTAssertNotNil(output.interruption)
        XCTAssertEqual(output.video.duration, 600, accuracy: 0.002)
        let decoded = try await decodedAudio(output.movie, windows: [0..<1, 298..<301, 599..<601])
        XCTAssertEqual(rms(decoded, from: 0.03, to: 0.08), 0.3, accuracy: 0.025)
        XCTAssertLessThan(rms(decoded, from: 298, to: 301), 0.002)
        XCTAssertEqual(rms(decoded, from: 599.78, to: 599.83), 0.3, accuracy: 0.025)
        XCTAssertGreaterThan(decoded.last?.time ?? 0, 599.97)
        XCTAssertTrue(sources.allSatisfy { $0.stops > 0 })
    }
    func testCaptureProfileSamplesSixtyWithoutChangingFixedPictureOrQueueBounds() throws {
        let rectangle = VideoRectangle(display: VideoDisplay(id: 3,
            frame: CGRect(x: -100, y: 200, width: 1000, height: 800), scale: 2),
            rect: CGRect(x: -20, y: 240, width: 600, height: 432))
        let config = try VideoRecorder.pictureConfiguration(rectangle: rectangle)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 60))
        XCTAssertEqual(config.queueDepth, 3)
        XCTAssertEqual(config.sourceRect, CGRect(x: 80, y: 40, width: 600, height: 432))
        XCTAssertEqual(config.destinationRect, CGRect(x: 0, y: 0, width: 1200, height: 864))
        XCTAssertEqual(config.width, 1200)
        XCTAssertEqual(config.height, 864)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertFalse(config.capturesAudio)
        XCTAssertTrue(config.showsCursor)
        XCTAssertTrue(config.preservesAspectRatio)
    }

    func testSixtyHzJitterAndDelayedFrameEncodeThirtyWithoutCatchupOrTimeCompression() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true)
        let image = try buffer(width: 16, height: 16)
        let origin = CMTime(seconds: 100, preferredTimescale: 1_000_000)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(accepted)
        // A late first update followed by a normal 60Hz update must not encode
        // both just 17ms apart to catch up with an old 30Hz deadline.
        let delayed = origin + CMTime(value: 49, timescale: 1000)
        let delayedAccepted = await recorder.receiveFrame(image, at: delayed, host: delayed)
        XCTAssertTrue(delayedAccepted)
        let following = origin + CMTime(value: 4, timescale: 60)
        let followingAccepted = await recorder.receiveFrame(image, at: following, host: following)
        XCTAssertFalse(followingAccepted, "A missed deadline cannot admit a 60fps catch-up pair")
        for index in 5..<180 {
            let jitter = index.isMultiple(of: 2) ? 0.0004 : -0.0004
            let time = origin + CMTime(seconds: Double(index) / 60 + jitter + (index >= 60 ? 5 : 0), preferredTimescale: 1_000_000)
            _ = await recorder.receiveFrame(image, at: time, host: time)
            // Let the real-time encoder consume fixtures as it would between
            // native callbacks; this test targets cadence, not writer saturation.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let output = try await recorder.stop(at: origin + CMTime(value: 8, timescale: 1))
        XCTAssertEqual(output.video.duration, 8, accuracy: 0.002)
        let asset = AVURLAsset(url: output.movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = decoded.copyNextSampleBuffer() { times.append(sample.presentationTimeStamp.seconds) }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(times.count, 85)
        XCTAssertLessThanOrEqual(times.count, 90)
        for (previous, next) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - previous, 0.031, "Decoded PTS must not contain 60Hz catch-up pairs")
        }
        XCTAssertTrue(times.contains { $0 > 5.99 && $0 < 6.04 }, "Idle elapsed time must survive downsampling")
        let audio = try await decodedAudio(output.movie)
        XCTAssertGreaterThan(audio.last?.time ?? 0, 7.97)
        XCTAssertNil(output.interruption)
    }

    func testSystemEncoderStallAtStopReportsInterruptedPlayablePortion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = SystemAudioCapture()
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        var ready = true
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSource: source, audioWriterReady: { ready }, hostTime: { origin })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        for index in 0..<6 {
            source.receive(try audio(at: 100 + Double(index) / 10, frames: 4800, amplitude: 0.2))
            await recorder.receiveTime(origin)
        }
        ready = false
        let began = ProcessInfo.processInfo.systemUptime
        let output = try await recorder.stop(at: origin + CMTime(value: 1, timescale: 1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 6)
        XCTAssertNotNil(output.interruption, "Exhausted audio backpressure must not publish as uninterrupted success")
        try await VideoRecorder.validateMovie(at: output.movie, width: 16, height: 16, audioExpected: true)
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.03, to: 0.08), 0.1414, accuracy: 0.02)
    }

    func testSystemBackwardPacketCannotBlockFollowingAudioUntilStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect), directory: directory, audioEnabled: true)
        let image = try buffer(width: 16, height: 16)
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        await recorder.receiveAudio(try audio(at: 100.5, frames: 4800, amplitude: 0.2))
        await recorder.receiveAudio(try audio(at: 100.1, frames: 4800, amplitude: 0.8))
        for index in 6..<12 {
            await recorder.receiveAudio(try audio(at: 100 + Double(index) / 10, frames: 4800, amplitude: 0.2))
        }
        let output = try await recorder.stop(at: origin + CMTime(value: 3, timescale: 2))
        let decoded = try await decodedAudio(output.movie)
        XCTAssertLessThan(rms(decoded, from: 0.12, to: 0.18), 0.002)
        XCTAssertEqual(rms(decoded, from: 0.65, to: 1.15), 0.1414, accuracy: 0.02)
    }
    func testSystemSourceBackpressureLateBuffersDiscontinuityAndHistoryActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = SystemAudioCapture()
        var host = CMTime(seconds: 100, preferredTimescale: 48_000)
        var ready = false
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSource: source, audioWriterReady: { ready }, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: host, host: host)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        for index in 0..<6 {
            host = CMTime(seconds: 100 + Double(index) / 10, preferredTimescale: 48_000)
            source.receive(try audio(at: host.seconds, frames: 4800, amplitude: 0.2, channels: 2))
            await recorder.receiveTime(host)
        }
        host = CMTime(seconds: 101, preferredTimescale: 48_000)
        await recorder.receiveTime(host)
        ready = true
        await recorder.receiveTime(host)
        // A backward/replayed packet cannot shift subsequent source audio.
        source.receive(try audio(at: 100.1, frames: 4800, amplitude: 0.8))
        await recorder.receiveTime(host)
        source.receive(try audio(at: 101, frames: 4800, amplitude: 0.2))
        host = CMTime(seconds: 101.8, preferredTimescale: 48_000)
        await recorder.receiveTime(host)
        // A forward clock discontinuity is an interruption, never arrival-time
        // retiming or an hour of generated silence on Stop.
        let failed = expectation(description: "System clock discontinuity")
        recorder.onFailure = { error in
            XCTAssertTrue(error.localizedDescription.contains("host clock")); failed.fulfill()
        }
        source.receive(try audio(at: 3700, frames: 4800, amplitude: 0.8))
        await fulfillment(of: [failed], timeout: 2)
        let began = ProcessInfo.processInfo.systemUptime
        let output = try await recorder.stop(at: host)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
        XCTAssertNotNil(output.interruption)
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.1, to: 0.5), 0.1414, accuracy: 0.02)
        XCTAssertLessThan(rms(decoded, from: 0.75, to: 0.95), 0.002)
        XCTAssertEqual(rms(decoded, from: 1.03, to: 1.08), 0.1414, accuracy: 0.02)
        let store = HistoryStore(url: directory.appendingPathComponent("History"))
        let staging = try store.stageVideo()
        try FileManager.default.copyItem(at: output.movie, to: staging.appendingPathComponent(output.video.movie))
        try FileManager.default.copyItem(at: directory.appendingPathComponent("thumbnail.png"), to: staging.appendingPathComponent("thumbnail.png"))
        let entry = try store.publishVideo(staging: staging, video: output.video, label: "System")
        let reopened = HistoryStore(url: store.url)
        XCTAssertFalse(try XCTUnwrap(reopened.entries().first).unavailable)
        let movie = try reopened.validatedMovieURL(entry)
        try await VideoRecorder.validateMovie(at: movie, width: 16, height: 16, audioExpected: true)
        let exported = directory.appendingPathComponent("system-export.mp4")
        try reopened.exportVideo(entry, to: exported)
        XCTAssertEqual(try Data(contentsOf: movie), try Data(contentsOf: exported))
        // A detached delivery after Stop cannot reopen source intake.
        source.receive(try audio(at: host.seconds, frames: 4800, amplitude: 0.9))
        let repeated = try await recorder.stop(at: host + CMTime(value: 10, timescale: 1))
        XCTAssertEqual(output.video, repeated.video)
    }
    func testSystemSourceQuietStaticTenMinutesKeepsLateEventsOnElapsedTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = SystemAudioCapture()
        let config = SCStreamConfiguration()
        source.configure(config)
        XCTAssertTrue(config.capturesAudio)
        XCTAssertTrue(config.excludesCurrentProcessAudio)
        XCTAssertEqual(config.sampleRate, 48_000)
        XCTAssertEqual(config.channelCount, 1)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        var host = CMTime(seconds: 100, preferredTimescale: 48_000)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSource: source, hostTime: { host })
        let start = Task { try await recorder.start() }
        let image = try buffer(width: 16, height: 16)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: host, host: host)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value // Quiet system audio must become ready without a buffer.
        // One still picture, ten elapsed minutes. Ticks are the recorder's
        // production silence watermark; the supplied host clock avoids a sleep.
        for index in 0..<2400 {
            host = CMTime(seconds: 100 + Double(index) / 4, preferredTimescale: 48_000)
            if index < 4 || index >= 2396 {
                source.receive(try audio(at: host.seconds, frames: 4800, amplitude: 0.2, channels: 2))
            }
            await recorder.receiveTime(host)
        }
        host = CMTime(seconds: 700, preferredTimescale: 48_000)
        let began = ProcessInfo.processInfo.systemUptime
        let output = try await recorder.stop(at: host)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3, "Stop drains only a bounded tail")
        XCTAssertNil(output.interruption)
        XCTAssertEqual(output.video.duration, 600, accuracy: 0.002)
        let decoded = try await decodedAudio(output.movie, windows: [0..<1, 300..<301, 599..<601])
        XCTAssertLessThan(rms(decoded, from: 300, to: 301), 0.002)
        XCTAssertEqual(rms(decoded, from: 0.03, to: 0.08), 0.1414, accuracy: 0.02)
        XCTAssertEqual(rms(decoded, from: 599.78, to: 599.83), 0.1414, accuracy: 0.02)
        XCTAssertGreaterThan(decoded.last?.time ?? 0, 599.97)
        XCTAssertLessThan(decoded.last?.time ?? 601, 600.025)
    }
    func testBackpressuredQueuedNarrationSurvivesVideoSilenceWatermark() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        var acceptsAudio = false
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true, audioWriterReady: { acceptsAudio })
        let image = try buffer(width: 16, height: 16)
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(accepted)
        for index in 0..<6 {
            await recorder.receiveAudio(try audio(at: 100 + Double(index) / 10, frames: 4800, amplitude: 0.2))
        }
        let picture = origin + CMTime(value: 1, timescale: 1)
        _ = await recorder.receiveFrame(image, at: picture, host: picture)
        // Release pressure only after queued real audio and a later video
        // watermark have both passed through production media processing.
        acceptsAudio = true
        let output = try await recorder.stop(at: origin + CMTime(value: 6, timescale: 5))
        let decoded = try await decodedAudio(output.movie)
        XCTAssertEqual(rms(decoded, from: 0.1, to: 0.5), 0.1414, accuracy: 0.015)
        XCTAssertLessThan(rms(decoded, from: 0.8, to: 1.1), 0.002)
    }

    func testRapidStopPadsPictureWithSilenceRatherThanPostStopMicrophone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true)
        let image = try buffer(width: 16, height: 16)
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(accepted)
        // The admitted buffer straddles the real 5ms Stop. Its first 5ms is
        // quiet; everything after Stop is loud and must not enter frame padding.
        let straddling = try audio(at: 100, frames: 4800, amplitude: 0.8)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: try XCTUnwrap(straddling.dataBuffer),
            offsetIntoDestination: 0, dataLength: 240 * 2), noErr)
        await recorder.receiveAudio(straddling)
        let output = try await recorder.stop(at: origin + CMTime(value: 1, timescale: 200))
        XCTAssertEqual(output.video.duration, 1.0 / 30, accuracy: 0.002)
        let decoded = try await decodedAudio(output.movie)
        XCTAssertLessThan(rms(decoded, from: 0.01, to: 0.03), 0.002,
            "The minimum video frame duration must not widen microphone admission")
    }

    func testInterleavedVideoDoesNotReplaceQueuedNarrationWithSilence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true)
        let image = try buffer(width: 16, height: 16)
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(image, at: origin, host: origin)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(accepted)
        // Each picture advances the safe audio boundary into (not past) the
        // first queued 100ms buffer. Audio arrives 450ms behind picture.
        for index in 0..<10 {
            await recorder.receiveAudio(try audio(at: 100 + Double(index) / 10, frames: 4800, amplitude: 0.2))
            let picture = origin + CMTime(seconds: 0.55 + Double(index) / 10, preferredTimescale: 48_000)
            _ = await recorder.receiveFrame(image, at: picture, host: picture)
        }
        let output = try await recorder.stop(at: origin + CMTime(value: 3, timescale: 2))
        let decoded = try await decodedAudio(output.movie)
        // Ignore AAC priming/transition edges; continuous known narration must
        // retain its level in every independent 100ms interior window.
        for index in 1..<9 {
            let start = Double(index) / 10
            XCTAssertEqual(rms(decoded, from: start, to: start + 0.08), 0.1414, accuracy: 0.015,
                "Queued narration was replaced near \(start)s")
        }
        XCTAssertLessThan(rms(decoded, from: 1.1, to: 1.4), 0.002)
    }

    private func decodedAudio(_ url: URL, windows: [Range<Double>]? = nil) async throws -> [(time: Double, value: Double)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [(Double, Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(sample.dataBuffer)
            let size = CMBlockBufferGetDataLength(block)
            var values = [Int16](repeating: 0, count: size / 2)
            XCTAssertEqual(values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }, noErr)
            let format = try XCTUnwrap(sample.formatDescription)
            let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
            for (index, value) in values.enumerated() {
                let time = sample.presentationTimeStamp.seconds + Double(index / Int(asbd.mChannelsPerFrame)) / asbd.mSampleRate
                if windows?.contains(where: { $0.contains(time) }) ?? true { result.append((time, Double(value) / 32768)) }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return result
    }

    private func rms(_ samples: [(time: Double, value: Double)], from start: Double, to end: Double) -> Double {
        let window = samples.filter { $0.time >= start && $0.time < end }
        XCTAssertFalse(window.isEmpty, "Missing decoded audio in \(start)..<\(end)")
        return sqrt(window.reduce(0) { $0 + $1.value * $1.value } / Double(max(1, window.count)))
    }

    func testAudioStartupTimeoutAndStalledStopAreBounded() async throws {
        for stallsAtStart in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = StalledAudioSource(starts: stallsAtStart)
            let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
            let recorder = try await VideoRecorder.preparedWriter(rectangle:
                VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
                directory: directory, startupTimeout: 0.08, audioSource: source)
            let start = Task { try await recorder.start() }
            let stamp = CMClockGetTime(CMClockGetHostTimeClock())
            let image = try buffer(width: 16, height: 16)
            var admitted = false
            for _ in 0..<100 where !admitted {
                admitted = await recorder.receiveFrame(image, at: stamp, host: stamp)
                if !admitted { try await Task.sleep(nanoseconds: 1_000_000) }
            }
            if stallsAtStart {
                do { try await start.value; XCTFail("Unready audio must block successful startup") } catch {}
            } else { try await start.value }
            let began = ProcessInfo.processInfo.systemUptime
            if stallsAtStart {
                do { _ = try await recorder.stop(at: stamp); XCTFail("Unready requested source must not publish") } catch {}
                source.resume()
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
                continue
            }
            let output = try await recorder.stop(at: stamp + CMTime(value: 1, timescale: 5))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
            XCTAssertNotNil(output.interruption)
            source.resume()
            try await VideoRecorder.validateMovie(at: output.movie, width: 16, height: 16, audioExpected: true)
        }
    }

    private final class StalledAudioSource: RecordingAudioSource {
        let id = "stalled"
        let stallsAtStart: Bool
        var continuation: CheckedContinuation<Void, Never>?
        init(starts: Bool) { stallsAtStart = starts }
        func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws {
            if stallsAtStart { await withCheckedContinuation { continuation = $0 } }
        }
        func stop() async { if !stallsAtStart { await withCheckedContinuation { continuation = $0 } } }
        func resume() { continuation?.resume(); continuation = nil }
    }
    func testNativeRateStereoSourceResamplesWithoutMovingLateNarration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true)
        let image = try buffer(width: 16, height: 16)
        let stamp = CMTime(seconds: 100, preferredTimescale: 48_000)
        var admitted = false
        for _ in 0..<100 where !admitted {
            admitted = await recorder.receiveFrame(image, at: stamp, host: stamp)
            if !admitted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        // Quiet interval followed by a 44.1k stereo tone, on the host timeline.
        for index in 5..<10 {
            await recorder.receiveAudio(try audio(at: 100 + Double(index) / 10, frames: 4410, amplitude: 0.2, rate: 44_100, channels: 2))
        }
        let output = try await recorder.stop(at: stamp + CMTime(value: 1, timescale: 1))
        let asset = AVURLAsset(url: output.movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(decoded)
        XCTAssertTrue(reader.startReading())
        var quiet = 0.0, tone = 0.0
        while let sample = decoded.copyNextSampleBuffer() {
            let block = try XCTUnwrap(sample.dataBuffer)
            let size = CMBlockBufferGetDataLength(block)
            var values = [Int16](repeating: 0, count: size / 2)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            let format = try XCTUnwrap(sample.formatDescription)
            let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
            for (index, value) in values.enumerated() {
                let time = sample.presentationTimeStamp.seconds + Double(index / Int(asbd.mChannelsPerFrame)) / asbd.mSampleRate
                let energy = pow(Double(value) / 32768, 2)
                if time < 0.4 { quiet += energy }
                if time > 0.6 { tone += energy }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertLessThan(quiet, 0.1)
        XCTAssertGreaterThan(tone, 100)
    }
    func testGenericSourceFailureRetainsPlayableAACAndCannotChangeFrozenSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = AudioSourceFixture()
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioSource: source)
        let start = Task { try await recorder.start() }
        let stamp = CMClockGetTime(CMClockGetHostTimeClock())
        let image = try buffer(width: 16, height: 16)
        var admitted = false
        for _ in 0..<100 where !admitted {
            admitted = await recorder.receiveFrame(image, at: stamp, host: stamp)
            if !admitted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await start.value
        XCTAssertEqual(source.starts, 1)
        source.deliver?(try audio(at: stamp.seconds, frames: 4800, amplitude: 0.2))
        let failed = expectation(description: "Source disconnect")
        recorder.onFailure = { _ in failed.fulfill() }
        source.failed?(NSError(domain: "Frozen microphone disconnected", code: 1))
        await fulfillment(of: [failed], timeout: 2)
        let output = try await recorder.stop(at: stamp + CMTime(value: 1, timescale: 5))
        XCTAssertNotNil(output.interruption)
        XCTAssertEqual(source.stops, 1)
        try await VideoRecorder.validateMovie(at: output.movie, width: 16, height: 16, audioExpected: true)
    }

    private final class AudioSourceFixture: RecordingAudioSource {
        let id = "frozen-input"
        var deliver: ((CMSampleBuffer) -> Void)?
        var failed: ((Error) -> Void)?
        var starts = 0
        var stops = 0
        func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws {
            starts += 1; self.deliver = deliver; self.failed = failed
        }
        func stop() async { stops += 1 }
    }
    func testQuietMicrophoneRapidStopStillHasOneDecodableAudioTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true)
        let source = try buffer(width: 16, height: 16)
        let first = CMTime(seconds: 100, preferredTimescale: 48_000)
        var admitted = false
        for _ in 0..<100 where !admitted {
            admitted = await recorder.receiveFrame(source, at: first, host: first)
            if !admitted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let output = try await recorder.stop(at: first + CMTime(value: 1, timescale: 600))
        try await VideoRecorder.validateMovie(at: output.movie, width: 16, height: 16, audioExpected: true)
        XCTAssertEqual(output.video.duration, 1.0 / 30, accuracy: 0.002)
    }
    func testMicrophoneOutputDecodesAACAndExcludesPreVideoAndStopTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect),
            directory: directory, audioEnabled: true)
        // A loud countdown sample must never be audible in the resulting movie.
        await recorder.receiveAudio(try audio(at: 99, frames: 4800, amplitude: 0.9))
        let source = try buffer(width: 16, height: 16)
        let first = CMTime(seconds: 100, preferredTimescale: 48_000)
        var admitted = false
        for _ in 0..<100 where !admitted {
            admitted = await recorder.receiveFrame(source, at: first, host: first)
            if !admitted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(admitted)
        for index in 0..<12 {
            await recorder.receiveAudio(try audio(at: 100 + Double(index) / 10, frames: 4800, amplitude: 0.2))
        }
        let output = try await recorder.stop(at: CMTime(seconds: 101, preferredTimescale: 48_000))
        XCTAssertEqual(output.video.audioCodec, "aac")
        try await VideoRecorder.validateMovie(at: output.movie, width: 16, height: 16, audioExpected: true)
        let asset = AVURLAsset(url: output.movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(decoded)
        XCTAssertTrue(reader.startReading())
        var energy = 0.0
        var count = 0
        var end = 0.0
        while let sample = decoded.copyNextSampleBuffer() {
            end = max(end, CMTimeGetSeconds(sample.presentationTimeStamp + sample.duration))
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(sample.presentationTimeStamp), -0.025)
            let block = try XCTUnwrap(sample.dataBuffer)
            let size = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: size / 2)
            XCTAssertEqual(data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }, noErr)
            for value in data { energy += pow(Double(value) / 32768, 2); count += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(count, 40_000)
        XCTAssertEqual(sqrt(energy / Double(count)), 0.1414, accuracy: 0.025)
        XCTAssertLessThanOrEqual(end, 1.025, "No audio beyond the common Stop endpoint")
        // The real History validator must reopen and export AAC recordings, and
        // metadata claiming silence must not accept an audio-bearing file.
        let historyRoot = directory.appendingPathComponent("History")
        let store = HistoryStore(url: historyRoot)
        let staging = try store.stageVideo()
        try FileManager.default.copyItem(at: output.movie, to: staging.appendingPathComponent(output.video.movie))
        try FileManager.default.copyItem(at: directory.appendingPathComponent("thumbnail.png"), to: staging.appendingPathComponent("thumbnail.png"))
        let entry = try store.publishVideo(staging: staging, video: output.video, label: "Narration")
        let reopened = HistoryStore(url: historyRoot)
        let listed = try XCTUnwrap(reopened.entries().first)
        XCTAssertFalse(listed.unavailable)
        XCTAssertEqual(listed.video?.audioCodec, "aac")
        _ = try reopened.validatedMovieURL(entry)
        let exported = directory.appendingPathComponent("export.mp4")
        try reopened.exportVideo(entry, to: exported)
        try await VideoRecorder.validateMovie(at: exported, width: 16, height: 16, audioExpected: true)
        do { try await VideoRecorder.validateMovie(at: exported, width: 16, height: 16); XCTFail("Silent metadata must reject audio") } catch {}
    }

    private func audio(at seconds: Double, frames: Int, amplitude: Double, rate: Double = 48_000, channels: UInt32 = 1, frequency: Double = 440, phase: Double = 0) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels, mChannelsPerFrame: channels,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 2 * Int(channels), blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * 2 * Int(channels), flags: 0, blockBufferOut: &block), noErr)
        let values = (0..<(frames * Int(channels))).map { Int16(sin((Double($0 / Int(channels)) / rate + phase) * 2 * .pi * frequency) * amplitude * 32767) }
        _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: values.count * 2) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var sampleSize = 2 * Int(channels)
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    func testProductionWriterFinalizesImmediateRapidStaticTailAndDroppedGaps() async throws {
        for (times, stop) in [([0.0], 1.0 / 600), ([0.0], 1.0 / 30),
                              ([0.0, 1.0], 11.0), ([0.0, 0.5, 2.0], 12.0),
                              ([0.0, 0.033333, 0.066666, 0.099999], 0.133333),
                              ([0.0, 0.032933, 0.067066, 0.099599], 0.133333)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let rectangle = VideoRectangle(display: VideoDisplay(id: 1,
                frame: CGRect(x: 0, y: 0, width: 101, height: 55), scale: 1),
                rect: CGRect(x: 0, y: 0, width: 101, height: 55))
            let recorder = try await VideoRecorder.preparedWriter(rectangle: rectangle, directory: directory)
            let source = try buffer(width: 102, height: 56)
            let start = Task { try await recorder.start() }
            for time in times {
                let stamp = CMTime(seconds: 100 + time, preferredTimescale: 1_000_000)
                var accepted = false
                for _ in 0..<100 where !accepted {
                    accepted = await recorder.receiveFrame(source, at: stamp, host: stamp)
                    if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
                }
                XCTAssertTrue(accepted)
            }
            try await start.value
            let output = try await recorder.stop(at: CMTime(seconds: 100 + stop, preferredTimescale: 1_000_000))
            let asset = AVURLAsset(url: output.movie)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            XCTAssertEqual(duration, stop, accuracy: 1.0 / 30 + 0.00001)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let fps = try await track.load(.nominalFrameRate)
            print("Production synthetic MP4: input=\(times), stop=\(stop)s, duration=\(duration)s, nominalFrameRate=\(fps), canvas=102x56")
            XCTAssertLessThanOrEqual(fps, 30.001, "Ultra-short clips must not advertise hundreds of fps")
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertTrue(audio.isEmpty)
            try await VideoRecorder.validateMovie(at: output.movie, width: 102, height: 56)
            XCTAssertEqual(output.video.duration, duration)
            // Decode every presented sample, not just container metadata.
            let reader = try AVAssetReader(asset: asset)
            let decoded = AVAssetReaderTrackOutput(track: track, outputSettings:
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(decoded)
            XCTAssertTrue(reader.startReading())
            var stamps: [Double] = []
            while let sample = decoded.copyNextSampleBuffer() { stamps.append(CMTimeGetSeconds(sample.presentationTimeStamp)) }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(stamps.count, times.count)
            // AVAssetWriter's default video timescale is 600; decoded sample
            // times may round to that grid without changing the source cadence.
            for (observed, expected) in zip(stamps, times) { XCTAssertEqual(observed, expected, accuracy: 1.0 / 600) }
        }
    }

    func testProductionIntakeRejectsLateAndNonmonotonicFramesAndCannotRestartAfterStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect), directory: directory)
        let source = try buffer(width: 16, height: 16)
        let first = CMTime(value: 100, timescale: 1)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(source, at: first, host: first)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(accepted)
        let duplicate = await recorder.receiveFrame(source, at: first, host: first)
        XCTAssertFalse(duplicate)
        let tooFast = await recorder.receiveFrame(source, at: first + CMTime(value: 1, timescale: 600), host: first)
        XCTAssertFalse(tooFast, "Intake must enforce at most 30fps independently of the OS request")
        recorder.closeIntake(at: first)
        let late = await recorder.receiveFrame(source, at: first + CMTime(value: 1, timescale: 1), host: first)
        XCTAssertFalse(late)
        _ = try await recorder.stop(at: first)
        do { try await recorder.start(); XCTFail("Finalized recorder must not restart") } catch {}
    }

    func testUnpaddedOddNativeImagePreservesLastEdgeAndAddsOpaqueBlackCanvas() throws {
        let canvas = try VideoCanvas(native: CGSize(width: 101, height: 55))
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 7, y: 9, width: 101, height: 55))
        let output = try buffer(width: 102, height: 56)
        CIContext().render(canvas.normalize(image), to: output,
            bounds: CGRect(x: 0, y: 0, width: 102, height: 56), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(output)
        for (x, y, red) in [(0, 0, 255), (100, 54, 255), (101, 54, 0), (100, 55, 0)] {
            // CI image coordinates are y-up; pixel buffer scanlines are top-down.
            let offset = (55 - y) * row + x * 4
            XCTAssertEqual(pixels[offset], 0)
            XCTAssertEqual(pixels[offset + 1], 0)
            XCTAssertEqual(pixels[offset + 2], UInt8(red))
            XCTAssertEqual(pixels[offset + 3], 255)
        }
    }

    private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
