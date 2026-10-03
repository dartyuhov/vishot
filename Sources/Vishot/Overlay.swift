import AppKit
import Carbon.HIToolbox

final class OverlayController: NSObject, NSWindowDelegate {
    private enum Mode {
        case window, element, screen

        var keys: String {
            switch self {
            case .window: "WINDOW   hjkl move · v elements · G screen · ↵ copy · esc cancel"
            case .element: "ELEMENT  hjkl move · i in · o out · G screen · ↵ copy · esc back"
            case .screen: "SCREEN   hjkl move · ↵ copy · esc back"
            }
        }
    }

    /// One level of the element tree. `selected` is saved when going in, and restored when coming out.
    private struct ElementLevel {
        let root: AXNode
        var nodes: [AXNode]
        var selected = 0
    }

    private var panels: [OverlayPanel] = []
    private var isShowing = false
    private let capturer = Capturer()
    private let elements = ElementCatalog()

    private var mode = Mode.window
    private var windows: [WindowInfo] = []
    /// What the current mode selects from, and the index of the selection.
    private var targets: [CaptureTarget] = []
    private var selected = 0
    /// Index in `windows` of the window last selected or browsed. Window mode returns to it.
    private var currentWindow = 0
    private var levels: [ElementLevel] = []
    /// Windows whose elements could not be read, so hovering over them doesn't retry on every move.
    private var unreadableWindows: Set<CGWindowID> = []
    private var status = ""
    private var warmUpTimer: Timer?

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
        currentWindow = windows.firstIndex { $0.pid == frontPID } ?? 0
        unreadableWindows = []
        status = ""
        enterWindowMode()
        isShowing = true
        render()
        panels.forEach { $0.orderFrontRegardless() }
        keyPanel.makeKey()
    }

    private func hide() {
        isShowing = false
        stopWarmUp()
        levels = []
        panels.forEach { $0.orderOut(nil) }
        elements.finish()
    }

    private func confirm() {
        let target = targets[selected]
        hide()
        capturer.capture(target)
    }

    // MARK: - Modes

    private func enterWindowMode() {
        stopWarmUp()
        mode = .window
        levels = []
        targets = windows.map(\.target)
        selected = currentWindow
    }

    private func enterElementMode() {
        guard elements.isTrusted() else {
            NSSound.beep()
            status = "Allow Vishot in System Settings → Privacy & Security → Accessibility"
            return
        }
        guard openElements(ofWindow: selected) else {
            NSSound.beep()
            return
        }
        let mouse = NSEvent.mouseLocation.flippedBetweenCocoaAndCG
        selected = windows[currentWindow].frame.contains(mouse)
            ? smallestTarget(containing: mouse) ?? largestTarget()
            : largestTarget()
    }

    /// Roots Element mode at the top level of a window. Returns false when its elements can't be read.
    private func openElements(ofWindow index: Int) -> Bool {
        let window = windows[index]
        guard let root = elements.windowNode(for: window) else {
            unreadableWindows.insert(window.id)
            return false
        }
        elements.prepare(root, pid: window.pid)
        let warmUpEnd = elements.warmUpEnd(for: window.pid)
        let nodes = elements.level(below: root, in: window)
        guard !nodes.isEmpty else {
            // An app still building its tree is worth another try.
            if warmUpEnd == nil { unreadableWindows.insert(window.id) } else { status = "loading page…" }
            return false
        }
        stopWarmUp()
        mode = .element
        currentWindow = index
        levels = [ElementLevel(root: root, nodes: nodes)]
        targets = elements.targets(for: nodes, in: window)
        selected = largestTarget()
        if let warmUpEnd { startWarmUp(until: warmUpEnd) }
        return true
    }

    private func goIn() {
        let window = windows[currentWindow]
        let node = levels[levels.count - 1].nodes[selected]
        let nodes = elements.level(below: node, in: window)
        guard !nodes.isEmpty else {
            NSSound.beep()
            status = "nothing inside"
            return
        }
        levels[levels.count - 1].selected = selected
        levels.append(ElementLevel(root: node, nodes: nodes))
        targets = elements.targets(for: nodes, in: window)
        selected = largestTarget()
    }

    private func goOut() {
        guard levels.count > 1 else {
            enterWindowMode()
            return
        }
        levels.removeLast()
        let level = levels[levels.count - 1]
        let window = windows[currentWindow]
        // Reloaded, as the parent may have changed while we were inside it.
        let nodes = elements.level(below: level.root, in: window)
        if !nodes.isEmpty { levels[levels.count - 1].nodes = nodes }
        targets = elements.targets(for: levels[levels.count - 1].nodes, in: window)
        selected = min(level.selected, targets.count - 1)
    }

    private func enterScreenMode() {
        let anchor = targets[selected].anchor
        let displays = DisplayCatalog.displays()
        guard !displays.isEmpty else {
            NSSound.beep()
            return
        }
        if mode == .window { currentWindow = selected }
        stopWarmUp()
        mode = .screen
        levels = []
        targets = displays
        selected = displays.firstIndex { $0.frame.contains(anchor) } ?? 0
    }

    // MARK: - Warm-up

    /// Electron and Chromium build their trees after a flag is set, so the level reloads until `end`.
    private func startWarmUp(until end: Date) {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.reloadLevel(until: end)
        }
        RunLoop.main.add(timer, forMode: .common)
        warmUpTimer = timer
    }

    private func reloadLevel(until end: Date) {
        guard isShowing, mode == .element, Date() < end, let level = levels.last else {
            stopWarmUp()
            status = ""
            if isShowing { render() }
            return
        }
        let window = windows[currentWindow]
        let nodes = elements.level(below: level.root, in: window)
        let reloaded = elements.targets(for: nodes, in: window)
        guard !reloaded.isEmpty,
              reloaded.map(\.frame) != targets.map(\.frame) || reloaded.map(\.label) != targets.map(\.label)
        else { return }
        levels[levels.count - 1].nodes = nodes
        targets = reloaded
        selected = min(selected, targets.count - 1)
        render()
    }

    private func stopWarmUp() {
        warmUpTimer?.invalidate()
        warmUpTimer = nil
    }

    // MARK: - Selection

    private func move(_ direction: Direction) {
        guard let next = Navigator.neighbor(of: selected, in: targets, toward: direction) else { return }
        selected = next
    }

    private func cycle(by step: Int) {
        selected = (selected + step + targets.count) % targets.count
    }

    private func smallestTarget(containing point: CGPoint) -> Int? {
        targets.indices
            .filter { targets[$0].frame.contains(point) }
            .min { area(targets[$0].frame) < area(targets[$1].frame) }
    }

    private func largestTarget() -> Int {
        targets.indices.max { area(targets[$0].frame) < area(targets[$1].frame) } ?? 0
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// Selects what is under the cursor. Returns false over empty space, keeping the selection.
    private func select(at point: CGPoint) -> Bool {
        let index: Int?
        switch mode {
        case .window, .screen:
            // Windows are ordered front to back, so the first hit is the frontmost.
            index = targets.firstIndex { $0.frame.contains(point) }
        case .element:
            guard let window = windows.firstIndex(where: { $0.frame.contains(point) }) else { return false }
            if window != currentWindow {
                guard !unreadableWindows.contains(windows[window].id), openElements(ofWindow: window) else { return false }
            }
            index = smallestTarget(containing: point)
        }
        guard let index else { return false }
        selected = index
        return true
    }

    private func render() {
        let target = targets[selected]
        let rect = target.frame.flippedBetweenCocoaAndCG
        let anchor = target.anchor.flippedBetweenCocoaAndCG
        let hudPanel = panels.first { $0.frame.contains(anchor) } ?? panels.first
        let statusLine = status.isEmpty && warmUpTimer != nil ? "loading page…" : status
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for panel in panels {
            panel.highlight(rect, label: target.label)
            panel.showHUD(keys: mode.keys, status: statusLine, visible: panel === hudPanel)
        }
        CATransaction.commit()
    }

    // MARK: - Input

    /// Key codes, not characters, so the keys keep working with non-Latin keyboard layouts.
    private func handle(_ event: NSEvent) {
        status = ""
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_ANSI_H, kVK_LeftArrow: move(.left)
        case kVK_ANSI_J, kVK_DownArrow: move(.down)
        case kVK_ANSI_K, kVK_UpArrow: move(.up)
        case kVK_ANSI_L, kVK_RightArrow: move(.right)
        case kVK_Tab: cycle(by: shift ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            confirm()
            return
        case kVK_ANSI_V where mode == .window: enterElementMode()
        case kVK_ANSI_I where mode == .element: goIn()
        case kVK_ANSI_O where mode == .element: goOut()
        case kVK_ANSI_G where shift && mode != .screen: enterScreenMode()
        case kVK_Escape where mode != .window: enterWindowMode()
        case kVK_Escape, kVK_ANSI_Q:
            hide()
            return
        default: break
        }
        // The Accessibility prompt can take key focus, which closes the overlay.
        if isShowing { render() }
    }

    private func mouseMoved(to point: CGPoint) {
        guard isShowing else { return }
        let before = targets[selected]
        // Even a miss can re-root Element mode on another window, so compare what is drawn rather than indices.
        _ = select(at: point)
        let after = targets[selected]
        if after.frame != before.frame || after.label != before.label { render() }
    }

    private func mouseDown(at point: CGPoint) {
        guard isShowing, select(at: point) else { return }
        confirm()
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
            panel.onMouseMoved = { [weak self] in self?.mouseMoved(to: $0) }
            panel.onMouseDown = { [weak self] in self?.mouseDown(at: $0) }
            return panel
        }
    }

    /// Clicking elsewhere or switching Spaces cancels the selection. A click on another screen's
    /// panel moves key focus between our own panels, which is not a cancel.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            if isShowing, !panels.contains(where: \.isKeyWindow) { hide() }
        }
    }
}
