import AppKit
import CoreMedia

struct VideoSessionState {
    enum Phase { case idle, countdown, preparing, starting, recording, stopping, publishing, failed }
    private(set) var phase = Phase.idle
    private(set) var generation = 0
    mutating func begin() -> Int { generation += 1; phase = .countdown; return generation }
    func accepts(_ id: Int) -> Bool { id == generation && phase != .idle && phase != .stopping && phase != .publishing && phase != .failed }
    mutating func advance(_ id: Int, to next: Phase) -> Bool {
        guard accepts(id) else { return false }
        phase = next
        return true
    }
    mutating func cancel(_ id: Int) -> Bool {
        guard id == generation, phase == .countdown || phase == .preparing else { return false }
        generation += 1; phase = .idle
        return true
    }
    mutating func stop() -> Bool {
        guard phase == .starting || phase == .recording else { return false }
        phase = .stopping
        return true
    }
    mutating func publishing() { phase = .publishing }
    mutating func finish(failed: Bool = false) { phase = failed ? .failed : .idle }
}

/// App-owned orchestration: picker dismissal never releases the outer capture
/// session. A failed completed movie remains retained here for rescue integration.
final class VideoSession {
    private let sessions: CaptureSessionCoordinator
    private let history: HistoryLibrary
    private var state = VideoSessionState()
    private var recorder: VideoRecorder?
    private var startup: Task<Void, Never>?
    private var sessionID: Int?
    private var tip: NSPanel?
    private var displayObserver: NSObjectProtocol?
    private var reason: Error?
    private var label = "Display"
    private(set) var completedUnpublishedMovie: URL?
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onCountdown: ((String) -> Void)?
    var onRectangle: ((CGRect) -> Void)?
    var onDismissPicker: (() -> Void)?
    var onReturnToPicker: ((String) -> Void)?
    var shortcut = CaptureShortcut.defaults
    var isActive: Bool { state.phase != .idle }
    var canStop: Bool { state.phase == .starting || state.phase == .recording }
    var isCountingDown: Bool { state.phase == .countdown || state.phase == .preparing }

    init(sessions: CaptureSessionCoordinator, history: HistoryLibrary) {
        self.sessions = sessions
        self.history = history
    }

    func begin(selection: VideoSelection, session: Int, label: String) {
        guard !isActive, history.retention != .off else { return }
        let token = state.begin()
        sessionID = session
        error = nil
        reason = nil
        self.label = label
        let frozenShortcut = shortcut
        onChange?()
        history.stageVideo { [weak self] result in
            guard let self else { return }
            guard self.state.accepts(token) else {
                if case .success(let directory) = result { self.removeUnfinished(directory) }
                return
            }
            switch result {
            case .failure(let error): self.startupFailed(error, token: token)
            case .success(let directory):
                self.startup = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        var countdown = VideoCountdown(rectangle: try self.resolve(selection))
                        var prepared: VideoRecorder?
                        while self.state.accepts(token) {
                            _ = self.state.advance(token, to: .countdown)
                            self.onRectangle?(countdown.rectangle.rect)
                            while !countdown.isReady && self.state.accepts(token) {
                                self.onCountdown?("Recording in \(countdown.remaining)… · esc cancel")
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                                countdown.tick()
                            }
                            guard self.state.accepts(token) else { break }
                            guard countdown.revalidate(try self.resolve(selection)) else { continue }
                            _ = self.state.advance(token, to: .preparing)
                            self.onCountdown?("Preparing recording… · esc cancel")
                            let recorder = try await VideoRecorder.prepare(rectangle: countdown.rectangle, directory: directory)
                            guard self.state.accepts(token) else {
                                await recorder.cancelPreparation()
                                break
                            }
                            // Preparation can be slow. Resolve again, then freeze before
                            // dismissal; no window identity is consulted after this point.
                            let current: VideoRectangle
                            do { current = try self.resolve(selection) }
                            catch { await recorder.cancelPreparation(); throw error }
                            guard countdown.revalidate(current) else {
                                await recorder.cancelPreparation()
                                continue
                            }
                            prepared = recorder
                            break
                        }
                        guard let recorder = prepared else { self.removeUnfinished(directory); return }
                        self.recorder = recorder
                        recorder.onFailure = { [weak self] error in
                            Task { @MainActor in self?.stop(because: error) }
                        }
                        _ = self.state.advance(token, to: .starting)
                        self.onDismissPicker?()
                        self.showTip(displayID: recorder.displayID, shortcut: frozenShortcut)
                        self.observeDisplay(recorder)
                        self.onChange?()
                        try await recorder.start()
                        guard self.state.advance(token, to: .recording) else { return }
                        self.onChange?()
                    } catch {
                        guard self.state.accepts(token) else {
                            if self.recorder?.directory != directory { self.removeUnfinished(directory) }
                            return
                        }
                        if self.recorder != nil { self.stop(because: error) }
                        else { self.removeUnfinished(directory); self.startupFailed(error, token: token) }
                    }
                }
            }
        }
    }

    /// Startup-only desktop adapters. Preserve NSScreen ordering for intersection
    /// ties and use CG bounds directly, including negative/above-primary origins.
    private func resolve(_ selection: VideoSelection) throws -> VideoRectangle {
        let displays = DisplayCatalog.displays().compactMap { target -> VideoDisplay? in
            guard case .display(let id) = target.kind, CGDisplayIsActive(id) != 0,
                  let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return nil }
            return VideoDisplay(id: id, frame: CGDisplayBounds(id), scale: CGFloat(mode.pixelWidth) / CGFloat(mode.width))
        }
        var windowFrame: CGRect?
        if let id = selection.windowID,
           let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
           let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
           (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
           let bounds = entry[kCGWindowBounds as String] as? NSDictionary {
            windowFrame = CGRect(dictionaryRepresentation: bounds)
        }
        return try selection.resolve(displays: displays, windowFrame: windowFrame)
    }

    func cancelCountdown() {
        guard state.cancel(state.generation) else { return }
        // Let preparation settle so its writer can be canceled and its directory
        // removed. Generation fencing prevents it from ever starting capture.
        startup = nil
        sessionID = nil
        onReturnToPicker?("")
        onChange?()
    }

    private func startupFailed(_ error: Error, token: Int) {
        guard state.accepts(token) else { return }
        state.finish()
        sessionID = nil
        self.error = error.localizedDescription
        onReturnToPicker?(error.localizedDescription)
        onChange?()
    }

    func stop(because error: Error? = nil) {
        let endpoint = CMClockGetTime(CMClockGetHostTimeClock())
        if isCountingDown { cancelCountdown(); return }
        guard state.stop(), let recorder, let id = sessionID else { return }
        recorder.closeIntake(at: endpoint)
        reason = error
        tip?.orderOut(nil)
        tip = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        onChange?()
        Task { @MainActor in
            do {
                let output = try await recorder.stop(at: endpoint)
                self.completedUnpublishedMovie = output.movie
                if let reason = self.reason { throw reason }
                self.state.publishing()
                self.history.publishVideo(staging: output.directory, video: output.video, label: self.label) { result in
                    switch result {
                    case .success:
                        self.completedUnpublishedMovie = nil
                        self.recorder = nil
                        self.state.finish()
                        self.sessionID = nil
                        self.sessions.finish(id)
                        self.onChange?()
                    case .failure(let error): self.failed(error, id: id)
                    }
                }
            } catch {
                if recorder.hasCompletedMovie { self.completedUnpublishedMovie = recorder.movie }
                else { self.removeUnfinished(recorder.directory) }
                self.failed(error, id: id)
            }
        }
    }

    private func failed(_ error: Error, id: Int) {
        self.error = error.localizedDescription
        state.finish(failed: completedUnpublishedMovie != nil)
        // A completed unpublished movie keeps ownership and the outer session.
        // The next failure/rescue slice supplies its Save As interaction.
        if completedUnpublishedMovie == nil {
            recorder = nil
            sessionID = nil
            sessions.finish(id)
        }
        onChange?()
        let alert = NSAlert()
        alert.messageText = "Recording failed"
        alert.informativeText = error.localizedDescription + (completedUnpublishedMovie == nil ? "" : "\nThe completed movie is retained for this app session.")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func removeUnfinished(_ directory: URL) {
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }

    private func observeDisplay(_ recorder: VideoRecorder) {
        let bounds = recorder.displayFrame
        let mode = CGDisplayCopyDisplayMode(recorder.displayID)
        let pixels = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            let current = CGDisplayCopyDisplayMode(recorder.displayID)
            if CGDisplayIsActive(recorder.displayID) == 0 || CGDisplayBounds(recorder.displayID) != bounds
                || current.map({ CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }) != pixels {
                Task { @MainActor in self?.stop(because: SettingsError(message: "The recorded display disappeared or changed geometry.")) }
            }
        }
    }

    private func showTip(displayID: CGDirectDisplayID, shortcut: CaptureShortcut) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { return }
        let text = "Press \(shortcut.display) to stop."
        let size = HUD.textSize(text, font: HUD.textFont)
        let panel = NSPanel(contentRect: CGRect(x: screen.frame.midX - (size.width + 32) / 2,
            y: screen.frame.minY + 24, width: size.width + 32, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        let root = CALayer()
        root.frame = view.bounds
        HUD.stylePanel(root)
        let label = HUD.makeText(text, font: HUD.textFont, color: Palette.text, scale: screen.backingScaleFactor)
        label.frame = CGRect(x: 16, y: 12, width: size.width, height: 24)
        root.addSublayer(label)
        view.layer?.addSublayer(root)
        panel.contentView = view
        panel.orderFrontRegardless()
        tip = panel
    }
}
