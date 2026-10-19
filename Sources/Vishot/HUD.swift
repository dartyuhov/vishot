import AppKit

/// One entry in the HUD: its keys, drawn as keycaps, and what they do. No keys shows only the action.
struct HUDKey: Equatable {
    let keys: [String]
    let action: String
    let unavailableReason: String?
    var isEnabled: Bool { unavailableReason == nil }

    init(_ keys: String..., action: String, unavailableReason: String? = nil) {
        self.keys = keys
        self.action = action
        self.unavailableReason = unavailableReason
    }
}

/// What the picker's HUD and the editor's toolbar draw alike: the landing page's panel, a name in the
/// pixel font, and entries of keycaps followed by what they do.
enum HUD {
    private static let pixelStyle = ThemeCatalog.pixel.hud
    static let nameFont = pixelStyle.nameFont
    static let keyFont = pixelStyle.keycap.font
    static let textFont = pixelStyle.textFont
    static let padding = pixelStyle.padding
    static let lineGap = pixelStyle.lineGap
    static let shadow = pixelStyle.panel.shadowOffset.width
    /// After the name and between entries, between an entry's keys and what they do, and between two
    /// keys of one entry.
    static let entryGap = pixelStyle.entryGap
    static let actionGap = pixelStyle.actionGap
    static let keyGap = pixelStyle.keyGap

    /// An entry's layers. `faces` are its keycaps' faces, so a highlight can recolor them.
    struct Entry {
        let layer: CALayer
        let faces: [CALayer]
        let action: CATextLayer
    }

    /// The landing page's panels: square, a 2 pt edge and a hard shadow. Set `shadowPath` once sized.
    static func stylePanel(_ layer: CALayer) {
        stylePanel(layer, style: pixelStyle)
    }

    static func stylePanel(_ layer: CALayer, style: HUDStyle) {
        style.panel.apply(to: layer)
    }

    /// The name, its baseline on a whole device pixel, centred in a row `height` tall.
    static func makeName(_ name: String, rowHeight height: CGFloat, scale: CGFloat) -> CATextLayer {
        makeName(name, rowHeight: height, scale: scale, style: pixelStyle)
    }

    static func makeName(_ name: String, rowHeight height: CGFloat, scale: CGFloat, style: HUDStyle) -> CATextLayer {
        let text = makeText(name, font: style.nameFont, color: style.text, scale: scale)
        text.frame.origin.y = textY(style.nameFont, lineHeight: text.frame.height, in: height, scale: scale)
        return text
    }

    /// The entry's keycaps, separated by slashes, then what they do, in one layer as tall as a keycap.
    static func makeEntry(_ entry: HUDKey, scale: CGFloat) -> Entry {
        makeEntry(entry, scale: scale, style: pixelStyle)
    }

    static func makeEntry(_ entry: HUDKey, scale: CGFloat, style: HUDStyle) -> Entry {
        let layer = CALayer()
        layer.opacity = entry.isEnabled ? 1 : 0.45
        var parts: [(layer: CALayer, font: NSFont?, gap: CGFloat)] = []
        var faces: [CALayer] = []
        for (index, key) in entry.keys.enumerated() {
            if index > 0 { parts.append((makeText("/", font: style.textFont, color: style.dim, scale: scale), style.textFont, style.keyGap)) }
            let keycap = makeKeycap(key, scale: scale, style: style.keycap)
            faces.append(keycap.face)
            parts.append((keycap.edge, nil, index == 0 ? 0 : style.keyGap))
        }
        let action = makeText(entry.action, font: style.textFont, color: style.muted, scale: scale)
        parts.append((action, style.textFont, entry.keys.isEmpty ? 0 : style.actionGap))

        // Text carries its font, so its capitals can be centred; keycaps are centred by their frame.
        let height = parts.map(\.layer.frame.height).max() ?? 0
        var x: CGFloat = 0
        for (part, font, gap) in parts {
            x += gap
            let y = font.map { textY($0, lineHeight: part.frame.height, in: height, scale: scale) } ?? ((height - part.frame.height) / 2).rounded()
            part.frame.origin = CGPoint(x: x, y: y)
            layer.addSublayer(part)
            x += part.frame.width
        }
        layer.frame.size = CGSize(width: x, height: height)
        return Entry(layer: layer, faces: faces, action: action)
    }

    /// A key drawn like the landing page's `<kbd>`: a raised face on a darker edge, thicker at the bottom.
    static func makeKeycap(
        _ key: String, face color: NSColor = Palette.surfaceRaised, text textColor: NSColor = Palette.text, scale: CGFloat
    ) -> (edge: CALayer, face: CALayer) {
        makeKeycap(key, face: color, text: textColor, scale: scale, style: pixelStyle.keycap)
    }

    static func makeKeycap(
        _ key: String, face color: NSColor? = nil, text textColor: NSColor? = nil,
        scale: CGFloat, style: KeycapStyle
    ) -> (edge: CALayer, face: CALayer) {
        let text = makeText(key, font: style.font, color: textColor ?? style.text, scale: scale)
        let faceHeight = (style.font.capHeight + 2 * style.padding).rounded()
        let size = CGSize(width: max(text.frame.width + 2 * style.padding, faceHeight + 2), height: faceHeight + style.edgeHeight)
        let edge = CALayer()
        edge.backgroundColor = style.edge.cgColor
        edge.cornerRadius = style.cornerRadius
        edge.frame.size = size
        let face = CALayer()
        face.backgroundColor = (color ?? style.face).cgColor
        face.cornerRadius = max(0, style.cornerRadius - 1)
        face.frame = CGRect(x: 1, y: style.edgeHeight - 1, width: size.width - 2, height: faceHeight)
        text.frame.origin = CGPoint(
            x: ((face.frame.width - text.frame.width) / 2).rounded(),
            y: textY(style.font, lineHeight: text.frame.height, in: faceHeight, scale: scale)
        )
        face.addSublayer(text)
        edge.addSublayer(face)
        return (edge, face)
    }

    /// A status line: muted, cut off with an ellipsis. Set its frame and string.
    static func makeStatus(scale: CGFloat) -> CATextLayer {
        makeStatus(scale: scale, style: pixelStyle)
    }

    static func makeStatus(scale: CGFloat, style: HUDStyle) -> CATextLayer {
        let layer = CATextLayer()
        configure(layer, font: style.textFont, color: style.muted, scale: scale)
        return layer
    }

    static func makeText(_ string: String, font: NSFont, color: NSColor, scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        configure(layer, font: font, color: color, scale: scale)
        layer.string = string
        layer.frame.size = textSize(string, font: font)
        return layer
    }

    static func configure(_ layer: CATextLayer, font: NSFont, color: NSColor, scale: CGFloat) {
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.contentsScale = scale
        layer.truncationMode = .end
    }

    static func textSize(_ text: String, font: NSFont) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The y of a text layer `lineHeight` tall that centres `font`'s capitals in a box `height` tall, with
    /// the baseline on a whole device pixel so the pixel font's glyphs stay sharp. CATextLayer puts the
    /// baseline one ascender below the layer's top.
    static func textY(_ font: NSFont, lineHeight: CGFloat, in height: CGFloat, scale: CGFloat) -> CGFloat {
        let baseline = ((height - font.capHeight) / 2 * scale).rounded() / scale
        return baseline + font.ascender - lineHeight
    }
}
