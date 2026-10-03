import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Config {
    /// ⇧⌘2 — next to the system ⇧⌘3/4/5 shortcuts and unused by macOS.
    static let hotKeyCode = kVK_ANSI_2
    static let hotKeyModifiers = cmdKey | shiftKey
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var overlay: OverlayController?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Vishot")

        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Window", action: #selector(captureFromMenu), keyEquivalent: "2")
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
