import Foundation

/// Shared Copy/Edit preparation. The adapters keep desktop effects at the edge;
/// destinations receive only a current, fully prepared frozen source.
final class FrozenSourcePreparation {
    private let waitForRaise: () async -> Void
    private let excludePicker: () -> Void
    private let capture: (CaptureTarget) async -> Capture?
    private let onFailure: () -> Void
    private var generation = 0

    init(waitForRaise: @escaping () async -> Void, excludePicker: @escaping () -> Void,
         capture: @escaping (CaptureTarget) async -> Capture?, onFailure: @escaping () -> Void) {
        self.waitForRaise = waitForRaise
        self.excludePicker = excludePicker
        self.capture = capture
        self.onFailure = onFailure
    }

    /// Called on the main thread, like the owning overlay's session transitions.
    /// Invalidates pending work without letting its eventual result affect a new session.
    func cancel() { generation += 1 }

    @MainActor
    func prepare(for target: CaptureTarget, receive: (Capture) -> Void) async {
        generation += 1
        let request = generation
        guard !Task.isCancelled else { return }
        await waitForRaise()
        guard request == generation, !Task.isCancelled else { return }
        excludePicker()
        let source = await capture(target)
        guard request == generation, !Task.isCancelled else { return }
        guard let source else { onFailure(); return }
        receive(source)
    }
}
