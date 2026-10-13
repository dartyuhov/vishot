import AppKit

/// The "vishot.dev" credit in the bottom-right corner of every copied or saved image, in the landing
/// page's look: light pixel small capitals on a square dark plate with a hard amber shadow, so it reads
/// on any content. Output preferences control whether it is drawn.
enum Watermark {
    static let text = "vishot.dev"
    /// From the image's right and bottom edges to the shadow, in points.
    static let margin: CGFloat = 12
    /// One pixel of the pixel font, in points. Whole points keep every edge on a device pixel.
    private static let cell: CGFloat = 2
    /// Padding around the text and the shadow's offset, in cells.
    private static let padding = (x: 4, y: 3)
    private static let shadowOffset = 1
    private static let plateColor = Palette.ink.cgColor
    private static let shadowColor = Palette.hintLeaf.cgColor
    private static let textColor = Palette.text.cgColor

    /// The small capitals of the pixel font, rows top to bottom, as the wordmark is set. The landing
    /// page's demo (site/main.js) has the full-height capitals.
    private static let glyphs: [Character: [String]] = [
        "v": ["101", "101", "101", "010"],
        "i": ["111", "010", "010", "111"],
        "s": ["011", "100", "001", "110"],
        "h": ["101", "111", "101", "101"],
        "o": ["010", "101", "101", "010"],
        "t": ["111", "010", "010", "010"],
        ".": ["0", "0", "0", "1"],
        "d": ["110", "101", "101", "110"],
        "e": ["111", "110", "100", "111"],
    ]
    private static let glyphHeight = 4

    /// The text's pixels in cells from its top-left, and its width in cells.
    private static let pixels: (cells: [CGPoint], width: Int) = {
        var cells: [CGPoint] = []
        var x = 0
        for character in text {
            let rows = glyphs[character]!
            for (y, row) in rows.enumerated() {
                for (dx, bit) in row.enumerated() where bit == "1" {
                    cells.append(CGPoint(x: x + dx, y: y))
                }
            }
            x += rows[0].count + 1
        }
        return (cells, x - 1)
    }()

    /// `image` with the badge drawn in, or `image` itself when it is too small for one or drawing fails.
    static func apply(to image: CGImage, scale: CGFloat) -> CGImage {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let badge = badgeRect(in: size),
              let context = AnnotationRenderer.imageSpaceContext(drawing: image, scale: scale)
        else { return image }

        let offset = CGFloat(shadowOffset) * cell
        let plate = CGRect(x: badge.minX, y: badge.minY, width: badge.width - offset, height: badge.height - offset)
        // The plate is opaque, so drawing it over the whole shadow leaves only the shadow's L.
        context.setFillColor(shadowColor)
        context.fill(plate.offsetBy(dx: offset, dy: offset))
        context.setFillColor(plateColor)
        context.fill(plate)

        let textOrigin = CGPoint(x: plate.minX + CGFloat(padding.x) * cell, y: plate.minY + CGFloat(padding.y) * cell)
        context.setFillColor(textColor)
        context.fill(pixels.cells.map {
            CGRect(x: textOrigin.x + $0.x * cell, y: textOrigin.y + $0.y * cell, width: cell, height: cell)
        })
        return context.makeImage() ?? image
    }

    /// The badge with its shadow in image space (points, y down), or nil when it and its margins would
    /// take more than half the image's width or height, as on a capture of a single button.
    static func badgeRect(in imageSize: CGSize) -> CGRect? {
        let width = CGFloat(pixels.width + 2 * padding.x + shadowOffset) * cell
        let height = CGFloat(glyphHeight + 2 * padding.y + shadowOffset) * cell
        guard 2 * (width + margin) <= imageSize.width, 2 * (height + margin) <= imageSize.height else { return nil }
        return CGRect(x: imageSize.width - margin - width, y: imageSize.height - margin - height, width: width, height: height)
    }
}
