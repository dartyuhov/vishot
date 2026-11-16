import AppKit
import VishotConfiguration
import VishotRendering
import AVFoundation
import ScreenCaptureKit
import CoreImage

protocol VideoRecording: AnyObject {
    var directory: URL { get }
    var movie: URL { get }
    var displayID: CGDirectDisplayID { get }
    var displayFrame: CGRect { get }
    @MainActor var hasCompletedMovie: Bool { get }
    @MainActor var onFailure: ((Error) -> Void)? { get set }
    @MainActor func start() async throws
    @MainActor func stop(at endpoint: CMTime) async throws -> VideoRecorder.Output
    func closeIntake(at endpoint: CMTime)
    func cancelPreparation() async
}

/// One stream and one serial writer owner. The callback queue retains at most
/// three pending SC buffers; normalization uses a threshold-bounded owned pool.
final class VideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate, VideoRecording {
    struct Output {
        let directory: URL
        let movie: URL
        let video: HistoryVideo
        var interruption: Error? = nil
    }
    let directory: URL
    let movie: URL
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let displayFrame: CGRect
    private let canvas: VideoCanvas
    private let scale: CGFloat
    private let callbacks = DispatchQueue(label: "dev.vishot.video.capture", qos: .userInitiated)
    private let media = DispatchQueue(label: "dev.vishot.video.media", qos: .userInitiated)
    private let intake = VideoIntake()
    private let audioIntake = VideoIntake()
    private var audioInput: AVAssetWriterInput?
    private var audioWriterReady: () -> Bool = { true }
    private var canAppendAudio: Bool { audioWriterReady() && audioInput?.isReadyForMoreMediaData == true }
    private var audioSource: RecordingAudioSource?
    private var audioEnabled = false
    private var lastAudioEnd = CMTime.zero
    private var pendingAudio: [CMSampleBuffer] = []
    private var audioReady = false
    private var audioConverter: AVAudioConverter?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
    private var stream: SCStream!
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var pool: CVPixelBufferPool!
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let background = CGColor(gray: 0, alpha: 1)
    private lazy var context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
                                                  .cacheIntermediates: false])
    private var timeline = VideoTimeline()
    private var lastFrame: CVPixelBuffer?
    private var terminalError: Error?
    private var stopTask: Task<Output, Error>?
    private var startCapture: ((@escaping (Error?) -> Void) -> Void)!
    private var stopCapture: ((@escaping (Error?) -> Void) -> Void)!
    private var startupTimeout: TimeInterval = 5
    @MainActor private var starting: VideoStreamOperation?
    @MainActor private var stopping = false
    @MainActor private(set) var hasCompletedMovie = false
    @MainActor var onFailure: ((Error) -> Void)?

    private init(directory: URL, rectangle: VideoRectangle) throws {
        self.directory = directory
        movie = directory.appendingPathComponent((Config.fileName(for: Date()) as NSString).deletingPathExtension + ".mp4")
        displayID = rectangle.display.id
        displayFrame = rectangle.display.frame
        frame = rectangle.rect
        scale = rectangle.display.scale
        canvas = try VideoCanvas(native: CGSize(width: frame.width * scale, height: frame.height * scale))
        super.init()
    }

    static func prepare(rectangle: VideoRectangle, directory: URL, microphone: MicrophoneDevice? = nil,
                        audioSource: RecordingAudioSource? = nil) async throws -> VideoRecorder {
        guard microphone == nil || audioSource == nil else {
            throw SettingsError(message: "Multiple requested audio sources require one mixed source delivery adapter.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw VideoPermissionError()
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == rectangle.display.id }),
              let own = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw SettingsError(message: "Recording display or Vishot application exclusion is unavailable.")
        }
        guard display.frame == rectangle.display.frame,
              display.frame.contains(rectangle.rect), rectangle.rect.width > 0, rectangle.rect.height > 0 else {
            throw SettingsError(message: "Recording display geometry changed. Select the target again.")
        }
        let recorder = try VideoRecorder(directory: directory, rectangle: rectangle)
        recorder.audioEnabled = microphone != nil || audioSource != nil
        recorder.audioSource = audioSource ?? microphone.map(MicrophoneCapture.init)
        let filter = SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = recorder.canvas.width
        config.height = recorder.canvas.height
        config.sourceRect = rectangle.sourceRect
        config.destinationRect = CGRect(origin: .zero, size: recorder.canvas.contentSize)
        config.backgroundColor = recorder.background
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        recorder.stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        recorder.startCapture = { [stream = recorder.stream!] completion in stream.startCapture { completion($0) } }
        recorder.stopCapture = { [stream = recorder.stream!] completion in stream.stopCapture { completion($0) } }
        try recorder.stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.callbacks)
        do { try await recorder.onMedia { try recorder.prepareWriter() } }
        catch {
            try? recorder.stream.removeStreamOutput(recorder, type: .screen)
            throw error
        }
        return recorder
    }

    /// Exercises the production media pipeline without a desktop capture. Only
    /// stream operations and clock readings are supplied by the caller.
    static func preparedWriter(rectangle: VideoRectangle, directory: URL, startupTimeout: TimeInterval = 5,
        audioEnabled: Bool = false, audioSource: RecordingAudioSource? = nil,
        audioWriterReady: @escaping () -> Bool = { true },
        startCapture: @escaping (@escaping (Error?) -> Void) -> Void = { $0(nil) },
        stopCapture: @escaping (@escaping (Error?) -> Void) -> Void = { $0(nil) }) async throws -> VideoRecorder {
        let recorder = try VideoRecorder(directory: directory, rectangle: rectangle)
        recorder.startCapture = startCapture
        recorder.stopCapture = stopCapture
        recorder.startupTimeout = startupTimeout
        recorder.audioEnabled = audioEnabled || audioSource != nil
        recorder.audioSource = audioSource
        recorder.audioWriterReady = audioWriterReady
        try await recorder.onMedia { try recorder.prepareWriter() }
        return recorder
    }

    private func prepareWriter() throws {
        writer = try AVAssetWriter(outputURL: movie, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width, AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: canvas.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw SettingsError(message: "H.264 output is unsupported for this display.")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width, kCVPixelBufferHeightKey as String: canvas.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw SettingsError(message: "Video writer rejected its input.") }
        writer.add(input)
        if audioEnabled {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audio.expectsMediaDataInRealTime = true
            guard writer.canApply(outputSettings: settings, forMediaType: .audio), writer.canAdd(audio) else {
                throw SettingsError(message: "AAC recording audio is unsupported.")
            }
            writer.add(audio)
            audioInput = audio
        }
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            throw SettingsError(message: "Could not allocate recording buffer pool.")
        }
        guard writer.startWriting() else { throw writer.error ?? SettingsError(message: "Could not start video writer.") }
    }

    @MainActor func start() async throws {
        guard !stopping else { throw CancellationError() }
        let operation = VideoStreamOperation()
        starting = operation
        var ready = false
        defer {
            if !ready {
                operation.abandon()
                closeIntake(at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
        let stop = stopCapture!
        if let audioSource {
            // Source startup is fenced by this same bounded operation. Late
            // completion after Stop must tear down rather than reopen intake.
            Task.detached { [weak self] in
                do {
                    try await audioSource.start(deliver: { [weak self] in self?.enqueueAudio($0) },
                        failed: { [weak self] in self?.sourceFailed($0) })
                    _ = try? await self?.onMedia { self?.audioReady = true }
                    if self?.intake.isClosed != false { await audioSource.stop() }
                } catch { self?.sourceFailed(error); await audioSource.stop() }
            }
        }
        startCapture { error in
            // An OS operation is not necessarily cancellation-cooperative. A
            // late successful start must stop its own stream, never reopen intake.
            if !operation.complete(error), error == nil { stop { _ in } }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !stopping, !Task.isCancelled else { operation.abandon(); throw CancellationError() }
            if let result = operation.result { try result.get() }
            let started = try await onMedia { () throws -> Bool in
                if let error = self.terminalError { throw error }
                return self.timeline.origin != nil && (self.audioSource == nil || self.audioReady)
            }
            if started, operation.result != nil { ready = true; return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw SettingsError(message: "Recording startup timed out before the stream and first complete frame were ready.")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return }
        if status == SCFrameStatus.suspended.rawValue || status == SCFrameStatus.stopped.rawValue {
            sourceFailed(SettingsError(message: "Screen recording was suspended or stopped."))
            return
        }
        guard status == SCFrameStatus.complete.rawValue, intake.admit(sample.presentationTimeStamp) else { return }
        media.async {
            defer { self.intake.release() }
            if let source = sample.imageBuffer {
                _ = self.append(source, at: sample.presentationTimeStamp, host: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    /// Synthetic buffers enter the same bounded intake, normalization, timing,
    /// append and finalization path as complete SCStream frames.
    func receiveFrame(_ source: CVPixelBuffer, at time: CMTime, host: CMTime) async -> Bool {
        guard intake.admit(time) else { return false }
        return (try? await onMedia {
            defer { self.intake.release() }
            return self.append(source, at: time, host: host)
        }) ?? false
    }

    private func append(_ source: CVPixelBuffer, at time: CMTime, host: CMTime) -> Bool {
        guard terminalError == nil, intake.allows(time), input.isReadyForMoreMediaData else { return false }
        guard CVPixelBufferGetWidth(source) == canvas.width, CVPixelBufferGetHeight(source) == canvas.height else {
            fail(SettingsError(message: "Recording surface dimensions changed unexpectedly.")); return false
        }
        // This is a runtime guard, not a claim that the clock mapping has been
        // validated on every supported OS. Never admit samples from a foreign epoch.
        guard abs(CMTimeGetSeconds(host - time)) < 5 else {
            fail(SettingsError(message: "Screen recording timestamps do not match the host clock.")); return false
        }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else {
            if result != kCVReturnWouldExceedAllocationThreshold { fail(SettingsError(message: "Recording buffer allocation failed.")) }
            return false
        }
        let image = CIImage(cvPixelBuffer: source)
        let bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let opaque = canvas.normalize(image)
        context.render(opaque, to: buffer, bounds: bounds, colorSpace: space)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        guard let relative = timeline.admit(time) else { return false }
        if relative == .zero { writer.startSession(atSourceTime: .zero) }
        guard adaptor.append(buffer, withPresentationTime: relative) else {
            fail(writer.error ?? SettingsError(message: "Video frame append failed.")); return false
        }
        lastFrame = buffer
        // Keep only a small late-arrival allowance; quiet intervals are encoded
        // as we go so a long quiet clip never creates unbounded Stop work.
        if audioEnabled, relative > CMTime(value: 1, timescale: 2) {
            let safe = time - CMTime(value: 1, timescale: 2)
            drainAudio(until: safe)
            appendSilence(until: safe - timeline.origin!)
        }
        return true
    }

    private func enqueueAudio(_ sample: CMSampleBuffer) {
        guard abs((CMClockGetTime(CMClockGetHostTimeClock()) - sample.presentationTimeStamp).seconds) < 5 else {
            sourceFailed(SettingsError(message: "Audio source timestamps do not match the host clock.")); return
        }
        guard audioIntake.admit(sample.presentationTimeStamp) else { return }
        media.async {
            defer { self.audioIntake.release() }
            self.appendAudio(sample)
        }
    }

    /// Fixture and native source delivery share admission, trimming and encoding.
    func receiveAudio(_ sample: CMSampleBuffer) async {
        guard audioIntake.admit(sample.presentationTimeStamp) else { return }
        _ = try? await onMedia {
            defer { self.audioIntake.release() }
            self.appendAudio(sample)
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard let sample = canonicalAudio(sample) else {
            fail(SettingsError(message: "Audio source format could not be converted to recording PCM.")); return
        }
        guard audioEnabled, terminalError == nil, sample.isValid,
              let origin = timeline.origin, let format = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0, sample.numSamples > 0 else { return }
        let duration = CMTime(seconds: Double(sample.numSamples) / asbd.mSampleRate, preferredTimescale: 48_000)
        guard sample.presentationTimeStamp + duration > origin, CMTimeGetSeconds(duration) <= 0.25 else { return }
        // A 250ms tail bounds retained memory and lets Stop trim a straddling
        // buffer before AAC encoding. No timestamps are shifted to arrival time.
        pendingAudio.append(sample)
        let safe = sample.presentationTimeStamp - CMTime(value: 1, timescale: 4)
        drainAudio(until: min(safe, audioIntake.endpoint ?? safe))
        if pendingAudio.count > 32 { pendingAudio.removeFirst(pendingAudio.count - 32) }
    }

    private func canonicalAudio(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let description = sample.formatDescription, sample.numSamples > 0, sample.numSamples <= 48_000 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if format == pcmFormat { return sample }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
        input.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else { return nil }
        if audioConverter?.inputFormat != format { audioConverter = AVAudioConverter(from: format, to: pcmFormat) }
        guard let converter = audioConverter,
              let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(ceil(Double(sample.numSamples) * 48_000 / format.sampleRate)) + 128) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        var sampleSize = 2
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: pcmFormat.formatDescription,
            sampleCount: Int(output.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &result) == noErr,
            let result,
            CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: output.audioBufferList) == noErr else { return nil }
        CMSampleBufferSetDataReady(result)
        return result
    }

    private func drainAudio(until endpoint: CMTime) {
        guard let origin = timeline.origin, let audioInput else { return }
        let deadline = DispatchTime.now() + 2
        while let sample = pendingAudio.first, sample.presentationTimeStamp < endpoint {
            let start = sample.presentationTimeStamp
            guard let format = sample.formatDescription,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate > 0 else { pendingAudio.removeFirst(); continue }
            let rate = asbd.mSampleRate
            let end = start + CMTime(seconds: Double(sample.numSamples) / rate, preferredTimescale: 48_000)
            guard end <= endpoint || audioIntake.isClosed else { break }
            if !canAppendAudio {
                guard audioIntake.isClosed else { break }
                while !canAppendAudio, writer.status == .writing, DispatchTime.now() < deadline {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            let lower = max(origin + lastAudioEnd, start)
            let upper = min(endpoint, end)
            let first = max(0, Int(ceil(CMTimeGetSeconds(lower - start) * rate - 0.00001)))
            let limit = min(sample.numSamples, Int(floor(CMTimeGetSeconds(upper - start) * rate + 0.00001)))
            guard canAppendAudio else { return }
            guard limit > first else { pendingAudio.removeFirst(); continue }
            var trimmed: CMSampleBuffer?
            let copyStatus = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleRange: CFRange(location: first, length: limit - first), sampleBufferOut: &trimmed)
            guard copyStatus == noErr,
                let trimmed else { fail(SettingsError(message: "Could not trim recording audio.")); return }
            let stamp = start + CMTime(seconds: Double(first) / rate, preferredTimescale: 1_000_000_000) - origin
            appendSilence(until: stamp)
            // Silence can itself encounter encoder backpressure. Keep the real
            // buffer queued for retry instead of consuming it or filling over it.
            guard canAppendAudio else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate.rounded())),
                presentationTimeStamp: stamp, decodeTimeStamp: .invalid)
            var relative: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: trimmed,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &relative) == noErr,
                let relative else { fail(SettingsError(message: "Could not retime recording audio.")); return }
            if !audioInput.append(relative) { fail(writer.error ?? SettingsError(message: "Audio encoding failed.")); return }
            pendingAudio.removeFirst()
            lastAudioEnd = stamp + CMTime(seconds: Double(limit - first) / rate, preferredTimescale: 1_000_000_000)
        }
    }

    /// Missing callbacks represent elapsed silence, never a compressed timeline.
    /// Generate small PCM packets directly on the media worker without retaining
    /// a clip-sized buffer. AAC remains one track, including an immediate Stop.
    private func appendSilence(until endpoint: CMTime) {
        // A safe video watermark can bisect a queued audio buffer, or the
        // encoder can defer it. Only fill the genuine gap before that buffer;
        // never advance lastAudioEnd through narration awaiting admission.
        let endpoint = min(endpoint, pendingAudio.first.flatMap { sample in
            timeline.origin.map { sample.presentationTimeStamp - $0 }
        } ?? endpoint)
        guard let audioInput, endpoint > lastAudioEnd else { return }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else { return }
        let deadline = DispatchTime.now() + 2
        while endpoint - lastAudioEnd >= CMTime(value: 1, timescale: 48_000) {
            guard DispatchTime.now() < deadline else { return }
            if !canAppendAudio {
                guard audioIntake.isClosed, writer.status == .writing, DispatchTime.now() < deadline else { return }
                Thread.sleep(forTimeInterval: 0.002); continue
            }
            let count = min(4800, Int(floor((endpoint - lastAudioEnd).seconds * 48_000 + 0.00001)))
            guard count > 0 else { return }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr,
                let block else { return }
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: lastAudioEnd, decodeTimeStamp: .invalid)
            var size = 2
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                let sample, audioInput.append(sample) else { return }
            lastAudioEnd = lastAudioEnd + CMTime(value: Int64(count), timescale: 48_000)
        }
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        intake.close(at: CMClockGetTime(CMClockGetHostTimeClock()))
        audioIntake.close(at: CMClockGetTime(CMClockGetHostTimeClock()))
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sourceFailed(error)
    }

    private func sourceFailed(_ error: Error) {
        guard !intake.isClosed else { return }
        // Close on the callback thread, then drain already admitted work before
        // marking the source error. Source loss is not a failed writer append.
        intake.close(at: CMClockGetTime(CMClockGetHostTimeClock()))
        audioIntake.close(at: CMClockGetTime(CMClockGetHostTimeClock()))
        callbacks.async {
            self.media.async {
                if self.terminalError == nil {
                    self.terminalError = error
                    DispatchQueue.main.async { self.onFailure?(error) }
                }
            }
        }
    }

    /// Main-thread entry; repeated requests share exactly one finalization task.
    @MainActor func stop(at endpoint: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) async throws -> Output {
        if let stopTask { return try await stopTask.value }
        let endpoint = min(endpoint, intake.endpoint ?? endpoint)
        stopping = true
        starting?.abandon()
        intake.close(at: endpoint)
        audioIntake.close(at: endpoint)
        let task = Task.detached(priority: .userInitiated) { () throws -> Output in
            var stopError: Error?
            if let source = self.audioSource {
                let operation = VideoStreamOperation()
                Task.detached { await source.stop(); _ = operation.complete(nil) }
                let deadline = ProcessInfo.processInfo.systemUptime + self.startupTimeout
                while operation.result == nil, ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                if operation.result == nil { stopError = SettingsError(message: "Audio source stop timed out; intake is closed.") }
            }
            do {
                let operation = VideoStreamOperation()
                self.stopCapture { _ = operation.complete($0) }
                let deadline = ProcessInfo.processInfo.systemUptime + self.startupTimeout
                while operation.result == nil, ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                guard let result = operation.result else { throw SettingsError(message: "Screen recording stop timed out.") }
                try result.get()
            } catch { stopError = error }
            try? self.stream?.removeStreamOutput(self, type: .screen)
            // A callback admitted just before Stop must enqueue its media work
            // before the finish marker is queued on the separate media worker.
            self.callbacks.sync {}
            // A foreign source may have admitted just before closing intake but
            // not yet enqueued. Bound that handoff before final media work.
            let drainDeadline = ProcessInfo.processInfo.systemUptime + 2
            while self.audioIntake.pendingCount > 0, ProcessInfo.processInfo.systemUptime < drainDeadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try await self.onMedia { try self.finishFrames(at: endpoint) }
            let finish = VideoStreamOperation()
            self.writer.finishWriting { _ = finish.complete(nil) }
            let finishDeadline = ProcessInfo.processInfo.systemUptime + 5
            while finish.result == nil, ProcessInfo.processInfo.systemUptime < finishDeadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard finish.result != nil else {
                self.writer.cancelWriting()
                throw SettingsError(message: "Recording finalization timed out.")
            }
            guard self.writer.status == .completed else {
                throw self.writer.error ?? SettingsError(message: "Recording could not be finalized.")
            }
            try await Self.validateMovie(at: self.movie, width: self.canvas.width, height: self.canvas.height, audioExpected: self.audioEnabled)
            await MainActor.run { self.hasCompletedMovie = true }
            // A finalized file remains owned here even if thumbnail or publication fails.
            let asset = AVURLAsset(url: self.movie)
            let duration = try await asset.load(.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 320, height: 320)
            let thumbnail = try await generator.image(at: .zero).image
            guard let data = ImageEncoding.data(thumbnail, scale: 1, type: .png) else {
                throw SettingsError(message: "Could not encode video thumbnail.")
            }
            try data.write(to: self.directory.appendingPathComponent("thumbnail.png"), options: .atomic)
            var video = HistoryVideo(movie: self.movie.lastPathComponent, thumbnail: "thumbnail.png",
                duration: CMTimeGetSeconds(duration), width: self.canvas.width, height: self.canvas.height,
                displayID: self.displayID, frame: self.frame, scale: self.scale)
            video.audioCodec = self.audioEnabled ? "aac" : nil
            let interruption = try await self.onMedia { self.terminalError ?? stopError }
            return Output(directory: self.directory, movie: self.movie, video: video, interruption: interruption)
        }
        stopTask = task
        return try await task.value
    }

    func closeIntake(at endpoint: CMTime) { intake.close(at: endpoint); audioIntake.close(at: endpoint) }

    func cancelPreparation() async {
        closeIntake(at: CMClockGetTime(CMClockGetHostTimeClock()))
        if let audioSource { await audioSource.stop() }
        _ = try? await onMedia {
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.movie)
        }
        try? stream?.removeStreamOutput(self, type: .screen)
    }

    private func finishFrames(at host: CMTime) throws {
        guard audioSource == nil || audioReady else {
            writer.cancelWriting()
            throw terminalError ?? SettingsError(message: "The requested audio source never became ready; recording was not published.")
        }
        guard let lastFrame, let endpoint = timeline.endpoint(host: host) else {
            writer.cancelWriting()
            throw terminalError ?? SettingsError(message: "Recording contains no playable frames.")
        }
        // Picture padding gives an immediate Stop one playable frame, but does
        // not extend source admission. Drop all queued post-cutoff samples before
        // generating silence for the padded picture tail.
        drainAudio(until: min(host, audioIntake.endpoint ?? host))
        pendingAudio.removeAll()
        appendSilence(until: endpoint)
        // Finalization has bounded backpressure waiting, independent of UI/main.
        let deadline = DispatchTime.now() + 5
        while !input.isReadyForMoreMediaData, writer.status == .writing, DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard input.isReadyForMoreMediaData, adaptor.append(lastFrame, withPresentationTime: endpoint) else {
            writer.cancelWriting()
            throw writer.error ?? SettingsError(message: "Could not append recording's final still frame.")
        }
        writer.endSession(atSourceTime: endpoint)
        input.markAsFinished()
        audioInput?.markAsFinished()
        self.lastFrame = nil
    }

    static func validateMovie(at url: URL, width: Int, height: Int, audioExpected: Bool = false) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first, tracks.count == 1, audio.count == (audioExpected ? 1 : 0),
              try await asset.load(.isPlayable) else { throw SettingsError(message: "Recording has unexpected tracks (video \(tracks.count), audio \(audio.count), expected \(audioExpected)) or is not playable.") }
        if let audioTrack = audio.first {
            let formats = try await audioTrack.load(.formatDescriptions)
            guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else {
                throw SettingsError(message: "Recording audio is not AAC.")
            }
            let reader = try AVAssetReader(asset: asset)
            let decoded = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(decoded) else { throw SettingsError(message: "Recording audio is unreadable.") }
            reader.add(decoded)
            guard reader.startReading(), decoded.copyNextSampleBuffer() != nil else {
                throw SettingsError(message: "Recording has no readable audio.")
            }
            reader.cancelReading()
        }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        guard duration.isNumeric, CMTimeGetSeconds(duration) > 0,
              Int(size.width) == width, Int(size.height) == height,
              formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
            throw SettingsError(message: "Recording failed duration, codec, or dimension validation.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw SettingsError(message: "Recording track is unreadable.") }
        reader.add(output)
        guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
            throw SettingsError(message: "Recording has no readable frame.")
        }
        reader.cancelReading()
    }

    private func onMedia<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            media.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

/// A callback may settle only once; abandoning never waits for the OS callback.
private final class VideoStreamOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false
    private var settled: Result<Void, Error>?
    var result: Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return settled }
    func complete(_ error: Error?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !abandoned, settled == nil else { return false }
        settled = error.map { .failure($0) } ?? .success(())
        return true
    }
    func abandon() { lock.lock(); abandoned = true; lock.unlock() }
}
