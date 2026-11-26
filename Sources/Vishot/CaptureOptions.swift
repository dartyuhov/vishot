import AppKit
import Carbon.HIToolbox

/// Capture-independent interaction/presentation owner. Content supplies actions;
/// the shell knows nothing about recording, permissions, or preference storage.
final class CaptureOptions: NSObject {
    struct Row {
        let id: String
        let title: String
        var value = ""
        var enabled = true
        var choices: [Row] = []
        var isOn: Bool? = nil
        var activate: () -> Void = {}
    }
    private var rows: [Row] = []
    private var chooser: [Row]?
    private var parentIndex = 0
    private(set) var selected = 0
    private(set) var isOpen = false
    var isChoosing: Bool { chooser != nil }
    var visibleRows: [Row] { chooser ?? rows }
    var onClose: (() -> Void)?
    var onPointerDismiss: (() -> Void)?
    private var panel: OptionsPanel?
    private var buttons: [NSButton] = []
    private var theme = ThemeCatalog.pixel
    private var focusObserver: NSObjectProtocol?
    private var restoreFocus: (() -> Void)?
    private var placementBounds = CGRect.zero
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }

    func open(rows: [Row], restoreFocus: @escaping () -> Void = {}) {
        guard !isOpen else { return }
        self.restoreFocus = restoreFocus
        self.rows = rows
        chooser = nil
        selected = 0
        isOpen = true
    }

    func update(rows: [Row]) {
        self.rows = rows
        // Keep a chooser's current position while its values refresh.
        if chooser != nil, rows.indices.contains(parentIndex) { chooser = rows[parentIndex].choices }
        selected = min(selected, max(0, visibleRows.count - 1))
        render()
    }

    func present(near point: CGPoint, theme: ResolvedTheme) {
        self.theme = theme
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        placementBounds = bounds
        let size = fittingSize(in: bounds.size)
        let width = size.width
        let height = size.height
        let rect = CGRect(x: min(max(point.x - width / 2, bounds.minX), bounds.maxX - width),
            y: min(max(point.y - height / 2, bounds.minY), bounds.maxY - height), width: width, height: height)
        let panel = OptionsPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.onKey = { [weak self] event in
            if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) { return false }
            if event.isARepeat, [kVK_ANSI_O, kVK_Space, kVK_Return, kVK_Escape].contains(Int(event.keyCode)) { return true }
            return self?.handle(Int(event.keyCode), backwards: event.modifierFlags.contains(.shift)) ?? true
        }
        self.panel = panel
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel?.isKeyWindow != true else { return }
                self.close()
            }
        }
        render()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    @discardableResult func handle(_ key: Int, backwards: Bool = false) -> Bool {
        guard isOpen else { return false }
        switch key {
        case kVK_ANSI_O: close()
        case kVK_Escape:
            if chooser != nil { chooser = nil; selected = parentIndex; render() } else { close() }
        case kVK_ANSI_J, kVK_DownArrow, kVK_Tab:
            move(key == kVK_Tab && backwards ? -1 : 1)
        case kVK_ANSI_K, kVK_UpArrow: move(-1)
        case kVK_Space, kVK_Return, kVK_ANSI_L, kVK_RightArrow: activate(selected)
        case kVK_ANSI_H, kVK_LeftArrow:
            if chooser != nil { chooser = nil; selected = parentIndex; render() }
        default: break
        }
        return true // Never leak picker confirmation or navigation.
    }

    private func move(_ step: Int) {
        let count = visibleRows.count + 1 // Close is keyboard reachable too.
        repeat { selected = (selected + step + count) % count }
        while selected < visibleRows.count && !visibleRows[selected].enabled
        focus()
    }

    func activate(_ index: Int) {
        guard isOpen else { return }
        if index == visibleRows.count { close(); return }
        guard visibleRows.indices.contains(index), visibleRows[index].enabled else { return }
        selected = index
        let row = visibleRows[index]
        if !row.choices.isEmpty {
            parentIndex = index; chooser = row.choices; selected = 0; render()
        } else {
            if chooser != nil { chooser = nil; selected = parentIndex }
            row.activate()
            render()
        }
    }

    /// The caller consumes this whole pointer gesture, including mouse-up.
    @discardableResult func outsideClick() -> Bool {
        guard isOpen else { return false }
        onPointerDismiss?()
        close()
        return true
    }

    func contains(cgPoint: CGPoint) -> Bool { panel?.frame.contains(cgPoint.flippedBetweenCocoaAndCG) ?? false }
    var isKeyWindow: Bool { panel?.isKeyWindow == true }

    @objc func close() {
        guard isOpen else { return }
        isOpen = false
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        chooser = nil
        panel?.orderOut(nil)
        panel = nil
        let restore = restoreFocus
        restoreFocus = nil
        restore?()
        onClose?()
    }

    @objc private func clicked(_ sender: NSButton) { activate(sender.tag) }
    @objc private func closeByPointer() { outsideClick() }

    /// Content sizing is shared by the outer popup and scrolling nested choosers.
    func fittingSize(in available: CGSize) -> CGSize {
        let width = min(420, available.width)
        let height = 68 + (visibleRows.isEmpty ? 48 : rowFrames(width: width - 24).map(\.maxY).max() ?? 0)
        return CGSize(width: width, height: min(height, available.height))
    }

    private func rowHeights(width: CGFloat) -> [CGFloat] {
        visibleRows.map { row in
            guard !row.enabled, row.value.isEmpty else { return 48 }
            let height = (row.title as NSString).boundingRect(
                with: CGSize(width: max(1, width - 64), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: theme.hud.textFont]).height
            return max(48, ceil(height) + 24)
        }
    }

    /// Adjacent toggles share a row when both labels fit; choosers stay full width.
    func rowFrames(width: CGFloat) -> [CGRect] {
        let heights = rowHeights(width: width + 24)
        var frames: [CGRect] = []
        var y: CGFloat = 0
        var index = 0
        while index < visibleRows.count {
            let pair = width >= 360 && visibleRows[index].isOn != nil &&
                index + 1 < visibleRows.count && visibleRows[index + 1].isOn != nil
            if pair {
                let half = (width - 8) / 2
                frames.append(CGRect(x: 0, y: y, width: half, height: 48))
                frames.append(CGRect(x: half + 8, y: y, width: half, height: 48))
                y += 48
                index += 2
            } else {
                frames.append(CGRect(x: 0, y: y, width: width, height: heights[index]))
                y += heights[index]
                index += 1
            }
        }
        return frames
    }

    private func render() {
        guard let panel else { return }
        let size = fittingSize(in: placementBounds.size)
        let oldFrame = panel.frame
        panel.setFrame(CGRect(x: min(max(oldFrame.minX, placementBounds.minX), placementBounds.maxX - size.width),
            y: min(max(oldFrame.maxY - size.height, placementBounds.minY), placementBounds.maxY - size.height),
            width: size.width, height: size.height), display: false)
        let root = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        HUD.stylePanel(root.layer!, style: theme.hud)
        let title = NSTextField(labelWithString: isChoosing ? rows[parentIndex].title : "Capture options")
        title.font = theme.hud.nameFont
        title.textColor = theme.hud.text
        title.frame = CGRect(x: 18, y: root.bounds.height - 44, width: root.bounds.width - 80, height: 28)
        root.addSubview(title)
        if visibleRows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No options for this capture type.")
            empty.font = theme.hud.textFont
            empty.textColor = theme.hud.muted
            empty.frame = CGRect(x: 18, y: root.bounds.height - 100, width: root.bounds.width - 36, height: 40)
            root.addSubview(empty)
        }
        let pixel = theme.hud.panel.cornerRadius == 0
        let close = pixel ? PixelOptionsButton(title: "×", theme: theme, target: self, action: #selector(closeByPointer))
            : NSButton(title: "×", target: self, action: #selector(closeByPointer))
        close.setAccessibilityLabel("Close options")
        close.frame = CGRect(x: root.bounds.width - 52, y: root.bounds.height - 48, width: 40, height: 36)
        root.addSubview(close)
        let scroll = NSScrollView(frame: CGRect(x: 12, y: 12, width: root.bounds.width - 24, height: max(1, root.bounds.height - 68)))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let frames = rowFrames(width: scroll.contentSize.width)
        let document = NSView(frame: CGRect(x: 0, y: 0, width: scroll.contentSize.width,
            height: max(scroll.contentSize.height, frames.map(\.maxY).max() ?? 0)))
        buttons = []
        for (index, row) in visibleRows.enumerated() {
            let layout = frames[index]
            let y = document.bounds.height - layout.maxY
            let frame = CGRect(x: layout.minX + 4, y: y + 4, width: layout.width - 8, height: layout.height - 8)
            if !row.enabled, row.value.isEmpty {
                let help = NSTextField(wrappingLabelWithString: row.title)
                help.font = theme.hud.textFont
                help.textColor = theme.hud.muted
                help.frame = frame.insetBy(dx: 8, dy: 4)
                document.addSubview(help)
                // Preserve row indices for keyboard dispatch, without a disabled focus target.
                let placeholder = NSButton(frame: frame)
                placeholder.isHidden = true
                buttons.append(placeholder)
                continue
            }
            let text = row.title + (row.value.isEmpty || row.isOn != nil ? "" : ": " + row.value) + (row.choices.isEmpty ? "" : "  ›")
            let button: NSButton
            if pixel {
                let control = PixelOptionsButton(title: text, theme: theme, target: self, action: #selector(clicked(_:)))
                control.isOn = row.isOn
                button = control
            } else {
                button = NSButton(title: text, target: self, action: #selector(clicked(_:)))
                if let isOn = row.isOn {
                    button.setButtonType(.switch)
                    button.state = isOn ? .on : .off
                }
            }
            button.tag = index
            button.font = theme.hud.textFont
            button.contentTintColor = theme.hud.text
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = row.title + (row.value.isEmpty ? "" : ": " + row.value)
            button.isEnabled = row.enabled
            button.setAccessibilityLabel(row.title)
            button.setAccessibilityValue(row.value)
            button.setAccessibilityHelp(row.choices.isEmpty ? "Press Space or Return to activate" : "Press Return to choose a value")
            button.frame = frame
            document.addSubview(button)
            buttons.append(button)
            if pixel, index < visibleRows.count - 1, frames[index + 1].minY > layout.minY {
                let separator = NSView(frame: CGRect(x: 4, y: y, width: document.bounds.width - 8, height: 2))
                separator.wantsLayer = true
                separator.layer?.backgroundColor = theme.hud.panel.border.cgColor
                document.addSubview(separator)
            }
        }
        buttons.append(close)
        let focusable = buttons.filter { !$0.isHidden && $0.isEnabled }
        for (index, button) in focusable.enumerated() { button.nextKeyView = focusable[(index + 1) % focusable.count] }
        scroll.documentView = document
        root.addSubview(scroll)
        panel.contentView = root
        focus()
    }

    private func focus() {
        guard buttons.indices.contains(selected) else { return }
        buttons.enumerated().forEach { index, button in
            (button as? PixelOptionsButton)?.isSelected = index == selected
        }
        let button = buttons[selected]
        panel?.makeFirstResponder(button)
        button.scrollToVisible(button.bounds)
    }
}

/// Square native buttons retain AppKit tracking and accessibility while drawing
/// their own plate, block indicator and focus/selection ring in the Pixel theme.
private final class PixelOptionsButton: NSButton {
    private let theme: ResolvedTheme
    private let caption: String
    var isOn: Bool?
    var isSelected = false { didSet { needsDisplay = true } }

    init(title: String, theme: ResolvedTheme, target: AnyObject?, action: Selector?) {
        self.theme = theme
        caption = title
        super.init(frame: .zero)
        self.title = ""
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let active = isSelected || window?.firstResponder === self
        (isHighlighted ? theme.editor.active : theme.hud.keycap.face).setFill()
        rect.fill()
        (active ? theme.picker.accent : theme.hud.keycap.edge).setStroke()
        let edge = NSBezierPath(rect: rect)
        edge.lineWidth = 2
        edge.stroke()
        let color = isHighlighted ? theme.editor.activeText : theme.hud.text
        var inset: CGFloat = caption == "×" ? 0 : 12
        if let isOn {
            let block = CGRect(x: 12, y: floor((bounds.height - 12) / 2), width: 12, height: 12)
            (isOn ? theme.picker.accent : theme.hud.muted).setStroke()
            NSBezierPath(rect: block).stroke()
            if isOn { theme.picker.accent.setFill(); block.insetBy(dx: 3, dy: 3).fill() }
            inset = 36
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = caption == "×" ? .center : .left
        let font = caption == "×" ? theme.hud.nameFont : theme.hud.textFont
        let height = ceil(font.ascender - font.descender + font.leading)
        (caption as NSString).draw(in: CGRect(x: inset, y: floor((bounds.height - height) / 2),
            width: bounds.width - inset - (caption == "×" ? 0 : 12), height: height),
            withAttributes: [.font: font, .foregroundColor: isEnabled ? color : theme.hud.muted, .paragraphStyle: paragraph])
    }
}

private final class OptionsPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}
