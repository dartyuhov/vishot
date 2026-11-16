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
        let width = min(420, bounds.width)
        let height = min(360, bounds.height)
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
        selected = (selected + step + count) % count
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

    private func render() {
        guard let panel else { return }
        let root = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        HUD.stylePanel(root.layer!, style: theme.hud)
        let title = NSTextField(labelWithString: isChoosing ? "Choose a value" : "Capture options")
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
        let close = NSButton(title: "×", target: self, action: #selector(closeByPointer))
        close.setAccessibilityLabel("Close options")
        close.frame = CGRect(x: root.bounds.width - 52, y: root.bounds.height - 48, width: 40, height: 36)
        root.addSubview(close)
        let scroll = NSScrollView(frame: CGRect(x: 12, y: 12, width: root.bounds.width - 24, height: max(1, root.bounds.height - 68)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = NSView(frame: CGRect(x: 0, y: 0, width: scroll.contentSize.width,
            height: max(scroll.contentSize.height, CGFloat(visibleRows.count) * 48)))
        buttons = []
        for (index, row) in visibleRows.enumerated() {
            let button = NSButton(title: row.title + (row.value.isEmpty ? "" : ": " + row.value) + (row.choices.isEmpty ? "" : "  ›"), target: self, action: #selector(clicked(_:)))
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
            button.frame = CGRect(x: 4, y: document.bounds.height - CGFloat(index + 1) * 48, width: document.bounds.width - 8, height: 40)
            document.addSubview(button)
            buttons.append(button)
        }
        buttons.append(close)
        for (index, button) in buttons.enumerated() { button.nextKeyView = buttons[(index + 1) % buttons.count] }
        scroll.documentView = document
        root.addSubview(scroll)
        panel.contentView = root
        focus()
    }

    private func focus() {
        guard buttons.indices.contains(selected) else { return }
        let button = buttons[selected]
        panel?.makeFirstResponder(button)
        button.scrollToVisible(button.bounds)
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
