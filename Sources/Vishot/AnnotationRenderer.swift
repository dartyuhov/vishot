import AppKit
import CoreText

/// Shared styled drawing and measurement for preview and export. Legacy calls resolve Pixel;
/// migrated owners retain and pass an immutable style for the document's lifetime.
enum AnnotationRenderer {
    private static var pixelStyle: AnnotationStyle { ThemeCatalog.pixel.annotation }

    /// Draws in image space: the context's user space must have its origin at the image's top-left,
    /// y down, in points.
    static func draw(_ annotations: [Annotation], in context: CGContext) {
        draw(annotations, in: context, style: pixelStyle)
    }

    static func draw(_ annotations: [Annotation], in context: CGContext, style: AnnotationStyle) {
        // A hard shadow one cell down and right, like the landing page's. Shadows are set in device
        // space, so the offset is converted, and points down-right on screen.
        let shadowOffset = CGSize(width: PixelArt.cell, height: PixelArt.cell).applying(context.ctm)
        for annotation in annotations {
            context.saveGState()
            if case .vector = style.treatment {
                drawVector(annotation, in: context, style: style)
                context.restoreGState()
                continue
            }
            switch annotation {
            case let .arrow(from, to, color):
                drawCells(arrowCells(from: from, to: to, style: style), color: color, shadowOffset: shadowOffset, in: context)
            case let .rect(rect, color):
                drawCells(PixelArt.outline(rect), color: color, shadowOffset: shadowOffset, in: context)
            case let .text(text, at, color):
                drawText(text, at: at, color: color, in: context, style: style)
            }
            context.restoreGState()
        }
    }

    /// The same vector treatment is used by preview and export. It never snaps input geometry.
    private static func drawVector(_ annotation: Annotation, in context: CGContext, style: AnnotationStyle) {
        context.setShouldAntialias(true)
        context.setLineWidth(style.strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation {
        case let .rect(rect, color):
            context.setStrokeColor(color.cgColor)
            context.stroke(rect)
        case let .arrow(from, to, color):
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return }
            let unit = CGVector(dx: (to.x - from.x) / length, dy: (to.y - from.y) / length)
            let head = min(style.headLength, length)
            let base = CGPoint(x: to.x - unit.dx * head, y: to.y - unit.dy * head)
            context.setStrokeColor(color.cgColor)
            context.move(to: from)
            context.addLine(to: base)
            context.strokePath()
            context.setFillColor(color.cgColor)
            context.move(to: to)
            context.addLine(to: CGPoint(x: base.x - unit.dy * head * style.headSpread,
                                       y: base.y + unit.dx * head * style.headSpread))
            context.addLine(to: CGPoint(x: base.x + unit.dy * head * style.headSpread,
                                       y: base.y - unit.dx * head * style.headSpread))
            context.closePath()
            context.fillPath()
        case let .text(text, at, color):
            drawText(text, at: at, color: color, in: context, style: style)
        }
    }

    /// A one-cell line with a filled triangle head at `to`.
    private static func arrowCells(from: CGPoint, to: CGPoint, style: AnnotationStyle) -> [PixelArt.Cell] {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return [] }
        let unit = CGVector(dx: (to.x - from.x) / length, dy: (to.y - from.y) / length)
        let head = min(style.headLength, length)
        let base = CGPoint(x: to.x - unit.dx * head, y: to.y - unit.dy * head)
        let spread = head * style.headSpread
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

    private static func drawText(_ text: String, at point: CGPoint, color: AnnotationColor, in context: CGContext, style: AnnotationStyle) {
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            drawTextLine(line, at: CGPoint(x: point.x, y: point.y + CGFloat(index) * style.lineHeight), color: color, in: context, style: style)
        }
    }

    private static func drawTextLine(_ text: String, at point: CGPoint, color: AnnotationColor, in context: CGContext, style: AnnotationStyle) {
        let line = layout(text, style: style).line
        let halo = color == .white ? AnnotationColor.black : .white
        let baseline = style.baseline(at: point)
        // Glyphs are drawn y up, so flip them back in the y-down image space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        if case .vector = style.treatment {
            context.setShouldAntialias(true)
            context.setLineJoin(.round)
            context.setLineWidth(2 * style.textHaloWidth)
            context.setStrokeColor(halo.cgColor)
            context.setFillColor(color.cgColor)
            context.setTextDrawingMode(.fillStroke)
            context.textPosition = baseline
            CTLineDraw(line, context)
            // Restore the fill over the inner half of the halo stroke.
            context.setTextDrawingMode(.fill)
            context.textPosition = baseline
            CTLineDraw(line, context)
            return
        }

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

    /// The line box of a text annotation, in image space.
    static func textBounds(_ text: String, at point: CGPoint) -> CGRect {
        textBounds(text, at: point, style: pixelStyle)
    }

    static func textBounds(_ text: String, at point: CGPoint, style: AnnotationStyle) -> CGRect {
        let lines = text.components(separatedBy: "\n")
        let metrics = layout("Hg", style: style).metrics
        let width = lines.map { layout($0, style: style).metrics.width }.max() ?? 0
        let baseline = style.baseline(at: point)
        let box = CGRect(x: baseline.x, y: baseline.y - metrics.ascent, width: width,
                      height: metrics.ascent + metrics.descent + CGFloat(lines.count - 1) * style.lineHeight)
        switch style.treatment {
        case .cells: return box
        case .vector: return box.insetBy(dx: -style.textHaloWidth, dy: -style.textHaloWidth)
        }
    }

    /// The caret after `text` while it is typed, in image space.
    static func caret(after text: String, at point: CGPoint) -> CGRect {
        caret(after: text, at: point, style: pixelStyle)
    }

    static func caret(after text: String, at point: CGPoint, style: AnnotationStyle) -> CGRect {
        let lines = text.components(separatedBy: "\n")
        let width = layout(lines.last ?? "", style: style).metrics.width
        // Measured on sample letters, so the caret has a height before anything is typed.
        let baseline = style.baseline(at: CGPoint(x: point.x, y: point.y + CGFloat(lines.count - 1) * style.lineHeight))
        let metrics = layout("Hg", style: style).metrics
        return CGRect(x: baseline.x + width + 1, y: baseline.y - metrics.ascent,
                      width: 2, height: metrics.ascent + metrics.descent)
    }

    private static func layout(_ text: String, style: AnnotationStyle) -> (line: CTLine, metrics: (width: CGFloat, ascent: CGFloat, descent: CGFloat)) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): style.font,
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
        export(document, style: document.resolvedAnnotationStyle)
    }

    static func export(_ document: EditDocument, style: AnnotationStyle) -> CGImage? {
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
        draw(document.annotations, in: context, style: style)

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
