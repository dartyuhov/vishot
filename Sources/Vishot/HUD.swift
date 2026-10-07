import AppKit

/// One entry in the HUD: its keys, drawn as keycaps, and what they do. No keys shows only the action.
struct HUDKey: Equatable {
    let keys: [String]
    let action: String

    init(_ keys: String..., action: String) {
        self.keys = keys
        self.action = action
    }
}

/// What the picker's HUD and the editor's toolbar draw alike: the landing page's panel, a name in the
/// pixel font, and entries of keycaps followed by what they do.
enum HUD {
    static let nameFont = Fonts.pixel()
    static let keyFont = Fonts.mono(12, bold: true)
    static let textFont = Fonts.mono(12)
    static let padding = CGSize(width: 14, height: 10)
    static let lineGap: CGFloat = 8
    static let shadow: CGFloat = 4
    /// After the name and between entries, between an entry's keys and what they do, and between two
    /// keys of one entry.
    static let entryGap: CGFloat = 18
    static let actionGap: CGFloat = 6
    static let keyGap: CGFloat = 3
    private static let keycapPadding: CGFloat = 5

    /// An entry's layers. `faces` are its keycaps' faces, so a highlight can recolor them.
    struct Entry {
        let layer: CALayer
        let faces: [CALayer]
        let action: CATextLayer
    }

    /// The landing page's panels: square, a 2 pt edge and a hard shadow. Set `shadowPath` once sized.
    static func stylePanel(_ layer: CALayer) {
        layer.backgroundColor = Palette.surface.cgColor
        layer.borderColor = Palette.line.cgColor
        layer.borderWidth = 2
        layer.shadowColor = Palette.shadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: shadow, height: -shadow)
    }

    /// The name, its baseline on a whole device pixel, centred in a row `height` tall.
    static func makeName(_ name: String, rowHeight height: CGFloat, scale: CGFloat) -> CATextLayer {
        let text = makeText(name, font: nameFont, color: Palette.text, scale: scale)
        text.frame.origin.y = textY(nameFont, lineHeight: text.frame.height, in: height, scale: scale)
        return text
    }

    /// The entry's keycaps, separated by slashes, then what they do, in one layer as tall as a keycap.
    static func makeEntry(_ entry: HUDKey, scale: CGFloat) -> Entry {
        let layer = CALayer()
        var parts: [(layer: CALayer, font: NSFont?, gap: CGFloat)] = []
        var faces: [CALayer] = []
        for (index, key) in entry.keys.enumerated() {
            if index > 0 { parts.append((makeText("/", font: textFont, color: Palette.textDim, scale: scale), textFont, keyGap)) }
            let keycap = makeKeycap(key, scale: scale)
            faces.append(keycap.face)
            parts.append((keycap.edge, nil, index == 0 ? 0 : keyGap))
        }
        let action = makeText(entry.action, font: textFont, color: Palette.textMuted, scale: scale)
        parts.append((action, textFont, entry.keys.isEmpty ? 0 : actionGap))

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
        let text = makeText(key, font: keyFont, color: textColor, scale: scale)
        let faceHeight = (keyFont.capHeight + 2 * keycapPadding).rounded()
        let size = CGSize(width: max(text.frame.width + 2 * keycapPadding, faceHeight + 2), height: faceHeight + 4)
        let edge = CALayer()
        edge.backgroundColor = Palette.line.cgColor
        edge.frame.size = size
        let face = CALayer()
        face.backgroundColor = color.cgColor
        face.frame = CGRect(x: 1, y: 3, width: size.width - 2, height: faceHeight)
        text.frame.origin = CGPoint(
            x: ((face.frame.width - text.frame.width) / 2).rounded(),
            y: textY(keyFont, lineHeight: text.frame.height, in: faceHeight, scale: scale)
        )
        face.addSublayer(text)
        edge.addSublayer(face)
        return (edge, face)
    }

    /// A status line: muted, cut off with an ellipsis. Set its frame and string.
    static func makeStatus(scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        configure(layer, font: textFont, color: Palette.textMuted, scale: scale)
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
