import Foundation

struct CountdownFrame: Equatable {
    let generation: Int
    let number: Int
}

/// Main-thread capture capability. Scheduling and presentation are independent
/// of capture type; animation completions never drive the capture deadline.
final class CaptureCountdown {
    enum Outcome: Equatable { case completed, cancelled }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    private let schedule: Schedule
    private var generation = 0
    private var requests = 0
    private var pending: [() -> Void] = []
    private var present: ((CountdownFrame?) -> Void)?
    private var completion: ((Outcome) -> Void)?

    init(schedule: @escaping Schedule = CaptureCountdown.scheduleOnMain) {
        self.schedule = schedule
    }

    static func scheduleOnMain(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }

    func start(present: @escaping (CountdownFrame?) -> Void, completion: @escaping (Outcome) -> Void) {
        requests += 1
        let request = requests
        cancel()
        guard requests == request else { completion(.cancelled); return }
        generation += 1
        let token = generation
        self.present = present
        self.completion = completion
        present(CountdownFrame(generation: token, number: 3))
        guard generation == token, self.completion != nil else { return }
        for second in 1...3 {
            pending.append(schedule(TimeInterval(second)) { [weak self] in
                guard let self, self.generation == token, self.completion != nil else { return }
                if second == 3 { self.finish(.completed) }
                else { self.present?(CountdownFrame(generation: token, number: 3 - second)) }
            })
        }
    }

    func cancel() { finish(.cancelled) }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        let present = self.present
        self.completion = nil
        self.present = nil
        generation += 1
        let pending = self.pending
        self.pending = []
        pending.forEach { $0() }
        present?(nil)
        completion(outcome)
    }

    func run(present: @escaping (CountdownFrame?) -> Void) async -> Outcome {
        await withCheckedContinuation { continuation in
            start(present: present) { continuation.resume(returning: $0) }
        }
    }
}
