import Foundation

/// App-owned lifetime, independent of panel visibility. Main-thread only.
/// Presentation can end before the operation does; only finish releases availability.
final class CaptureSessionCoordinator {
    private enum Entry { case capture, history }
    private var entry: Entry?
    private var generation = 0
    private var sessionID: Int?
    private var hasPresentation = false
    private var isQuitting = false
    private var waitingForQuit = false
    var onCapture: ((Int) -> Bool)?
    var onHistory: ((Int) -> Bool)?
    var onCaptureAgain: ((Int) -> Void)?
    var onSessionChange: ((Bool) -> Void)?
    var onQuitReady: (() -> Void)?
    var isSessionActive: Bool { sessionID != nil }
    var callbackSession: Int { hasPresentation ? sessionID ?? -1 : -1 }

    func capture() {
        guard !isQuitting else { return }
        if let id = sessionID {
            if hasPresentation { onCaptureAgain?(id) }
            return
        }
        begin(.capture, present: onCapture)
    }

    /// History-to-picker handoff reserves availability throughout UI teardown.
    func replaceWithCapture(_ id: Int) {
        guard !isQuitting, sessionID == id, entry == .history else { return }
        begin(.capture, present: onCapture)
    }

    func showHistory() {
        guard !isQuitting, !isSessionActive else { return }
        begin(.history, present: onHistory)
    }

    private func begin(_ entry: Entry, present: ((Int) -> Bool)?) {
        generation += 1
        let id = generation
        sessionID = id
        self.entry = entry
        hasPresentation = true
        onSessionChange?(true)
        if present?(id) != true { finish(id) }
    }

    func acceptsCallbacks(_ id: Int) -> Bool { sessionID == id && hasPresentation }

    func dismissPresentation(_ id: Int) {
        guard sessionID == id else { return }
        hasPresentation = false
    }

    func finish(_ id: Int) {
        guard sessionID == id else { return }
        sessionID = nil
        entry = nil
        hasPresentation = false
        onSessionChange?(false)
        if waitingForQuit {
            waitingForQuit = false
            onQuitReady?()
        }
    }

    /// Screenshot presentation preserves immediate Quit. A detached operation
    /// must release its lifetime before the application replies to termination.
    func requestQuit() -> Bool {
        isQuitting = true
        guard isSessionActive, !hasPresentation else { return true }
        waitingForQuit = true
        return false
    }
}
