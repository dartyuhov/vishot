import AppKit
import Carbon.HIToolbox

final class OverlayController: NSObject, NSWindowDelegate {
    private enum Mode {
        case window, element, hint, screen, region

        var keys: String {
            switch self {
            case .window: "WINDOW   hjkl move · f elements · v region · G screen · ↵ copy · ⇧↵/e edit · esc cancel"
            case .element: "ELEMENT  f elements · v region · G screen · ↵ copy · ⇧↵/e edit · esc back"
            case .hint: "HINT     type a label · ⌫ undo · esc back"
            case .screen: "SCREEN   hjkl move · v region · ↵ copy · ⇧↵/e edit · esc back"
            case .region: "REGION   hjkl move (⇧ far, ⌥ slow) · v corner · tab screen · ↵ copy · ⇧↵/e edit · esc back"
            }
        }
    }

    /// A labelled element in hint mode.
    private struct Hint {
        let label: String
        let target: CaptureTarget
        /// Containers are outlined, so it is clear which area a label stands for.
        let isContainer: Bool
    }

    private var panels: [OverlayPanel] = []
    private var isShowing = false
    private let capturer = Capturer()
    private let elements = ElementCatalog()
    private let raiser = WindowRaiser()

    private var mode = Mode.window
    private var windows: [WindowInfo] = []
    /// What the current mode selects from, and the index of the selection.
    private var targets: [CaptureTarget] = []
    private var selected = 0
    /// Index in `windows` of the window last selected or browsed. Window mode returns to it, and hints
    /// label its elements.
    private var currentWindow = 0
    private var hints: [Hint] = []
    private var typedHint = ""
    private var status = ""
    private var warmUpTimer: Timer?
    /// Region mode's cursor and region, while in it.
    private var region: RegionSelector?
    /// Set while a capture for the editor runs, then the editor until it finishes.
    private var isCapturing = false
    private var editor: EditorController?
    /// Increases on every hide, so a capture that finishes after the overlay closed is dropped.
    private var session = 0
    /// The save panel hides the overlay, which must not cancel the edit.
    private var isPresentingSavePanel = false
    /// The app that was active before the save panel activated Vishot.
    private var appToReactivate: NSRunningApplication?

    override init() {
        super.init()
        raiser.onKey = { [weak self] in $0.type == .keyDown ? self?.handle($0) : self?.keyUp($0) }
        raiser.onActivated = { [weak self] in
            guard let self, isShowing else { return }
            (panels.first(where: \.isKeyWindow) ?? panels.first)?.makeKey()
        }
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
        raiser.begin(windows)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        currentWindow = windows.firstIndex { $0.pid == frontPID } ?? 0
        status = ""
        enterWindowMode()
        isShowing = true
        render()
        panels.forEach { $0.orderFrontRegardless() }
        keyPanel.makeKey()
    }

    private func hide() {
        isShowing = false
        session += 1
        isCapturing = false
        editor = nil
        region = nil
        stopWarmUp()
        hints = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panels.forEach { $0.hideEditor() }
        CATransaction.commit()
        panels.forEach { $0.orderOut(nil) }
        elements.finish()
        raiser.restore()
        appToReactivate?.activate()
        appToReactivate = nil
    }

    /// What ↵ copies and ⇧↵/e edits. Region mode has nothing until a region is drawn.
    private var selection: CaptureTarget? {
        if let region { region.target } else { targets[selected] }
    }

    private func confirm() {
        guard let target = selection else { return }
        hide()
        capturer.capture(target)
    }

    // MARK: - Editor

    /// Captures the selection with the overlay up, then edits it in place.
    private func edit() {
        guard !isCapturing, let target = selection else { return }
        let session = session
        isCapturing = true
        stopWarmUp()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let capture = await capturer.image(for: target)
            guard session == self.session else { return }
            isCapturing = false
            guard let capture else {
                NSSound.beep()
                status = "capture failed"
                render()
                return
            }
            startEditing(capture)
        }
    }

    private func startEditing(_ capture: Capture) {
        let editor = EditorController(capture: capture)
        editor.onFinish = { [weak self] in self?.finishEditing($0, export: $1) }
        editor.onChange = { [weak self] in self?.render() }
        self.editor = editor
        status = ""
        render()
    }

    private func finishEditing(_ finish: EditorController.Finish, export: (image: CGImage, scale: CGFloat)?) {
        guard let (image, scale) = export else {
            hide()
            return
        }
        if finish == .saveAs {
            saveAs(image, scale: scale)
            return
        }
        hide()
        if finish == .copy || finish == .saveAndCopy { capturer.copy(image, scale: scale) }
        if finish == .save || finish == .saveAndCopy { capturer.save(image, scale: scale, to: Config.newSaveURL()) }
    }

    /// The save panel can't show above the overlay, so the overlay steps aside, and comes back with
    /// the edit intact if the panel is cancelled.
    private func saveAs(_ image: CGImage, scale: CGFloat) {
        isPresentingSavePanel = true
        panels.forEach { $0.orderOut(nil) }
        if !NSApp.isActive { appToReactivate = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.directoryURL = Config.saveFolder()
        savePanel.nameFieldStringValue = Config.fileName(for: Date())
        let response = savePanel.runModal()
        isPresentingSavePanel = false
        if response == .OK, let url = savePanel.url {
            // The hotkey may have closed the overlay meanwhile, but the save was still asked for.
            if isShowing { hide() }
            capturer.save(image, scale: scale, to: url)
        } else if isShowing {
            panels.forEach { $0.orderFrontRegardless() }
            panels.first?.makeKey()
            render()
        }
    }

    // MARK: - Modes

    private func enterWindowMode() {
        stopWarmUp()
        region = nil
        mode = .window
        hints = []
        typedHint = ""
        targets = windows.map(\.target)
        selected = currentWindow
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
        targets = displays
        selected = displays.firstIndex { $0.frame.contains(anchor) } ?? 0
    }

    /// The cursor starts on the selection, until the mouse moves.
    private func enterRegionMode() {
        let displays = DisplayCatalog.displays()
        guard !displays.isEmpty else {
            NSSound.beep()
            return
        }
        if mode == .window { currentWindow = selected }
        stopWarmUp()
        let region = RegionSelector(displays: displays, start: targets[selected].anchor)
        region.onChange = { [weak self] in self?.render() }
        self.region = region
        mode = .region
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: - Hints

    /// Labels the elements of the current window. The window stays selected until a label is typed.
    private func startHints() {
        guard elements.isTrusted() else {
            NSSound.beep()
            status = "Allow Vishot in System Settings → Privacy & Security → Accessibility"
            return
        }
        if mode == .window { currentWindow = selected }
        let window = windows[currentWindow]
        guard let root = elements.windowNode(for: window) else {
            NSSound.beep()
            status = "can't read this window"
            return
        }
        elements.prepare(root, pid: window.pid)
        let warmUpEnd = elements.warmUpEnd(for: window.pid)
        let found = hints(below: root)
        // An app still building its tree gets labels as they appear.
        guard !found.isEmpty || warmUpEnd != nil else {
            NSSound.beep()
            status = "nothing to label"
            return
        }
        stopWarmUp()
        mode = .hint
        targets = windows.map(\.target)
        selected = currentWindow
        hints = found
        typedHint = ""
        if let warmUpEnd { startWarmUp(root, until: warmUpEnd) }
    }

    private func hints(below root: AXNode) -> [Hint] {
        let window = windows[currentWindow]
        let nodes = elements.hints(below: root, in: window)
        return zip(HintLabels.make(count: nodes.count), nodes).map { label, node in
            Hint(label: label, target: elements.target(for: node, in: window), isContainer: node.hasChildren)
        }
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
            stopWarmUp()
            mode = .element
            hints = []
            typedHint = ""
            targets = [hint.target]
            selected = 0
        }
    }

    private func handleHint(_ keyCode: Int) {
        switch keyCode {
        case kVK_Escape: enterWindowMode()
        case kVK_Delete: typedHint = String(typedHint.dropLast())
        default:
            if let letter = HintLabels.letter(forKeyCode: keyCode) { typeHint(letter) }
        }
    }

    // MARK: - Warm-up

    /// Electron and Chromium build their trees after a flag is set, so the labels reload until `end`.
    private func startWarmUp(_ root: AXNode, until end: Date) {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.reloadHints(below: root, until: end)
        }
        RunLoop.main.add(timer, forMode: .common)
        warmUpTimer = timer
    }

    private func reloadHints(below root: AXNode, until end: Date) {
        guard isShowing, mode == .hint, Date() < end else {
            stopWarmUp()
            status = ""
            if isShowing { render() }
            return
        }
        // Labels must not change under a label being typed.
        guard typedHint.isEmpty else { return }
        let reloaded = hints(below: root)
        guard reloaded.map(\.target.frame) != hints.map(\.target.frame) else { return }
        hints = reloaded
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
        raiseSelectedWindow()
    }

    private func cycle(by step: Int) {
        selected = (selected + step + targets.count) % targets.count
        raiseSelectedWindow()
    }

    /// Shows a covered window while it is browsed. Indices in Window mode are those of `windows`.
    private func raiseSelectedWindow() {
        if mode == .window { raiser.raise(index: selected) }
    }

    /// Selects what is under the cursor. Returns false over empty space, keeping the selection.
    private func select(at point: CGPoint) -> Bool {
        switch mode {
        case .window, .screen:
            // Windows are ordered front to back, so the first hit is the frontmost.
            guard let index = targets.firstIndex(where: { $0.frame.contains(point) }) else { return false }
            selected = index
            return true
        case .element:
            // The picked element is the only target, so a click on it copies it.
            return targets[selected].frame.contains(point)
        // Region mode handles its own mouse events.
        case .hint, .region:
            return false
        }
    }

    private func render() {
        if let editor {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            editor.render(on: panels)
            CATransaction.commit()
            return
        }
        let target = selection
        // Region mode's HUD follows its cursor, since there may be no region yet.
        let anchor = (region?.cursor ?? targets[selected].anchor).flippedBetweenCocoaAndCG
        let hudPanel = panels.first { $0.frame.contains(anchor) } ?? panels.first
        let statusLine = isCapturing ? "capturing…"
            : !status.isEmpty ? status
            : warmUpTimer != nil ? "loading page…"
            : region?.status ?? ""
        let regionRect = region == nil ? nil : target?.frame.flippedBetweenCocoaAndCG
        let regionCursor = region?.cursor.flippedBetweenCocoaAndCG
        // Containers are numbered among themselves, so nested ones (adjacent in the list) get different colors.
        var containers = 0
        let marks = hints.compactMap { hint -> HintMark? in
            let colorIndex = hint.isContainer ? containers : nil
            if hint.isContainer { containers += 1 }
            guard hint.label.hasPrefix(typedHint) else { return nil }
            return HintMark(rect: hint.target.frame.flippedBetweenCocoaAndCG, label: hint.label, colorIndex: colorIndex)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for panel in panels {
            panel.highlight(target?.frame.flippedBetweenCocoaAndCG, label: target?.label ?? "", cornerRadius: target?.cornerRadius ?? 0)
            panel.showRegion(regionRect, cursor: regionCursor)
            panel.showHints(marks, typed: typedHint.count)
            panel.showHUD(keys: mode.keys, status: statusLine, visible: panel === hudPanel)
        }
        CATransaction.commit()
    }

    // MARK: - Input

    /// Key codes, not characters, so the keys keep working with non-Latin keyboard layouts.
    private func handle(_ event: NSEvent) {
        if let editor {
            editor.handle(event)
            if isShowing, self.editor != nil { render() }
            return
        }
        status = ""
        let keyCode = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        if isCapturing {
            if keyCode == kVK_Escape || keyCode == kVK_ANSI_Q { hide() }
            return
        }
        if mode == .hint {
            handleHint(keyCode)
            render()
            return
        }
        if let region {
            switch region.handle(event) {
            case .copy:
                confirm()
                return
            case .edit: edit()
            case .back: enterWindowMode()
            case .cancel:
                hide()
                return
            case .none: break
            }
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
            guard shift else {
                confirm()
                return
            }
            edit()
        case kVK_ANSI_E: edit()
        case kVK_ANSI_F where mode == .window || mode == .element: startHints()
        case kVK_ANSI_G where shift && mode != .screen: enterScreenMode()
        case kVK_ANSI_V: enterRegionMode()
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
        guard isShowing, !isCapturing else { return }
        if let editor {
            // The cursor stays on the image while the pointer is over the toolbar.
            guard !panels.contains(where: { $0.toolbarContains(point) }) else { return }
            editor.mouseMoved(to: point)
            render()
            return
        }
        if let region {
            region.mouseMoved(to: point)
            render()
            return
        }
        let before = selected
        _ = select(at: point)
        if selected != before { render() }
    }

    private func mouseDown(at point: CGPoint) {
        guard isShowing, !isCapturing else { return }
        if let editor {
            if let panel = panels.first(where: { $0.toolbarContains(point) }) {
                if let item = panel.toolbarItem(at: point) { editor.select(item) }
            } else {
                editor.mouseDown(at: point)
            }
            if isShowing, self.editor != nil { render() }
            return
        }
        if let region {
            region.mouseDown(at: point)
            render()
            return
        }
        guard select(at: point) else { return }
        confirm()
    }

    private func mouseDragged(to point: CGPoint) {
        guard isShowing else { return }
        if let editor {
            editor.mouseDragged(to: point)
        } else if let region, !isCapturing {
            region.mouseDragged(to: point)
        } else {
            return
        }
        render()
    }

    private func mouseUp(at point: CGPoint) {
        guard isShowing else { return }
        if let editor {
            editor.mouseUp(at: point)
            if isShowing, self.editor != nil { render() }
        } else if let region, !isCapturing {
            if region.mouseUp(at: point) == .copy {
                confirm()
                return
            }
            render()
        }
    }

    private func keyUp(_ event: NSEvent) {
        if let editor { editor.keyUp(event) } else { region?.keyUp(event) }
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
            panel.onKeyUp = { [weak self] in self?.keyUp($0) }
            panel.onMouseMoved = { [weak self] in self?.mouseMoved(to: $0) }
            panel.onMouseDown = { [weak self] in self?.mouseDown(at: $0) }
            panel.onMouseDragged = { [weak self] in self?.mouseDragged(to: $0) }
            panel.onMouseUp = { [weak self] in self?.mouseUp(at: $0) }
            return panel
        }
    }

    /// Clicking elsewhere or switching Spaces cancels the selection. A click on another screen's
    /// panel moves key focus between our own panels, which is not a cancel.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            if isShowing, !isPresentingSavePanel, !raiser.isSwitchingApps, !panels.contains(where: \.isKeyWindow) { hide() }
        }
    }
}
