import AppKit

private enum Style {
    static let borderWidth: CGFloat = 4
    static let color = Palette.accent
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let labelPadding = CGSize(width: 8, height: 4)
    static let labelInset: CGFloat = 10

    static let hudKeysFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static let hudStatusFont = NSFont.systemFont(ofSize: 12)
    static let hudBackground = Palette.chrome
    static let hudPadding = CGSize(width: 14, height: 8)
    static let hudLineGap: CGFloat = 4
    static let hudBottomInset: CGFloat = 24
    /// Fully transparent pixels let clicks through to the windows below, so the panel keeps a trace of tint.
    static let panelBackground = NSColor(white: 0, alpha: 0.01)

    static let hintFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    /// Leaves: yellow labels, no outline.
    static let hintBackground = Palette.hintLeaf
    /// Containers: outline and label share one of these. No yellow, so it stays the mark of a leaf.
    static let hintPalette = Palette.hintContainers
    static let hintPadding = CGSize(width: 4, height: 1)
}

/// A hint label. `rect` is in Cocoa global space. Containers have a `colorIndex` and get an outline.
struct HintMark {
    let rect: CGRect
    let label: String
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

    private let border = CALayer()
    private let labelBackground = CALayer()
    private let labelText = CATextLayer()
    private let hud = CALayer()
    private let hudKeys = CATextLayer()
    private let hudStatus = CATextLayer()
    /// All outlines sit below all labels, so no outline crosses a label.
    private let hintOutlines = CALayer()
    private let hintLabels = CALayer()
    /// Hint outlines and labels, grown on first use and reused after.
    private var hintLayers: [(outline: CALayer, background: CALayer, text: CATextLayer)] = []
    /// Region mode: the dimming around the region, and the cursor.
    private let regionDim = SelectionStyle.makeDim()
    private let crosshair = SelectionStyle.makeCrosshair()
    private let editor: EditorLayer

    init(screen: NSScreen) {
        editor = EditorLayer(size: screen.frame.size, scale: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = Style.panelBackground
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

        border.borderWidth = Style.borderWidth
        border.borderColor = Style.color.cgColor
        border.cornerCurve = .continuous

        labelBackground.backgroundColor = Style.color.cgColor
        labelBackground.cornerRadius = 6
        configure(labelText, font: Style.labelFont, color: .white, scale: screen.backingScaleFactor)
        labelBackground.addSublayer(labelText)

        hud.backgroundColor = Style.hudBackground.cgColor
        hud.cornerRadius = 10
        hud.isHidden = true
        configure(hudKeys, font: Style.hudKeysFont, color: .white, scale: screen.backingScaleFactor)
        configure(hudStatus, font: Style.hudStatusFont, color: Palette.textSecondary, scale: screen.backingScaleFactor)
        hud.addSublayer(hudKeys)
        hud.addSublayer(hudStatus)

        regionDim.frame = view.bounds
        regionDim.isHidden = true
        crosshair.isHidden = true

        view.layer?.addSublayer(regionDim)
        view.layer?.addSublayer(border)
        view.layer?.addSublayer(labelBackground)
        hintOutlines.frame = view.bounds
        hintLabels.frame = view.bounds
        view.layer?.addSublayer(hintOutlines)
        view.layer?.addSublayer(hintLabels)
        view.layer?.addSublayer(crosshair)
        view.layer?.addSublayer(hud)
        view.layer?.addSublayer(editor.root)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(event)
    }

    /// `rect` is in Cocoa global space. Parts outside this screen are clipped by the panel. Nil, as in
    /// region mode before anything is drawn, hides the highlight. `cornerRadius` is the target's own.
    func highlight(_ rect: CGRect?, label: String, cornerRadius: CGFloat) {
        let local = rect?.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let visible = local?.intersects(bounds) ?? false
        border.isHidden = !visible
        labelBackground.isHidden = !visible
        guard visible, let local else { return }

        // A target that touches the screen edge (always true for displays) draws its border inside,
        // where it stays visible.
        let outset = local.insetBy(dx: -Style.borderWidth, dy: -Style.borderWidth)
        let isInset = bounds.contains(local) && !bounds.contains(outset)
        border.frame = isInset ? local : outset
        // Outside the target, the border's radius grows by its width so it runs parallel to the corner.
        border.cornerRadius = isInset ? cornerRadius : cornerRadius + Style.borderWidth

        let textSize = (label as NSString).size(withAttributes: [.font: Style.labelFont])
        let maxWidth = max(0, local.width - 2 * Style.labelInset - 2 * Style.labelPadding.width)
        let textWidth = min(ceil(textSize.width), maxWidth)
        let size = CGSize(width: textWidth + 2 * Style.labelPadding.width, height: ceil(textSize.height) + 2 * Style.labelPadding.height)
        labelBackground.frame = CGRect(
            x: local.minX + Style.labelInset,
            y: local.maxY - Style.labelInset - size.height,
            width: size.width,
            height: size.height
        )
        labelText.frame = CGRect(x: Style.labelPadding.width, y: Style.labelPadding.height, width: textWidth, height: ceil(textSize.height))
        labelText.string = label
    }

    /// The mode's keys, and an optional status line below them, at the bottom centre of the screen.
    func showHUD(keys: String, status: String, visible: Bool) {
        hud.isHidden = !visible
        guard visible else { return }

        let keysSize = textSize(keys, font: Style.hudKeysFont)
        let statusSize = status.isEmpty ? .zero : textSize(status, font: Style.hudStatusFont)
        let statusHeight = status.isEmpty ? 0 : statusSize.height + Style.hudLineGap
        let maxWidth = frame.width - 2 * Style.hudPadding.width
        let width = min(max(keysSize.width, statusSize.width), maxWidth)
        let height = keysSize.height + statusHeight + 2 * Style.hudPadding.height

        hud.frame = CGRect(
            x: ((frame.width - width) / 2 - Style.hudPadding.width).rounded(),
            y: Style.hudBottomInset,
            width: width + 2 * Style.hudPadding.width,
            height: height
        )
        hudKeys.frame = CGRect(x: Style.hudPadding.width, y: Style.hudPadding.height + statusHeight, width: width, height: keysSize.height)
        hudKeys.string = keys
        hudStatus.isHidden = status.isEmpty
        hudStatus.frame = CGRect(x: Style.hudPadding.width, y: Style.hudPadding.height, width: width, height: statusSize.height)
        hudStatus.string = status
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
    func showEditor(_ scene: EditorScene, showsToolbar: Bool) {
        border.isHidden = true
        labelBackground.isHidden = true
        hud.isHidden = true
        showHints([], typed: 0)
        showRegion(nil, cursor: nil)
        editor.show(scene, panelFrame: frame, showsToolbar: showsToolbar)
    }

    func hideEditor() {
        editor.hide()
    }

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

    /// Labels at the top-left corner of each mark. Containers also get an outline in their label's
    /// color, so a label can be matched to the area it stands for. The first `typed` letters of each
    /// label are dimmed.
    func showHints(_ marks: [HintMark], typed: Int) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        var used = 0
        for mark in marks {
            let local = mark.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard local.intersects(bounds) else { continue }
            if used == hintLayers.count { hintLayers.append(makeHintLayer()) }
            let (outline, background, text) = hintLayers[used]
            used += 1

            let color = mark.colorIndex.map { Style.hintPalette[$0 % Style.hintPalette.count] } ?? Style.hintBackground
            outline.isHidden = mark.colorIndex == nil
            outline.frame = local.insetBy(dx: 1, dy: 1)
            outline.borderColor = color.cgColor

            let size = textSize(mark.label, font: Style.hintFont)
            let labelSize = CGSize(width: size.width + 2 * Style.hintPadding.width, height: size.height + 2 * Style.hintPadding.height)
            let origin = CGPoint(
                x: min(max(local.minX, 0), bounds.width - labelSize.width),
                y: min(max(local.maxY - labelSize.height, 0), bounds.height - labelSize.height)
            )
            background.frame = CGRect(origin: origin, size: labelSize)
            background.backgroundColor = color.cgColor
            background.isHidden = false
            text.frame = CGRect(x: Style.hintPadding.width, y: Style.hintPadding.height, width: size.width, height: size.height)
            let string = NSMutableAttributedString(string: mark.label, attributes: [.font: Style.hintFont, .foregroundColor: NSColor.black])
            string.addAttribute(.foregroundColor, value: NSColor(white: 0, alpha: 0.35), range: NSRange(location: 0, length: min(typed, mark.label.utf16.count)))
            text.string = string
        }
        for unused in hintLayers[used...] {
            unused.outline.isHidden = true
            unused.background.isHidden = true
        }
    }

    private func makeHintLayer() -> (outline: CALayer, background: CALayer, text: CATextLayer) {
        let outline = CALayer()
        outline.borderWidth = 2
        outline.cornerRadius = 4
        hintOutlines.addSublayer(outline)

        let background = CALayer()
        background.cornerRadius = 3
        background.borderColor = NSColor(white: 0, alpha: 0.4).cgColor
        background.borderWidth = 0.5
        let text = CATextLayer()
        text.contentsScale = backingScaleFactor
        background.addSublayer(text)
        hintLabels.addSublayer(background)
        return (outline, background, text)
    }

    private func configure(_ layer: CATextLayer, font: NSFont, color: NSColor, scale: CGFloat) {
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.contentsScale = scale
        layer.truncationMode = .end
    }

    private func textSize(_ text: String, font: NSFont) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
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
