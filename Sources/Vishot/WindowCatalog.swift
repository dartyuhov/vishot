import AppKit

/// A window that can be selected. Geometry is in CoreGraphics global space
/// (origin at top-left of the primary display, y grows downward).
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let frame: CGRect
    /// Centroid of the part of the window that is actually visible. Used for navigation,
    /// so partially covered windows are reached where you can see them.
    let anchor: CGPoint
    var title: String = ""

    var target: CaptureTarget {
        CaptureTarget(kind: .window(id), frame: frame, anchor: anchor, label: appName)
    }
}

enum WindowCatalog {
    private static let minSide: CGFloat = 40
    private static let samplesPerSide = 12
    private static let minVisibleSamples = 4

    /// Visible windows across all screens, ordered front to back.
    /// Uses CGWindowList (a few ms) instead of Accessibility or ScreenCaptureKit, which are much slower.
    static func visibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map(\.cgFrame)
        var isRegularApp: [pid_t: Bool] = [:]
        var occluders: [CGRect] = []
        var result: [WindowInfo] = []

        for entry in entries {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= minSide, frame.height >= minSide
            else { continue }

            // Only windows of regular (Dock) apps. Drops overlays from agents such as
            // JankyBorders, which would otherwise be selectable and hide the real window.
            let regular = isRegularApp[pid] ?? {
                let value = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
                isRegularApp[pid] = value
                return value
            }()
            guard regular else { continue }

            let anchor = visibleCentroid(of: frame, screens: screens, occluders: occluders)
            occluders.append(frame)
            guard let anchor else { continue }

            result.append(WindowInfo(
                id: id,
                pid: pid,
                appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                frame: frame,
                anchor: anchor,
                title: entry[kCGWindowName as String] as? String ?? ""
            ))
        }
        return result
    }

    /// Samples a grid over the window. Returns nil when the window is effectively hidden:
    /// covered by windows in front, or parked off-screen (AeroSpace hides windows that way).
    private static func visibleCentroid(of frame: CGRect, screens: [CGRect], occluders: [CGRect]) -> CGPoint? {
        let n = samplesPerSide
        var count = 0
        var sum = CGPoint.zero
        for i in 0..<n {
            for j in 0..<n {
                let p = CGPoint(
                    x: frame.minX + frame.width * (CGFloat(i) + 0.5) / CGFloat(n),
                    y: frame.minY + frame.height * (CGFloat(j) + 0.5) / CGFloat(n)
                )
                guard screens.contains(where: { $0.contains(p) }),
                      !occluders.contains(where: { $0.contains(p) })
                else { continue }
                count += 1
                sum.x += p.x
                sum.y += p.y
            }
        }
        guard count >= minVisibleSamples else { return nil }
        return CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
    }
}

extension NSScreen {
    /// Screen frame in CoreGraphics global space.
    var cgFrame: CGRect { frame.flippedBetweenCocoaAndCG }
}

extension CGRect {
    /// Converts between Cocoa (bottom-left origin) and CoreGraphics (top-left origin) global space.
    /// The conversion is its own inverse.
    var flippedBetweenCocoaAndCG: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}

extension CGPoint {
    /// Same conversion as `CGRect.flippedBetweenCocoaAndCG`, for a point.
    var flippedBetweenCocoaAndCG: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: x, y: primaryHeight - y)
    }
}
