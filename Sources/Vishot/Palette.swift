import AppKit

/// Every color the UI draws, in one place so the app, the logo and the landing page share one look.
enum Palette {
    /// The brand accent, a vivid indigo. Selection border, active tool, crop outline.
    static let accent = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1)
    /// Dark chrome behind the HUD and the editor toolbar.
    static let chrome = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 0.9)
    static let textSecondary = NSColor(white: 1, alpha: 0.65)
    static let textTertiary = NSColor(white: 1, alpha: 0.45)

    /// Hint labels on leaf elements.
    static let hintLeaf = NSColor(srgbRed: 1, green: 0.82, blue: 0.28, alpha: 1)
    /// Hint labels and outlines on containers. Close in lightness, so none shouts over the others.
    /// No amber, so it stays the mark of a leaf, and no indigo, so it stays the selection.
    static let hintContainers = [
        NSColor(srgbRed: 0.38, green: 0.84, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.52, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.52, green: 0.90, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 1, green: 0.62, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.66, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.92, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 1, green: 0.58, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.76, blue: 1, alpha: 1),
    ]
}
