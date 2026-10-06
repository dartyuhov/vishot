import CoreGraphics
import CoreText
import Foundation

/// Draws annotations. The on-screen layers and the export both call `draw`, so what you see is what
/// you get.
enum AnnotationRenderer {
    private static let lineWidth: CGFloat = 4
    private static let headLength: CGFloat = 18
    /// Half the head's width, relative to its length.
    private static let headSpread: CGFloat = 0.6
    private static let haloWidth: CGFloat = 3
    private static let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 20, nil)!

    /// Draws in image space: the context's user space must have its origin at the image's top-left,
    /// y down, in points.
    static func draw(_ annotations: [Annotation], in context: CGContext) {
        // Shadows are set in device space, so the 1 pt offset is converted, and points down on screen.
        let ctm = context.ctm
        let pixelsPerPoint = hypot(ctm.a, ctm.b)
        let shadowOffset = CGSize(width: 0, height: 1).applying(ctm)
        for annotation in annotations {
            context.saveGState()
            context.setShadow(
                offset: shadowOffset, blur: 2 * pixelsPerPoint,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)
            )
            // One shadow for the whole annotation, not one per stroke and fill.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            switch annotation {
            case let .arrow(from, to, color): drawArrow(from: from, to: to, color: color, in: context)
            case let .rect(rect, color): drawRect(rect, color: color, in: context)
            case let .text(text, at, color): drawText(text, at: at, color: color, in: context)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: AnnotationColor, in context: CGContext) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return }
        let unit = CGVector(dx: (to.x - from.x) / length, dy: (to.y - from.y) / length)
        let head = min(headLength, length)
        let base = CGPoint(x: to.x - unit.dx * head, y: to.y - unit.dy * head)
        let spread = head * headSpread

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        if length > head {
            // Ends inside the head, so the round cap doesn't show past its sides or tip.
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.move(to: from)
            context.addLine(to: CGPoint(x: base.x + unit.dx * head / 3, y: base.y + unit.dy * head / 3))
            context.strokePath()
        }
        context.move(to: to)
        context.addLine(to: CGPoint(x: base.x - unit.dy * spread, y: base.y + unit.dx * spread))
        context.addLine(to: CGPoint(x: base.x + unit.dy * spread, y: base.y - unit.dx * spread))
        context.closePath()
        context.fillPath()
    }

    private static func drawRect(_ rect: CGRect, color: AnnotationColor, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.stroke(rect)
    }

    private static func drawText(_ text: String, at point: CGPoint, color: AnnotationColor, in context: CGContext) {
        let (line, metrics) = layout(text)
        let halo = color == .white ? AnnotationColor.black : .white
        let baseline = CGPoint(x: point.x, y: point.y + (metrics.ascent - metrics.descent) / 2)
        // Glyphs are drawn y up, so flip them back in the y-down image space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // The stroke is centred on the outline, so it is twice the halo's width.
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(halo.cgColor)
        context.setLineWidth(2 * haloWidth)
        context.setLineJoin(.round)
        context.textPosition = baseline
        CTLineDraw(line, context)

        context.setTextDrawingMode(.fill)
        context.setFillColor(color.cgColor)
        context.textPosition = baseline
        CTLineDraw(line, context)
    }

    /// The line box of a text annotation, in image space.
    static func textBounds(_ text: String, at point: CGPoint) -> CGRect {
        let metrics = layout(text).metrics
        let height = metrics.ascent + metrics.descent
        return CGRect(x: point.x, y: point.y - height / 2, width: metrics.width, height: height)
    }

    /// The caret after `text` while it is typed, in image space.
    static func caret(after text: String, at point: CGPoint) -> CGRect {
        let width = text.isEmpty ? 0 : layout(text).metrics.width
        // Measured on sample letters, so the caret has a height before anything is typed.
        let height = textBounds("Hg", at: point).height
        return CGRect(x: point.x + width + 1, y: point.y - height / 2, width: 2, height: height)
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
