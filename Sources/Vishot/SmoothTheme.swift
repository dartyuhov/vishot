import AppKit
import VishotConfiguration

enum SmoothTheme {
    static let definition = ThemeDefinition(id: "smooth", label: "Smooth",
        annotationID: VisualStyle.smooth.annotationID, appearances: .both, makeStyles: makeStyles)

    private static func makeStyles(_ colorScheme: ColorScheme) -> ThemeStyles {
        let light = colorScheme == .light
        let surface = light ? NSColor(srgbRed: 0.97, green: 0.96, blue: 0.99, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        let raised = light ? NSColor.white : NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1)
        let line = light ? NSColor(srgbRed: 0.73, green: 0.71, blue: 0.78, alpha: 1)
            : NSColor(srgbRed: 0.27, green: 0.27, blue: 0.31, alpha: 1)
        let text = light ? Palette.ink : Palette.text
        let muted = light ? NSColor(srgbRed: 0.35, green: 0.33, blue: 0.40, alpha: 1) : Palette.textMuted
        let panel = PanelStyle(background: surface, border: line, borderWidth: 1,
            cornerRadius: 10, shadow: Palette.shadow, shadowRadius: 12,
            shadowOffset: CGSize(width: 0, height: -4))
        let keycap = KeycapStyle(font: .monospacedSystemFont(ofSize: 12, weight: .semibold),
            face: raised, text: text, edge: line, padding: 5, cornerRadius: 4, edgeHeight: 2)
        let hud = HUDStyle(panel: panel, keycap: keycap,
            nameFont: .systemFont(ofSize: 14, weight: .semibold),
            textFont: .systemFont(ofSize: 12), text: text, muted: muted, dim: muted,
            padding: CGSize(width: 14, height: 10), lineGap: 8, entryGap: 18, actionGap: 6, keyGap: 3, disabledOpacity: 0.35)
        let label = PanelStyle(background: Palette.accent, border: .clear, borderWidth: 0,
            cornerRadius: 5, shadow: Palette.shadow,
            shadowRadius: 6, shadowOffset: CGSize(width: 0, height: -2))
        return ThemeStyles(hud: hud,
            picker: PickerStyle(accent: Palette.accent,
                outline: .rounded(radius: 6), borderWidth: 2,
                label: label, labelFont: .systemFont(ofSize: 13, weight: .semibold),
                labelText: .white, labelPadding: CGSize(width: 8, height: 2), labelInset: 10,
                hintFont: .monospacedSystemFont(ofSize: 11, weight: .semibold),
                hintText: Palette.ink, hintLeaf: Palette.hintLeaf, hintContainers: Palette.hintContainers,
                hintPadding: CGSize(width: 4, height: 1), hintCornerRadius: 3,
                hintBorderWidth: 0.5, hintBorder: NSColor(white: 0, alpha: 0.4), typedHintOpacity: 0.35,
                hintOutlineWidth: 1, hudBottomInset: 24,
                panelBackground: NSColor(white: 0, alpha: 0.01)),
            selection: SelectionDrawingStyle(outsideDim: NSColor(white: 0, alpha: 0.45), arm: 12, gap: 3,
                foreground: .white, outline: NSColor(white: 0, alpha: 0.75), width: 2, outlineWidth: 4,
                lineCap: .round),
            editor: EditorStyle(active: Palette.accent, activeText: .white, cropped: .white, cropDim: NSColor(white: 0, alpha: 0.45),
                cropOutline: .rounded(radius: 3), cropWidth: 3,
                cropShadow: NSColor(white: 0, alpha: 0.35), cropShadowRadius: 3,
                cropShadowOffset: CGSize(width: 0, height: -3),
                caretBorder: NSColor(white: 1, alpha: 0.8), caretBorderWidth: 0.5, swatchRing: 2,
                swatchLightText: .white, swatchDarkText: Palette.ink,
                cropHandleBorderWidth: 1, cropHandleSize: 10, cropHandleRadius: 3),
            history: HistoryStyle(backdrop: surface,
                background: raised, selected: Palette.accent, separator: line,
                text: text, muted: muted, font: .systemFont(ofSize: 14),
                queryFont: .systemFont(ofSize: 13), rowCornerRadius: 6,
                outline: .rounded(radius: 6), selectedWidth: 2, borderWidth: 1),
            settings: SettingsStyle(appearance: colorScheme.appearance, usesNativeAppearance: false,
                background: surface, text: text, muted: muted, accent: Palette.accent,
                font: .systemFont(ofSize: 13), error: .systemRed),
            watermark: WatermarkStyle(treatment: .systemText,
                plate: PanelStyle(background: Palette.ink, border: .clear, borderWidth: 0,
                    cornerRadius: 5, shadow: Palette.shadow,
                    shadowRadius: 4, shadowOffset: CGSize(width: 0, height: -2)),
                text: Palette.text, font: .systemFont(ofSize: 12, weight: .semibold),
                padding: CGSize(width: 8, height: 6), margin: 12))
    }
}
