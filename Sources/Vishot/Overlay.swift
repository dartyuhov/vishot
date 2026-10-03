import AppKit
import Carbon.HIToolbox

final class OverlayController: NSObject, NSWindowDelegate {
    private enum Mode {
        case window, element, hint, screen

        var keys: String {
            switch self {
            case .window: "WINDOW   hjkl move · v elements · f hints · G screen · ↵ copy · esc cancel"
            case .element: "ELEMENT  hjkl move · i in · o out · f hints · G screen · ↵ copy · esc back"
            case .hint: "HINT     type a label · ⌫ undo · esc back"
            case .screen: "SCREEN   hjkl move · ↵ copy · esc back"
            }
        }
    }

    /// A labelled element in hint mode, with the levels that lead to it.
    private struct Hint {
        let label: String
        let path: [ElementLevel<AXNode>]
        let target: CaptureTarget
    }

    /// How many levels below the current one get hint labels.
    private static let hintDepth = 3

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
    /// The element levels from the window down to the current one. `selected` of each parent level is
    /// saved when going in, and restored when coming out.
    private var levels: [ElementLevel<AXNode>] = []
    /// Levels loaded for the current window. Hover walks the tree on every mouse move, so it must not
    /// repeat Accessibility calls. Entries hold their node, so its identifier can't be reused.
    private var levelCache: [ObjectIdentifier: (node: AXNode, nodes: [AXNode])] = [:]
    /// Windows whose elements could not be read, so hovering over them doesn't retry on every move.
    private var unreadableWindows: Set<CGWindowID> = []
    private var hints: [Hint] = []
    private var typedHint = ""
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
        levelCache = [:]
        hints = []
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
        levelCache = [:]
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
        levelCache = [ObjectIdentifier(root): (root, nodes)]
        levels = [ElementLevel(root: root, nodes: nodes)]
        targets = elements.targets(for: nodes, in: window)
        selected = largestTarget()
        if let warmUpEnd { startWarmUp(until: warmUpEnd) }
        return true
    }

    private func loadLevel(below node: AXNode) -> [AXNode] {
        if let cached = levelCache[ObjectIdentifier(node)] { return cached.nodes }
        let nodes = elements.level(below: node, in: windows[currentWindow])
        levelCache[ObjectIdentifier(node)] = (node, nodes)
        return nodes
    }

    /// Makes the last of `levels` current.
    private func showLevels(_ newLevels: [ElementLevel<AXNode>]) {
        levels = newLevels
        let level = levels[levels.count - 1]
        targets = elements.targets(for: level.nodes, in: windows[currentWindow])
        selected = min(level.selected, targets.count - 1)
    }

    private func goIn() {
        let node = levels[levels.count - 1].nodes[selected]
        let nodes = loadLevel(below: node)
        guard !nodes.isEmpty else {
            NSSound.beep()
            status = "nothing inside"
            return
        }
        levels[levels.count - 1].selected = selected
        showLevels(levels + [ElementLevel(root: node, nodes: nodes)])
        selected = largestTarget()
    }

    private func goOut() {
        guard levels.count > 1 else {
            enterWindowMode()
            return
        }
        var parent = levels[levels.count - 2]
        // Reloaded, as the parent may have changed while we were inside it.
        let nodes = elements.level(below: parent.root, in: windows[currentWindow])
        if !nodes.isEmpty {
            parent.nodes = nodes
            levelCache[ObjectIdentifier(parent.root)] = (parent.root, nodes)
        }
        showLevels(levels.dropLast(2) + [parent])
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
        levelCache = [:]
        targets = displays
        selected = displays.firstIndex { $0.frame.contains(anchor) } ?? 0
    }

    // MARK: - Hints

    /// Labels the elements a few levels below the current one, entering Element mode first if needed.
    private func startHints() {
        if mode == .window {
            enterElementMode()
            guard mode == .element else { return }
        }
        let window = windows[currentWindow]
        let parents = Array(levels.dropLast())
        let paths = ElementFilter.hintPaths(below: levels[levels.count - 1].root, maxDepth: Self.hintDepth) {
            loadLevel(below: $0)
        }
        guard !paths.isEmpty else {
            NSSound.beep()
            status = "nothing to label"
            return
        }
        hints = zip(HintLabels.make(count: paths.count), paths).map { label, path in
            let level = path[path.count - 1]
            return Hint(label: label, path: parents + path, target: elements.target(for: level.nodes[level.selected], in: window))
        }
        typedHint = ""
        mode = .hint
    }

    private func typeHint(_ letter: String) {
        let typed = typedHint + letter
        let matches = hints.filter { $0.label.hasPrefix(typed) }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        typedHint = typed
        // Labels have equal length, so a complete label matches exactly one hint.
        if let hint = matches.first(where: { $0.label == typed }) {
            endHints()
            showLevels(hint.path)
        }
    }

    private func endHints() {
        hints = []
        typedHint = ""
        mode = .element
    }

    private func handleHint(_ keyCode: Int) {
        switch keyCode {
        case kVK_Escape: endHints()
        case kVK_Delete: typedHint = String(typedHint.dropLast())
        default:
            if let letter = HintLabels.letter(forKeyCode: keyCode) { typeHint(letter) }
        }
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
        guard isShowing, mode == .element || mode == .hint, Date() < end, let level = levels.last else {
            stopWarmUp()
            status = ""
            if isShowing { render() }
            return
        }
        // Hint labels point into the levels as they were when shown.
        guard mode == .element else { return }
        let window = windows[currentWindow]
        let nodes = elements.level(below: level.root, in: window)
        let reloaded = elements.targets(for: nodes, in: window)
        guard !reloaded.isEmpty,
              reloaded.map(\.frame) != targets.map(\.frame) || reloaded.map(\.label) != targets.map(\.label)
        else { return }
        // The tree is still changing, so nothing loaded before is current.
        levelCache = [ObjectIdentifier(level.root): (level.root, nodes)]
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
        switch mode {
        case .window, .screen:
            // Windows are ordered front to back, so the first hit is the frontmost.
            guard let index = targets.firstIndex(where: { $0.frame.contains(point) }) else { return false }
            selected = index
            return true
        case .element:
            guard let window = windows.firstIndex(where: { $0.frame.contains(point) }) else { return false }
            if window != currentWindow {
                guard !unreadableWindows.contains(windows[window].id), openElements(ofWindow: window) else { return false }
            }
            // The deepest element under the cursor, with the levels above it, so `o` widens from there.
            let path = ElementFilter.path(to: point, below: levels[0].root) { loadLevel(below: $0) }
            guard !path.isEmpty else { return false }
            showLevels(path)
            return true
        case .hint:
            return false
        }
    }

    private func render() {
        let target = targets[selected]
        let rect = target.frame.flippedBetweenCocoaAndCG
        let anchor = target.anchor.flippedBetweenCocoaAndCG
        let hudPanel = panels.first { $0.frame.contains(anchor) } ?? panels.first
        let statusLine = status.isEmpty && warmUpTimer != nil ? "loading page…" : status
        let shownHints = hints
            .filter { $0.label.hasPrefix(typedHint) }
            .map { (rect: $0.target.frame.flippedBetweenCocoaAndCG, label: $0.label) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for panel in panels {
            panel.highlight(rect, label: target.label)
            panel.showHints(shownHints, typed: typedHint.count)
            panel.showHUD(keys: mode.keys, status: statusLine, visible: panel === hudPanel)
        }
        CATransaction.commit()
    }

    // MARK: - Input

    /// Key codes, not characters, so the keys keep working with non-Latin keyboard layouts.
    private func handle(_ event: NSEvent) {
        status = ""
        let keyCode = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        if mode == .hint {
            handleHint(keyCode)
            render()
            return
        }
        switch keyCode {
        case kVK_ANSI_H, kVK_LeftArrow: move(.left)
        case kVK_ANSI_J, kVK_DownArrow: move(.down)
        case kVK_ANSI_K, kVK_UpArrow: move(.up)
        case kVK_ANSI_L, kVK_RightArrow: move(.right)
        case kVK_Tab: cycle(by: shift ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            confirm()
            return
        case kVK_ANSI_V where mode == .window: enterElementMode()
        case kVK_ANSI_F where mode == .window || mode == .element: startHints()
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
