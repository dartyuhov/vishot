import AppKit

/// What the editor and region mode draw alike, so they keep looking the same.
enum SelectionStyle {
    /// Over what is outside the selection: around the editor's image, or around a region.
    static let outsideDim = NSColor(white: 0, alpha: 0.45)
    private static let crosshairArm: CGFloat = 12
    private static let crosshairGap: CGFloat = 3

    /// The cursor: four arms around a gap, white on a darker outline so it shows on any content.
    /// Its position is the aiming point.
    static func makeCrosshair() -> CALayer {
        let crosshair = CALayer()
        let path = CGMutablePath()
        let (gap, end) = (crosshairGap, crosshairGap + crosshairArm)
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(CGFloat, CGFloat)] {
            path.move(to: CGPoint(x: dx * gap, y: dy * gap))
            path.addLine(to: CGPoint(x: dx * end, y: dy * end))
        }
        for (color, width) in [(NSColor(white: 0, alpha: 0.75), CGFloat(4)), (.white, 2)] {
            let arms = CAShapeLayer()
            arms.path = path
            arms.strokeColor = color.cgColor
            arms.lineWidth = width
            arms.lineCap = .round
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
