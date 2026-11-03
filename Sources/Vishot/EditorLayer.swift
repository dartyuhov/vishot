import AppKit
import VishotRendering

/// The editor on one panel: the frozen image, its annotations, the dimming around it, the cursor and,
/// on one screen, the toolbar. Built with the panel and hidden until editing.
final class EditorLayer: NSObject, CALayerDelegate {
    let root = CALayer()
    private let image = CALayer()
    private let annotations = CALayer()
    private let cropDim: CAShapeLayer
    private let cropOutline = CAShapeLayer()
    private let cropHandle = CALayer()
    private let annotationMask = CAShapeLayer()
    private let outsideDim: CAShapeLayer
    private let crosshair: CALayer
    private let caret = CALayer()
    private var horizontalToolbar: EditorToolbar
    private var verticalToolbar: EditorToolbar
    private var compactToolbar: EditorToolbar
    private var toolbar: EditorToolbar
    private(set) var canHideHUD = false

    /// What the annotations layer draws, and where the image's top-left is in it (y up).
    private var drawn: [Annotation] = []
    private var drawnOffset = CGPoint.zero
    private var drawnScale: CGFloat = 1
    private var drawnStyleID: ThemeID?
    private var drawnStyle: AnnotationStyle
    private var theme: ResolvedTheme
    private let backingScale: CGFloat

    init(size: CGSize, scale: CGFloat, theme: ResolvedTheme) {
        self.theme = theme
        drawnStyle = theme.annotation
        cropDim = SelectionStyle.makeDim(theme.editor.cropDim)
        outsideDim = SelectionStyle.makeDim(theme.selection.outsideDim)
        crosshair = SelectionStyle.makeCrosshair(style: theme.selection)
        backingScale = scale
        horizontalToolbar = EditorToolbar(scale: scale, theme: theme)
        verticalToolbar = EditorToolbar(scale: scale, layout: .vertical, theme: theme)
        compactToolbar = EditorToolbar(scale: scale, layout: .compact, theme: theme)
        toolbar = horizontalToolbar
        super.init()
        root.frame = CGRect(origin: .zero, size: size)
        root.isHidden = true

        image.contentsGravity = .resize
        annotations.delegate = self
        annotations.contentsScale = scale
        annotations.needsDisplayOnBoundsChange = true
        annotations.mask = annotationMask
        cropDim.frame = root.bounds
        outsideDim.frame = root.bounds
        cropOutline.shadowOpacity = 1
        applyAppearance()

        for layer in [image, annotations, cropDim, cropOutline, outsideDim, crosshair, caret, cropHandle,
                      horizontalToolbar.root, verticalToolbar.root, compactToolbar.root] {
            root.addSublayer(layer)
        }
    }

    /// Called with reusable panel preparation, off the hotkey path.
    func prepare(theme: ResolvedTheme) {
        guard self.theme.definition.id != theme.definition.id || self.theme.colorScheme != theme.colorScheme else { return }
        self.theme = theme
        for hud in [horizontalToolbar, verticalToolbar, compactToolbar] { hud.root.removeFromSuperlayer() }
        horizontalToolbar = EditorToolbar(scale: backingScale, theme: theme)
        verticalToolbar = EditorToolbar(scale: backingScale, layout: .vertical, theme: theme)
        compactToolbar = EditorToolbar(scale: backingScale, layout: .compact, theme: theme)
        toolbar = horizontalToolbar
        for hud in [horizontalToolbar, verticalToolbar, compactToolbar] { root.addSublayer(hud.root) }
        applyAppearance()
    }

    private func applyAppearance() {
        cropDim.fillColor = theme.editor.cropDim.cgColor
        outsideDim.fillColor = theme.selection.outsideDim.cgColor
        SelectionStyle.apply(theme.selection, to: crosshair)
        cropOutline.shadowColor = theme.editor.cropShadow.cgColor
        cropOutline.shadowRadius = theme.editor.cropShadowRadius
        cropOutline.shadowOffset = theme.editor.cropShadowOffset
        caret.borderColor = theme.editor.caretBorder.cgColor
        caret.borderWidth = theme.editor.caretBorderWidth
        cropHandle.backgroundColor = theme.editor.active.cgColor
        cropHandle.borderColor = theme.editor.cropped.cgColor
        cropHandle.borderWidth = theme.editor.cropHandleBorderWidth
        cropHandle.cornerRadius = theme.editor.cropHandleRadius
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
            if scene.annotations != drawn || offset != drawnOffset || scale != drawnScale || scene.annotationStyle != drawnStyleID {
                drawn = scene.annotations
                drawnOffset = offset
                drawnScale = scale
                drawnStyleID = scene.annotationStyle
                drawnStyle = scene.resolvedAnnotationStyle
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
            ring.addPath(theme.editor.cropOutline.cropPath(around: crop, width: theme.editor.cropWidth), transform: flip)
            cropOutline.fillRule = .evenOdd
            cropOutline.path = ring
            cropOutline.shadowPath = ring
            cropOutline.fillColor = (scene.isCropping ? theme.editor.active : theme.editor.cropped).cgColor
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
            let size = theme.editor.cropHandleSize
            cropHandle.frame = CGRect(x: position.x - size / 2, y: position.y - size / 2, width: size, height: size)
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
        AnnotationRenderer.draw(drawn, in: context, style: drawnStyle)
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

/// Wide, stacked, and collapsed versions of the editor HUD, built with the panels. The active tool
/// replaces the tool list with its tip. Each layout keeps its footprint and output actions steady.
private final class EditorToolbar {
    private let theme: ResolvedTheme
    private var style: HUDStyle { theme.hud }
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
    private static let actions: [(item: ToolbarItem, key: HUDKey, row: Int, column: Int)] = [
        (.finish(.copy), HUDKey("y", action: "copy to clipboard"), 0, 0),
        (.finish(.save), HUDKey("s", action: "save"), 0, 1),
        (.finish(.saveAndCopy), HUDKey("S", action: "save+copy"), 1, 0),
        (.finish(.saveAs), HUDKey("⌘s", action: "save as"), 1, 1),
        (.escape, HUDKey("esc", action: "discard"), 2, 0),
        (.toggleHUD, HUDKey("o", action: "hide HUD"), 2, 1),
    ]

    init(scale: CGFloat, layout: EditorHUDPlacement.Layout = .horizontal, theme: ResolvedTheme) {
        self.theme = theme
        let style = theme.hud
        self.layout = layout
        status = HUD.makeStatus(scale: scale, style: style)
        colorHint = HUD.makeEntry(HUDKey("tab", action: "color"), scale: scale, style: style)
        let colorWidth = AnnotationColor.allCases.map { HUD.textSize($0.name, font: style.textFont).width }.max() ?? 0
        colorHint.layer.frame.size.width += max(0, colorWidth - colorHint.action.frame.width)
        colorHint.action.frame.size.width = max(colorHint.action.frame.width, colorWidth)
        // Swatches reserve their selection ring. All other controls reserve the same space vertically,
        // aligning the keycap faces rather than the outside of the ring.
        let keyHeight = HUD.makeKeycap("a", scale: scale, style: style.keycap).edge.frame.height
        let rowHeight = keyHeight + 2 * theme.editor.swatchRing
        name = HUD.makeName("EDIT", rowHeight: rowHeight, scale: scale, style: style)
        HUD.stylePanel(root, style: style)

        var top: [(layer: CALayer, gap: CGFloat)] = []
        for (item, key) in Self.tools {
            let entry = HUD.makeEntry(key, scale: scale, style: style)
            buttons.append((item, entry.layer, entry))
            top.append((entry.layer, top.isEmpty ? 0 : style.entryGap))
        }
        var swatches: [(layer: CALayer, gap: CGFloat)] = []
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let swatch = Self.makeSwatch(color, key: "\(index + 1)", scale: scale, theme: theme)
            buttons.append((.color(color), swatch, nil))
            swatches.append((swatch, index == 0 ? 0 : style.keyGap))
        }
        swatches.append((colorHint.layer, style.actionGap))

        var historyParts: [(layer: CALayer, gap: CGFloat)] = []
        for (item, key) in Self.history {
            let entry = HUD.makeEntry(key, scale: scale, style: style)
            buttons.append((item, entry.layer, entry))
            historyParts.append((entry.layer, historyParts.isEmpty ? 0 : style.entryGap))
        }

        var actions: [ToolbarItem: CALayer] = [:]
        for control in Self.actions {
            let entry = HUD.makeEntry(control.key, scale: scale, style: style)
            buttons.append((control.item, entry.layer, entry))
            actions[control.item] = entry.layer
        }

        let statusHeight = HUD.textSize("Hg", font: style.textFont).height
        let bottomY = style.padding.height
        let statusY = bottomY + HUD.textY(style.textFont, lineHeight: statusHeight, in: rowHeight, scale: scale)
        let colorY = bottomY + rowHeight + style.lineGap
        let topY = colorY + rowHeight + style.lineGap

        // Reserve enough name space for every tool, so changing context never moves the controls.
        let nameWidth = (["EDIT"] + EditorController.Tool.allCases.map { $0.name.uppercased() })
            .map { HUD.textSize($0, font: style.nameFont).width }.max() ?? 0
        name.frame.origin.x = style.padding.width
        name.frame.origin.y += topY
        name.frame.size.width = nameWidth
        root.addSublayer(name)
        let indent = name.frame.maxX + style.entryGap
        tools.frame.origin = CGPoint(x: indent, y: topY)
        tools.frame.size = CGSize(width: Self.place(top, x: 0, y: 0, height: rowHeight, in: tools), height: rowHeight)
        colors.frame.origin = CGPoint(x: style.padding.width, y: colorY)
        colors.frame.size = CGSize(width: Self.place(swatches, x: 0, y: 0, height: rowHeight, in: colors), height: rowHeight)
        history.frame.origin = CGPoint(x: colors.frame.maxX + 2 * style.entryGap, y: colorY)
        history.frame.size = CGSize(width: Self.place(historyParts, x: 0, y: 0, height: rowHeight, in: history), height: rowHeight)
        // Give contextual tips their own measure; the actions never borrow space from the editor.
        let editingRight = max(tools.frame.maxX, history.frame.maxX, indent + 440)
        let dividerX = editingRight + style.entryGap
        let actionX = dividerX + style.panel.borderWidth + style.entryGap
        let firstColumnWidth = Self.actions.filter { $0.column == 0 }.map { actions[$0.item]!.frame.width }.max() ?? 0
        let secondColumnX = actionX + firstColumnWidth + style.entryGap
        var actionRight = actionX
        for control in Self.actions {
            let layer = actions[control.item]!
            let x = control.column == 0 ? actionX : secondColumnX
            let y = topY - CGFloat(control.row) * (rowHeight + style.lineGap)
            layer.frame.origin = CGPoint(x: x, y: y + ((rowHeight - layer.frame.height) / 2).rounded())
            root.addSublayer(layer)
            actionRight = max(actionRight, layer.frame.maxX)
        }

        let width = actionRight + style.padding.width
        root.frame.size = CGSize(width: width, height: topY + rowHeight + style.padding.height)
        root.shadowPath = style.panel.path(in: root.bounds)
        idleStatusFrame = CGRect(x: style.padding.width, y: statusY, width: editingRight - style.padding.width, height: statusHeight)
        activeStatusFrame = CGRect(x: indent, y: topY + HUD.textY(style.textFont, lineHeight: statusHeight, in: rowHeight, scale: scale),
                                  width: editingRight - indent, height: statusHeight)
        let divider = CALayer()
        divider.backgroundColor = style.panel.border.cgColor
        divider.frame = CGRect(x: dividerX, y: style.padding.height, width: style.panel.borderWidth, height: root.bounds.height - 2 * style.padding.height)
        for layer in [tools, colors, history, divider] { root.addSublayer(layer) }
        status.frame = idleStatusFrame
        root.addSublayer(status)

        if layout == .vertical {
            let widestEntry = buttons.map { $0.layer.frame.width }.max() ?? 0
            let width = max(200, widestEntry + 2 * style.padding.width)
            let contentWidth = width - 2 * style.padding.width
            let step = rowHeight + style.lineGap
            // Build down from the heading. Fixed slots keep actions steady when controls are hidden.
            let height = 2 * style.padding.height + CGFloat(1 + top.count + 3 + historyParts.count + actions.count) * step + 80 + 2 * style.lineGap
            root.frame.size = CGSize(width: width, height: height)
            var y = height - style.padding.height - rowHeight
            name.frame.origin.y = y + HUD.textY(style.nameFont, lineHeight: name.frame.height, in: rowHeight, scale: scale)
            y -= step
            let toolHeight = CGFloat((top.count + 1) / 2) * step
            tools.frame = CGRect(x: style.padding.width, y: y - toolHeight + step, width: contentWidth, height: toolHeight)
            for (index, part) in top.enumerated() {
                part.layer.frame.origin = CGPoint(x: index.isMultiple(of: 2) ? 0 : contentWidth / 2,
                                                  y: toolHeight - CGFloat(index / 2 + 1) * step + theme.editor.swatchRing)
            }
            y -= toolHeight
            idleStatusFrame = CGRect(x: style.padding.width, y: y - 80 + rowHeight, width: contentWidth, height: 80)
            activeStatusFrame = CGRect(x: style.padding.width, y: y - 80 + rowHeight, width: contentWidth, height: 80)
            status.isWrapped = true
            y -= 80 + style.lineGap
            colors.frame.origin = CGPoint(x: style.padding.width, y: y - 2 * step)
            for (index, part) in swatches.enumerated() {
                if index < 6 {
                    part.layer.frame.origin = CGPoint(x: CGFloat(index % 3) * (part.layer.frame.width + style.keyGap),
                                                      y: CGFloat(2 - index / 3) * step)
                } else {
                    part.layer.frame.origin = CGPoint(x: 0, y: theme.editor.swatchRing)
                }
            }
            colors.frame.size = CGSize(width: contentWidth, height: 3 * step)
            y -= 3 * step
            let historyHeight = step
            history.frame = CGRect(x: style.padding.width, y: y - historyHeight + step, width: contentWidth, height: historyHeight)
            for (index, part) in historyParts.enumerated() {
                part.layer.frame.origin = CGPoint(x: index.isMultiple(of: 2) ? 0 : contentWidth / 2,
                                                  y: theme.editor.swatchRing)
            }
            y -= historyHeight - rowHeight
            y -= style.lineGap
            divider.frame = CGRect(x: style.padding.width, y: y, width: contentWidth, height: style.panel.borderWidth)
            y -= step
            for control in Self.actions {
                let layer = actions[control.item]!
                layer.frame.origin = CGPoint(x: style.padding.width, y: y)
                y -= step
            }
            // Remove unused space below the last action without changing any of the local slots.
            let excess = actions.values.map { $0.frame.minY }.min()! - style.padding.height
            for layer in root.sublayers ?? [] { layer.frame.origin.y -= excess }
            idleStatusFrame.origin.y -= excess
            activeStatusFrame.origin.y -= excess
            root.frame.size.height -= excess
        } else if layout == .compact {
            for layer in root.sublayers ?? [] { layer.isHidden = true }
            let toggle = actions[.toggleHUD]!
            let discard = actions[.escape]!
            toggle.isHidden = false
            discard.isHidden = false
            let toggleEntry = buttons.first { $0.item == .toggleHUD }!.entry!
            toggleEntry.action.string = "show HUD"
            toggle.frame.origin = CGPoint(x: style.padding.width, y: style.padding.height + theme.editor.swatchRing)
            discard.frame.origin = CGPoint(x: toggle.frame.maxX + style.entryGap, y: toggle.frame.minY)
            root.frame.size = CGSize(width: discard.frame.maxX + style.padding.width, height: rowHeight + 2 * style.padding.height)
        }
        root.shadowPath = style.panel.path(in: root.bounds)
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
    private static func makeSwatch(_ color: AnnotationColor, key: String, scale: CGFloat, theme: ResolvedTheme) -> CALayer {
        let isLight = [.yellow, .green, .white].contains(color)
        let ring = theme.editor.swatchRing
        let keycap = HUD.makeKeycap(key, face: NSColor(cgColor: color.cgColor)!, text: isLight ? theme.editor.swatchDarkText : theme.editor.swatchLightText, scale: scale, style: theme.hud.keycap).edge
        keycap.frame.origin = CGPoint(x: ring, y: ring)
        let swatch = CALayer()
        swatch.borderColor = theme.hud.text.cgColor
        swatch.cornerRadius = theme.hud.keycap.cornerRadius == 0 ? 0 : theme.hud.keycap.cornerRadius + ring
        swatch.frame.size = CGSize(width: keycap.frame.width + 2 * ring, height: keycap.frame.height + 2 * ring)
        swatch.addSublayer(keycap)
        return swatch
    }

    func update(_ scene: EditorScene, canHideHUD: Bool) {
        tools.isHidden = scene.context.isActive || layout == .compact
        history.isHidden = scene.context.isActive || layout == .compact
        colors.isHidden = scene.isCropping || layout == .compact
        colorHint.action.string = scene.color.name
        name.string = scene.context.isActive ? (scene.context.tool?.name.uppercased() ?? "EDIT") : "EDIT"
        status.frame = scene.context.isActive ? activeStatusFrame : idleStatusFrame
        for (item, layer, entry) in buttons {
            switch item {
            case .tool(let tool):
                let isActive = tool == scene.context.tool
                entry?.faces.forEach { face in
                    face.backgroundColor = (isActive ? theme.editor.active : style.keycap.face).cgColor
                    face.sublayers?.compactMap { $0 as? CATextLayer }.forEach {
                        $0.foregroundColor = (isActive ? theme.editor.activeText : style.keycap.text).cgColor
                    }
                }
                entry?.action.foregroundColor = (isActive ? style.text : style.muted).cgColor
            case .color(let color):
                layer.borderWidth = color == scene.color ? theme.editor.swatchRing : 0
            case .undo:
                layer.opacity = scene.canUndo ? 1 : style.disabledOpacity
            case .redo:
                layer.opacity = scene.canRedo ? 1 : style.disabledOpacity
            case .escape:
                // Esc places the current annotation (or applies a resize) before it can discard.
                entry?.action.string = scene.context.escapeLabel
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
        guard !root.isHidden, root.bounds.contains(point) else { return nil }
        return buttons.first {
            var ancestor: CALayer? = $0.layer
            while let layer = ancestor, layer !== root {
                guard !layer.isHidden, layer.opacity == 1 else { return false }
                ancestor = layer.superlayer
            }
            return root.convert($0.layer.bounds, from: $0.layer).contains(point)
        }?.item
    }
}
