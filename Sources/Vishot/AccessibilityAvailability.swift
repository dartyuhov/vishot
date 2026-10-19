import Foundation
import ApplicationServices

/// Main-thread snapshot for the picker. Only the serial worker reads AX trust;
/// it never discovers windows or requests permission. Changes arrive within 0.5 s.
final class AccessibilityAvailability {
    private let queue = DispatchQueue(label: "dev.vishot.accessibility-status", qos: .utility)
    private let interval: TimeInterval
    private let readAccess: () -> Bool
    private var timer: DispatchSourceTimer?
    private var generation: UUID?
    private(set) var isAllowed = false
    var onChange: ((Bool) -> Void)?

    init(interval: TimeInterval = 0.5, readAccess: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.interval = interval
        self.readAccess = readAccess
    }

    func start() {
        guard timer == nil else { return }
        let generation = UUID()
        self.generation = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let readAccess = readAccess
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            let allowed = readAccess()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                guard self.isAllowed != allowed else { return }
                self.isAllowed = allowed
                self.onChange?(allowed)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        generation = nil
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }
}
