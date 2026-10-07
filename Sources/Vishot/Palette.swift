import AppKit

/// Every color the UI draws, in one place so the app, the logo and the landing page share one look.
/// The names in comments are the landing page's CSS variables (site/style.css).
enum Palette {
    /// The brand accent, a vivid indigo. The logo's plate, selection border, active tool, crop outline. `--accent`.
    static let accent = NSColor(rgb: 0x6B5CFA)

    /// The darkest surface: the watermark's plate, text on light chips. `--bg`.
    static let ink = NSColor(rgb: 0x12121A)
    /// The HUD and the editor toolbar. `--surface`.
    static let surface = NSColor(rgb: 0x1B1B28)
    /// The face of a keycap. `--surface-2`.
    static let surfaceRaised = NSColor(rgb: 0x232336)
    /// Borders of the HUD, the toolbar and keycaps. `--line`.
    static let line = NSColor(rgb: 0x34344E)
    /// The hard shadow under the HUD and the toolbar.
    static let shadow = NSColor(white: 0, alpha: 0.45)

    static let text = NSColor(rgb: 0xEDEDF5)
    static let textMuted = NSColor(rgb: 0xA3A3BD)
    static let textDim = NSColor(rgb: 0x75758F)

    /// Hints on leaf elements, and the hard shadow under the target label and the watermark. `--hint`.
    static let hintLeaf = NSColor(srgbRed: 1, green: 0.82, blue: 0.28, alpha: 1)
    /// Hints and outlines on containers. Close in lightness, so none shouts over the others.
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

private extension NSColor {
    /// An sRGB color from a CSS-style hex number, so values can be compared with the landing page's.
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
