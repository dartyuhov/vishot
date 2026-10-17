import AppKit

private enum Style {
    static let cropDim = NSColor(white: 0, alpha: 0.45)
    /// The crop's outline: accent while it is drawn, then white.
    static let cropping = Palette.accent
    static let cropped = NSColor.white
    /// A rectangle annotation's shadow, one cell down and right.
    static let cropShadow = NSColor(white: 0, alpha: 0.35)
    static let accent = Palette.accent

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
    private let cropHandle = CALayer()
    private let annotationMask = CAShapeLayer()
    private let outsideDim = SelectionStyle.makeDim()
    private let crosshair = SelectionStyle.makeCrosshair()
    private let caret = CALayer()
    private let horizontalToolbar: EditorToolbar
    private let verticalToolbar: EditorToolbar
    private let compactToolbar: EditorToolbar
    private var toolbar: EditorToolbar
    private(set) var canHideHUD = false

    /// What the annotations layer draws, and where the image's top-left is in it (y up).
    private var drawn: [Annotation] = []
    private var drawnOffset = CGPoint.zero
    private var drawnScale: CGFloat = 1

    init(size: CGSize, scale: CGFloat) {
        horizontalToolbar = EditorToolbar(scale: scale)
        verticalToolbar = EditorToolbar(scale: scale, layout: .vertical)
        compactToolbar = EditorToolbar(scale: scale, layout: .compact)
        toolbar = horizontalToolbar
        super.init()
        root.frame = CGRect(origin: .zero, size: size)
        root.isHidden = true

        image.contentsGravity = .resize
        annotations.delegate = self
        annotations.contentsScale = scale
        annotations.needsDisplayOnBoundsChange = true
        annotations.mask = annotationMask
        cropHandle.backgroundColor = Palette.accent.cgColor
        cropHandle.borderColor = NSColor.white.cgColor
        cropHandle.borderWidth = 2

        cropDim.frame = root.bounds
        outsideDim.frame = root.bounds
        cropOutline.shadowColor = Style.cropShadow.cgColor
        cropOutline.shadowOpacity = 1
        cropOutline.shadowRadius = 0
        cropOutline.shadowOffset = CGSize(width: PixelArt.cell, height: -PixelArt.cell)
        caret.borderColor = NSColor(white: 1, alpha: 0.8).cgColor
        caret.borderWidth = 0.5

        for layer in [image, annotations, cropDim, cropOutline, outsideDim, crosshair, caret, cropHandle,
                      horizontalToolbar.root, verticalToolbar.root, compactToolbar.root] {
            root.addSublayer(layer)
        }
    }

    /// `panelFrame` is the panel's frame in Cocoa global space.
    func show(_ scene: EditorScene, panelFrame: CGRect, showsToolbar: Bool) {
        root.isHidden = false
        let bounds = root.bounds
        let imageRect = scene.frame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        let scale = scene.viewScale
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.maxY - point.y * scale)
        }
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: imageRect.minX + rect.minX * scale, y: imageRect.maxY - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        }

        if (image.contents as AnyObject?) !== scene.image { image.contents = scene.image }
        image.frame = imageRect

        // Only the part on this screen, so a window spanning screens doesn't get a backing store per screen.
        let visible = imageRect.intersection(bounds)
        annotations.isHidden = visible.isEmpty
        if !visible.isEmpty {
            annotations.frame = visible
            let clip = scene.crop.map(local) ?? imageRect
            annotationMask.frame = annotations.bounds
            annotationMask.path = CGPath(rect: clip.offsetBy(dx: -visible.minX, dy: -visible.minY), transform: nil)
            let offset = CGPoint(x: imageRect.minX - visible.minX, y: imageRect.maxY - visible.minY)
            if scene.annotations != drawn || offset != drawnOffset || scale != drawnScale {
                drawn = scene.annotations
                drawnOffset = offset
                drawnScale = scale
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
            let flip = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: imageRect.height)
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
        cropHandle.isHidden = scene.cropHandle == nil
        if let handle = scene.cropHandle {
            let position = local(handle)
            cropHandle.frame = CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10)
        }

        for hud in [horizontalToolbar, verticalToolbar, compactToolbar] { hud.root.isHidden = true }
        if showsToolbar {
            let selection = scene.crop.map(local) ?? imageRect
            let placement = EditorHUDPlacement.choose(around: selection, in: bounds,
                horizontal: horizontalToolbar.root.bounds.size, vertical: verticalToolbar.root.bounds.size,
                compact: compactToolbar.root.bounds.size, hidden: scene.isHUDHidden)
            switch placement.layout {
            case .horizontal: toolbar = horizontalToolbar
            case .vertical: toolbar = verticalToolbar
            case .compact: toolbar = compactToolbar
            }
            toolbar.root.isHidden = false
            canHideHUD = placement.frame.intersects(selection)
            toolbar.update(scene, canHideHUD: canHideHUD)
            toolbar.root.frame = placement.frame
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
        context.scaleBy(x: drawnScale, y: -drawnScale)
        AnnotationRenderer.draw(drawn, in: context)
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

/// Wide, stacked, and collapsed versions of the editor HUD, built with the panels. The active tool
/// replaces the tool list with its tip. Each layout keeps its footprint and output actions steady.
private final class EditorToolbar {
    let root = CALayer()
    private var buttons: [(item: ToolbarItem, layer: CALayer, entry: HUD.Entry?)] = []
    private let status: CATextLayer
    private let name: CATextLayer
    private let tools = CALayer()
    private let colors = CALayer()
    private let history = CALayer()
    private let colorHint: HUD.Entry
    private var idleStatusFrame: CGRect
    private var activeStatusFrame: CGRect
    private let layout: EditorHUDPlacement.Layout

    private static let tools = EditorController.Tool.allCases.map { (ToolbarItem.tool($0), HUDKey($0.key, action: $0.name)) }
    private static let history: [(ToolbarItem, HUDKey)] = [
        (.undo, HUDKey("u", action: "undo")),
        (.redo, HUDKey("⌃r", action: "redo")),
    ]
    private static let actions: [(ToolbarItem, HUDKey)] = [
        (.finish(.copy), HUDKey("y", action: "copy to clipboard")),
        (.finish(.save), HUDKey("s", action: "save")),
        (.finish(.saveAndCopy), HUDKey("S", action: "save+copy")),
        (.finish(.saveAs), HUDKey("⌘s", action: "save as")),
        (.finish(.discard), HUDKey("esc", action: "discard")),
        (.toggleHUD, HUDKey("o", action: "hide HUD")),
    ]

    init(scale: CGFloat, layout: EditorHUDPlacement.Layout = .horizontal) {
        self.layout = layout
        status = HUD.makeStatus(scale: scale)
        colorHint = HUD.makeEntry(HUDKey("tab", action: "color"), scale: scale)
        let colorWidth = AnnotationColor.allCases.map { HUD.textSize($0.name, font: HUD.textFont).width }.max() ?? 0
        colorHint.layer.frame.size.width += max(0, colorWidth - colorHint.action.frame.width)
        colorHint.action.frame.size.width = max(colorHint.action.frame.width, colorWidth)
        // Swatches reserve their selection ring. All other controls reserve the same space vertically,
        // aligning the keycap faces rather than the outside of the ring.
        let keyHeight = HUD.makeKeycap("a", scale: scale).edge.frame.height
        let rowHeight = keyHeight + 2 * Style.swatchRing
        name = HUD.makeName("EDIT", rowHeight: rowHeight, scale: scale)
        HUD.stylePanel(root)

        var top: [(layer: CALayer, gap: CGFloat)] = []
        for (item, key) in Self.tools {
            let entry = HUD.makeEntry(key, scale: scale)
            buttons.append((item, entry.layer, entry))
            top.append((entry.layer, top.isEmpty ? 0 : HUD.entryGap))
        }
        var swatches: [(layer: CALayer, gap: CGFloat)] = []
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let swatch = Self.makeSwatch(color, key: "\(index + 1)", scale: scale)
            buttons.append((.color(color), swatch, nil))
            swatches.append((swatch, index == 0 ? 0 : HUD.keyGap))
        }
        swatches.append((colorHint.layer, HUD.actionGap))

        var historyParts: [(layer: CALayer, gap: CGFloat)] = []
        for (item, key) in Self.history {
            let entry = HUD.makeEntry(key, scale: scale)
            buttons.append((item, entry.layer, entry))
            historyParts.append((entry.layer, historyParts.isEmpty ? 0 : HUD.entryGap))
        }

        var actions: [CALayer] = []
        for (item, key) in Self.actions {
            let entry = HUD.makeEntry(key, scale: scale)
            buttons.append((item, entry.layer, entry))
            actions.append(entry.layer)
        }

        let statusHeight = HUD.textSize("Hg", font: HUD.textFont).height
        let bottomY = HUD.padding.height
        let statusY = bottomY + HUD.textY(HUD.textFont, lineHeight: statusHeight, in: rowHeight, scale: scale)
        let colorY = bottomY + rowHeight + HUD.lineGap
        let topY = colorY + rowHeight + HUD.lineGap

        // Reserve enough name space for every tool, so changing context never moves the controls.
        let nameWidth = (["EDIT"] + EditorController.Tool.allCases.map { $0.name.uppercased() })
            .map { HUD.textSize($0, font: HUD.nameFont).width }.max() ?? 0
        name.frame.origin.x = HUD.padding.width
        name.frame.origin.y += topY
        name.frame.size.width = nameWidth
        root.addSublayer(name)
        let indent = name.frame.maxX + HUD.entryGap
        tools.frame.origin = CGPoint(x: indent, y: topY)
        tools.frame.size = CGSize(width: Self.place(top, x: 0, y: 0, height: rowHeight, in: tools), height: rowHeight)
        colors.frame.origin = CGPoint(x: HUD.padding.width, y: colorY)
        colors.frame.size = CGSize(width: Self.place(swatches, x: 0, y: 0, height: rowHeight, in: colors), height: rowHeight)
        history.frame.origin = CGPoint(x: colors.frame.maxX + 2 * HUD.entryGap, y: colorY)
        history.frame.size = CGSize(width: Self.place(historyParts, x: 0, y: 0, height: rowHeight, in: history), height: rowHeight)
        // Give contextual tips their own measure; the actions never borrow space from the editor.
        let editingRight = max(tools.frame.maxX, history.frame.maxX, indent + 440)
        let dividerX = editingRight + HUD.entryGap
        let actionX = dividerX + 2 + HUD.entryGap
        let firstColumnWidth = max(actions[0].frame.width, actions[2].frame.width, actions[4].frame.width)
        let secondColumnX = actionX + firstColumnWidth + HUD.entryGap
        var actionRight = actionX
        for (index, layer) in actions.enumerated() {
            let x = index.isMultiple(of: 2) ? actionX : secondColumnX
            let y = topY - CGFloat(index / 2) * (rowHeight + HUD.lineGap)
            layer.frame.origin = CGPoint(x: x, y: y + ((rowHeight - layer.frame.height) / 2).rounded())
            root.addSublayer(layer)
            actionRight = max(actionRight, layer.frame.maxX)
        }

        let width = actionRight + HUD.padding.width
        root.frame.size = CGSize(width: width, height: topY + rowHeight + HUD.padding.height)
        root.shadowPath = CGPath(rect: root.bounds, transform: nil)
        idleStatusFrame = CGRect(x: HUD.padding.width, y: statusY, width: editingRight - HUD.padding.width, height: statusHeight)
        activeStatusFrame = CGRect(x: indent, y: topY + HUD.textY(HUD.textFont, lineHeight: statusHeight, in: rowHeight, scale: scale),
                                  width: editingRight - indent, height: statusHeight)
        let divider = CALayer()
        divider.backgroundColor = Palette.line.cgColor
        divider.frame = CGRect(x: dividerX, y: HUD.padding.height, width: 2, height: root.bounds.height - 2 * HUD.padding.height)
        for layer in [tools, colors, history, divider] { root.addSublayer(layer) }
        status.frame = idleStatusFrame
        root.addSublayer(status)

        if layout == .vertical {
            let widestEntry = buttons.map { $0.layer.frame.width }.max() ?? 0
            let width = max(200, widestEntry + 2 * HUD.padding.width)
            let contentWidth = width - 2 * HUD.padding.width
            let step = rowHeight + HUD.lineGap
            // Build down from the heading. Fixed slots keep actions steady when controls are hidden.
            let height = 2 * HUD.padding.height + CGFloat(1 + top.count + 3 + historyParts.count + actions.count) * step + 80 + 2 * HUD.lineGap
            root.frame.size = CGSize(width: width, height: height)
            var y = height - HUD.padding.height - rowHeight
            name.frame.origin.y = y + HUD.textY(HUD.nameFont, lineHeight: name.frame.height, in: rowHeight, scale: scale)
            y -= step
            let toolHeight = CGFloat(top.count) * step
            tools.frame = CGRect(x: HUD.padding.width, y: y - toolHeight + step, width: contentWidth, height: toolHeight)
            for (index, part) in top.enumerated() {
                part.layer.frame.origin = CGPoint(x: 0, y: toolHeight - CGFloat(index + 1) * step + Style.swatchRing)
            }
            y -= toolHeight
            idleStatusFrame = CGRect(x: HUD.padding.width, y: y - 80 + rowHeight, width: contentWidth, height: 80)
            activeStatusFrame = CGRect(x: HUD.padding.width, y: y - 80 + rowHeight, width: contentWidth, height: 80)
            status.isWrapped = true
            y -= 80 + HUD.lineGap
            colors.frame.origin = CGPoint(x: HUD.padding.width, y: y - 2 * step)
            for (index, part) in swatches.enumerated() {
                if index < 6 {
                    part.layer.frame.origin = CGPoint(x: CGFloat(index % 3) * (part.layer.frame.width + HUD.keyGap),
                                                      y: CGFloat(2 - index / 3) * step)
                } else {
                    part.layer.frame.origin = CGPoint(x: 0, y: Style.swatchRing)
                }
            }
            colors.frame.size = CGSize(width: contentWidth, height: 3 * step)
            y -= 3 * step
            let historyHeight = CGFloat(historyParts.count) * step
            history.frame = CGRect(x: HUD.padding.width, y: y - historyHeight + step, width: contentWidth, height: historyHeight)
            for (index, part) in historyParts.enumerated() {
                part.layer.frame.origin = CGPoint(x: 0, y: historyHeight - CGFloat(index + 1) * step + Style.swatchRing)
            }
            y -= historyHeight - rowHeight
            y -= HUD.lineGap
            divider.frame = CGRect(x: HUD.padding.width, y: y, width: contentWidth, height: 2)
            y -= step
            for layer in actions {
                layer.frame.origin = CGPoint(x: HUD.padding.width, y: y)
                y -= step
            }
            // Remove unused space below the last action without changing any of the local slots.
            let excess = actions.last!.frame.minY - HUD.padding.height
            for layer in root.sublayers ?? [] { layer.frame.origin.y -= excess }
            idleStatusFrame.origin.y -= excess
            activeStatusFrame.origin.y -= excess
            root.frame.size.height -= excess
        } else if layout == .compact {
            for layer in root.sublayers ?? [] { layer.isHidden = true }
            let toggle = actions.last!
            let discard = actions[4]
            toggle.isHidden = false
            discard.isHidden = false
            let toggleEntry = buttons.first { $0.item == .toggleHUD }!.entry!
            toggleEntry.action.string = "show HUD"
            toggle.frame.origin = CGPoint(x: HUD.padding.width, y: HUD.padding.height + Style.swatchRing)
            discard.frame.origin = CGPoint(x: toggle.frame.maxX + HUD.entryGap, y: toggle.frame.minY)
            root.frame.size = CGSize(width: discard.frame.maxX + HUD.padding.width, height: rowHeight + 2 * HUD.padding.height)
        }
        root.shadowPath = CGPath(rect: root.bounds, transform: nil)
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

    func update(_ scene: EditorScene, canHideHUD: Bool) {
        tools.isHidden = scene.isUsingTool || layout == .compact
        history.isHidden = scene.isUsingTool || layout == .compact
        colors.isHidden = scene.isCropping || layout == .compact
        colorHint.action.string = scene.color.name
        name.string = scene.isUsingTool ? (scene.tool?.name.uppercased() ?? "EDIT") : "EDIT"
        status.frame = scene.isUsingTool ? activeStatusFrame : idleStatusFrame
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
            case .finish(.discard):
                // Esc places the current annotation (or applies a resize) before it can discard.
                entry?.action.string = scene.isUsingTool ? (scene.isCropping ? "apply" : "place") : "discard"
            case .finish:
                break
            case .toggleHUD:
                layer.isHidden = !scene.isHUDHidden && !canHideHUD
            }
        }
        status.string = scene.status
    }

    /// `point` is in the toolbar's coordinates.
    func item(at point: CGPoint) -> ToolbarItem? {
        buttons.first {
            guard !$0.layer.isHidden, $0.layer.opacity == 1,
                  let parent = $0.layer.superlayer, !parent.isHidden else { return false }
            return $0.layer.frame.contains(parent.convert(point, from: root))
        }?.item
    }
}
