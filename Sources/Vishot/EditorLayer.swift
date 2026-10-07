import AppKit

private enum Style {
    static let cropDim = NSColor(white: 0, alpha: 0.7)
    /// The crop's outline: accent while it is drawn, then white.
    static let cropping = Palette.accent
    static let cropped = NSColor.white
    /// A rectangle annotation's shadow, one cell down and right.
    static let cropShadow = NSColor(white: 0, alpha: 0.35)
    static let accent = Palette.accent

    /// Between the image and the toolbar, and between the toolbar and the screen edge.
    static let margin: CGFloat = 12
    static let floatingInset: CGFloat = 24
    /// Around the selected swatch.
    static let swatchRing: CGFloat = 2
}

/// The editor on one panel: the frozen image, its annotations, the dimming around it, the cursor and,
/// on one screen, the toolbar. Built with the panel and hidden until editing.
final class EditorLayer: NSObject, CALayerDelegate {
    let root = CALayer()
    private let image = CALayer()
    private let annotations = CALayer()
    private let cropDim = SelectionStyle.makeDim(Style.cropDim)
    private let cropOutline = CAShapeLayer()
    private let outsideDim = SelectionStyle.makeDim()
    private let crosshair = SelectionStyle.makeCrosshair()
    private let caret = CALayer()
    private let toolbar: EditorToolbar

    /// What the annotations layer draws, and where the image's top-left is in it (y up).
    private var drawn: [Annotation] = []
    private var drawnOffset = CGPoint.zero

    init(size: CGSize, scale: CGFloat) {
        toolbar = EditorToolbar(scale: scale)
        super.init()
        root.frame = CGRect(origin: .zero, size: size)
        root.isHidden = true

        image.contentsGravity = .resize
        annotations.delegate = self
        annotations.contentsScale = scale
        annotations.needsDisplayOnBoundsChange = true

        cropDim.frame = root.bounds
        outsideDim.frame = root.bounds
        cropOutline.shadowColor = Style.cropShadow.cgColor
        cropOutline.shadowOpacity = 1
        cropOutline.shadowRadius = 0
        cropOutline.shadowOffset = CGSize(width: PixelArt.cell, height: -PixelArt.cell)
        caret.borderColor = NSColor(white: 1, alpha: 0.8).cgColor
        caret.borderWidth = 0.5

        for layer in [image, annotations, cropDim, cropOutline, outsideDim, crosshair, caret, toolbar.root] {
            root.addSublayer(layer)
        }
    }

    /// `panelFrame` is the panel's frame in Cocoa global space.
    func show(_ scene: EditorScene, panelFrame: CGRect, showsToolbar: Bool) {
        root.isHidden = false
        let bounds = root.bounds
        let imageRect = scene.frame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: imageRect.minX + point.x, y: imageRect.maxY - point.y)
        }
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: imageRect.minX + rect.minX, y: imageRect.maxY - rect.maxY, width: rect.width, height: rect.height)
        }

        if (image.contents as AnyObject?) !== scene.image { image.contents = scene.image }
        image.frame = imageRect

        // Only the part on this screen, so a window spanning screens doesn't get a backing store per screen.
        let visible = imageRect.intersection(bounds)
        annotations.isHidden = visible.isEmpty
        if !visible.isEmpty {
            annotations.frame = visible
            let offset = CGPoint(x: imageRect.minX - visible.minX, y: imageRect.maxY - visible.minY)
            if scene.annotations != drawn || offset != drawnOffset {
                drawn = scene.annotations
                drawnOffset = offset
                annotations.setNeedsDisplay()
            }
        }

        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addRect(imageRect)
        outsideDim.path = outside

        cropDim.isHidden = scene.crop == nil
        cropOutline.isHidden = scene.crop == nil
        if let crop = scene.crop {
            let path = CGMutablePath()
            path.addRect(imageRect)
            path.addRect(local(crop))
            cropDim.path = path
            // Drawn in image space, flipped into the layer's y-up coordinates.
            cropOutline.frame = imageRect
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: imageRect.height)
            let ring = CGMutablePath()
            ring.addRects(Self.cropRing(crop).map(PixelArt.rect), transform: flip)
            cropOutline.path = ring
            cropOutline.shadowPath = ring
            cropOutline.fillColor = (scene.isCropping ? Style.cropping : Style.cropped).cgColor
        }

        crosshair.isHidden = scene.cursor == nil
        if let cursor = scene.cursor { crosshair.position = local(cursor) }
        caret.isHidden = scene.caret == nil
        if let rect = scene.caret {
            caret.frame = local(rect)
            caret.backgroundColor = scene.color.cgColor
        }

        toolbar.root.isHidden = !showsToolbar
        if showsToolbar {
            toolbar.update(scene)
            toolbar.root.frame.origin = toolbarOrigin(around: visible.isEmpty ? imageRect : visible)
        }
    }

    /// A rectangle annotation's ring, on the cells just outside the crop, so it covers only the corner
    /// cells of what is kept.
    private static func cropRing(_ crop: CGRect) -> [PixelArt.Cell] {
        let cell = PixelArt.cell
        let minX = ((crop.minX / cell).rounded(.down) - 1) * cell
        let minY = ((crop.minY / cell).rounded(.down) - 1) * cell
        let maxX = ((crop.maxX / cell).rounded(.up) + 1) * cell
        let maxY = ((crop.maxY / cell).rounded(.up) + 1) * cell
        return PixelArt.outline(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// Below the image if there is room, otherwise above it, otherwise inside its bottom edge.
    private func toolbarOrigin(around image: CGRect) -> CGPoint {
        let bounds = root.bounds
        let size = toolbar.root.frame.size
        let x = min(max(image.midX - size.width / 2, Style.margin), bounds.width - size.width - Style.margin)
        let y: CGFloat
        if image.minY - Style.margin - size.height >= Style.margin {
            y = image.minY - Style.margin - size.height
        } else if image.maxY + Style.margin + size.height <= bounds.height - Style.margin {
            y = image.maxY + Style.margin
        } else {
            y = max(image.minY, 0) + Style.floatingInset
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    func hide() {
        root.isHidden = true
        // Lets the capture go.
        image.contents = nil
        annotations.contents = nil
        drawn = []
    }

    /// `point` is in the panel's coordinates.
    func toolbarContains(_ point: CGPoint) -> Bool {
        !root.isHidden && !toolbar.root.isHidden && toolbar.root.frame.contains(point)
    }

    func toolbarItem(at point: CGPoint) -> ToolbarItem? {
        guard toolbarContains(point) else { return nil }
        let origin = toolbar.root.frame.origin
        return toolbar.item(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    // MARK: - CALayerDelegate

    func draw(_ layer: CALayer, in context: CGContext) {
        // Into image space: origin at the image's top-left, y down.
        context.translateBy(x: drawnOffset.x, y: drawnOffset.y)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(drawn, in: context)
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

/// The picker's HUD with the editor's keys: its name, the tools, the colors, undo and redo, and the
/// finishing actions, in two rows above a status line. Each entry is a button. Laid out once; updates
/// only change highlights and the status.
private final class EditorToolbar {
    let root = CALayer()
    private var buttons: [(item: ToolbarItem, layer: CALayer, entry: HUD.Entry?)] = []
    private let status: CATextLayer

    private static let tools = EditorController.Tool.allCases.map { (ToolbarItem.tool($0), HUDKey($0.key, action: $0.name)) }
    private static let actions: [(ToolbarItem, HUDKey)] = [
        (.undo, HUDKey("u", action: "undo")),
        (.redo, HUDKey("⌃r", action: "redo")),
        (.finish(.copy), HUDKey("y", action: "copy")),
        (.finish(.save), HUDKey("s", action: "save")),
        (.finish(.saveAndCopy), HUDKey("S", action: "save+copy")),
        (.finish(.saveAs), HUDKey("⌘s", action: "save as")),
        (.finish(.discard), HUDKey("esc", action: "discard")),
    ]

    init(scale: CGFloat) {
        status = HUD.makeStatus(scale: scale)
        HUD.stylePanel(root)

        // The first row: the tools, then the swatches with their numbers, and tab, which cycles them.
        var top: [(layer: CALayer, gap: CGFloat)] = []
        for (item, key) in Self.tools {
            let entry = HUD.makeEntry(key, scale: scale)
            buttons.append((item, entry.layer, entry))
            top.append((entry.layer, HUD.entryGap))
        }
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let swatch = Self.makeSwatch(color, key: "\(index + 1)", scale: scale)
            buttons.append((.color(color), swatch, nil))
            top.append((swatch, index == 0 ? HUD.entryGap : HUD.keyGap - 2 * Style.swatchRing))
        }
        top.append((HUD.makeText("/", font: HUD.textFont, color: Palette.textDim, scale: scale), HUD.keyGap))
        top.append((HUD.makeEntry(HUDKey("tab", action: "color"), scale: scale).layer, HUD.keyGap))

        // The second row, under the first's entries: undo, redo and the finishing actions.
        var bottom: [(layer: CALayer, gap: CGFloat)] = []
        for (item, key) in Self.actions {
            let entry = HUD.makeEntry(key, scale: scale)
            buttons.append((item, entry.layer, entry))
            bottom.append((entry.layer, bottom.isEmpty ? 0 : HUD.entryGap))
        }

        let topHeight = top.map(\.layer.frame.height).max() ?? 0
        let bottomHeight = bottom.map(\.layer.frame.height).max() ?? 0
        let statusHeight = HUD.textSize("Hg", font: HUD.textFont).height
        let bottomY = HUD.padding.height + statusHeight + HUD.lineGap
        let topY = bottomY + bottomHeight + HUD.lineGap

        let name = HUD.makeName("EDIT", rowHeight: topHeight, scale: scale)
        name.frame.origin.x = HUD.padding.width
        name.frame.origin.y += topY
        root.addSublayer(name)
        let indent = name.frame.maxX
        let topWidth = Self.place(top, x: indent, y: topY, height: topHeight, in: root)
        let bottomWidth = Self.place(bottom, x: indent + HUD.entryGap, y: bottomY, height: bottomHeight, in: root)

        let width = max(topWidth, bottomWidth) + HUD.padding.width
        root.frame.size = CGSize(width: width, height: topY + topHeight + HUD.padding.height)
        root.shadowPath = CGPath(rect: root.bounds, transform: nil)
        status.frame = CGRect(x: HUD.padding.width, y: HUD.padding.height, width: width - 2 * HUD.padding.width, height: statusHeight)
        root.addSublayer(status)
    }

    /// Lays `parts` out left to right from `x`, each after its gap, centred in a row `height` tall at `y`.
    /// Returns where the row ends.
    private static func place(_ parts: [(layer: CALayer, gap: CGFloat)], x: CGFloat, y: CGFloat, height: CGFloat, in root: CALayer) -> CGFloat {
        var x = x
        for (layer, gap) in parts {
            x += gap
            layer.frame.origin = CGPoint(x: x, y: y + ((height - layer.frame.height) / 2).rounded())
            root.addSublayer(layer)
            x += layer.frame.width
        }
        return x
    }

    /// A keycap with the color on its face and the number that picks it, in a ring shown while selected.
    private static func makeSwatch(_ color: AnnotationColor, key: String, scale: CGFloat) -> CALayer {
        let isLight = [.yellow, .green, .white].contains(color)
        let keycap = HUD.makeKeycap(key, face: NSColor(cgColor: color.cgColor) ?? .gray, text: isLight ? Palette.ink : .white, scale: scale).edge
        keycap.frame.origin = CGPoint(x: Style.swatchRing, y: Style.swatchRing)
        let swatch = CALayer()
        swatch.borderColor = Palette.text.cgColor
        swatch.frame.size = CGSize(width: keycap.frame.width + 2 * Style.swatchRing, height: keycap.frame.height + 2 * Style.swatchRing)
        swatch.addSublayer(keycap)
        return swatch
    }

    func update(_ scene: EditorScene) {
        for (item, layer, entry) in buttons {
            switch item {
            case .tool(let tool):
                let isActive = tool == scene.tool
                entry?.faces.forEach { $0.backgroundColor = (isActive ? Style.accent : Palette.surfaceRaised).cgColor }
                entry?.action.foregroundColor = (isActive ? Palette.text : Palette.textMuted).cgColor
            case .color(let color):
                layer.borderWidth = color == scene.color ? Style.swatchRing : 0
            case .undo:
                layer.opacity = scene.canUndo ? 1 : 0.35
            case .redo:
                layer.opacity = scene.canRedo ? 1 : 0.35
            case .finish:
                break
            }
        }
        status.string = scene.status
    }

    /// `point` is in the toolbar's coordinates.
    func item(at point: CGPoint) -> ToolbarItem? {
        buttons.first { $0.layer.frame.contains(point) }?.item
    }
}
