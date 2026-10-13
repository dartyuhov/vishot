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
    private var settingsItem: NSMenuItem?
    private var overlay: OverlayController?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the overlay builds its panels, which ask for the fonts.
        Fonts.register()
        let overlay = OverlayController()
        self.overlay = overlay
        let settings = SettingsStore { [weak self] shortcut in
            guard let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: { [weak self] in
                if self?.settingsWindow?.recordGlobalShortcut(shortcut) == true { return }
                overlay.toggle()
            }) else { throw SettingsError(message: "Could not register \(shortcut.display). It may be used by macOS or another app.") }
            return hotKey
        }
        self.settings = settings
        overlay.onSessionChange = { [weak settings] in settings?.setSessionActive($0) }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        setUpStatusItem()
        settings.start()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()

        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Window", action: #selector(captureFromMenu), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        captureItem = capture
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
        DispatchQueue.main.async { self.overlay?.toggle() }
    }

    private func settingsChanged() {
        guard let settings else { return }
        // A physical-key title remains accurate on non-Latin layouts; a
        // character-based menu equivalent would advertise a different key.
        captureItem?.title = "Capture Window  (\(settings.active.shortcut.display))"
        settingsItem?.title = settings.error == nil ? "Settings…" : "Settings… — Configuration Error"
        overlay?.watermark = settings.active.watermark
        settingsWindow?.refresh()
    }

    @objc private func openSettings() {
        guard let settings else { return }
        if settingsWindow == nil { settingsWindow = SettingsWindow(store: settings) }
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
}
