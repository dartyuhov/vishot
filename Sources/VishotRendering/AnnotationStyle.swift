import AppKit
import CoreText

/// Stable persisted annotation presets, independent of selectable interface identities.
public enum ThemeID: String, Codable, CaseIterable {
    case pixel
    case clean
}

public struct AnnotationStyle {
    public enum Treatment { case cells, vector }
    public let treatment: Treatment
    public let font: CTFont
    public let lineHeight: CGFloat
    public let strokeWidth: CGFloat
    public let headLength: CGFloat
    public let headSpread: CGFloat
    public let textHaloWidth: CGFloat
    public let shadow: CGColor
    /// Interactive Pixel aiming snaps to cells; externally anchored pixel coordinates are exact.
    public var snapsTextToGrid = true

    public func baseline(at point: CGPoint) -> CGPoint {
        let baseline = CGPoint(x: point.x, y: point.y + CTFontGetCapHeight(font) / 2)
        switch treatment {
        case .cells: return snapsTextToGrid ? PixelArt.snapped(baseline) : baseline
        case .vector: return baseline
        }
    }
}

public enum AnnotationCatalog {
    /// Resolve after registering fonts; callers retain the value for their document/session.
    public static func annotation(_ id: ThemeID) -> AnnotationStyle {
        switch id {
        case .pixel:
            let font = Fonts.pixel(24) as CTFont
            let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            return AnnotationStyle(treatment: .cells, font: font,
                lineHeight: ceil(height / 3) * 3 + 3, strokeWidth: 3,
                headLength: 24, headSpread: 0.6, textHaloWidth: 1,
                shadow: NSColor(white: 0, alpha: 0.35).cgColor)
        case .clean:
            let font = NSFont.systemFont(ofSize: 24, weight: .semibold) as CTFont
            let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            return AnnotationStyle(treatment: .vector, font: font,
                lineHeight: ceil(height) + 3, strokeWidth: 3,
                headLength: 18, headSpread: 0.45, textHaloWidth: 1,
                shadow: NSColor(white: 0, alpha: 0.35).cgColor)
        }
    }
}
