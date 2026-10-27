import AppKit
import VishotRendering
import ScreenCaptureKit
import VishotAgent

/// Isolated window capture; deliberately independent of Capturer, editor output,
/// watermark, pasteboard, and Capture history. Called on service workers only.
enum AgentWindowCapture {
    static func capture(id: UInt32) async throws -> AgentResponse {
        guard CGPreflightScreenCaptureAccess() else {
            throw AgentFailure(.permissionDenied, "Allow Screen Recording for Vishot in System Settings > Privacy & Security, then reopen Vishot manually and retry.")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  let app = window.owningApplication, app.processID != getpid(),
                  app.bundleIdentifier != "com.dartsiukhou.vishot", window.windowLayer == 0,
                  NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular else {
                throw AgentFailure(.targetUnavailable, "Window \(id) is no longer available as an app window. Run vishot windows and select a current ID.")
            }
            if isReliablyMinimized(id: id, pid: app.processID) {
                throw AgentFailure(.minimizedUnsupported, "Window \(id) is minimized. Vishot does not restore minimized windows; restore it manually before retrying.")
            }
            let frame = window.frame
            let target = AgentWindow(id: id,
                app: AgentApp(pid: app.processID, bundleID: app.bundleIdentifier, name: app.applicationName),
                title: window.title ?? "",
                bounds: AgentBounds(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height))
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = Double(filter.pointPixelScale)
            let width = ceil(Double(filter.contentRect.width) * scale)
            let height = ceil(Double(filter.contentRect.height) * scale)
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  width <= 32768, height <= 32768, width * height <= 64_000_000 else {
                throw AgentFailure(.captureUnavailable, "Window \(id) has unsupported capture dimensions (maximum 64 million pixels).")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(width)
            configuration.height = Int(height)
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.shouldBeOpaque = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            // Do not report success from a window that disappeared during the operation.
            guard let current = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                  current.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == id &&
                      ($0[kCGWindowOwnerPID as String] as? Int32) == app.processID }) else {
                throw AgentFailure(.targetUnavailable, "Window \(id) disappeared during capture. No image was saved.")
            }
            if isReliablyMinimized(id: id, pid: app.processID) {
                throw AgentFailure(.minimizedUnsupported, "Window \(id) was minimized during capture. No image was saved.")
            }
            guard let png = ImageEncoding.data(image, scale: CGFloat(scale), type: .png) else {
                throw AgentFailure(.encodingFailed, "Could not encode window \(id) as PNG. No image was saved.")
            }
            // The private JSON wire base64-encodes Data. Leave room for its envelope.
            guard png.count <= 90 * 1024 * 1024 else {
                throw AgentFailure(.encodingFailed, "The PNG exceeds the service's 90 MiB encoded-image limit.")
            }
            return .captured(AgentCapturedImage(target: target, png: png, width: image.width, height: image.height))
        } catch let error as AgentFailure { throw error }
        catch {
            if !CGPreflightScreenCaptureAccess() {
                throw AgentFailure(.permissionDenied, "Screen Recording permission for Vishot is unavailable. Enable it in System Settings and reopen Vishot manually.")
            }
            throw AgentFailure(.captureUnavailable, "macOS could not capture window \(id). It may have closed, be minimized, or be unavailable in its Space. No other window was captured.")
        }
    }

    /// isOnScreen == false is not proof of minimization (it also covers Spaces).
    /// An exact AX window-ID match plus AXMinimized is positive evidence only.
    private static func isReliablyMinimized(id: UInt32, pid: Int32) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.1)
            var candidate: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &candidate) == .success, candidate == id else { continue }
            var minimized: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success
                && (minimized as? Bool) == true
        }
        return false
    }
}
