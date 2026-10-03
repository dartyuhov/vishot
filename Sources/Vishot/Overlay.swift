import AppKit
import Carbon.HIToolbox

private enum Style {
    static let borderWidth: CGFloat = 4
    static let cornerRadius: CGFloat = 12
    static let color = NSColor.controlAccentColor
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let labelPadding = CGSize(width: 8, height: 4)
    static let labelInset: CGFloat = 10
}

/// One transparent panel per screen. Panels are created once and reused, so showing the
/// overlay costs only an order-front plus a layer move.
final class OverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Void)?

    private let border = CALayer()
    private let labelBackground = CALayer()
    private let labelText = CATextLayer()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view

        border.borderWidth = Style.borderWidth
        border.borderColor = Style.color.cgColor
        border.cornerRadius = Style.cornerRadius

        labelBackground.backgroundColor = Style.color.cgColor
        labelBackground.cornerRadius = 6
        labelText.font = Style.labelFont
        labelText.fontSize = Style.labelFont.pointSize
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.contentsScale = screen.backingScaleFactor
        labelText.truncationMode = .end
        labelBackground.addSublayer(labelText)

        view.layer?.addSublayer(border)
        view.layer?.addSublayer(labelBackground)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    /// `rect` is in Cocoa global space. Parts outside this screen are clipped by the panel.
    func highlight(_ rect: CGRect, label: String) {
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let visible = local.intersects(CGRect(origin: .zero, size: frame.size))
        border.isHidden = !visible
        labelBackground.isHidden = !visible
        guard visible else { return }

        border.frame = local.insetBy(dx: -Style.borderWidth, dy: -Style.borderWidth)

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
}

final class OverlayController: NSObject, NSWindowDelegate {
    private var panels: [OverlayPanel] = []
    private var windows: [WindowInfo] = []
    private var selected = 0
    private var isShowing = false
    private let capturer = Capturer()

    override init() {
        super.init()
        rebuildPanels()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    private func show() {
        windows = WindowCatalog.visibleWindows()
        guard !windows.isEmpty, let keyPanel = panels.first else {
            NSSound.beep()
            return
        }
        capturer.prefetch()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        selected = windows.firstIndex { $0.pid == frontPID } ?? 0
        isShowing = true
        render()
        panels.forEach { $0.orderFrontRegardless() }
        keyPanel.makeKey()
    }

    private func hide() {
        isShowing = false
        panels.forEach { $0.orderOut(nil) }
    }

    private func confirm() {
        let target = windows[selected]
        hide()
        capturer.capture(windowID: target.id)
    }

    private func move(_ direction: Direction) {
        guard let next = Navigator.neighbor(of: windows[selected], in: windows, toward: direction),
              let index = windows.firstIndex(where: { $0.id == next.id })
        else { return }
        selected = index
        render()
    }

    private func cycle(by step: Int) {
        selected = (selected + step + windows.count) % windows.count
        render()
    }

    private func render() {
        let target = windows[selected]
        let rect = target.frame.flippedBetweenCocoaAndCG
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panels.forEach { $0.highlight(rect, label: target.label) }
        CATransaction.commit()
    }

    /// Key codes, not characters, so hjkl keep working with non-Latin keyboard layouts.
    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_ANSI_H, kVK_LeftArrow: move(.left)
        case kVK_ANSI_J, kVK_DownArrow: move(.down)
        case kVK_ANSI_K, kVK_UpArrow: move(.up)
        case kVK_ANSI_L, kVK_RightArrow: move(.right)
        case kVK_Tab: cycle(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: confirm()
        case kVK_Escape, kVK_ANSI_Q: hide()
        default: break
        }
    }

    @objc private func screensChanged() {
        hide()
        rebuildPanels()
    }

    private func rebuildPanels() {
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen)
            panel.delegate = self
            panel.onKeyDown = { [weak self] in self?.handle($0) }
            return panel
        }
    }

    /// Clicking elsewhere or switching Spaces cancels the selection.
    func windowDidResignKey(_ notification: Notification) {
        if isShowing { hide() }
    }
}
