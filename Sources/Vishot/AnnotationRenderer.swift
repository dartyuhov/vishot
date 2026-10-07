import AppKit
import CoreText

/// Draws annotations as pixel art on `PixelArt`'s grid. The on-screen layers and the export both call
/// `draw`, so what you see is what you get.
enum AnnotationRenderer {
    private static let headLength = 8 * PixelArt.cell
    /// Half the head's width, relative to its length.
    private static let headSpread: CGFloat = 0.6
    /// Its pixels are `PixelArt.cell` points, so text sits on the same grid as arrows and rectangles.
    private static let font: CTFont = Fonts.pixel(8 * PixelArt.cell)

    /// Draws in image space: the context's user space must have its origin at the image's top-left,
    /// y down, in points.
    static func draw(_ annotations: [Annotation], in context: CGContext) {
        // A hard shadow one cell down and right, like the landing page's. Shadows are set in device
        // space, so the offset is converted, and points down-right on screen.
        let shadowOffset = CGSize(width: PixelArt.cell, height: PixelArt.cell).applying(context.ctm)
        for annotation in annotations {
            context.saveGState()
            switch annotation {
            case let .arrow(from, to, color):
                drawCells(arrowCells(from: from, to: to), color: color, shadowOffset: shadowOffset, in: context)
            case let .rect(rect, color):
                drawCells(PixelArt.outline(rect), color: color, shadowOffset: shadowOffset, in: context)
            case let .text(text, at, color):
                drawText(text, at: at, color: color, in: context)
            }
            context.restoreGState()
        }
    }

    /// A one-cell line with a filled triangle head at `to`.
    private static func arrowCells(from: CGPoint, to: CGPoint) -> [PixelArt.Cell] {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return [] }
        let unit = CGVector(dx: (to.x - from.x) / length, dy: (to.y - from.y) / length)
        let head = min(headLength, length)
        let base = CGPoint(x: to.x - unit.dx * head, y: to.y - unit.dy * head)
        let spread = head * headSpread
        return PixelArt.line(from: from, to: to) + PixelArt.triangle(
            to,
            CGPoint(x: base.x - unit.dy * spread, y: base.y + unit.dx * spread),
            CGPoint(x: base.x + unit.dy * spread, y: base.y - unit.dx * spread)
        )
    }

    private static func drawCells(_ cells: [PixelArt.Cell], color: AnnotationColor, shadowOffset: CGSize, in context: CGContext) {
        context.setShadow(offset: shadowOffset, blur: 0, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        context.setFillColor(color.cgColor)
        // One fill, so overlapping cells (the line inside the head) don't darken the shadow.
        context.fill(Set(cells).map(PixelArt.rect))
    }

    private static func drawText(_ text: String, at point: CGPoint, color: AnnotationColor, in context: CGContext) {
        let line = layout(text).line
        let halo = color == .white ? AnnotationColor.black : .white
        let baseline = baseline(at: point)
        // Glyphs are drawn y up, so flip them back in the y-down image space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // An outline: the text in the halo color moved 1 pt each way. Thinner than a cell, so it doesn't
        // fill the one-cell gaps between letters.
        context.setFillColor(halo.cgColor)
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                context.textPosition = CGPoint(x: baseline.x + CGFloat(dx), y: baseline.y + CGFloat(dy))
                CTLineDraw(line, context)
            }
        }
        context.setFillColor(color.cgColor)
        context.textPosition = baseline
        CTLineDraw(line, context)
    }

    /// Where a text annotation centred on `point` starts its baseline: its capitals centred on the
    /// point, and on the grid, so the font's pixels are cells.
    private static func baseline(at point: CGPoint) -> CGPoint {
        PixelArt.snapped(CGPoint(x: point.x, y: point.y + CTFontGetCapHeight(font) / 2))
    }

    /// The line box of a text annotation, in image space.
    static func textBounds(_ text: String, at point: CGPoint) -> CGRect {
        let metrics = layout(text).metrics
        let baseline = baseline(at: point)
        return CGRect(x: baseline.x, y: baseline.y - metrics.ascent, width: metrics.width, height: metrics.ascent + metrics.descent)
    }

    /// The caret after `text` while it is typed, in image space.
    static func caret(after text: String, at point: CGPoint) -> CGRect {
        let width = text.isEmpty ? 0 : layout(text).metrics.width
        // Measured on sample letters, so the caret has a height before anything is typed.
        let line = textBounds("Hg", at: point)
        return CGRect(x: line.minX + width + 1, y: line.minY, width: 2, height: line.height)
    }

    private static func layout(_ text: String) -> (line: CTLine, metrics: (width: CGFloat, ascent: CGFloat, descent: CGFloat)) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            // Colors come from the context, so one line serves both the halo and the fill.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return (line, (width, ascent, descent))
    }

    // MARK: - Export

    /// The image with its annotations drawn in, cropped. Nil if drawing fails.
    static func export(_ document: EditDocument) -> CGImage? {
        let image = document.image
        let pixelSize = CGSize(width: image.width, height: image.height)
        var cropRect: CGRect?
        if let crop = document.crop {
            guard let rect = pixelRect(for: crop, scale: document.scale, imageSize: pixelSize) else { return nil }
            cropRect = rect
        }
        // Nothing drawn: the capture's own pixels, without a redraw.
        guard !document.annotations.isEmpty else {
            guard let cropRect else { return image }
            return image.cropping(to: cropRect)
        }

        guard let context = imageSpaceContext(drawing: image, scale: document.scale) else { return nil }
        draw(document.annotations, in: context)

        guard let drawn = context.makeImage() else { return nil }
        guard let cropRect else { return drawn }
        return drawn.cropping(to: cropRect)
    }

    /// A bitmap the size of `image`, in its color space, with `image` drawn in and user space set to
    /// image space (points from the top-left, y down), ready to draw over it.
    static func imageSpaceContext(drawing image: CGImage, scale: CGFloat) -> CGContext? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? sRGB
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)
        return context
    }

    /// The pixels of `crop` (in points), with each edge rounded to the nearest pixel and clamped to
    /// the image. Nil when nothing is left.
    static func pixelRect(for crop: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        let minX = (crop.minX * scale).rounded()
        let minY = (crop.minY * scale).rounded()
        let rect = CGRect(
            x: minX, y: minY,
            width: (crop.maxX * scale).rounded() - minX,
            height: (crop.maxY * scale).rounded() - minY
        ).intersection(CGRect(origin: .zero, size: imageSize))
        return rect.isEmpty ? nil : rect
    }
}
