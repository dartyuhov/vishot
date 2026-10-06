import CoreGraphics
import CoreText
import Foundation

/// The "vishot.dev" badge in the bottom-right corner of every copied or saved image: light bold text on
/// a dark rounded pill, so it reads on any content.
enum Watermark {
    static let text = "vishot.dev"
    /// From the image's right and bottom edges, in points.
    static let margin: CGFloat = 12
    private static let padding = CGSize(width: 10, height: 5)
    private static let cornerRadius: CGFloat = 8
    private static let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 13, nil)!
    private static let fill = CGColor(srgbRed: 0.07, green: 0.09, blue: 0.13, alpha: 0.85)
    private static let textColor = CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)

    /// `image` with the badge drawn in, or `image` itself when it is too small for one or drawing fails.
    static func apply(to image: CGImage, scale: CGFloat) -> CGImage {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let badge = badgeRect(in: size),
              let context = AnnotationRenderer.imageSpaceContext(drawing: image, scale: scale)
        else { return image }

        context.addPath(CGPath(roundedRect: badge, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.setFillColor(fill)
        context.fillPath()

        let (line, metrics) = layout()
        // Glyphs are drawn y up, so flip them back in the y-down image space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: badge.minX + padding.width, y: badge.midY + (metrics.ascent - metrics.descent) / 2)
        context.setFillColor(textColor)
        CTLineDraw(line, context)
        return context.makeImage() ?? image
    }

    /// The badge in image space (points, y down), or nil when it and its margins would take more than
    /// half the image's width or height, as on a capture of a single button.
    static func badgeRect(in imageSize: CGSize) -> CGRect? {
        let metrics = layout().metrics
        let width = metrics.width.rounded(.up) + 2 * padding.width
        let height = (metrics.ascent + metrics.descent).rounded(.up) + 2 * padding.height
        guard 2 * (width + margin) <= imageSize.width, 2 * (height + margin) <= imageSize.height else { return nil }
        return CGRect(x: imageSize.width - margin - width, y: imageSize.height - margin - height, width: width, height: height)
    }

    private static func layout() -> (line: CTLine, metrics: (width: CGFloat, ascent: CGFloat, descent: CGFloat)) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return (line, (width, ascent, descent))
    }
}
