import Foundation

/// Main-thread settings state; the returned registration keeps the hotkey alive.
final class SettingsStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vishot/config.toml")
    let url: URL
    private(set) var active = AppSettings.defaults
    private(set) var configured: AppSettings?
    private(set) var error: String?
    private(set) var isSessionActive = false
    var onChange: (() -> Void)?
    private let register: (CaptureShortcut) throws -> AnyObject
    private var registration: AnyObject?
    private let registerHistory: ((CaptureShortcut) throws -> AnyObject)?
    private var historyRegistration: AnyObject?
    private var timer: DispatchSourceTimer?
    private var lastSource: String?
    private var lastTarget: URL?
    private var lastReadError: String?

    init(url: URL = defaultURL, registerHistory: ((CaptureShortcut) throws -> AnyObject)? = nil,
         register: @escaping (CaptureShortcut) throws -> AnyObject) {
        self.url = url
        self.register = register
        self.registerHistory = registerHistory
    }

    deinit { timer?.cancel() }

    func start(watching: Bool = true) {
        reload()
        if registration == nil {
            do { registration = try register(active.shortcut) }
            catch { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
        }
        if historyRegistration == nil, let registerHistory, let shortcut = active.historyShortcut {
            do { historyRegistration = try registerHistory(shortcut) }
            catch { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
        }
        onChange?()
        guard watching else { return }
        // Poll off the hotkey path. Watching the contents rather than one inode
        // handles editor atomic saves, replaced directories, and dotfile links.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        let url = url
        timer.setEventHandler { [weak self] in
            let target = url.resolvingSymlinksInPath()
            let read = Result { try String(contentsOf: target, encoding: .utf8) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A synchronous reload/window write may have overtaken this
                // read while its callback waited for the main queue.
                guard url.resolvingSymlinksInPath() == target else { return }
                if case .success(let source) = read {
                    guard (try? String(contentsOf: target, encoding: .utf8)) == source else { return }
                }
                switch read {
                case .success(let source):
                    guard source != lastSource || target != lastTarget || lastReadError != nil else { return }
                    receive(source, target: target)
                case .failure(let failure):
                    guard failure.localizedDescription != lastReadError else { return }
                    reload()
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func reload() {
        do {
            let target = url.resolvingSymlinksInPath()
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AppSettings.defaultSource.write(to: target, atomically: true, encoding: .utf8)
            }
            receive(try String(contentsOf: target, encoding: .utf8), target: target)
        } catch {
            configured = nil
            self.error = error.localizedDescription
            lastReadError = error.localizedDescription
            onChange?()
        }
    }

    private func receive(_ source: String, target: URL) {
        lastSource = source
        lastTarget = target
        lastReadError = nil
        do {
            configured = try AppSettings.parse(source)
            error = nil
            if !isSessionActive { applyConfigured() }
        } catch {
            configured = nil
            self.error = error.localizedDescription
        }
        onChange?()
    }

    func setSessionActive(_ active: Bool) {
        isSessionActive = active
        if !active { applyConfigured() }
        onChange?()
    }

    private func applyConfigured() {
        guard let candidate = configured else { return }
        do {
            // Retain both previous registrations until both replacements succeed.
            var nextCapture = registration
            var nextHistory = historyRegistration
            if registration == nil || candidate.shortcut != active.shortcut {
                nextCapture = try register(candidate.shortcut)
            }
            if let registerHistory, historyRegistration == nil || candidate.historyShortcut != active.historyShortcut {
                nextHistory = try candidate.historyShortcut.map(registerHistory)
            }
            registration = nextCapture
            historyRegistration = nextHistory
            active = candidate
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Edits only the requested preference on fresh source, retaining external edits.
    func update(theme: ThemeID? = nil, watermark: Bool? = nil, shortcut: CaptureShortcut? = nil,
                historyRetention: HistoryRetention? = nil, historyShortcut: CaptureShortcut? = nil,
                clearHistoryShortcut: Bool = false) {
        do {
            let target = url.resolvingSymlinksInPath()
            let original = try String(contentsOf: target, encoding: .utf8)
            let edited = try AppSettings.edit(original, theme: theme, watermark: watermark, shortcut: shortcut,
                historyRetention: historyRetention, historyShortcut: historyShortcut, clearHistoryShortcut: clearHistoryShortcut)
            guard url.resolvingSymlinksInPath() == target,
                  try String(contentsOf: target, encoding: .utf8) == original else {
                throw SettingsError(message: "Configuration changed while saving. Try again.")
            }
            try edited.write(to: target, atomically: true, encoding: .utf8)
            receive(edited, target: target)
        } catch { self.error = error.localizedDescription; onChange?() }
    }
}
