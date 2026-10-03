import AppKit

private enum Style {
    static let borderWidth: CGFloat = 4
    static let cornerRadius: CGFloat = 12
    static let color = NSColor.controlAccentColor
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let labelPadding = CGSize(width: 8, height: 4)
    static let labelInset: CGFloat = 10

    static let hudKeysFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static let hudStatusFont = NSFont.systemFont(ofSize: 12)
    static let hudBackground = NSColor(white: 0.1, alpha: 0.85)
    static let hudPadding = CGSize(width: 14, height: 8)
    static let hudLineGap: CGFloat = 4
    static let hudBottomInset: CGFloat = 24
    /// Fully transparent pixels let clicks through to the windows below, so the panel keeps a trace of tint.
    static let panelBackground = NSColor(white: 0, alpha: 0.01)

    static let hintFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    static let hintBackground = NSColor(red: 1, green: 0.84, blue: 0.3, alpha: 1)
    static let hintPadding = CGSize(width: 4, height: 1)
}

/// One transparent panel per screen. Panels are created once and reused, so showing the
/// overlay costs only an order-front plus a layer move.
final class OverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Void)?
    /// Points are in CoreGraphics global space.
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?

    private let border = CALayer()
    private let labelBackground = CALayer()
    private let labelText = CATextLayer()
    private let hud = CALayer()
    private let hudKeys = CATextLayer()
    private let hudStatus = CATextLayer()
    /// Hint labels, grown on first use and reused after.
    private var hintLayers: [(background: CALayer, text: CATextLayer)] = []

    init(screen: NSScreen) {
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
        contentView = view

        border.borderWidth = Style.borderWidth
        border.borderColor = Style.color.cgColor
        border.cornerRadius = Style.cornerRadius

        labelBackground.backgroundColor = Style.color.cgColor
        labelBackground.cornerRadius = 6
        configure(labelText, font: Style.labelFont, color: .white, scale: screen.backingScaleFactor)
        labelBackground.addSublayer(labelText)

        hud.backgroundColor = Style.hudBackground.cgColor
        hud.cornerRadius = 10
        hud.isHidden = true
        configure(hudKeys, font: Style.hudKeysFont, color: .white, scale: screen.backingScaleFactor)
        configure(hudStatus, font: Style.hudStatusFont, color: NSColor(white: 1, alpha: 0.7), scale: screen.backingScaleFactor)
        hud.addSublayer(hudKeys)
        hud.addSublayer(hudStatus)

        view.layer?.addSublayer(border)
        view.layer?.addSublayer(labelBackground)
        view.layer?.addSublayer(hud)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    /// `rect` is in Cocoa global space. Parts outside this screen are clipped by the panel.
    func highlight(_ rect: CGRect, label: String) {
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let visible = local.intersects(bounds)
        border.isHidden = !visible
        labelBackground.isHidden = !visible
        guard visible else { return }

        // A target that touches the screen edge (always true for displays) draws its border inside,
        // where it stays visible.
        let outset = local.insetBy(dx: -Style.borderWidth, dy: -Style.borderWidth)
        border.frame = bounds.contains(local) && !bounds.contains(outset) ? local : outset

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

    /// Labels at the top-left corner of each rect, which is in Cocoa global space. The first `typed`
    /// letters of each label are dimmed.
    func showHints(_ hints: [(rect: CGRect, label: String)], typed: Int) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        var used = 0
        for hint in hints {
            let local = hint.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard local.intersects(bounds) else { continue }
            if used == hintLayers.count { hintLayers.append(makeHintLayer()) }
            let (background, text) = hintLayers[used]
            used += 1

            let size = textSize(hint.label, font: Style.hintFont)
            let labelSize = CGSize(width: size.width + 2 * Style.hintPadding.width, height: size.height + 2 * Style.hintPadding.height)
            let origin = CGPoint(
                x: min(max(local.minX, 0), bounds.width - labelSize.width),
                y: min(max(local.maxY - labelSize.height, 0), bounds.height - labelSize.height)
            )
            background.frame = CGRect(origin: origin, size: labelSize)
            text.frame = CGRect(x: Style.hintPadding.width, y: Style.hintPadding.height, width: size.width, height: size.height)
            let string = NSMutableAttributedString(string: hint.label, attributes: [.font: Style.hintFont, .foregroundColor: NSColor.black])
            string.addAttribute(.foregroundColor, value: NSColor(white: 0, alpha: 0.35), range: NSRange(location: 0, length: min(typed, hint.label.utf16.count)))
            text.string = string
            background.isHidden = false
        }
        for unused in hintLayers[used...] { unused.background.isHidden = true }
    }

    private func makeHintLayer() -> (background: CALayer, text: CATextLayer) {
        let background = CALayer()
        background.backgroundColor = Style.hintBackground.cgColor
        background.cornerRadius = 3
        background.borderColor = NSColor(white: 0, alpha: 0.4).cgColor
        background.borderWidth = 0.5
        let text = CATextLayer()
        text.contentsScale = backingScaleFactor
        background.addSublayer(text)
        // Below the HUD, above the selection.
        contentView?.layer?.insertSublayer(background, below: hud)
        return (background, text)
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

/// Reports hover and clicks. `.activeAlways` keeps hover working on screens whose panel is not key.
private final class OverlayView: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?

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

    private func globalLocation(of event: NSEvent) -> CGPoint {
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return point.flippedBetweenCocoaAndCG
    }
}
