import AppKit
import VishotRendering
import VishotConfiguration
import Carbon.HIToolbox

final class OverlayController: NSObject, NSWindowDelegate {
    private typealias Mode = PickerHUD.Picker

    /// A hint and the element it is shown on.
    private struct Hint {
        let code: String
        let target: CaptureTarget
        /// Containers are outlined, so it is clear which area a hint stands for.
        let isContainer: Bool
    }

    private var panels: [OverlayPanel] = []
    private var preparedTheme = ThemeCatalog.pixel
    /// One immutable resolved value for the entire picker/history/editor lifetime.
    /// History-to-editor and editor-to-history transitions deliberately retain it.
    private(set) var sessionTheme: ResolvedTheme?
    private var sessionOutput: OutputStyle?

    func prepareTheme(style: VisualStyle, colorScheme: ColorScheme) {
        guard !sessions.isSessionActive,
              preparedTheme.definition.id != style.rawValue || preparedTheme.colorScheme != ThemeCatalog.colorScheme(style: style, requested: colorScheme) else { return }
        preparedTheme = ThemeCatalog.resolve(style: style, colorScheme: colorScheme)
        preparePickerPanels()
        reusableBrowser.prepare(theme: preparedTheme)
    }

    private func preparePickerPanels() {
        panels.forEach { $0.prepare(theme: preparedTheme) }
    }
    private var isShowing = false
    private let capturer = Capturer()
    let historyLibrary: HistoryLibrary
    private let presentsPanels: Bool
    private let windowCatalog: () -> [WindowInfo]
    private let displayCatalog: () -> [CaptureTarget]
    /// Optional discovery adapter; key dispatch and hint matching stay here.
    private let hintCatalog: ((WindowInfo) -> [CaptureTarget])?
    private lazy var screenshotCompletion = ScreenshotCompletion(history: historyLibrary, save: { [capturer] in
        capturer.save($0, scale: $1, to: $2, output: $3, completion: $4)
    }) { [capturer] image, scale, output in
        capturer.copy(image, scale: scale, output: output)
    }
    private var browser: HistoryBrowser?
    private var reusableBrowser: HistoryBrowser!
    private var historyEditingID: UUID?
    private var captureLabel = ""
    private var captureWindowTitle = ""
    private let sessions: CaptureSessionCoordinator
    var video: VideoSession?
    private var videoType = false
    private var videoCountdown = false
    private var videoRectangle: CGRect?
    private var countdownFrame: CountdownFrame?
    var watermark = true
    private let elements = ElementCatalog()
    private let accessibility = AccessibilityAvailability()
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
    private var hoverStatus: String?
    private var accessibilityAvailable = false
    private var warmUpTimer: Timer?
    /// Region mode's cursor and region, while in it.
    private var region: RegionSelector?
    /// Set while a capture for the editor runs, then the editor until it finishes.
    private var isCapturing = false
    private var editor: EditorController?
    /// App-owned identity fences presentation callbacks, including delayed teardown.
    private var session: Int { sessions.callbackSession }
    /// The save panel hides the overlay, which must not cancel the edit.
    private var isPresentingSavePanel = false
    /// The app that was active before the save panel activated Vishot.
    private var appToReactivate: NSRunningApplication?

    init(sessions: CaptureSessionCoordinator, history: HistoryLibrary = HistoryLibrary(),
         presentsPanels: Bool = true,
         windowCatalog: @escaping () -> [WindowInfo] = WindowCatalog.visibleWindows,
         displayCatalog: @escaping () -> [CaptureTarget] = DisplayCatalog.displays,
         hintCatalog: ((WindowInfo) -> [CaptureTarget])? = nil) {
        self.sessions = sessions
        historyLibrary = history
        self.presentsPanels = presentsPanels
        self.windowCatalog = windowCatalog
        self.displayCatalog = displayCatalog
        self.hintCatalog = hintCatalog
        super.init()
        guard presentsPanels else { return }
        accessibility.onChange = { [weak self] allowed in
            guard let self else { return }
            accessibilityAvailable = allowed
            if isShowing { render() }
        }
        accessibility.start()
        reusableBrowser = HistoryBrowser(library: historyLibrary)
        reusableBrowser?.onFileOperation = { [sessions] active in
            if active { sessions.beginFileOperation() } else { sessions.endFileOperation() }
        }
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

    func toggle(session: Int) {
        if videoCountdown { video?.cancelCountdown(); return }
        guard sessions.acceptsCallbacks(session) else { return }
        guard !isPresentingSavePanel else { return }
        guard !(isCapturing && editor != nil) else { return }
        if browser != nil {
            guard browser?.isBusy != true else { return }
            guard editor == nil, !isCapturing else { return }
            closeHistory()
            sessions.replaceWithCapture(session)
            return
        }
        if isShowing { hide() }
    }

    func showHistory(session: Int) -> Bool {
        guard sessions.acceptsCallbacks(session), !isShowing, browser == nil,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return false }
        appToReactivate = NSWorkspace.shared.frontmostApplication
        let browser = reusableBrowser!
        self.browser = browser
        sessionTheme = preparedTheme
        sessionOutput = OutputStyle(watermark: watermark, style: preparedTheme.watermark)
        browser.onClose = { [weak self] in
            guard let self, sessions.acceptsCallbacks(session) else { return }
            closeHistory()
        }
        browser.onEdit = { [weak self] id, screen in
            guard let self, sessions.acceptsCallbacks(session) else { return }
            editHistory(id, on: screen)
        }
        browser.onOpenVideo = { [weak self] entry in
            guard let self, sessions.acceptsCallbacks(session) else { return }
            isCapturing = true
            browser.setBusy(true)
            historyLibrary.openVideo(entry) { [weak self] opened in
                guard let self, sessions.acceptsCallbacks(session) else { return }
                self.isCapturing = false
                browser.setBusy(false)
                if opened {
                    // Closing History must not reactivate its previous application
                    // over the player NSWorkspace just opened.
                    self.appToReactivate = nil
                    self.hide()
                }
            }
        }
        browser.onYank = { [weak self, weak browser] entry in
            guard let self, sessions.acceptsCallbacks(session), !isCapturing, let output = sessionOutput else { return }
            browser?.yank(entry) { [weak self] image in
                guard let self, self.session == session, self.browser === browser else { return }
                guard let image else { return }
                self.capturer.copy(image, scale: entry.scale, output: output)
                self.closeHistory()
            }
        }
        browser.show(on: screen)
        return true
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
            guard let theme = self.sessionTheme else { self.historyLibrary.release(id); return }
            let editor = EditorController(capture: capture, restored: loaded, viewScale: scale, theme: theme)
            self.connect(editor, session: session)
            self.editor = editor
            self.panels.forEach { $0.hidePicker(); $0.orderFrontRegardless() }
            self.render()
            (self.panels.first { $0.frame == screen.frame } ?? self.panels.first)?.makeKey()
        }
    }

    private func returnToHistory(_ id: UUID) {
        editor = nil
        historyEditingID = nil
        isShowing = false
        isCapturing = false
        panels.forEach { $0.hideEditor(); $0.orderOut(nil) }
        browser?.resume(select: id)
        historyLibrary.release(id)
    }

    func show(session: Int) -> Bool {
        guard sessions.acceptsCallbacks(session) else { return false }
        windows = windowCatalog()
        guard !windows.isEmpty, !presentsPanels || !panels.isEmpty else {
            NSSound.beep()
            return false
        }
        if presentsPanels {
            capturer.prefetch()
            appToReactivate = NSWorkspace.shared.frontmostApplication
            raiser.begin(windows)
        }
        let frontPID = presentsPanels ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        currentWindow = WindowCatalog.initialSelection(in: windows, frontPID: frontPID) ?? 0
        status = ""
        videoType = false
        videoCountdown = false
        videoRectangle = nil
        hoverStatus = nil
        accessibilityAvailable = accessibility.isAllowed
        enterWindowMode()
        isShowing = true
        sessionTheme = preparedTheme
        sessionOutput = OutputStyle(watermark: watermark, style: preparedTheme.watermark)
        render()
        panels.forEach { $0.orderFrontRegardless() }
        panels.first?.makeKey()
        return true
    }

    private func hide(continuingVideo: Bool = false) {
        let session = session
        guard sessions.acceptsCallbacks(session) else { return }
        sessions.dismissPresentation(session)
        if browser != nil {
            browser?.close()
            browser = nil
            historyLibrary.finishSession()
        }
        isShowing = false
        sessionTheme = nil
        sessionOutput = nil
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
        panels.forEach { $0.hideEditor(); $0.showCountdown(nil, target: nil, visible: false) }
        CATransaction.commit()
        panels.forEach { $0.orderOut(nil) }
        elements.finish()
        raiser.restore()
        appToReactivate?.activate()
        appToReactivate = nil
        // Activate settings between sessions after presentation has finished unwinding.
        if !continuingVideo { DispatchQueue.main.async { [sessions] in sessions.finish(session) } }
    }

    func videoCountdownStatus(_ message: String) {
        videoCountdown = true
        status = message
        render()
    }

    func videoReturnToPicker(_ message: String) {
        countdownFrame = nil
        videoCountdown = false
        videoRectangle = nil
        status = message
        render()
    }

    func dismissForVideo() {
        countdownFrame = nil
        // hide owns presentation teardown and focus restoration; the outer
        // session remains reserved until recorder publication finishes.
        videoCountdown = false
        videoRectangle = nil
        hide(continuingVideo: true)
    }

    /// What ↵ copies and ⇧↵/e edits. Region mode has nothing until a region is drawn.
    var selection: CaptureTarget? {
        if let region { region.target } else { targets[selected] }
    }

    private func confirm() {
        guard !isCapturing, let target = selection else { return }
        if videoType {
            guard historyLibrary.retention != .off else {
                status = "Video requires History. Enable retention in Vishot Settings."; render(); return
            }
            do {
                let windowFrame: CGRect?
                if case .element(let id, _) = target.kind { windowFrame = windows.first { $0.id == id }?.frame }
                else { windowFrame = nil }
                let selection = try VideoSelection(target: target, windowFrame: windowFrame)
                videoCountdown = true
                stopWarmUp()
                video?.onRectangle = { [weak self] rect in
                    self?.videoRectangle = rect
                    self?.render()
                }
                video?.onCountdownFrame = { [weak self] frame in
                    self?.countdownFrame = frame
                    self?.render()
                }
                captureMetadata(for: target)
                video?.begin(selection: selection, session: session, label: captureLabel, windowTitle: captureWindowTitle)
            } catch { video?.presentStartupFailure(error, session: session) }
            return
        }
        guard let output = sessionOutput else { return }
        captureMetadata(for: target)
        let label = captureLabel, title = captureWindowTitle
        prepareSource(for: target) { [self] capture in
            let document = EditDocument(image: capture.image, scale: capture.scale, crop: capture.initialCrop,
                annotationStyle: sessionTheme?.id ?? .pixel)
            guard let request = screenshotCompletion.prepare(document: document, undo: [], label: label,
                windowTitle: title, session: session, output: output)
            else { status = "export failed"; render(); return }
            present(request.copy(currentSession: self.session))
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
        if videoType { status = "Video editing is unavailable. Press ↵ to record."; render(); return }
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
                guard self.sessions.acceptsCallbacks(session) else { return }
                self.isCapturing = false
                receive(capture)
            }
        }
    }

    private func startEditing(_ capture: Capture) {
        guard let theme = sessionTheme else { return }
        let editor = EditorController(capture: capture, theme: theme)
        connect(editor, session: session)
        self.editor = editor
        status = ""
        render()
    }

    private func connect(_ editor: EditorController, session: Int) {
        editor.onFinish = { [weak self] finish, export in
            guard let self, sessions.acceptsCallbacks(session) else { return }
            finishEditing(finish, export: export)
        }
        editor.onChange = { [weak self] in
            guard let self, sessions.acceptsCallbacks(session) else { return }
            render()
        }
    }

    private func finishEditing(_ finish: EditorController.Finish, export: (image: CGImage, scale: CGFloat)?) {
        guard !isCapturing else { return }
        guard let (image, _) = export else {
            if let id = historyEditingID { returnToHistory(id) } else { hide() }
            return
        }
        guard let editor, let output = sessionOutput,
            let request = screenshotCompletion.prepare(document: editor.document, undo: editor.history.snapshots,
            label: captureLabel, windowTitle: captureWindowTitle, id: historyEditingID,
            session: session, output: output, exported: image) else { return }
        switch finish {
        case .copy:
            present(request.copy(currentSession: session))
        case .save, .saveAndCopy:
            isCapturing = true
            request.save(to: Config.newSaveURL(), copying: finish == .saveAndCopy,
                currentSession: { [weak self] in self?.session ?? -1 },
                present: { [weak self] in self?.present($0) })
        case .saveAs:
            saveAs(request)
        case .discard:
            break
        }
    }

    private func present(_ presentation: ScreenshotCompletion.Presentation?) {
        switch presentation {
        case .close: hide()
        case .history(let id): returnToHistory(id)
        case nil: break
        }
    }

    /// The save panel can't show above the overlay, so the overlay steps aside, and comes back with
    /// the edit intact if the panel is cancelled.
    private func saveAs(_ request: ScreenshotCompletion.Request) {
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
        let url = response == .OK ? savePanel.url : nil
        if isShowing {
            panels.forEach { $0.orderFrontRegardless() }
            panels.first?.makeKey()
            if url == nil { render() }
        }
        if url != nil, isShowing { isCapturing = true }
        request.saveAs(to: url, currentSession: { [weak self] in self?.session ?? -1 },
            present: { [weak self] in self?.present($0) })
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
        let displays = displayCatalog()
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
        let displays = displayCatalog()
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
        if presentsPanels { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: - Hints

    /// Puts hints on the elements of the current window. The window stays selected until a hint is typed.
    private func startHints() {
        if let hintCatalog {
            if mode == .window { currentWindow = selected }
            let found = hintCatalog(windows[currentWindow])
            guard !found.isEmpty else { return }
            enterHintMode(zip(Hints.make(count: found.count), found).map { Hint(code: $0, target: $1, isContainer: false) })
            return
        }
        accessibilityAvailable = elements.isTrusted()
        guard accessibilityAvailable else {
            status = PickerHUD.elementUnavailableReason
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
        enterHintMode(found)
        if let warmUpEnd { startWarmUp(root, until: warmUpEnd) }
    }

    private func enterHintMode(_ found: [Hint]) {
        stopWarmUp()
        mode = .hint
        targets = windows.map(\.target)
        selected = currentWindow
        hints = found
        typedHint = ""
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
        if presentsPanels, mode == .window { raiser.raise(index: selected) }
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
        let anchor = (videoRectangle.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? region?.cursor ?? targets[selected].anchor).flippedBetweenCocoaAndCG
        let hudPanel = panels.first { $0.frame.contains(anchor) } ?? panels.first
        let statusLine = isCapturing ? "capturing…" : videoCountdown ? status : hoverStatus ?? (
            !status.isEmpty ? status
            : warmUpTimer != nil ? "loading page…"
            : region?.status(captureType: videoType ? .video : .screenshot) ?? ""
        )
        let regionRect = region == nil ? nil : (videoRectangle ?? target?.frame)?.flippedBetweenCocoaAndCG
        let regionCursor = videoCountdown ? nil : region?.cursor.flippedBetweenCocoaAndCG
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
        let hudContent = pickerHUDContent
        for panel in panels {
            panel.showCountdown(countdownFrame, target: videoRectangle?.flippedBetweenCocoaAndCG,
                                visible: videoCountdown && panel === hudPanel)
            panel.highlight((videoRectangle ?? target?.frame)?.flippedBetweenCocoaAndCG, label: target?.label ?? "")
            panel.showRegion(regionRect, cursor: regionCursor)
            panel.showHints(marks, typed: typedHint.count)
            panel.showHUD(hudContent, status: statusLine, visible: panel === hudPanel)
        }
        CATransaction.commit()
    }

    // MARK: - Input

    var pickerHUDContent: PickerHUD.Content {
        PickerHUD.Content(captureType: videoType ? .video : .screenshot, picker: mode,
            accessibilityAvailable: accessibilityAvailable, historyAvailable: historyLibrary.retention != .off,
            regionState: region?.hudState ?? .empty, isCountingDown: videoCountdown)
    }

    /// Key codes, not characters, so the keys keep working with non-Latin keyboard layouts.
    func handle(_ event: NSEvent) {
        if videoCountdown {
            if Int(event.keyCode) == kVK_Escape { video?.cancelCountdown() }
            return
        }
        if isCapturing, editor != nil { return }
        if let editor {
            editor.handle(event)
            if isShowing, self.editor != nil { render() }
            return
        }
        status = ""
        hoverStatus = nil
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
        var hudContent = pickerHUDContent
        switch hudContent.handleCaptureTypeKey(keyCode) {
        case .unavailable:
            status = PickerHUD.historyUnavailableReason
            render()
            return
        case .handled:
            videoType = hudContent.captureType == .video
            render()
            return
        case .unhandled: break
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
        case kVK_ANSI_Y:
            confirm()
            return
        case kVK_ANSI_F where mode == .window || mode == .element: startHints()
        case kVK_ANSI_G where shift && mode != .screen: enterScreenMode()
        case kVK_ANSI_V: enterRegionMode()
        case kVK_Escape where mode != .window: enterWindowMode()
        case kVK_Escape, kVK_ANSI_Q:
            hide()
            return
        default: break
        }
        if isShowing { render() }
    }

    private func mouseMoved(to point: CGPoint) {
        guard isShowing, !isCapturing, !videoCountdown else { return }
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
        let previousHover = hoverStatus
        hoverStatus = panels.compactMap { $0.hudUnavailableReason(at: point) }.first
        if panels.contains(where: { $0.hudContains(point) }) {
            if hoverStatus != previousHover { render() }
            return
        }
        if let region {
            region.mouseMoved(to: point)
            render()
            return
        }
        let before = selected
        _ = select(at: point)
        if selected != before || previousHover != nil { render() }
    }

    func mouseDown(at point: CGPoint) {
        guard isShowing, !isCapturing, !videoCountdown else { return }
        if let editor {
            if let panel = panels.first(where: { $0.toolbarContains(point) }) {
                if let item = panel.toolbarItem(at: point) { editor.select(item) }
            } else {
                editor.mouseDown(at: point)
            }
            if isShowing, self.editor != nil { render() }
            return
        }
        if let reason = panels.compactMap({ $0.hudUnavailableReason(at: point) }).first {
            status = reason
            render()
            return
        }
        guard !panels.contains(where: { $0.hudContains(point) }) else { return }
        if let region {
            region.mouseDown(at: point)
            render()
            return
        }
        guard select(at: point) else { return }
        confirm()
    }

    func mouseDragged(to point: CGPoint) {
        guard isShowing, !isCapturing, !videoCountdown else { return }
        if let editor {
            editor.mouseDragged(to: point)
        } else if let region, !isCapturing {
            region.mouseDragged(to: point)
        } else {
            return
        }
        render()
    }

    func mouseUp(at point: CGPoint) {
        guard isShowing, !isCapturing, !videoCountdown else { return }
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
        if videoCountdown { video?.cancelCountdown() }
        if browser != nil { closeHistory() }
        hide()
        rebuildPanels()
    }

    private func rebuildPanels() {
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen, theme: preparedTheme)
            panel.delegate = self
            panel.onKeyDown = { [weak self] in self?.handle($0) }
            panel.onKeyUp = { [weak self] in self?.keyUp($0) }
            panel.onMouseMoved = { [weak self] in self?.mouseMoved(to: $0) }
            panel.onMouseDown = { [weak self] in self?.mouseDown(at: $0) }
            panel.onMouseDragged = { [weak self] in self?.mouseDragged(to: $0) }
            panel.onMouseUp = { [weak self] in self?.mouseUp(at: $0) }
            return panel
        }
        preparePickerPanels()
    }

    /// Clicking elsewhere or switching Spaces cancels the selection. A click on another screen's
    /// panel moves key focus between our own panels, which is not a cancel.
    func windowDidResignKey(_ notification: Notification) {
        let session = session
        DispatchQueue.main.async { [self] in
            guard sessions.acceptsCallbacks(session) else { return }
            if isCapturing, editor != nil { return }
            if browser != nil, editor == nil { return }
            if isShowing, !isPresentingSavePanel, !raiser.isSwitchingApps, !panels.contains(where: \.isKeyWindow) {
                if videoCountdown { video?.cancelCountdown() }
                hide()
            }
        }
    }
}
