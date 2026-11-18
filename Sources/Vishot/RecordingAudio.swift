import AVFoundation

/// Delivery timestamps use CMClockGetHostTimeClock, never callback arrival time.
/// Source adapters own clock conversion and lifecycle; media owns admission.
protocol RecordingAudioSource: AnyObject {
    var id: String { get }
    func start(deliver: @escaping (CMSampleBuffer) -> Void, failed: @escaping (Error) -> Void) async throws
    func stop() async
}

struct VideoAudioOptions: Equatable {
    var microphoneEnabled = false
    var microphoneDevice = ""
    var systemEnabled = false
    func validate() throws {}
    func summary() -> String {
        if systemEnabled {
            if microphoneEnabled { return "System + Mic" }
            return "All system audio"
        }
        return microphoneEnabled ? "Microphone" : "Audio off"
    }
}

struct RecordingAudioOptionsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Immutable result of pre-countdown source resolution. No adapter may consult
/// live preferences/default devices after this snapshot has been admitted.
struct RecordingAudioSnapshot: Equatable {
    let microphone: MicrophoneDevice?
    let systemEnabled: Bool
}
