import AppKit
import VishotRendering
import CoreText

/// The themed "vishot.dev" credit in the bottom-right corner of copied or saved images.
/// Output preferences control whether it is drawn.
enum Watermark {
    static let text = "vishot.dev"
    /// One pixel of the pixel font, in points. Whole points keep every edge on a device pixel.
    private static let cell: CGFloat = 2

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
    static func apply(to image: CGImage, scale: CGFloat, style: WatermarkStyle) -> CGImage {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let badge = badgeRect(in: size, style: style),
              let context = AnnotationRenderer.imageSpaceContext(drawing: image, scale: scale)
        else { return image }

        if case .systemText = style.treatment {
            // Reserve the shadow inside the measured badge so placement and the small-image
            // rule include it, just as they do for Pixel's hard shadow.
            let radius = style.plate.shadowRadius
            let offset = style.plate.shadowOffset
            let plateRect = CGRect(x: badge.minX + radius + max(0, -offset.width),
                y: badge.minY + radius + max(0, offset.height),
                width: badge.width - 2 * radius - abs(offset.width),
                height: badge.height - 2 * radius - abs(offset.height))
            let plate = CGPath(roundedRect: plateRect, cornerWidth: style.plate.cornerRadius,
                                cornerHeight: style.plate.cornerRadius, transform: nil)
            context.saveGState()
            context.clip(to: badge)
            context.setShouldAntialias(true)
            // Quartz shadows use device units and y-up offsets, independent of the CTM.
            context.setShadow(offset: CGSize(width: offset.width * scale, height: offset.height * scale),
                              blur: radius * scale, color: style.plate.shadow.cgColor)
            context.setFillColor(style.plate.background.cgColor)
            context.addPath(plate)
            context.fillPath()
            context.restoreGState()
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: style.font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.setShouldAntialias(true)
            context.textPosition = CGPoint(x: plateRect.minX + style.padding.width,
                y: plateRect.minY + style.padding.height + style.font.ascender)
            context.setFillColor(style.text.cgColor)
            CTLineDraw(line, context)
            return context.makeImage() ?? image
        }

        let offset = style.plate.shadowOffset
        let plate = CGRect(x: badge.minX, y: badge.minY,
            width: badge.width - offset.width, height: badge.height + offset.height)
        // The plate is opaque, so drawing it over the whole shadow leaves only the shadow's L.
        context.setFillColor(style.plate.shadow.cgColor)
        context.fill(plate.offsetBy(dx: offset.width, dy: -offset.height))
        context.setFillColor(style.plate.background.cgColor)
        context.fill(plate)

        let textOrigin = CGPoint(x: plate.minX + style.padding.width, y: plate.minY + style.padding.height)
        context.setFillColor(style.text.cgColor)
        context.fill(pixels.cells.map {
            CGRect(x: textOrigin.x + $0.x * cell, y: textOrigin.y + $0.y * cell, width: cell, height: cell)
        })
        return context.makeImage() ?? image
    }

    /// The badge with its shadow in image space (points, y down), or nil when it and its margins would
    /// take more than half the image's width or height, as on a capture of a single button.
    static func badgeRect(in imageSize: CGSize, style: WatermarkStyle) -> CGRect? {
        let width: CGFloat
        let height: CGFloat
        switch style.treatment {
        case .pixelGlyphs:
            width = CGFloat(pixels.width) * cell + 2 * style.padding.width + style.plate.shadowOffset.width
            height = CGFloat(glyphHeight) * cell + 2 * style.padding.height - style.plate.shadowOffset.height
        case .systemText:
            let textSize = HUD.textSize(text, font: style.font)
            width = textSize.width + 2 * style.padding.width + 2 * style.plate.shadowRadius + abs(style.plate.shadowOffset.width)
            height = textSize.height + 2 * style.padding.height + 2 * style.plate.shadowRadius + abs(style.plate.shadowOffset.height)
        }
        guard 2 * (width + style.margin) <= imageSize.width, 2 * (height + style.margin) <= imageSize.height else { return nil }
        return CGRect(x: imageSize.width - style.margin - width, y: imageSize.height - style.margin - height, width: width, height: height)
    }
}
