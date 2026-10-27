import AppKit
import CoreMedia
import ScreenCaptureKit

struct VideoPermissionError: LocalizedError {
    var errorDescription: String? { "Video needs Screen Recording. Enable it in Vishot Settings." }
}

struct VideoSessionState {
    enum Phase { case idle, countdown, preparing, starting, recording, stopping, publishing, failed }
    private(set) var phase = Phase.idle
    private(set) var generation = 0
    mutating func begin() -> Int {
        guard phase == .idle else { return generation }
        generation += 1; phase = .countdown; return generation
    }
    func accepts(_ id: Int) -> Bool { id == generation && phase != .idle && phase != .stopping && phase != .publishing && phase != .failed }
    mutating func advance(_ id: Int, to next: Phase) -> Bool {
        guard accepts(id) else { return false }
        if phase == .starting || phase == .recording {
            guard phase == .starting, next == .recording else { return false }
        }
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
    private var recorder: VideoRecording?
    private let prepare: (VideoRectangle, URL) async throws -> VideoRecording
    private let resolveSelection: ((VideoSelection) throws -> VideoRectangle)?
    private let countdownTick: () async throws -> Void
    private let reportError: ((String, Bool) -> Void)?
    private let presentsControls: Bool
    private var startup: Task<Void, Never>?
    private var sessionID: Int?
    private var tip: NSPanel?
    private var displayObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var errorPanel: NSPanel?
    private var errorText: NSTextField?
    private var rescueButton: NSButton?
    private var savePanel: NSSavePanel?
    private var isRescuing = false
    private var reason: Error?
    private struct Metadata {
        let label: String
        let windowTitle: String
    }
    private var metadata = Metadata(label: "Display", windowTitle: "")
    private(set) var isErrorPresented = false
    private(set) var isPermissionRecoveryPresented = false
    private(set) var completedUnpublishedMovie: URL?
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onCountdown: ((String) -> Void)?
    var onRectangle: ((CGRect) -> Void)?
    var onDismissPicker: (() -> Void)?
    var onReturnToPicker: ((String) -> Void)?
    var onPermissionSettings: (() -> Void)?
    var shortcut = CaptureShortcut.defaults
    var isActive: Bool { state.phase != .idle }
    var canStop: Bool { state.phase == .starting || state.phase == .recording }
    var isCountingDown: Bool { state.phase == .countdown || state.phase == .preparing }

    init(sessions: CaptureSessionCoordinator, history: HistoryLibrary,
         prepare: @escaping (VideoRectangle, URL) async throws -> VideoRecording = { try await VideoRecorder.prepare(rectangle: $0, directory: $1) },
         resolve: ((VideoSelection) throws -> VideoRectangle)? = nil,
         countdownTick: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) },
         presentsControls: Bool = true, reportError: ((String, Bool) -> Void)? = nil) {
        self.sessions = sessions
        self.history = history
        self.prepare = prepare
        self.resolveSelection = resolve
        self.countdownTick = countdownTick
        self.reportError = reportError
        self.presentsControls = presentsControls
    }

    func begin(selection: VideoSelection, session: Int, label: String, windowTitle: String = "") {
        guard !isActive, history.retention != .off else { return }
        dismissError()
        let token = state.begin()
        sessionID = session
        error = nil
        reason = nil
        metadata = Metadata(label: label, windowTitle: windowTitle)
        let frozenShortcut = shortcut
        onChange?()
        sessions.beginFileOperation()
        history.stageVideo { [weak self] result in
            guard let self else { return }
            guard self.state.accepts(token) else {
                if case .success(let directory) = result { self.removeUnfinished(directory) }
                self.sessions.endFileOperation()
                return
            }
            switch result {
            case .failure(let error):
                self.startupFailed(error, token: token)
                self.sessions.endFileOperation()
            case .success(let directory):
                self.startup = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.sessions.endFileOperation() }
                    do {
                        var countdown = VideoCountdown(rectangle: try self.resolve(selection))
                        var prepared: VideoRecording?
                        while self.state.accepts(token) {
                            _ = self.state.advance(token, to: .countdown)
                            self.onRectangle?(countdown.rectangle.rect)
                            while !countdown.isReady && self.state.accepts(token) {
                                self.onCountdown?("Recording in \(countdown.remaining)… · esc cancel")
                                try await self.countdownTick()
                                countdown.tick()
                            }
                            guard self.state.accepts(token) else { break }
                            guard countdown.revalidate(try self.resolve(selection)) else { continue }
                            _ = self.state.advance(token, to: .preparing)
                            self.onCountdown?("Preparing recording… · esc cancel")
                            let recorder = try await self.prepare(countdown.rectangle, directory)
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
                            Task { @MainActor in
                                guard let self, self.state.accepts(token) else { return }
                                self.stop(because: error)
                            }
                        }
                        _ = self.state.advance(token, to: .starting)
                        self.onDismissPicker?()
                        guard self.state.accepts(token) else { return }
                        if self.presentsControls {
                            self.showTip(displayID: recorder.displayID, shortcut: frozenShortcut)
                            self.observeDisplay(recorder)
                        }
                        self.onChange?()
                        guard self.state.accepts(token) else { return }
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
        if let resolveSelection { return try resolveSelection(selection) }
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
        let id = sessionID
        state.finish()
        sessionID = nil
        presentStartupFailure(error, session: id)
    }

    func presentStartupFailure(_ error: Error, session: Int?) {
        self.error = error.localizedDescription
        // All startup errors outlive picker key/status updates. Dismiss its
        // screen-saver-level panels before presenting the persistent surface.
        onDismissPicker?()
        let sdkError = error as NSError
        showError(permission: error is VideoPermissionError ||
            (sdkError.domain == SCStreamErrorDomain && sdkError.code == SCStreamError.Code.userDeclined.rawValue) ||
            !CGPreflightScreenCaptureAccess())
        if let session { sessions.finish(session) }
        onChange?()
    }

    func stop(because error: Error? = nil) {
        let endpoint = CMClockGetTime(CMClockGetHostTimeClock())
        if isCountingDown {
            cancelCountdown()
            if let error {
                self.error = error.localizedDescription
                onReturnToPicker?(error.localizedDescription)
                onChange?()
            }
            return
        }
        guard state.stop(), let recorder, let id = sessionID else { return }
        let metadata = metadata
        recorder.closeIntake(at: endpoint)
        reason = error
        tip?.orderOut(nil)
        tip = nil
        stopObserving()
        onChange?()
        Task { @MainActor in
            do {
                let output = try await recorder.stop(at: endpoint)
                self.completedUnpublishedMovie = output.movie
                self.state.publishing()
                self.history.publishVideo(staging: output.directory, video: output.video,
                    label: metadata.label, windowTitle: metadata.windowTitle) { result in
                    switch result {
                    case .success:
                        self.completedUnpublishedMovie = nil
                        self.dismissError()
                        if let reason = self.reason ?? output.interruption {
                            self.error = "Recording ended early: " + reason.localizedDescription
                            self.showError(permission: !CGPreflightScreenCaptureAccess())
                        }
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
        // A failed quit is canceled before releasing ownership or presenting
        // rescue. A subsequent explicit Quit may abandon an idle rescue only.
        sessions.cancelQuit()
        if completedUnpublishedMovie == nil {
            recorder = nil
            sessionID = nil
            sessions.finish(id)
        }
        onChange?()
        showError(permission: completedUnpublishedMovie == nil && (error is VideoPermissionError || !CGPreflightScreenCaptureAccess()))
    }

    /// Called before the app asks the coordinator about termination. A completed
    /// rescue may be abandoned only on an explicit later Quit, never mid-copy.
    func prepareToQuit() {
        if state.phase == .failed {
            if isRescuing { return }
            if let id = sessionID {
                completedUnpublishedMovie = nil
                recorder = nil
                sessionID = nil
                state.finish()
                sessions.finish(id)
            }
        } else if isCountingDown {
            let id = sessionID
            cancelCountdown()
            onDismissPicker?()
            if let id { sessions.finish(id) }
        } else {
            stop(because: canStop ? SettingsError(message: "Vishot is quitting.") : nil)
        }
    }

    private func showError(permission: Bool = false) {
        isErrorPresented = true
        isPermissionRecoveryPresented = permission
        if let reportError { reportError(error ?? "Recording failed.", completedUnpublishedMovie != nil); return }
        errorPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 190),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = completedUnpublishedMovie == nil ? "Recording ended" : "Save completed recording"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 440, height: 190))
        let text = NSTextField(wrappingLabelWithString: (error ?? "Recording failed.") +
            (completedUnpublishedMovie == nil ? "" : "\nThe completed MP4 is retained during this app session. Use Save As to keep an independent copy."))
        text.frame = CGRect(x: 20, y: 65, width: 400, height: 105)
        content.addSubview(text)
        errorText = text
        let rescue = completedUnpublishedMovie != nil
        let button = NSButton(title: rescue ? "Save As…" : permission ? "Open Settings…" : "OK",
                              target: self, action: rescue ? #selector(saveCompletedMovie) : permission ? #selector(openPermissionRecovery) : #selector(dismissError))
        button.frame = CGRect(x: 270, y: 20, width: 150, height: 32)
        button.keyEquivalent = "\r"
        content.addSubview(button)
        if permission && !rescue {
            let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissError))
            dismiss.frame = CGRect(x: 150, y: 20, width: 110, height: 32)
            content.addSubview(dismiss)
        }
        rescueButton = button
        panel.contentView = content
        panel.center()
        // Error reporting must not replace the recorded app's focus.
        panel.orderFrontRegardless()
        errorPanel = panel
    }

    @objc func dismissError() {
        guard completedUnpublishedMovie == nil else { return }
        errorPanel?.orderOut(nil)
        errorPanel = nil
        errorText = nil
        rescueButton = nil
        isErrorPresented = false
        isPermissionRecoveryPresented = false
        error = nil
        onChange?()
    }

    @objc func openPermissionRecovery() { onPermissionSettings?() }

    @objc private func saveCompletedMovie() {
        guard !isRescuing, let movie = completedUnpublishedMovie, let id = sessionID else { return }
        isRescuing = true
        sessions.beginFileOperation()
        rescueButton?.isEnabled = false
        let panel = NSSavePanel()
        panel.title = "Save Completed Video As"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = movie.lastPathComponent
        savePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            self.savePanel = nil
            guard response == .OK, let destination = panel.url else {
                self.rescueEnded(.failure(CancellationError()), id: id, movie: movie)
                return
            }
            self.errorText?.stringValue = "Saving completed recording…"
            self.copyRescue(movie, to: destination, id: id)
        }
    }

    /// The same rescue operation used by the native Save As panel. A nil
    /// destination is cancellation; neither cancellation nor failure releases it.
    func rescue(to destination: URL?, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isRescuing, let movie = completedUnpublishedMovie, let id = sessionID else { completion(false); return }
        guard let destination else { completion(false); return }
        isRescuing = true
        sessions.beginFileOperation()
        copyRescue(movie, to: destination, id: id, completion: completion)
    }

    private func copyRescue(_ movie: URL, to destination: URL, id: Int, completion: @escaping (Bool) -> Void = { _ in }) {
        history.exportCompletedVideo(movie, to: destination) { result in
            self.rescueEnded(result, id: id, movie: movie)
            if case .success = result { completion(true) } else { completion(false) }
        }
    }

    private func rescueEnded(_ result: Result<Void, Error>, id: Int, movie: URL) {
        guard sessionID == id else { return }
        isRescuing = false
        switch result {
        case .success:
            completedUnpublishedMovie = nil
            recorder = nil
            sessionID = nil
            state.finish()
            dismissError()
            removeUnfinished(movie.deletingLastPathComponent())
            sessions.finish(id)
        case .failure(let failure):
            sessions.cancelQuit()
            if !(failure is CancellationError) { error = failure.localizedDescription }
            showError()
        }
        sessions.endFileOperation()
        onChange?()
    }

    private func removeUnfinished(_ directory: URL) {
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }

    private func observeDisplay(_ recorder: VideoRecording) {
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
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, message) in [(NSWorkspace.willSleepNotification, "The Mac is going to sleep."),
                                (NSWorkspace.screensDidSleepNotification, "The recorded screen went to sleep."),
                                (NSWorkspace.sessionDidResignActiveNotification, "The login session became inactive.")] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stop(because: SettingsError(message: message))
            })
        }
        // macOS 14 has no public dedicated screen-lock notification. Observe the
        // distributed loginwindow signal as well as workspace sleep/session loss.
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
                self?.stop(because: SettingsError(message: "The screen was locked."))
            }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if !CGPreflightScreenCaptureAccess() { self?.stop(because: VideoPermissionError()) }
        }
    }

    private func stopObserving() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func showTip(displayID: CGDirectDisplayID, shortcut: CaptureShortcut) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { return }
        let text = "Press \(shortcut.display) to stop."
        let style = ThemeCatalog.pixel.hud
        let size = HUD.textSize(text, font: style.textFont)
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
        HUD.stylePanel(root, style: style)
        let label = HUD.makeText(text, font: style.textFont, color: style.text, scale: screen.backingScaleFactor)
        label.frame = CGRect(x: 16, y: 12, width: size.width, height: 24)
        root.addSublayer(label)
        view.layer?.addSublayer(root)
        panel.contentView = view
        panel.orderFrontRegardless()
        tip = panel
    }
}
