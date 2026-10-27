import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Config {
    /// Where macOS saves screenshots (set in the Screenshot app's options), or the Desktop.
    static func saveFolder() -> URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        guard let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") else {
            return desktop
        }
        let path = (location as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return desktop
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `vishot-2026-10-03-142205.png`.
    static func fileName(for date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "vishot-\(formatter.string(from: date)).png"
    }

    /// A file in the save folder named for now, numbered if two saves fall in the same second.
    static func newSaveURL() -> URL {
        let folder = saveFolder()
        let name = (fileName(for: Date()) as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name + ".png")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name)-\(number).png")
            number += 1
        }
        return url
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settings: SettingsStore?
    private var settingsWindow: SettingsWindow?
    private var captureItem: NSMenuItem?
    private var historyItem: NSMenuItem?
    private var settingsItem: NSMenuItem?
    private var overlay: OverlayController?
    private let sessions = CaptureSessionCoordinator()
    private var video: VideoSession?
    private var stopItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private lazy var setup = SetupFlow.live()
    private var setupWindow: SetupWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the overlay builds its panels, which ask for the fonts.
        Fonts.register()
        let overlay = OverlayController(sessions: sessions)
        self.overlay = overlay
        let video = VideoSession(sessions: sessions, history: overlay.historyLibrary)
        self.video = video
        overlay.video = video
        video.onCountdown = { [weak overlay] in overlay?.videoCountdownStatus($0) }
        video.onReturnToPicker = { [weak overlay] in overlay?.videoReturnToPicker($0) }
        video.onDismissPicker = { [weak overlay] in overlay?.dismissForVideo() }
        video.onChange = { [weak self] in self?.settingsChanged() }
        sessions.onCapture = { [weak overlay] in overlay?.show(session: $0) ?? false }
        sessions.onHistory = { [weak overlay] in overlay?.showHistory(session: $0) ?? false }
        sessions.onCaptureAgain = { [weak overlay] in overlay?.toggle(session: $0) }
        sessions.onQuitReady = { NSApp.reply(toApplicationShouldTerminate: true) }
        let settings = SettingsStore(registerHistory: { [weak self] shortcut in
            guard let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: { [weak self] in
                if self?.settingsWindow?.recordGlobalShortcut(shortcut) == true { return }
                self?.showHistory()
            }) else { throw SettingsError(message: "Could not register History shortcut \(shortcut.display). It may be used by macOS or another app.") }
            return hotKey
        }) { [weak self] shortcut in
            guard let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: { [weak self] in
                if self?.settingsWindow?.recordGlobalShortcut(shortcut) == true { return }
                self?.capture()
            }) else { throw SettingsError(message: "Could not register \(shortcut.display). It may be used by macOS or another app.") }
            return hotKey
        }
        self.settings = settings
        sessions.onSessionChange = { [weak settings] in settings?.setSessionActive($0) }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        overlay.historyLibrary.onChange = { [weak self, weak overlay] in
            overlay?.refreshHistory()
            self?.settingsChanged()
        }
        setUpStatusItem()
        settings.start()
        overlay.historyLibrary.start()

        if setup.needsSetup { presentSetup() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()

        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Window", action: #selector(captureFromMenu), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        captureItem = capture
        let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.isHidden = true
        menu.addItem(stop)
        stopItem = stop
        let history = NSMenuItem(title: "Capture History", action: #selector(historyFromMenu), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        historyItem = history
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        settingsItem = preferences
        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        launchAtLoginItem = launchAtLogin

        menu.addItem(NSMenuItem(title: "Quit Vishot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// The logo's plate and v (Resources/logo/vishot-mark-16.svg), one point per pixel. A template image
    /// has only alpha, so the v is cut out of the plate and its extrusion is half see-through. The menu
    /// bar tints it.
    private static func statusImage() -> NSImage {
        let rows = [
            ".###########.",
            "#############",
            "###  ###  ###",
            "###  +##  +##",
            "###  +##  +##",
            "###  +##  +##",
            "###  +##  +##",
            "####  #  ++##",
            "#####   ++###",
            "###### ++####",
            "#######+#####",
            "#############",
            ".###########.",
        ]
        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: true) { _ in
            for (y, row) in rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "#" || cell == "+" {
                    NSColor.black.withAlphaComponent(cell == "#" ? 1 : 0.5).setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vishot"
        return image
    }

    @objc private func captureFromMenu() {
        // Let the menu finish closing before the overlay takes key focus.
        DispatchQueue.main.async { self.capture() }
    }

    @objc private func historyFromMenu() { DispatchQueue.main.async { self.showHistory() } }

    private func capture() {
        if video?.isActive == true { video?.stop(); return }
        if sessions.isSessionActive { sessions.capture(); return }
        if setupWindow?.window?.isVisible == true, setup.isShowingGuide {
            setupWindow?.takeFirstScreenshot()
            return
        }
        guard !setup.needsSetup else {
            if setup.isShowingGuide { setupWindow?.takeFirstScreenshot() }
            else { presentSetup() }
            return
        }
        sessions.capture()
    }

    private func showHistory() {
        guard !sessions.isSessionActive else { return }
        guard !setup.needsSetup else { presentSetup(); return }
        sessions.showHistory()
    }

    private func presentSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindow(flow: setup, shortcut: { [weak self] in
                self?.settings?.active.shortcut.display ?? CaptureShortcut.defaults.display
            }, capture: { [weak self] in self?.sessions.capture() })
        }
        setupWindow?.present()
    }

    private func settingsChanged() {
        guard let settings else { return }
        // A physical-key title remains accurate on non-Latin layouts; a
        // character-based menu equivalent would advertise a different key.
        captureItem?.title = "Capture Window  (\(settings.active.shortcut.display))" + (video?.error == nil ? "" : " — Recording Error")
        stopItem?.isHidden = video?.canStop != true
        video?.shortcut = settings.active.shortcut
        historyItem?.title = "Capture History" + (settings.active.historyShortcut.map { "  (\($0.display))" } ?? "") + (overlay?.historyLibrary.error == nil ? "" : " — Storage Error")
        settingsItem?.title = settings.error == nil ? "Settings…" : "Settings… — Configuration Error"
        overlay?.watermark = settings.active.watermark
        overlay?.historyLibrary.retention = settings.active.historyRetention
        settingsWindow?.refresh()
        if setupWindow?.window?.isVisible == true { setupWindow?.refresh() }
    }

    @objc private func openSettings() {
        guard let settings else { return }
        if settingsWindow == nil { settingsWindow = SettingsWindow(store: settings, history: overlay?.historyLibrary) }
        settingsWindow?.present()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Vishot: launch at login failed: \(error)")
        }
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        video?.stop()
        return sessions.requestQuit() ? .terminateNow : .terminateLater
    }

    @objc private func stopRecording() { video?.stop() }
}
