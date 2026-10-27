import AppKit
import VishotRendering
import VishotConfiguration

extension ColorScheme {
    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

struct ResolvedTheme {
    let definition: ThemeDefinition
    let id: ThemeID
    let colorScheme: ColorScheme
    let annotation: AnnotationStyle
    private let styles: ThemeStyles
    var hud: HUDStyle { styles.hud }
    var picker: PickerStyle { styles.picker }
    var selection: SelectionDrawingStyle { styles.selection }
    var editor: EditorStyle { styles.editor }
    var history: HistoryStyle { styles.history }
    var settings: SettingsStyle { styles.settings }
    var watermark: WatermarkStyle { styles.watermark }

    fileprivate init(definition: ThemeDefinition, colorScheme: ColorScheme, styles: ThemeStyles) {
        self.definition = definition
        id = definition.annotationID
        self.colorScheme = colorScheme
        annotation = AnnotationCatalog.annotation(definition.annotationID)
        self.styles = styles
    }
}

/// A complete interface look. Saved markup is selected separately by the definition.
struct ThemeStyles {
    let hud: HUDStyle
    let picker: PickerStyle
    let selection: SelectionDrawingStyle
    let editor: EditorStyle
    let history: HistoryStyle
    let settings: SettingsStyle
    let watermark: WatermarkStyle
}

struct ThemeDefinition {
    enum Appearances {
        case light, dark, both

        func resolve(_ requested: ColorScheme) -> ColorScheme {
            switch self {
            case .light: return .light
            case .dark: return .dark
            case .both: return requested
            }
        }
    }

    let id: String
    let label: String
    let annotationID: ThemeID
    let appearances: Appearances
    let makeStyles: (ColorScheme) -> ThemeStyles
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
    let disabledOpacity: Float
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
            let inner = rect.insetBy(dx: width, dy: width)
            // Reflect the symmetric inner contour to reverse its winding without changing
            // its geometry. CALayer.shadowPath uses nonzero fill, regardless of fillRule.
            let reverse = CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                           tx: inner.minX + inner.maxX, ty: 0)
            path.addRoundedRect(in: inner, cornerWidth: innerRadius, cornerHeight: innerRadius,
                                transform: reverse)
        }
        return path
    }

    /// Crop feedback stays outside the retained pixels. Pixel uses whole annotation cells.
    func cropPath(around crop: CGRect, width: CGFloat) -> CGPath {
        switch self {
        case .pixel:
            let cell = PixelArt.cell
            let minX = ((crop.minX / cell).rounded(.down) - 1) * cell
            let minY = ((crop.minY / cell).rounded(.down) - 1) * cell
            let maxX = ((crop.maxX / cell).rounded(.up) + 1) * cell
            let maxY = ((crop.maxY / cell).rounded(.up) + 1) * cell
            let path = CGMutablePath()
            path.addRects(PixelArt.outline(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)).map(PixelArt.rect))
            return path
        case .rounded:
            return path(around: crop.insetBy(dx: -width, dy: -width), width: width)
        }
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
    let hintBorder: NSColor
    let typedHintOpacity: CGFloat
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
    let activeText: NSColor
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
    let swatchLightText: NSColor
    let swatchDarkText: NSColor
    let cropHandleBorderWidth: CGFloat
    let cropHandleSize: CGFloat
    let cropHandleRadius: CGFloat
}

struct HistoryStyle {
    let backdrop: NSColor
    let background: NSColor
    let selected: NSColor
    let separator: NSColor
    let text: NSColor
    let muted: NSColor
    let font: NSFont
    let queryFont: NSFont
    let rowCornerRadius: CGFloat
    let outline: OutlineTreatment
    let selectedWidth: CGFloat
    let borderWidth: CGFloat
}

struct SettingsStyle {
    let appearance: NSAppearance
    /// Pixel retains the existing native Settings presentation.
    let usesNativeAppearance: Bool
    let background: NSColor
    let text: NSColor
    let muted: NSColor
    let accent: NSColor
    let font: NSFont
    let error: NSColor

    var labelColor: NSColor { usesNativeAppearance ? .labelColor : text }
    var secondaryLabelColor: NSColor { usesNativeAppearance ? .secondaryLabelColor : muted }

    /// Only app-owned content receives the fixed dark preset; window chrome stays native.
    func apply(to content: NSView) {
        content.appearance = appearance
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
    /// GUI registration list. Factories run at resolution time, after font registration.
    static let definitions = [PixelTheme.definition, SmoothTheme.definition]

    static func definition(for style: VisualStyle) -> ThemeDefinition {
        guard let definition = definitions.first(where: { $0.id == style.rawValue }) else {
            preconditionFailure("No GUI theme registered for \(style.rawValue)")
        }
        return definition
    }

    static func colorScheme(style: VisualStyle, requested: ColorScheme) -> ColorScheme {
        definition(for: style).appearances.resolve(requested)
    }

    static func resolve(style: VisualStyle, colorScheme: ColorScheme) -> ResolvedTheme {
        resolve(definition(for: style), colorScheme: colorScheme)
    }

    static func resolve(_ definition: ThemeDefinition, colorScheme: ColorScheme) -> ResolvedTheme {
        let scheme = definition.appearances.resolve(colorScheme)
        return ResolvedTheme(definition: definition, colorScheme: scheme, styles: definition.makeStyles(scheme))
    }

    static func resolve(_ definition: ThemeDefinition, appearance: AppearancePreference,
                        system: ColorScheme) -> ResolvedTheme {
        resolve(definition, colorScheme: appearance.resolve(system: system))
    }
    // Computed definitions avoid freezing fallback fonts before font registration. Owners keep the
    // resolved value for their lifetime; rendering never resolves resources or consults settings.
    static func resolve(_ id: ThemeID) -> ResolvedTheme {
        switch id {
        case .pixel: return pixel
        case .clean: return clean
        }
    }

    static var pixel: ResolvedTheme { resolve(style: .pixel, colorScheme: .dark) }
    static var clean: ResolvedTheme { resolve(style: .smooth, colorScheme: .dark) }

}
