import AppKit

/// What the editor and region mode draw alike, so they keep looking the same.
enum SelectionStyle {
    /// Over what is outside the selection: around the editor's image, or around a region.
    static let outsideDim = NSColor(white: 0, alpha: 0.45)

    /// The cursor: four arms around a gap, white on a darker outline so it shows on any content.
    /// Its position is the aiming point.
    static func makeCrosshair() -> CALayer {
        makeCrosshair(style: ThemeCatalog.pixel.selection)
    }

    static func makeCrosshair(style: SelectionDrawingStyle) -> CALayer {
        let crosshair = CALayer()
        let path = CGMutablePath()
        let (gap, end) = (style.gap, style.gap + style.arm)
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(CGFloat, CGFloat)] {
            path.move(to: CGPoint(x: dx * gap, y: dy * gap))
            path.addLine(to: CGPoint(x: dx * end, y: dy * end))
        }
        for (color, width) in [(style.outline, style.outlineWidth), (style.foreground, style.width)] {
            let arms = CAShapeLayer()
            arms.path = path
            arms.strokeColor = color.cgColor
            arms.lineWidth = width
            arms.lineCap = style.lineCap
            crosshair.addSublayer(arms)
        }
        return crosshair
    }

    /// A dim layer that leaves a hole, through an even-odd fill. Set its path to the dimmed area plus
    /// the hole.
    static func makeDim(_ color: NSColor = outsideDim) -> CAShapeLayer {
        let dim = CAShapeLayer()
        dim.fillRule = .evenOdd
        dim.fillColor = color.cgColor
        return dim
    }
}
