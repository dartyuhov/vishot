import AVFoundation
import Foundation

enum MicrophoneAuthorization: Equatable {
    case notDetermined, authorized, denied, restricted

    static func read() -> Self {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
}

/// App-owned boundary for setup, Settings and future pre-countdown callers.
/// Use on the main thread. Reading never prompts or enumerates devices.
final class MicrophonePermission {
    static let shared = MicrophonePermission()
    private let readStatus: () -> MicrophoneAuthorization
    private let requestAccess: (@escaping (Bool) -> Void) -> Void
    private var callers: [UUID: (MicrophoneAuthorization) -> Void] = [:]
    private var prompt: UUID?
    var status: MicrophoneAuthorization { readStatus() }

    init(readStatus: @escaping () -> MicrophoneAuthorization = MicrophoneAuthorization.read,
         requestAccess: @escaping (@escaping (Bool) -> Void) -> Void = {
             AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
         }) {
        self.readStatus = readStatus
        self.requestAccess = requestAccess
    }

    @discardableResult
    func refresh() -> MicrophoneAuthorization { status }

    /// Results always arrive on a subsequent main-queue turn. The identity can
    /// abandon a caller, but cannot dismiss the system's already visible prompt.
    @discardableResult
    func request(completion: @escaping (MicrophoneAuthorization) -> Void) -> UUID {
        let id = UUID()
        callers[id] = completion
        guard status == .notDetermined else {
            DispatchQueue.main.async { [weak self] in self?.deliver(id) }
            return id
        }
        guard prompt == nil else { return id }
        let generation = UUID()
        prompt = generation
        requestAccess { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.prompt == generation else { return }
                self.prompt = nil
                for id in Array(self.callers.keys) { self.deliver(id) }
            }
        }
        return id
    }

    func cancel(_ id: UUID) { callers.removeValue(forKey: id) }

    private func deliver(_ id: UUID) {
        guard let completion = callers.removeValue(forKey: id) else { return }
        completion(status)
    }
}
