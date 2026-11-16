import AVFoundation
import VishotConfiguration

struct MicrophoneDevice: Equatable {
    let id: String
    let name: String
    static func available() -> [Self] {
        captureDevices().map { Self(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    static func defaultID() -> String? { AVCaptureDevice.default(for: .audio)?.uniqueID }
}

struct MicrophonePreflightError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Main-thread permission owner adapter. Cancellation resumes immediately and
/// detaches only this caller from the shared, potentially still visible prompt.
final class MicrophonePreflight {
    private let permission: MicrophonePermission
    let devices: () -> [MicrophoneDevice]
    private let defaultDevice: () -> String?
    private var request: UUID?
    private var pending: CheckedContinuation<MicrophoneAuthorization, Error>?
    var onPrompt: ((Bool) -> Void)?

    init(permission: MicrophonePermission = .shared,
         devices: @escaping () -> [MicrophoneDevice] = MicrophoneDevice.available,
         defaultDevice: @escaping () -> String? = MicrophoneDevice.defaultID) {
        self.permission = permission; self.devices = devices; self.defaultDevice = defaultDevice
    }

    @MainActor func resolve(enabled: Bool, device: String) async throws -> MicrophoneDevice? {
        guard enabled else { return nil }
        var status = permission.refresh()
        if status == .notDetermined {
            let prompt = onPrompt
            prompt?(true)
            defer { prompt?(false) }
            status = try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                request = permission.request { [weak self] status in
                    guard let self else { return }
                    request = nil
                    let completion = pending
                    pending = nil
                    completion?.resume(returning: status)
                }
            }
        }
        guard status == .authorized else {
            throw MicrophonePreflightError(message: status == .restricted
                ? "Microphone access is restricted. Check your Mac's policy or turn Microphone off in Options."
                : "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone, or turn Microphone off in Options.")
        }
        guard let uid = device.isEmpty ? defaultDevice() : device,
              let resolved = devices().first(where: { $0.id == uid }) else {
            throw MicrophonePreflightError(message: "The selected microphone is unavailable. Choose an input or turn Microphone off in Options.")
        }
        return resolved
    }

    func cancel() {
        if let request { permission.cancel(request) }
        request = nil
        let completion = pending
        pending = nil
        completion?.resume(throwing: CancellationError())
    }
}

/// Delivery timestamps must be in CMClockGetHostTimeClock's domain, not arrival
/// time. Sources own clock conversion and lifecycle; the recorder owns admission.
/// Later SC audio and process-tap adapters use this same capture-independent seam.
protocol RecordingAudioSource: AnyObject {
    var id: String { get }
    func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws
    func stop() async
}

final class MicrophoneCapture: NSObject, RecordingAudioSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let id: String
    private let queue = DispatchQueue(label: "dev.vishot.microphone", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var deliver: ((CMSampleBuffer) -> Void)?
    private var failed: ((Error) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var startup: CheckedContinuation<Void, Error>?

    init(device: MicrophoneDevice) { id = device.id; super.init() }

    func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.stopped, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          let device = MicrophoneDevice.captureDevices().first(where: { $0.uniqueID == self.id }), device.isConnected else {
                        throw SettingsError(message: "The frozen microphone is unavailable or no longer authorized.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        throw SettingsError(message: "The microphone cannot supply recording audio.")
                    }
                    self.session.addInput(input)
                    self.session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.session.commitConfiguration()
                    self.deliver = deliver; self.failed = failed
                    let center = NotificationCenter.default
                    let disconnected = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                        object: device, queue: nil) { [weak owner = self] _ in
                        owner?.queue.async { [weak owner] in owner?.failed?(SettingsError(message: "The microphone disconnected.")) }
                    }
                    self.observers.append(disconnected)
                    let runtime = center.addObserver(forName: .AVCaptureSessionRuntimeError,
                        object: self.session, queue: nil) { [weak owner = self] _ in
                        owner?.queue.async { [weak owner] in owner?.failed?(SettingsError(message: "Microphone capture was interrupted.")) }
                    }
                    self.observers.append(runtime)
                    self.session.startRunning()
                    guard self.session.isRunning else { throw SettingsError(message: "Microphone capture did not start.") }
                    // Source readiness requires a real, correctly clocked buffer.
                    // The recorder bounds this wait and stops abandoned startup.
                    self.startup = continuation
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, let clock = session.synchronizationClock else { return }
        let host = CMSyncConvertTime(sample.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        guard host.isNumeric, abs((CMClockGetTime(CMClockGetHostTimeClock()) - host).seconds) < 5 else {
            failed?(SettingsError(message: "Microphone timestamps could not be mapped to the host clock.")); return
        }
        guard let format = sample.formatDescription,
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate > 0 else {
            failed?(SettingsError(message: "Microphone supplied an invalid audio format.")); return
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate.rounded())), presentationTimeStamp: host, decodeTimeStamp: .invalid)
        var converted: CMSampleBuffer?
        guard host.isNumeric, CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &converted) == noErr, let converted else { return }
        let ready = startup
        startup = nil
        deliver?(converted)
        ready?.resume()
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopped = true
                let ready = self.startup
                self.startup = nil
                ready?.resume(throwing: CancellationError())
                self.deliver = nil; self.failed = nil
                self.observers.forEach { NotificationCenter.default.removeObserver($0) }
                self.observers.removeAll()
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }
}
