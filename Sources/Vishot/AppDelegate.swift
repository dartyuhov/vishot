import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Config {
    /// ⇧⌘S. A global hotkey, so apps no longer get it (it is Save As in many).
    static let hotKeyCode = kVK_ANSI_S
    static let hotKeyModifiers = cmdKey | shiftKey

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
    private var hotKey: HotKey?
    private var overlay: OverlayController?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the overlay builds its panels, which ask for the fonts.
        Fonts.register()
        let overlay = OverlayController()
        self.overlay = overlay
        hotKey = HotKey(keyCode: Config.hotKeyCode, modifiers: Config.hotKeyModifiers) {
            overlay.toggle()
        }
        if hotKey == nil {
            NSLog("Vishot: could not register hotkey, it may be taken by another app")
        }
        setUpStatusItem()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()

        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Window", action: #selector(captureFromMenu), keyEquivalent: "s")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)
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

    /// The logo's label and selection border around a window, as pixel art on an 18 pt grid. A template
    /// image, so the menu bar tints it.
    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let pixels = [
                // label
                NSRect(x: 2, y: 2, width: 9, height: 3),
                // selection border, corner pixels left out so it reads as rounded
                NSRect(x: 3, y: 6, width: 12, height: 1), NSRect(x: 3, y: 15, width: 12, height: 1),
                NSRect(x: 2, y: 7, width: 1, height: 8), NSRect(x: 15, y: 7, width: 1, height: 8),
                NSRect(x: 3, y: 7, width: 1, height: 1), NSRect(x: 14, y: 7, width: 1, height: 1),
                NSRect(x: 3, y: 14, width: 1, height: 1), NSRect(x: 14, y: 14, width: 1, height: 1),
                // window: title bar, then body
                NSRect(x: 5, y: 8, width: 8, height: 1), NSRect(x: 4, y: 9, width: 10, height: 1),
                NSRect(x: 4, y: 11, width: 10, height: 2), NSRect(x: 5, y: 13, width: 8, height: 1),
            ]
            pixels.forEach { $0.fill() }
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
