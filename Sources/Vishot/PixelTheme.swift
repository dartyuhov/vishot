import AppKit
import VishotRendering
import VishotConfiguration

enum PixelTheme {
    static let definition = ThemeDefinition(id: "pixel", label: "Pixel",
        annotationID: VisualStyle.pixel.annotationID, appearances: .both, makeStyles: makeStyles)

    private static func makeStyles(_ colorScheme: ColorScheme) -> ThemeStyles {
        let light = colorScheme == .light
        let surface = light ? NSColor(srgbRed: 0.97, green: 0.96, blue: 0.99, alpha: 1) : Palette.surface
        let raised = light ? NSColor.white : Palette.surfaceRaised
        let line = light ? NSColor(srgbRed: 0.73, green: 0.71, blue: 0.78, alpha: 1) : Palette.line
        let text = light ? Palette.ink : Palette.text
        let muted = light ? NSColor(srgbRed: 0.35, green: 0.33, blue: 0.40, alpha: 1) : Palette.textMuted
        let panel = PanelStyle(background: surface, border: line, borderWidth: 2,
            cornerRadius: 0, shadow: Palette.shadow, shadowRadius: 0,
            shadowOffset: CGSize(width: 4, height: -4))
        let keycap = KeycapStyle(font: Fonts.mono(12, bold: true),
            face: raised, text: text, edge: line, padding: 5, cornerRadius: 0, edgeHeight: 4)
        let hud = HUDStyle(panel: panel, keycap: keycap,
            nameFont: Fonts.pixel(), textFont: Fonts.mono(12), text: text, muted: muted, dim: muted,
            padding: CGSize(width: 14, height: 10), lineGap: 8, entryGap: 18, actionGap: 6, keyGap: 3, disabledOpacity: 0.35)
        let label = PanelStyle(background: Palette.accent, border: .clear, borderWidth: 0,
            cornerRadius: 0, shadow: Palette.hintLeaf,
            shadowRadius: 0, shadowOffset: CGSize(width: 2, height: -2))
        return ThemeStyles(hud: hud,
            picker: PickerStyle(accent: Palette.accent,
                outline: .pixel(corner: 4), borderWidth: 4,
                label: label, labelFont: Fonts.pixel(),
                labelText: .white, labelPadding: CGSize(width: 8, height: 2), labelInset: 10,
                hintFont: Fonts.mono(11, bold: true),
                hintText: Palette.ink, hintLeaf: Palette.hintLeaf, hintContainers: Palette.hintContainers,
                hintPadding: CGSize(width: 4, height: 1), hintCornerRadius: 0,
                hintBorderWidth: 0.5, hintBorder: NSColor(white: 0, alpha: 0.4), typedHintOpacity: 0.35,
                hintOutlineWidth: 2, hudBottomInset: 24,
                panelBackground: NSColor(white: 0, alpha: 0.01)),
            selection: SelectionDrawingStyle(outsideDim: NSColor(white: 0, alpha: 0.45), arm: 12, gap: 3,
                foreground: .white, outline: NSColor(white: 0, alpha: 0.75), width: 2, outlineWidth: 4,
                lineCap: .square),
            editor: EditorStyle(active: Palette.accent, activeText: .white, cropped: .white, cropDim: NSColor(white: 0, alpha: 0.45),
                cropOutline: .pixel(corner: 3), cropWidth: 3,
                cropShadow: NSColor(white: 0, alpha: 0.35), cropShadowRadius: 0,
                cropShadowOffset: CGSize(width: 3, height: -3),
                caretBorder: NSColor(white: 1, alpha: 0.8), caretBorderWidth: 0.5, swatchRing: 2,
                swatchLightText: .white, swatchDarkText: Palette.ink,
                cropHandleBorderWidth: 2, cropHandleSize: 10, cropHandleRadius: 0),
            history: HistoryStyle(backdrop: light ? surface : NSColor(white: 0, alpha: 0.78),
                background: surface, selected: Palette.accent, separator: line,
                text: text, muted: muted, font: Fonts.mono(14),
                queryFont: Fonts.mono(13), rowCornerRadius: 0,
                outline: .pixel(corner: 4), selectedWidth: 4, borderWidth: 2),
            settings: SettingsStyle(appearance: colorScheme.appearance, usesNativeAppearance: false,
                background: surface, text: text, muted: muted, accent: Palette.accent,
                font: .systemFont(ofSize: 13), error: .systemRed),
            watermark: WatermarkStyle(treatment: .pixelGlyphs,
                plate: PanelStyle(background: Palette.ink, border: .clear, borderWidth: 0,
                    cornerRadius: 0, shadow: Palette.hintLeaf,
                    shadowRadius: 0, shadowOffset: CGSize(width: 2, height: -2)),
                text: Palette.text, font: .systemFont(ofSize: 12, weight: .semibold),
                padding: CGSize(width: 8, height: 6), margin: 12))
    }
}
