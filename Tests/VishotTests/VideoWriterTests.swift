import XCTest
import AVFoundation
import CoreImage
@testable import Vishot

@MainActor final class VideoWriterTests: XCTestCase {
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

    private func decodedAudio(_ url: URL) async throws -> [(time: Double, value: Double)] {
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
                result.append((sample.presentationTimeStamp.seconds + Double(index / Int(asbd.mChannelsPerFrame)) / asbd.mSampleRate,
                    Double(value) / 32768))
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

    private func audio(at seconds: Double, frames: Int, amplitude: Double, rate: Double = 48_000, channels: UInt32 = 1) throws -> CMSampleBuffer {
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
        let values = (0..<(frames * Int(channels))).map { Int16(sin(Double($0 / Int(channels)) * 2 * .pi * 440 / rate) * amplitude * 32767) }
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
