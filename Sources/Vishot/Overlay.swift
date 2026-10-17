import AppKit
import Carbon.HIToolbox

final class OverlayController: NSObject, NSWindowDelegate {
    private enum Mode {
        case window, element, hint, screen, region

        var name: String {
            switch self {
            case .window: "WINDOW"
            case .element: "ELEMENT"
            case .hint: "HINT"
            case .screen: "SCREEN"
            case .region: "REGION"
            }
        }

        var keys: [HUDKey] {
            switch self {
            case .window: [
                HUDKey("hjkl", action: "move"), HUDKey("f", action: "elements"), HUDKey("v", action: "region"),
                HUDKey("G", action: "screen"), HUDKey("↵", action: "copy"), HUDKey("⇧↵", "e", action: "edit"),
                HUDKey("esc", action: "cancel"),
            ]
            case .element: [
                HUDKey("f", action: "elements"), HUDKey("v", action: "region"), HUDKey("G", action: "screen"),
                HUDKey("↵", action: "copy"), HUDKey("⇧↵", "e", action: "edit"), HUDKey("esc", action: "back"),
            ]
            case .hint: [HUDKey(action: "type a hint"), HUDKey("⌫", action: "undo"), HUDKey("esc", action: "back")]
            case .screen: [
                HUDKey("hjkl", action: "move"), HUDKey("v", action: "region"), HUDKey("↵", action: "copy"),
                HUDKey("⇧↵", "e", action: "edit"), HUDKey("esc", action: "back"),
            ]
            case .region: [
                HUDKey("hjkl", action: "move (⇧ far, ⌥ slow)"), HUDKey("v", action: "corner"), HUDKey("tab", action: "screen"),
                HUDKey("↵", action: "copy"), HUDKey("⇧↵", "e", action: "edit"), HUDKey("esc", action: "back"),
            ]
            }
        }
    }

    /// A hint and the element it is shown on.
    private struct Hint {
        let code: String
        let target: CaptureTarget
        /// Containers are outlined, so it is clear which area a hint stands for.
        let isContainer: Bool
    }

    private var panels: [OverlayPanel] = []
    private var isShowing = false
    private let capturer = Capturer()
    let historyLibrary = HistoryLibrary()
    private var browser: HistoryBrowser?
    private var reusableBrowser: HistoryBrowser!
    private var historyEditingID: UUID?
    private var captureLabel = ""
    private var captureWindowTitle = ""
    var isSessionActive: Bool { isShowing || browser != nil }
    var onSessionChange: ((Bool) -> Void)?
    var watermark: Bool {
        get { capturer.watermark }
        set { capturer.watermark = newValue }
    }
    private let elements = ElementCatalog()
    private let raiser = WindowRaiser()
    private lazy var sourcePreparation = FrozenSourcePreparation(
        waitForRaise: { [raiser] in await raiser.waitForPendingRaise() },
        excludePicker: { [weak self] in
            // Remove decorations as well as excluding our app from capture: a
            // stale compositor frame can otherwise retain the target outline.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.panels.forEach { $0.hidePicker() }
            CATransaction.commit()
            CATransaction.flush()
        },
        capture: { [capturer] in await capturer.frozenSource(for: $0) },
        onFailure: { [weak self] in
            guard let self else { return }
            isCapturing = false
            status = "capture failed"
            NSSound.beep()
            render()
        }
    )

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
        reusableBrowser = HistoryBrowser(library: historyLibrary)
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
        guard !isPresentingSavePanel else { return }
        guard !(isCapturing && editor != nil) else { return }
        if browser != nil {
            guard editor == nil, !isCapturing else { return }
            closeHistory()
            show()
            return
        }
        isShowing ? hide() : show()
    }

    func showHistory() {
        guard !isShowing, browser == nil,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        appToReactivate = NSWorkspace.shared.frontmostApplication
        let browser = reusableBrowser!
        self.browser = browser
        browser.onClose = { [weak self] in self?.closeHistory() }
        browser.onEdit = { [weak self] in self?.editHistory($0, on: $1) }
        browser.onYank = { [weak self, weak browser] entry in
            guard let self, !isCapturing else { return }
            isCapturing = true
            browser?.setBusy(true)
            historyLibrary.image(entry, thumbnail: false) { [weak self] image in
                guard let self, self.browser === browser else { return }
                self.isCapturing = false
                browser?.setBusy(false)
                guard let image else { return }
                self.capturer.copy(image, scale: entry.scale)
                self.closeHistory()
            }
        }
        onSessionChange?(true)
        browser.show(on: screen)
    }

    func refreshHistory() { browser?.libraryChanged() }

    private func closeHistory() {
        hide()
    }

    private func editHistory(_ id: UUID, on screen: NSScreen) {
        guard !isCapturing, editor == nil else { return }
        isCapturing = true
        browser?.setBusy(true)
        historyLibrary.hold(id)
        let session = session
        historyLibrary.load(id) { [weak self] loaded in
            guard let self else { return }
            guard session == self.session, let browser = self.browser else { self.historyLibrary.release(id); return }
            self.isCapturing = false
            browser.setBusy(false)
            guard let loaded else { self.historyLibrary.release(id); return }
            self.historyEditingID = id
            self.captureLabel = loaded.entry.label
            self.captureWindowTitle = loaded.entry.windowTitle
            let size = loaded.document.size
            let bounds = screen.cgFrame.insetBy(dx: 24, dy: 24)
            let scale = min(1, bounds.width / size.width, bounds.height / size.height)
            let frame = CGRect(x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2,
                width: size.width * scale, height: size.height * scale)
            browser.suspend()
            self.isShowing = true
            let capture = Capture(image: loaded.document.image, scale: loaded.document.scale, frame: frame, initialCrop: loaded.document.crop)
            let editor = EditorController(capture: capture, restored: loaded, viewScale: scale)
            editor.onFinish = { [weak self] in self?.finishEditing($0, export: $1) }
            editor.onChange = { [weak self] in self?.render() }
            self.editor = editor
            self.panels.forEach { $0.hidePicker(); $0.orderFrontRegardless() }
            self.render()
            (self.panels.first { $0.frame == screen.frame } ?? self.panels.first)?.makeKey()
        }
    }

    private func returnToHistory(_ id: UUID, release: Bool = true) {
        editor = nil
        historyEditingID = nil
        isShowing = false
        isCapturing = false
        panels.forEach { $0.hideEditor(); $0.orderOut(nil) }
        browser?.resume(select: id)
        if release { historyLibrary.release(id) }
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
        onSessionChange?(true)
        render()
        panels.forEach { $0.orderFrontRegardless() }
        keyPanel.makeKey()
    }

    private func hide() {
        if browser != nil {
            browser?.close()
            browser = nil
            historyLibrary.finishSession()
        }
        isShowing = false
        session += 1
        sourcePreparation.cancel()
        isCapturing = false
        editor = nil
        if let id = historyEditingID { historyLibrary.release(id) }
        historyEditingID = nil
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
        // Copy/save call sites finish synchronously after hide. Defer settings
        // activation so those outputs retain the just-finished session's values.
        DispatchQueue.main.async { [weak self] in
            guard let self, !isSessionActive else { return }
            onSessionChange?(false)
        }
    }

    /// What ↵ copies and ⇧↵/e edits. Region mode has nothing until a region is drawn.
    private var selection: CaptureTarget? {
        if let region { region.target } else { targets[selected] }
    }

    private func confirm() {
        guard !isCapturing, let target = selection else { return }
        captureMetadata(for: target)
        let label = captureLabel, title = captureWindowTitle, watermark = capturer.watermark
        prepareSource(for: target) { [self] capture in
            let document = EditDocument(image: capture.image, scale: capture.scale, crop: capture.initialCrop)
            guard let image = AnnotationRenderer.export(document) else { status = "export failed"; render(); return }
            historyLibrary.commit(document: document, undo: [], label: label, windowTitle: title)
            hide()
            capturer.copy(image, scale: capture.scale, watermark: watermark)
        }
    }

    private func captureMetadata(for target: CaptureTarget) {
        captureLabel = target.label
        captureWindowTitle = ""
        switch target.kind {
        case .window(let id), .element(let id, _): captureWindowTitle = windows.first { $0.id == id }?.title ?? ""
        default: break
        }
    }

    // MARK: - Editor

    /// Captures the selection with the overlay up, then edits it in place.
    private func edit() {
        guard !isCapturing, let target = selection else { return }
        captureMetadata(for: target)
        prepareSource(for: target) { [self] in startEditing($0) }
    }

    private func prepareSource(for target: CaptureTarget, receive: @escaping (Capture) -> Void) {
        let session = session
        isCapturing = true
        stopWarmUp()
        Task { @MainActor [weak self] in
            guard let self, session == self.session else { return }
            await sourcePreparation.prepare(for: target) { capture in
                self.isCapturing = false
                receive(capture)
            }
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
        guard !isCapturing else { return }
        guard let (image, scale) = export else {
            if let id = historyEditingID { returnToHistory(id) } else { hide() }
            return
        }
        if finish == .saveAs {
            saveAs(image, scale: scale)
            return
        }
        let commit = historyCommit()
        if finish == .save {
            completeSave(image, scale: scale, to: Config.newSaveURL(), commit: commit)
            return
        }
        if let id = historyEditingID { returnToHistory(id, release: false) } else { hide() }
        if finish == .copy || finish == .saveAndCopy { capturer.copy(image, scale: scale) }
        if finish == .copy || finish == .saveAndCopy { commit() }
        if finish == .saveAndCopy {
            capturer.save(image, scale: scale, to: Config.newSaveURL())
        }
    }

    /// Keep the session and its retention hold until save (or clipboard fallback) completes.
    private func completeSave(_ image: CGImage, scale: CGFloat, to url: URL, watermark: Bool? = nil, commit: @escaping () -> Void) {
        isCapturing = true
        let session = session
        capturer.save(image, scale: scale, to: url, watermark: watermark) { [weak self] in
            commit()
            guard let self, self.session == session else { return }
            self.isCapturing = false
            if let id = self.historyEditingID { self.returnToHistory(id, release: false) } else { self.hide() }
        }
    }

    private func historyCommit() -> () -> Void {
        guard let editor else { return {} }
        let document = editor.document, undo = editor.history.snapshots
        let id = historyEditingID, label = captureLabel, title = captureWindowTitle
        let enabled = historyLibrary.retention != .off
        return { [historyLibrary] in
            if enabled || id != nil { historyLibrary.commit(document: document, undo: undo, label: label, windowTitle: title, id: id, recording: enabled) }
            if let id { historyLibrary.release(id) }
        }
    }

    /// The save panel can't show above the overlay, so the overlay steps aside, and comes back with
    /// the edit intact if the panel is cancelled.
    private func saveAs(_ image: CGImage, scale: CGFloat) {
        let watermark = capturer.watermark
        let commit = historyCommit()
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
            if isShowing {
                panels.forEach { $0.orderFrontRegardless() }
                panels.first?.makeKey()
                completeSave(image, scale: scale, to: url, watermark: watermark, commit: commit)
            } else {
                capturer.save(image, scale: scale, to: url, watermark: watermark, completion: commit)
            }
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

    /// Puts hints on the elements of the current window. The window stays selected until a hint is typed.
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
        // An app still building its tree gets hints as they appear.
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
        return zip(Hints.make(count: nodes.count), nodes).map { code, node in
            Hint(code: code, target: elements.target(for: node, in: window), isContainer: node.hasChildren)
        }
    }

    private func typeHint(_ letter: String) {
        let typed = typedHint + letter
        let matches = hints.filter { $0.code.hasPrefix(typed) }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        typedHint = typed
        // Hints have equal length, so a complete one matches exactly one element.
        if let hint = matches.first(where: { $0.code == typed }) {
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
            if let letter = Hints.letter(forKeyCode: keyCode) { typeHint(letter) }
        }
    }

    // MARK: - Warm-up

    /// Electron and Chromium build their trees after a flag is set, so the hints reload until `end`.
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
        // Hints must not change while one is being typed.
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
        // Capture preparation hides picker layers. Input handlers and delayed callbacks must
        // not reveal them again while ScreenCaptureKit is awaiting a frame.
        guard !isCapturing || editor != nil else { return }
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
            guard hint.code.hasPrefix(typedHint) else { return nil }
            return HintMark(rect: hint.target.frame.flippedBetweenCocoaAndCG, code: hint.code, colorIndex: colorIndex)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for panel in panels {
            panel.highlight(target?.frame.flippedBetweenCocoaAndCG, label: target?.label ?? "")
            panel.showRegion(regionRect, cursor: regionCursor)
            panel.showHints(marks, typed: typedHint.count)
            panel.showHUD(name: mode.name, keys: mode.keys, status: statusLine, visible: panel === hudPanel)
        }
        CATransaction.commit()
    }

    // MARK: - Input

    /// Key codes, not characters, so the keys keep working with non-Latin keyboard layouts.
    private func handle(_ event: NSEvent) {
        if isCapturing, editor != nil { return }
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
            if let panel = panels.first(where: { $0.toolbarContains(point) }) {
                (panel.toolbarItem(at: point) == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
                return
            }
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
        guard isShowing, !isCapturing else { return }
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
        guard isShowing, !isCapturing else { return }
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
        if browser != nil { closeHistory() }
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
            if isCapturing, editor != nil { return }
            if browser != nil, editor == nil { return }
            if isShowing, !isPresentingSavePanel, !raiser.isSwitchingApps, !panels.contains(where: \.isKeyWindow) { hide() }
        }
    }
}
