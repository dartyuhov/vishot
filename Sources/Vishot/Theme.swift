import AppKit
import CoreText

/// Stable persisted identities. Resolve once off the hotkey path and pass the value to consumers;
/// there is deliberately no mutable "current theme" here.
enum ThemeID: String, Codable, CaseIterable {
    case pixel
    case clean

    var label: String {
        switch self {
        case .pixel: return "Pixel"
        case .clean: return "Clean"
        }
    }
}

struct ResolvedTheme {
    let id: ThemeID
    let hud: HUDStyle
    let picker: PickerStyle
    let selection: SelectionDrawingStyle
    let editor: EditorStyle
    let history: HistoryStyle
    let settings: SettingsStyle
    let annotation: AnnotationStyle
    let watermark: WatermarkStyle
}

struct PanelStyle {
    let background: NSColor
    let border: NSColor
    let borderWidth: CGFloat
    let cornerRadius: CGFloat
    let shadow: NSColor
    let shadowRadius: CGFloat
    /// In layer coordinates (y up).
    let shadowOffset: CGSize

    func apply(to layer: CALayer) {
        layer.backgroundColor = background.cgColor
        layer.borderColor = border.cgColor
        layer.borderWidth = borderWidth
        layer.cornerRadius = cornerRadius
        layer.shadowColor = shadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = shadowOffset
    }

    func path(in rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}

struct KeycapStyle {
    let font: NSFont
    let face: NSColor
    let text: NSColor
    let edge: NSColor
    let padding: CGFloat
    let cornerRadius: CGFloat
    let edgeHeight: CGFloat
}

struct HUDStyle {
    let panel: PanelStyle
    let keycap: KeycapStyle
    let nameFont: NSFont
    let textFont: NSFont
    let text: NSColor
    let muted: NSColor
    let dim: NSColor
    let padding: CGSize
    let lineGap: CGFloat
    let entryGap: CGFloat
    let actionGap: CGFloat
    let keyGap: CGFloat
}

/// Ring geometry is a drawing treatment, independent of the theme identity and input geometry.
enum OutlineTreatment {
    case pixel(corner: CGFloat)
    case rounded(radius: CGFloat)

    func path(around rect: CGRect, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch self {
        case let .pixel(corner):
            path.addPixelRoundedRect(rect, pixel: corner)
            path.addPixelRoundedRect(rect.insetBy(dx: width, dy: width), pixel: corner)
        case let .rounded(radius):
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            let innerRadius = max(0, radius - width)
            path.addRoundedRect(in: rect.insetBy(dx: width, dy: width),
                                cornerWidth: innerRadius, cornerHeight: innerRadius)
        }
        return path
    }
}

struct PickerStyle {
    let accent: NSColor
    let outline: OutlineTreatment
    let borderWidth: CGFloat
    let label: PanelStyle
    let labelFont: NSFont
    let labelText: NSColor
    let labelPadding: CGSize
    let labelInset: CGFloat
    let hintFont: NSFont
    let hintText: NSColor
    let hintLeaf: NSColor
    let hintContainers: [NSColor]
    let hintPadding: CGSize
    let hintCornerRadius: CGFloat
    let hintBorderWidth: CGFloat
    let hintOutlineWidth: CGFloat
    let hudBottomInset: CGFloat
    let panelBackground: NSColor
}

struct SelectionDrawingStyle {
    let outsideDim: NSColor
    let arm: CGFloat
    let gap: CGFloat
    let foreground: NSColor
    let outline: NSColor
    let width: CGFloat
    let outlineWidth: CGFloat
    let lineCap: CAShapeLayerLineCap
}

struct EditorStyle {
    let active: NSColor
    let cropped: NSColor
    let cropDim: NSColor
    let cropOutline: OutlineTreatment
    let cropWidth: CGFloat
    let cropShadow: NSColor
    let cropShadowRadius: CGFloat
    let cropShadowOffset: CGSize
    let caretBorder: NSColor
    let caretBorderWidth: CGFloat
    let swatchRing: CGFloat
}

struct HistoryStyle {
    let background: NSColor
    let selected: NSColor
    let separator: NSColor
    let text: NSColor
    let muted: NSColor
    let font: NSFont
    let queryFont: NSFont
    let rowCornerRadius: CGFloat
}

struct SettingsStyle {
    /// Pixel retains the existing native Settings presentation.
    let usesNativeAppearance: Bool
    let background: NSColor
    let text: NSColor
    let muted: NSColor
    let accent: NSColor
    let font: NSFont

    var labelColor: NSColor { usesNativeAppearance ? .labelColor : text }
    var secondaryLabelColor: NSColor { usesNativeAppearance ? .secondaryLabelColor : muted }

    /// Only app-owned content receives the fixed dark preset; window chrome stays native.
    func apply(to content: NSView) {
        content.appearance = usesNativeAppearance ? nil : NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = usesNativeAppearance ? nil : background.cgColor
        applyControls(in: content)
    }

    private func applyControls(in view: NSView) {
        if let label = view as? NSTextField {
            label.textColor = (label.font?.pointSize ?? font.pointSize) <= 12 ? secondaryLabelColor : labelColor
        }
        if let control = view as? NSButton {
            control.contentTintColor = usesNativeAppearance ? nil : accent
        }
        for child in view.subviews { applyControls(in: child) }
    }
}

struct AnnotationStyle {
    enum Treatment { case cells, vector }
    let treatment: Treatment
    let font: CTFont
    let lineHeight: CGFloat
    let strokeWidth: CGFloat
    let headLength: CGFloat
    let headSpread: CGFloat

    func baseline(at point: CGPoint) -> CGPoint {
        let baseline = CGPoint(x: point.x, y: point.y + CTFontGetCapHeight(font) / 2)
        switch treatment {
        case .cells: return PixelArt.snapped(baseline)
        case .vector: return baseline
        }
    }
}

struct WatermarkStyle {
    enum Treatment { case pixelGlyphs, systemText }
    let treatment: Treatment
    let plate: PanelStyle
    let text: NSColor
    let font: NSFont
    let padding: CGSize
    let margin: CGFloat
}

enum ThemeCatalog {
    // Computed definitions avoid freezing fallback fonts before Fonts.register(). Owners keep the
    // resolved value for their lifetime; rendering never resolves resources or consults settings.
    static func resolve(_ id: ThemeID) -> ResolvedTheme {
        switch id {
        case .pixel: return pixel
        case .clean: return clean
        }
    }

    static var pixel: ResolvedTheme { make(clean: false) }
    static var clean: ResolvedTheme { make(clean: true) }

    private static func make(clean: Bool) -> ResolvedTheme {
        let surface = clean ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1) : Palette.surface
        let raised = clean ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1) : Palette.surfaceRaised
        let line = clean ? NSColor(srgbRed: 0.27, green: 0.27, blue: 0.31, alpha: 1) : Palette.line
        let text = Palette.text
        let muted = Palette.textMuted
        let panel = PanelStyle(background: surface, border: line, borderWidth: clean ? 1 : 2,
            cornerRadius: clean ? 10 : 0, shadow: Palette.shadow, shadowRadius: clean ? 12 : 0,
            shadowOffset: CGSize(width: clean ? 0 : 4, height: -4))
        let keycap = KeycapStyle(font: clean ? .monospacedSystemFont(ofSize: 12, weight: .semibold) : Fonts.mono(12, bold: true),
            face: raised, text: text, edge: line, padding: 5, cornerRadius: clean ? 4 : 0, edgeHeight: clean ? 2 : 4)
        let hud = HUDStyle(panel: panel, keycap: keycap,
            nameFont: clean ? .systemFont(ofSize: 14, weight: .semibold) : Fonts.pixel(),
            textFont: clean ? .systemFont(ofSize: 12) : Fonts.mono(12), text: text, muted: muted, dim: Palette.textDim,
            padding: CGSize(width: 14, height: 10), lineGap: 8, entryGap: 18, actionGap: 6, keyGap: 3)
        let label = PanelStyle(background: Palette.accent, border: .clear, borderWidth: 0,
            cornerRadius: clean ? 5 : 0, shadow: clean ? Palette.shadow : Palette.hintLeaf,
            shadowRadius: clean ? 6 : 0, shadowOffset: CGSize(width: clean ? 0 : 2, height: -2))
        let annotationFont = clean ? NSFont.systemFont(ofSize: 24, weight: .semibold) : Fonts.pixel(24)
        let font = annotationFont as CTFont
        let fontHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return ResolvedTheme(id: clean ? .clean : .pixel, hud: hud,
            picker: PickerStyle(accent: Palette.accent,
                outline: clean ? .rounded(radius: 6) : .pixel(corner: 4), borderWidth: clean ? 2 : 4,
                label: label, labelFont: clean ? .systemFont(ofSize: 13, weight: .semibold) : Fonts.pixel(),
                labelText: .white, labelPadding: CGSize(width: 8, height: 2), labelInset: 10,
                hintFont: clean ? .monospacedSystemFont(ofSize: 11, weight: .semibold) : Fonts.mono(11, bold: true),
                hintText: Palette.ink, hintLeaf: Palette.hintLeaf, hintContainers: Palette.hintContainers,
                hintPadding: CGSize(width: 4, height: 1), hintCornerRadius: clean ? 3 : 0,
                hintBorderWidth: 0.5, hintOutlineWidth: clean ? 1 : 2, hudBottomInset: 24,
                panelBackground: NSColor(white: 0, alpha: 0.01)),
            selection: SelectionDrawingStyle(outsideDim: NSColor(white: 0, alpha: 0.45), arm: 12, gap: 3,
                foreground: .white, outline: NSColor(white: 0, alpha: 0.75), width: 2, outlineWidth: 4,
                lineCap: clean ? .round : .square),
            editor: EditorStyle(active: Palette.accent, cropped: .white, cropDim: NSColor(white: 0, alpha: 0.45),
                cropOutline: clean ? .rounded(radius: 3) : .pixel(corner: 3), cropWidth: 3,
                cropShadow: NSColor(white: 0, alpha: 0.35), cropShadowRadius: clean ? 3 : 0,
                cropShadowOffset: CGSize(width: clean ? 0 : 3, height: -3),
                caretBorder: NSColor(white: 1, alpha: 0.8), caretBorderWidth: 0.5, swatchRing: 2),
            history: HistoryStyle(background: surface, selected: Palette.accent, separator: line,
                text: .white, muted: muted, font: clean ? .systemFont(ofSize: 14) : Fonts.mono(14),
                queryFont: clean ? .systemFont(ofSize: 13) : Fonts.mono(13), rowCornerRadius: clean ? 6 : 0),
            settings: SettingsStyle(usesNativeAppearance: !clean, background: surface, text: text,
                muted: muted, accent: Palette.accent, font: .systemFont(ofSize: 13)),
            annotation: AnnotationStyle(treatment: clean ? .vector : .cells, font: font,
                lineHeight: clean ? ceil(fontHeight) + 3 : ceil(fontHeight / 3) * 3 + 3,
                strokeWidth: 3, headLength: 24, headSpread: 0.6),
            watermark: WatermarkStyle(treatment: clean ? .systemText : .pixelGlyphs,
                plate: PanelStyle(background: Palette.ink, border: .clear, borderWidth: 0,
                    cornerRadius: clean ? 5 : 0, shadow: clean ? Palette.shadow : Palette.hintLeaf,
                    shadowRadius: clean ? 4 : 0, shadowOffset: CGSize(width: clean ? 0 : 2, height: -2)),
                text: text, font: .systemFont(ofSize: 12, weight: .semibold),
                padding: CGSize(width: 8, height: 6), margin: 12))
    }
}
