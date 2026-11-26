import AVFoundation
import ScreenCaptureKit

/// Audio output adapter on the existing fixed-rectangle picture stream. Stream
/// startup establishes readiness: no audio callbacks during silence is normal.
/// SC audio PTS is already host-clock time; never replace it with arrival time.
final class SystemAudioCapture: RecordingAudioSource, @unchecked Sendable {
    let id = "all-system"
    private let lock = NSLock()
    private var deliver: ((CMSampleBuffer) -> Void)?
    private var stopped = false

    func configure(_ configuration: SCStreamConfiguration) {
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
    }

    func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws {
        try activate(deliver)
    }
    private func activate(_ deliver: @escaping (CMSampleBuffer) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        self.deliver = deliver
    }
    func receive(_ sample: CMSampleBuffer) {
        lock.lock()
        let callback = stopped ? nil : deliver
        lock.unlock()
        callback?(sample)
    }
    func stop() async { close() }
    private func close() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        deliver = nil
    }
}
