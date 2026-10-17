import AppKit

private enum Style {
    /// Also the size of the pixel left out of each corner, as in the logo.
    static let borderWidth: CGFloat = 4
    static let color = Palette.accent
    static let labelFont = Fonts.pixel()
    static let labelPadding = CGSize(width: 8, height: 2)
    static let labelInset: CGFloat = 10
    /// The landing page's button shadow: hard, offset right and down.
    static let labelShadow: CGFloat = 2

    static let hudBottomInset: CGFloat = 24
    /// Fully transparent pixels let clicks through to the windows below, so the panel keeps a trace of tint.
    static let panelBackground = NSColor(white: 0, alpha: 0.01)

    static let hintFont = Fonts.mono(11, bold: true)
    /// Leaves: yellow hints, no outline.
    static let hintBackground = Palette.hintLeaf
    /// Containers: outline and hint share one of these. No yellow, so it stays the mark of a leaf.
    static let hintPalette = Palette.hintContainers
    static let hintPadding = CGSize(width: 4, height: 1)
}

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
    private let hud = CALayer()
    /// The mode's name and keys, laid out again only when the mode changes.
    private let hudRow = CALayer()
    private var hudRowContent: (name: String, keys: [HUDKey]) = ("", [])
    private let hudStatus: CATextLayer
    /// All outlines sit below all hints, so no outline crosses a hint.
    private let hintOutlines = CALayer()
    private let hints = CALayer()
    /// Each hint's outline, background and text, grown on first use and reused after.
    private var hintLayers: [(outline: CALayer, background: CALayer, text: CATextLayer)] = []
    /// Region mode: the dimming around the region, and the cursor.
    private let regionDim = SelectionStyle.makeDim()
    private let crosshair = SelectionStyle.makeCrosshair()
    private let editor: EditorLayer

    init(screen: NSScreen) {
        editor = EditorLayer(size: screen.frame.size, scale: screen.backingScaleFactor)
        hudStatus = HUD.makeStatus(scale: screen.backingScaleFactor)
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

        border.frame = view.bounds
        border.fillColor = Style.color.cgColor
        border.fillRule = .evenOdd

        labelBackground.backgroundColor = Style.color.cgColor
        labelBackground.shadowColor = Palette.hintLeaf.cgColor
        labelBackground.shadowOpacity = 1
        labelBackground.shadowRadius = 0
        labelBackground.shadowOffset = CGSize(width: Style.labelShadow, height: -Style.labelShadow)
        HUD.configure(labelText, font: Style.labelFont, color: .white, scale: screen.backingScaleFactor)
        labelBackground.addSublayer(labelText)

        HUD.stylePanel(hud)
        hud.isHidden = true
        hudRow.masksToBounds = true
        hud.addSublayer(hudRow)
        hud.addSublayer(hudStatus)

        regionDim.frame = view.bounds
        regionDim.isHidden = true
        crosshair.isHidden = true

        view.layer?.addSublayer(regionDim)
        view.layer?.addSublayer(border)
        view.layer?.addSublayer(labelBackground)
        hintOutlines.frame = view.bounds
        hints.frame = view.bounds
        view.layer?.addSublayer(hintOutlines)
        view.layer?.addSublayer(hints)
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
        let outset = local.insetBy(dx: -Style.borderWidth, dy: -Style.borderWidth)
        let isInset = bounds.contains(local) && !bounds.contains(outset)
        let outer = isInset ? local : outset
        // A ring, through the even-odd fill: the outer shape and the same shape one border width in.
        let path = CGMutablePath()
        path.addPixelRoundedRect(outer, pixel: Style.borderWidth)
        path.addPixelRoundedRect(outer.insetBy(dx: Style.borderWidth, dy: Style.borderWidth), pixel: Style.borderWidth)
        border.path = path

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
        labelBackground.shadowPath = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        labelText.frame = CGRect(
            x: Style.labelPadding.width, y: HUD.textY(Style.labelFont, lineHeight: ceil(textSize.height), in: size.height, scale: backingScaleFactor),
            width: textWidth, height: ceil(textSize.height)
        )
        labelText.string = label
    }

    /// The mode's name and keys, and an optional status line below them, at the bottom centre of the screen.
    func showHUD(name: String, keys: [HUDKey], status: String, visible: Bool) {
        hud.isHidden = !visible
        guard visible else { return }

        if hudRowContent.name != name || hudRowContent.keys != keys {
            layOutHUDRow(name: name, keys: keys)
            hudRowContent = (name, keys)
        }
        let rowSize = hudRow.bounds.size
        let statusSize = status.isEmpty ? .zero : HUD.textSize(status, font: HUD.textFont)
        let statusHeight = status.isEmpty ? 0 : statusSize.height + HUD.lineGap
        let maxWidth = frame.width - 2 * HUD.padding.width
        let width = min(max(rowSize.width, statusSize.width), maxWidth)
        let height = rowSize.height + statusHeight + 2 * HUD.padding.height

        hud.frame = CGRect(
            x: ((frame.width - width) / 2 - HUD.padding.width).rounded(),
            y: Style.hudBottomInset,
            width: width + 2 * HUD.padding.width,
            height: height
        )
        hud.shadowPath = CGPath(rect: hud.bounds, transform: nil)
        // A row wider than the screen is cut off by the row's own bounds, not the HUD's, so the shadow stays.
        hudRow.frame = CGRect(x: HUD.padding.width, y: HUD.padding.height + statusHeight, width: min(rowSize.width, width), height: rowSize.height)
        hudStatus.isHidden = status.isEmpty
        hudStatus.frame = CGRect(x: HUD.padding.width, y: HUD.padding.height, width: width, height: statusSize.height)
        hudStatus.string = status
    }

    /// The mode's name in the pixel font, then each entry's keys as keycaps followed by what they do,
    /// in one row sized to fit, centred vertically.
    private func layOutHUDRow(name: String, keys: [HUDKey]) {
        hudRow.sublayers?.forEach { $0.removeFromSuperlayer() }
        let entries = keys.map { HUD.makeEntry($0, scale: backingScaleFactor).layer }
        let nameHeight = HUD.textSize(name, font: HUD.nameFont).height
        let height = max(nameHeight, entries.map(\.frame.height).max() ?? 0)
        let nameLayer = HUD.makeName(name, rowHeight: height, scale: backingScaleFactor)
        hudRow.addSublayer(nameLayer)
        var x = nameLayer.frame.width
        for entry in entries {
            x += HUD.entryGap
            entry.frame.origin = CGPoint(x: x, y: ((height - entry.frame.height) / 2).rounded())
            hudRow.addSublayer(entry)
            x += entry.frame.width
        }
        hudRow.bounds.size = CGSize(width: x, height: height)
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
        hud.isHidden = true
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

            let color = mark.colorIndex.map { Style.hintPalette[$0 % Style.hintPalette.count] } ?? Style.hintBackground
            outline.isHidden = mark.colorIndex == nil
            outline.frame = local.insetBy(dx: 1, dy: 1)
            outline.borderColor = color.cgColor

            let size = HUD.textSize(mark.code, font: Style.hintFont)
            let hintSize = CGSize(width: size.width + 2 * Style.hintPadding.width, height: size.height + 2 * Style.hintPadding.height)
            let origin = CGPoint(
                x: min(max(local.minX, 0), bounds.width - hintSize.width),
                y: min(max(local.maxY - hintSize.height, 0), bounds.height - hintSize.height)
            )
            background.frame = CGRect(origin: origin, size: hintSize)
            background.backgroundColor = color.cgColor
            background.isHidden = false
            text.frame = CGRect(x: Style.hintPadding.width, y: Style.hintPadding.height, width: size.width, height: size.height)
            let string = NSMutableAttributedString(string: mark.code, attributes: [.font: Style.hintFont, .foregroundColor: Palette.ink])
            string.addAttribute(.foregroundColor, value: Palette.ink.withAlphaComponent(0.35), range: NSRange(location: 0, length: min(typed, mark.code.utf16.count)))
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
        hintOutlines.addSublayer(outline)

        let background = CALayer()
        background.borderColor = NSColor(white: 0, alpha: 0.4).cgColor
        background.borderWidth = 0.5
        let text = CATextLayer()
        text.contentsScale = backingScaleFactor
        background.addSublayer(text)
        hints.addSublayer(background)
        return (outline, background, text)
    }
}

private extension CGMutablePath {
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
