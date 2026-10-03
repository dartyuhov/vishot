import AppKit
import ApplicationServices

/// Private but long-stable: maps an Accessibility window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// An Accessibility element, with the attributes that filtering and labels need read in one call.
final class AXNode: ElementNode {
    private static let attributes = [
        kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute, kAXSubroleAttribute,
        kAXRoleDescriptionAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
    ]

    let element: AXUIElement
    let frame: CGRect?
    let subrole: String?
    let roleDescription: String
    /// Title, or description when there is no title. `AXValue` is never read: it can be a whole document.
    let title: String

    init(_ element: AXUIElement) {
        self.element = element
        var results: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(), &results)
        // Missing attributes come back as AXValues of type .axError, which the casts below reject.
        let values = Dictionary(uniqueKeysWithValues: zip(Self.attributes, (results as? [AnyObject]) ?? []))

        if let origin = Self.point(values[kAXPositionAttribute]), let size = Self.size(values[kAXSizeAttribute]) {
            frame = CGRect(origin: origin, size: size)
        } else {
            frame = nil
        }
        let role = values[kAXRoleAttribute] as? String ?? ""
        subrole = values[kAXSubroleAttribute] as? String
        roleDescription = (values[kAXRoleDescriptionAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? role
        let title = values[kAXTitleAttribute] as? String ?? ""
        self.title = title.isEmpty ? values[kAXDescriptionAttribute] as? String ?? "" : title
    }

    lazy var hasChildren: Bool = {
        var count: CFIndex = 0
        return AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success && count > 0
    }()

    func children() -> [AXNode] {
        (copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AXNode.init)
    }

    private static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// Finds UI elements inside a window over Accessibility. Only used after `v`, never on the hotkey path.
final class ElementCatalog {
    /// Chrome drops its web tree as soon as `AXEnhancedUserInterface` goes back to false, and rebuilding it
    /// takes ~2 s every time. Leaving it on may slow down window-manager moves of that browser.
    static let restoresEnhancedUserInterface = false
    /// How long an app may take to build its tree after a flag is set. Levels reload meanwhile.
    static let warmUpDuration: TimeInterval = 3

    private static let messagingTimeout: Float = 0.25
    private static let maxLabelLength = 40
    private static let manualAccessibility = "AXManualAccessibility"
    private static let enhancedUserInterface = "AXEnhancedUserInterface"

    private var hasPrompted = false
    private var preparedPIDs: Set<pid_t> = []
    private var enhancedApps: [pid_t: AXUIElement] = [:]
    private var warmUpEnds: [pid_t: Date] = [:]

    init() {
        // A timeout set on an app element may not carry over to the elements read from it,
        // so it is also set process-wide. A hung app then blocks the main thread for 0.25 s, not ~6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    /// Shows the system prompt the first time in a session, then only checks.
    func isTrusted() -> Bool {
        guard !hasPrompted else { return AXIsProcessTrusted() }
        hasPrompted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The Accessibility window for a CG window, or nil when the app doesn't expose it.
    func windowNode(for window: WindowInfo) -> AXNode? {
        let app = appElement(window.pid)
        guard let candidates = copyAttribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let byID = candidates.first { candidate in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(candidate, &id) == .success && id == window.id
        }
        if let byID { return AXNode(byID) }
        return candidates.lazy.map(AXNode.init).first { node in
            guard let frame = node.frame else { return false }
            return abs(frame.minX - window.frame.minX) < 1 && abs(frame.minY - window.frame.minY) < 1
                && abs(frame.width - window.frame.width) < 1 && abs(frame.height - window.frame.height) < 1
        }
    }

    /// Turns on the accessibility trees of Electron and Chromium apps, once per app per session.
    /// After a flag is set, the app is warming up until `warmUpEnd(for:)`.
    func prepare(_ window: AXNode, pid: pid_t) {
        guard preparedPIDs.insert(pid).inserted else { return }
        let app = appElement(pid)
        var warming = false

        // Electron builds its tree only when asked. Other apps reject the attribute.
        if copyAttribute(app, Self.manualAccessibility) as? Bool != true {
            warming = AXUIElementSetAttributeValue(app, Self.manualAccessibility as CFString, kCFBooleanTrue) == .success
        }
        // Chromium browsers leave the web area empty until assistive tech announces itself.
        if isChromium(window), copyAttribute(app, Self.enhancedUserInterface) as? Bool != true {
            // Chrome returns kAXErrorNotImplemented here, yet the flag works, so the result is ignored.
            _ = AXUIElementSetAttributeValue(app, Self.enhancedUserInterface as CFString, kCFBooleanTrue)
            enhancedApps[pid] = app
            warming = true
        }
        if warming { warmUpEnds[pid] = Date().addingTimeInterval(Self.warmUpDuration) }
    }

    /// When the app should have finished building its tree, or nil if it isn't warming up.
    func warmUpEnd(for pid: pid_t) -> Date? {
        guard let end = warmUpEnds[pid], end > Date() else { return nil }
        return end
    }

    /// Called when the overlay closes.
    func finish() {
        guard Self.restoresEnhancedUserInterface else { return }
        for (pid, app) in enhancedApps {
            AXUIElementSetAttributeValue(app, Self.enhancedUserInterface as CFString, kCFBooleanFalse)
            preparedPIDs.remove(pid)
            warmUpEnds[pid] = nil
        }
        enhancedApps = [:]
    }

    /// Selectable elements one level below `root`.
    func level(below root: AXNode, in window: WindowInfo) -> [AXNode] {
        ElementFilter.level(below: root, clippedTo: window.frame)
    }

    func targets(for nodes: [AXNode], in window: WindowInfo) -> [CaptureTarget] {
        nodes.map { target(for: $0, in: window) }
    }

    private func target(for node: AXNode, in window: WindowInfo) -> CaptureTarget {
        let rect = (node.frame ?? window.frame).intersection(window.frame)
        return CaptureTarget(
            kind: .element(windowID: window.id, rect: rect),
            frame: rect,
            anchor: CGPoint(x: rect.midX, y: rect.midY),
            label: label(for: node, size: rect.size)
        )
    }

    private func label(for node: AXNode, size: CGSize) -> String {
        let text = node.title.isEmpty
            ? "\(node.roleDescription) \(Int(size.width))×\(Int(size.height))"
            : "\(node.roleDescription) — \(node.title)"
        return text.count > Self.maxLabelLength ? text.prefix(Self.maxLabelLength - 1) + "…" : text
    }

    private func isChromium(_ window: AXNode) -> Bool {
        let children = copyAttribute(window.element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.contains { child in
            (copyAttribute(child, "AXDOMClassList") as? [String])?.contains("BrowserRootView") == true
        }
    }

    private func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return app
    }
}

private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}
