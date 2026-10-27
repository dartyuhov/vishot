import AppKit
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

    static func prepare(rectangle: VideoRectangle, directory: URL) async throws -> VideoRecorder {
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
        startCapture: @escaping (@escaping (Error?) -> Void) -> Void = { $0(nil) },
        stopCapture: @escaping (@escaping (Error?) -> Void) -> Void = { $0(nil) }) async throws -> VideoRecorder {
        let recorder = try VideoRecorder(directory: directory, rectangle: rectangle)
        recorder.startCapture = startCapture
        recorder.stopCapture = stopCapture
        recorder.startupTimeout = startupTimeout
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
                intake.close(at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
        let stop = stopCapture!
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
                return self.timeline.origin != nil
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
        return true
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        intake.close(at: CMClockGetTime(CMClockGetHostTimeClock()))
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
        stopping = true
        starting?.abandon()
        intake.close(at: endpoint)
        let task = Task.detached(priority: .userInitiated) { () throws -> Output in
            var stopError: Error?
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
            try await self.onMedia { try self.finishFrames(at: endpoint) }
            await self.writer.finishWriting()
            guard self.writer.status == .completed else {
                throw self.writer.error ?? SettingsError(message: "Recording could not be finalized.")
            }
            try await Self.validateMovie(at: self.movie, width: self.canvas.width, height: self.canvas.height)
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
            let video = HistoryVideo(movie: self.movie.lastPathComponent, thumbnail: "thumbnail.png",
                duration: CMTimeGetSeconds(duration), width: self.canvas.width, height: self.canvas.height,
                displayID: self.displayID, frame: self.frame, scale: self.scale)
            let interruption = try await self.onMedia { self.terminalError ?? stopError }
            return Output(directory: self.directory, movie: self.movie, video: video, interruption: interruption)
        }
        stopTask = task
        return try await task.value
    }

    func closeIntake(at endpoint: CMTime) { intake.close(at: endpoint) }

    func cancelPreparation() async {
        _ = try? await onMedia {
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.movie)
        }
        try? stream?.removeStreamOutput(self, type: .screen)
    }

    private func finishFrames(at host: CMTime) throws {
        guard let lastFrame, let endpoint = timeline.endpoint(host: host) else {
            writer.cancelWriting()
            throw terminalError ?? SettingsError(message: "Recording contains no playable frames.")
        }
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
        self.lastFrame = nil
    }

    static func validateMovie(at url: URL, width: Int, height: Int) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first, tracks.count == 1, audio.isEmpty,
              try await asset.load(.isPlayable) else { throw SettingsError(message: "Recording is not playable silent video.") }
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
private final class VideoStreamOperation {
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
