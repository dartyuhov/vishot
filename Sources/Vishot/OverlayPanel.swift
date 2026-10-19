import AppKit

/// A hint and the element it is shown on. `rect` is in Cocoa global space. Containers have a
/// `colorIndex` and get an outline.
struct HintMark {
    let rect: CGRect
    let code: String
    let colorIndex: Int?
}

/// One transparent panel per screen. Panels are created once and reused, so showing the
/// overlay costs only an order-front plus a layer move.
final class OverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?
    /// Points are in CoreGraphics global space.
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    private let border = CAShapeLayer()
    private let labelBackground = CALayer()
    private let labelText = CATextLayer()
    private let hud: PickerHUD
    /// All outlines sit below all hints, so no outline crosses a hint.
    private let hintOutlines = CALayer()
    private let hints = CALayer()
    /// Each hint's outline, background and text, grown on first use and reused after.
    private var hintLayers: [(outline: CALayer, background: CALayer, text: CATextLayer)] = []
    /// Region mode: the dimming around the region, and the cursor.
    private let regionDim = SelectionStyle.makeDim()
    private let crosshair = SelectionStyle.makeCrosshair()
    private let editor: EditorLayer
    private var theme: ResolvedTheme
    private var style: PickerStyle { theme.picker }
    private var hudStyle: HUDStyle { theme.hud }

    init(screen: NSScreen, theme: ResolvedTheme) {
        self.theme = theme
        editor = EditorLayer(size: screen.frame.size, scale: screen.backingScaleFactor)
        hud = PickerHUD(scale: screen.backingScaleFactor, style: theme.hud)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = style.panelBackground
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false

        let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.onMouseMoved = { [weak self] in self?.onMouseMoved?($0) }
        view.onMouseDown = { [weak self] in self?.onMouseDown?($0) }
        view.onMouseDragged = { [weak self] in self?.onMouseDragged?($0) }
        view.onMouseUp = { [weak self] in self?.onMouseUp?($0) }
        contentView = view

        border.frame = view.bounds
        border.fillColor = style.accent.cgColor
        border.fillRule = .evenOdd

        style.label.apply(to: labelBackground)
        HUD.configure(labelText, font: style.labelFont, color: style.labelText, scale: screen.backingScaleFactor)
        labelBackground.addSublayer(labelText)

        regionDim.frame = view.bounds
        regionDim.isHidden = true
        crosshair.isHidden = true
        regionDim.fillColor = theme.selection.outsideDim.cgColor
        SelectionStyle.apply(theme.selection, to: crosshair)

        view.layer?.addSublayer(regionDim)
        view.layer?.addSublayer(border)
        view.layer?.addSublayer(labelBackground)
        hintOutlines.frame = view.bounds
        hints.frame = view.bounds
        view.layer?.addSublayer(hintOutlines)
        view.layer?.addSublayer(hints)
        view.layer?.addSublayer(crosshair)
        view.layer?.addSublayer(hud.root)
        view.layer?.addSublayer(editor.root)
    }

    /// Called only at startup, screen changes, or an idle preference change.
    func prepare(theme: ResolvedTheme, modes: [(name: String, keys: [HUDKey])]) {
        self.theme = theme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundColor = style.panelBackground
        border.fillColor = style.accent.cgColor
        style.label.apply(to: labelBackground)
        HUD.configure(labelText, font: style.labelFont, color: style.labelText, scale: backingScaleFactor)
        hud.prepare(style: hudStyle, modes: modes)
        regionDim.fillColor = theme.selection.outsideDim.cgColor
        SelectionStyle.apply(theme.selection, to: crosshair)
        for layers in hintLayers { styleHint(layers) }
        CATransaction.commit()
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(event)
    }

    /// `rect` is in Cocoa global space. Parts outside this screen are clipped by the panel. Nil, as in
    /// region mode before anything is drawn, hides the highlight.
    func highlight(_ rect: CGRect?, label: String) {
        let local = rect?.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let visible = local?.intersects(bounds) ?? false
        border.isHidden = !visible
        labelBackground.isHidden = !visible
        guard visible, let local else { return }

        // A target that touches the screen edge (always true for displays) draws its border inside,
        // where it stays visible.
        let outset = local.insetBy(dx: -style.borderWidth, dy: -style.borderWidth)
        let isInset = bounds.contains(local) && !bounds.contains(outset)
        let outer = isInset ? local : outset
        // A ring, through the even-odd fill: the outer shape and the same shape one border width in.
        border.path = style.outline.path(around: outer, width: style.borderWidth)

        let textSize = (label as NSString).size(withAttributes: [.font: style.labelFont])
        let maxWidth = max(0, local.width - 2 * style.labelInset - 2 * style.labelPadding.width)
        let textWidth = min(ceil(textSize.width), maxWidth)
        let size = CGSize(width: textWidth + 2 * style.labelPadding.width, height: ceil(textSize.height) + 2 * style.labelPadding.height)
        labelBackground.frame = CGRect(
            x: local.minX + style.labelInset,
            y: local.maxY - style.labelInset - size.height,
            width: size.width,
            height: size.height
        )
        labelBackground.shadowPath = style.label.path(in: CGRect(origin: .zero, size: size))
        labelText.frame = CGRect(
            x: style.labelPadding.width, y: HUD.textY(style.labelFont, lineHeight: ceil(textSize.height), in: size.height, scale: backingScaleFactor),
            width: textWidth, height: ceil(textSize.height)
        )
        labelText.string = label
    }

    /// The mode's name and keys, and optional status above them, at the bottom centre of the screen.
    func showHUD(name: String, keys: [HUDKey], status: String, visible: Bool) {
        hud.show(name: name, keys: keys, status: status, size: frame.size, visible: visible)
    }

    func hudUnavailableReason(at point: CGPoint) -> String? {
        guard isVisible, frame.contains(point.flippedBetweenCocoaAndCG) else { return nil }
        return hud.unavailableReason(at: localPoint(point))
    }

    /// Region mode: dims everything around `rect` and shows the cursor, both in Cocoa global space.
    /// Nil hides each.
    func showRegion(_ rect: CGRect?, cursor: CGPoint?) {
        regionDim.isHidden = rect == nil
        if let rect {
            let path = CGMutablePath()
            path.addRect(regionDim.bounds)
            path.addRect(rect.offsetBy(dx: -frame.minX, dy: -frame.minY))
            regionDim.path = path
        }
        // Off this screen, the crosshair is simply outside the panel.
        crosshair.isHidden = cursor == nil
        if let cursor { crosshair.position = CGPoint(x: cursor.x - frame.minX, y: cursor.y - frame.minY) }
    }

    /// Replaces the picker's border, hints, region and HUD with the editor. The toolbar shows on one screen.
    func hidePicker() {
        border.isHidden = true
        labelBackground.isHidden = true
        hud.root.isHidden = true
        showHints([], typed: 0)
        showRegion(nil, cursor: nil)
    }

    func showEditor(_ scene: EditorScene, showsToolbar: Bool) {
        hidePicker()
        editor.show(scene, panelFrame: frame, showsToolbar: showsToolbar)
    }

    func hideEditor() {
        editor.hide()
    }

    var canHideEditorHUD: Bool { editor.canHideHUD }

    /// `point` is in CoreGraphics global space.
    func toolbarContains(_ point: CGPoint) -> Bool {
        editor.toolbarContains(localPoint(point))
    }

    func toolbarItem(at point: CGPoint) -> ToolbarItem? {
        editor.toolbarItem(at: localPoint(point))
    }

    private func localPoint(_ point: CGPoint) -> CGPoint {
        let cocoa = point.flippedBetweenCocoaAndCG
        return CGPoint(x: cocoa.x - frame.minX, y: cocoa.y - frame.minY)
    }

    /// Each hint at the top-left corner of its element. Containers also get an outline in their hint's
    /// color, so a hint can be matched to the area it stands for. The first `typed` letters of each
    /// hint are dimmed.
    func showHints(_ marks: [HintMark], typed: Int) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        var used = 0
        for mark in marks {
            let local = mark.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard local.intersects(bounds) else { continue }
            if used == hintLayers.count { hintLayers.append(makeHintLayer()) }
            let (outline, background, text) = hintLayers[used]
            used += 1

            let color = mark.colorIndex.map { style.hintContainers[$0 % style.hintContainers.count] } ?? style.hintLeaf
            outline.isHidden = mark.colorIndex == nil
            outline.frame = local.insetBy(dx: 1, dy: 1)
            outline.borderColor = color.cgColor

            let size = HUD.textSize(mark.code, font: style.hintFont)
            let hintSize = CGSize(width: size.width + 2 * style.hintPadding.width, height: size.height + 2 * style.hintPadding.height)
            let origin = CGPoint(
                x: min(max(local.minX, 0), bounds.width - hintSize.width),
                y: min(max(local.maxY - hintSize.height, 0), bounds.height - hintSize.height)
            )
            background.frame = CGRect(origin: origin, size: hintSize)
            background.backgroundColor = color.cgColor
            background.isHidden = false
            text.frame = CGRect(x: style.hintPadding.width, y: style.hintPadding.height, width: size.width, height: size.height)
            let string = NSMutableAttributedString(string: mark.code, attributes: [.font: style.hintFont, .foregroundColor: style.hintText])
            string.addAttribute(.foregroundColor, value: style.hintText.withAlphaComponent(0.35), range: NSRange(location: 0, length: min(typed, mark.code.utf16.count)))
            text.string = string
        }
        for unused in hintLayers[used...] {
            unused.outline.isHidden = true
            unused.background.isHidden = true
        }
    }

    private func makeHintLayer() -> (outline: CALayer, background: CALayer, text: CATextLayer) {
        let outline = CALayer()
        hintOutlines.addSublayer(outline)

        let background = CALayer()
        background.borderColor = NSColor(white: 0, alpha: 0.4).cgColor
        let text = CATextLayer()
        text.contentsScale = backingScaleFactor
        background.addSublayer(text)
        hints.addSublayer(background)
        let layers = (outline, background, text)
        styleHint(layers)
        return layers
    }

    private func styleHint(_ layers: (outline: CALayer, background: CALayer, text: CATextLayer)) {
        layers.outline.borderWidth = style.hintOutlineWidth
        layers.outline.cornerRadius = style.hintCornerRadius
        layers.background.borderWidth = style.hintBorderWidth
        layers.background.cornerRadius = style.hintCornerRadius
        HUD.configure(layers.text, font: style.hintFont, color: style.hintText, scale: backingScaleFactor)
    }
}

extension CGMutablePath {
    /// `rect` with a `pixel`-sized square left out of each corner, the logo's pixel-art rounding.
    func addPixelRoundedRect(_ rect: CGRect, pixel: CGFloat) {
        let p = min(pixel, rect.width / 2, rect.height / 2)
        addLines(between: [
            CGPoint(x: rect.minX + p, y: rect.minY), CGPoint(x: rect.maxX - p, y: rect.minY),
            CGPoint(x: rect.maxX - p, y: rect.minY + p), CGPoint(x: rect.maxX, y: rect.minY + p),
            CGPoint(x: rect.maxX, y: rect.maxY - p), CGPoint(x: rect.maxX - p, y: rect.maxY - p),
            CGPoint(x: rect.maxX - p, y: rect.maxY), CGPoint(x: rect.minX + p, y: rect.maxY),
            CGPoint(x: rect.minX + p, y: rect.maxY - p), CGPoint(x: rect.minX, y: rect.maxY - p),
            CGPoint(x: rect.minX, y: rect.minY + p), CGPoint(x: rect.minX + p, y: rect.minY + p),
        ])
        closeSubpath()
    }
}

/// Reports hover, clicks and drags. `.activeAlways` keeps hover working on screens whose panel is not key.
private final class OverlayView: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(globalLocation(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(globalLocation(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(globalLocation(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(globalLocation(of: event))
    }

    private func globalLocation(of event: NSEvent) -> CGPoint {
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return point.flippedBetweenCocoaAndCG
    }
}
