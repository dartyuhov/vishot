import AppKit

/// Something that can be selected and captured. Geometry is in CoreGraphics global space.
struct CaptureTarget {
    enum Kind {
        case window(CGWindowID)
        /// `rect` is the element's frame clipped to its window.
        case element(windowID: CGWindowID, rect: CGRect)
        case display(CGDirectDisplayID)
    }

    let kind: Kind
    let frame: CGRect
    /// Point that navigation measures from.
    let anchor: CGPoint
    let label: String
}

enum DisplayCatalog {
    static func displays() -> [CaptureTarget] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let frame = screen.cgFrame
            return CaptureTarget(
                kind: .display(id),
                frame: frame,
                anchor: CGPoint(x: frame.midX, y: frame.midY),
                label: screen.localizedName
            )
        }
    }
}
