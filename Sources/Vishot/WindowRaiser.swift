import AppKit
import ApplicationServices

/// Brings a window to the front while it is browsed, so a covered window can be seen before it is
/// captured, and puts the stacking back when the overlay closes. `AXRaise` alone never gets a window
/// above the active app's front window, so the window's app is activated too. Once the window is in
/// front, Vishot activates itself to take key focus back. Activating Vishot any earlier cancels the
/// app switch, so until then an event tap catches keys and passes them to `onKey` instead of letting
/// them reach the raised app. Needs the Accessibility permission; without it, nothing happens. AX
/// runs on a serial queue because a hung app can take its messaging timeout to answer.
final class WindowRaiser {
    private static let messagingTimeout: Float = 0.25
    /// How long to wait for a raise or an app switch to reorder the windows.
    private static let landTimeout: TimeInterval = 0.5

    /// Keys pressed while another app has key focus. Called on the main thread.
    var onKey: ((NSEvent) -> Void)?
    /// Called on the main thread once Vishot is active again after the last raise.
    var onActivated: (() -> Void)?

    private let queue = DispatchQueue(label: "vishot.raiser", qos: .userInitiated)
    /// Windows to restore, front to back. Only touched on the main thread.
    private var original: [WindowInfo] = []
    private var lowestRaised = -1
    private var isBrowsing = false
    /// Raises not yet finished, and those whose app switch may still take key focus.
    private var pending = 0
    private var holds = 0
    /// The window the next queued raise brings forward. Moving faster than raises finish skips the
    /// windows in between.
    private let lock = NSLock()
    private var next: WindowInfo?
    private var tap: CFMachPort?

    /// True while a raise may have taken key focus from the overlay, which is not a cancel.
    var isSwitchingApps: Bool { holds > 0 }

    /// Starts a browsing session over `windows`, ordered front to back.
    func begin(_ windows: [WindowInfo]) {
        original = windows
        lowestRaised = -1
        isBrowsing = true
    }

    func raise(index: Int) {
        guard AXIsProcessTrusted(), original.indices.contains(index), index > 0 || lowestRaised >= 0 else { return }
        lowestRaised = max(lowestRaised, index)
        pending += 1
        holds += 1
        catchKeys(true)
        lock.withLock { next = original[index] }
        let catalog = Set(original.map(\.id))
        queue.async { [self] in
            if let window = lock.withLock({ defer { next = nil }; return next }) {
                Self.raise(window)
                Self.activate(window.pid)
                Self.wait(until: window, isAbove: catalog.subtracting([window.id]))
            }
            DispatchQueue.main.async { self.finished() }
        }
    }

    /// Makes the window that was in front frontmost again, then raises the others that were in front
    /// of the lowest raised one, back to front, so each lands just below it. Apps handle `AXRaise`
    /// asynchronously, so each raise must land before the next is sent.
    func restore() {
        isBrowsing = false
        guard lowestRaised >= 0, let front = original.first else { return }
        let behind = original[...lowestRaised].dropFirst().reversed()
        let catalog = Set(original.map(\.id))
        let frontApp = Set(original.filter { $0.pid == front.pid }.map(\.id))
        lowestRaised = -1
        queue.async {
            Self.raise(front)
            Self.activate(front.pid)
            Self.wait(until: front, isAbove: catalog.subtracting([front.id]))
            for window in behind {
                Self.raise(window)
                Self.wait(until: window, isAbove: catalog.subtracting(frontApp).subtracting([window.id]))
            }
        }
    }

    private func finished() {
        pending -= 1
        if pending == 0, isBrowsing {
            NSApp.activate(ignoringOtherApps: true)
            onActivated?()
        }
        // Activation completes asynchronously; keys keep coming through the tap until it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            holds -= 1
            if holds == 0 { catchKeys(false) }
        }
    }

    // MARK: - Keys

    private func catchKeys(_ enabled: Bool) {
        if enabled, tap == nil { tap = makeTap() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    private func makeTap() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                Unmanaged<WindowRaiser>.fromOpaque(info!).takeUnretainedValue().caught(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return tap
    }

    private func caught(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown, .keyUp:
            if let key = NSEvent(cgEvent: event) { onKey?(key) }
            return nil
        case .tapDisabledByTimeout:
            if holds > 0, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - AX

    private static func activate(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Waits until none of `others` is above `window`, since raises and app switches land some time
    /// after the call returns.
    private static func wait(until window: WindowInfo, isAbove others: Set<CGWindowID>) {
        let deadline = Date().addingTimeInterval(landTimeout)
        while Date() < deadline {
            let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, window.id) as? [[String: Any]] ?? []
            if !above.contains(where: { ($0[kCGWindowNumber as String] as? Int).map { others.contains(CGWindowID($0)) } ?? false }) {
                return
            }
            usleep(5000)
        }
    }

    private static func raise(_ window: WindowInfo) {
        if let element = axWindows(of: window.pid)[window.id] {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    private static func axWindows(of pid: pid_t) -> [CGWindowID: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [:] }
        var result: [CGWindowID: AXUIElement] = [:]
        for element in elements {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success { result[id] = element }
        }
        return result
    }
}
