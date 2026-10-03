import AppKit
import Carbon.HIToolbox

/// A toolbar button.
enum ToolbarItem: Equatable {
    case tool(EditorController.Tool)
    case color(AnnotationColor)
    case undo, redo
    case finish(EditorController.Finish)
}

/// What the editor shows. Geometry is in image space, except `frame`.
struct EditorScene {
    let image: CGImage
    /// Where the image is, in Cocoa global space.
    let frame: CGRect
    /// Committed annotations plus a preview of the action in progress.
    let annotations: [Annotation]
    let crop: CGRect?
    /// A crop is being drawn, so it gets an outline.
    let isCropping: Bool
    /// Nil while typing, when the caret shows instead.
    let cursor: CGPoint?
    let caret: CGRect?
    let tool: EditorController.Tool
    let color: AnnotationColor
    let canUndo: Bool
    let canRedo: Bool
    let status: String
}

/// Edits a capture in place, over the overlay panels. Takes keys and mouse events until it finishes.
final class EditorController {
    enum Tool: CaseIterable {
        case arrow, rect, text, crop

        var name: String {
            switch self {
            case .arrow: "arrow"
            case .rect: "rect"
            case .text: "text"
            case .crop: "crop"
            }
        }

        var key: String {
            switch self {
            case .arrow: "a"
            case .rect: "r"
            case .text: "t"
            case .crop: "c"
            }
        }
    }

    enum Finish {
        case copy, save, saveAndCopy, saveAs, discard
    }

    private enum Action: Equatable {
        case idle
        /// Started from the keyboard; the cursor is the other end.
        case anchored(CGPoint)
        /// Started with the mouse; the cursor is the other end until the button goes up.
        case dragging(CGPoint)
        case typing(String, at: CGPoint)
    }

    /// The image is exported before this is called. It is nil only for `.discard`.
    var onFinish: ((Finish, (image: CGImage, scale: CGFloat)?) -> Void)?
    /// Called when the cursor glides, outside of any input event.
    var onChange: (() -> Void)?

    private var document: EditDocument
    private var history = EditHistory()
    private var cursor: EditCursor
    private var tool = Tool.arrow
    private var color = AnnotationColor.red
    /// The image's top-left, in CoreGraphics global space.
    private let imageOrigin: CGPoint
    /// The last key asked to discard, so the next esc does it.
    private var confirmsDiscard = false
    private var action = Action.idle
    /// Where the mouse went down on the image, until it goes up.
    private var pressedAt: CGPoint?
    /// Shown instead of the key help until the next input.
    private var message = ""
    /// Direction keys held down, by key code, so h and ← count once.
    private var heldKeys: [Int: Direction] = [:]
    private var glideTimer: Timer?
    private var glideStart: TimeInterval = 0
    private var lastGlide: TimeInterval = 0

    init(capture: Capture) {
        document = EditDocument(image: capture.image, scale: capture.scale)
        cursor = EditCursor(size: document.size)
        imageOrigin = capture.frame.origin
    }

    deinit {
        glideTimer?.invalidate()
    }

    // MARK: - Keys

    /// Key codes, not characters, as in the picker. Only typed text reads characters.
    func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        // A held esc must not run past "esc again to discard".
        if event.isARepeat, keyCode == kVK_Escape || keyCode == kVK_ANSI_Q { return }
        message = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if case let .typing(text, at) = action {
            handleTyping(event, keyCode: keyCode, flags: flags, text: text, at: at)
            return
        }
        let shift = flags.contains(.shift)
        let confirmed = confirmsDiscard
        confirmsDiscard = false

        if flags.contains(.command) {
            switch keyCode {
            case kVK_ANSI_Z: shift ? redo() : undo()
            case kVK_ANSI_S: finish(.saveAs)
            default: break
            }
            return
        }
        if flags.contains(.control) {
            if keyCode == kVK_ANSI_R { redo() }
            return
        }
        if let direction = Self.directionKeys[keyCode] {
            // Holding is the glide's job, so repeats are ignored.
            guard !event.isARepeat else { return }
            heldKeys[keyCode] = direction
            step(direction, flags: flags)
            startGlide()
            return
        }
        switch keyCode {
        case kVK_ANSI_0: jump(.left)
        case kVK_ANSI_4 where shift: jump(.right)
        case kVK_ANSI_G: jump(shift ? .bottom : .top)
        case kVK_ANSI_M where shift: jump(.center)
        case kVK_ANSI_A: toolKey(.arrow)
        case kVK_ANSI_R: toolKey(.rect)
        case kVK_ANSI_C: toolKey(.crop)
        case kVK_ANSI_T: startTyping(at: cursor.position)
        case kVK_Return, kVK_ANSI_KeypadEnter: finishAnchored()
        case kVK_Tab: color = color.cycled(by: shift ? -1 : 1)
        case _ where Self.colorKeys.contains(keyCode): color = AnnotationColor.allCases[Self.colorKeys.firstIndex(of: keyCode)!]
        case kVK_ANSI_U: undo()
        case kVK_ANSI_Y: finish(.copy)
        case kVK_ANSI_S: finish(shift ? .saveAndCopy : .save)
        case kVK_Escape, kVK_ANSI_Q: escape(confirmed: confirmed)
        default: break
        }
    }

    private static let directionKeys: [Int: Direction] = [
        kVK_ANSI_H: .left, kVK_LeftArrow: .left,
        kVK_ANSI_J: .down, kVK_DownArrow: .down,
        kVK_ANSI_K: .up, kVK_UpArrow: .up,
        kVK_ANSI_L: .right, kVK_RightArrow: .right,
    ]

    func keyUp(_ event: NSEvent) {
        heldKeys[Int(event.keyCode)] = nil
        if heldKeys.isEmpty { stopGlide() }
    }

    private static func speed(for flags: NSEvent.ModifierFlags) -> EditCursor.Speed {
        flags.contains(.option) ? .slow : flags.contains(.shift) ? .fast : .normal
    }

    /// A press moves one step right away. Holding then glides.
    private func step(_ direction: Direction, flags: NSEvent.ModifierFlags) {
        cursor.move(direction, speed: Self.speed(for: flags))
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func startGlide() {
        guard glideTimer == nil else { return }
        glideStart = CACurrentMediaTime()
        lastGlide = glideStart
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.glide() }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    private func glide() {
        // A key-up can go missing when key focus moves, so ask which keys are still down.
        heldKeys = heldKeys.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0.key)) }
        guard !heldKeys.isEmpty else {
            stopGlide()
            return
        }
        let now = CACurrentMediaTime()
        let elapsed = now - lastGlide
        lastGlide = now
        let speed = CursorGlide.speed(Self.speed(for: NSEvent.modifierFlags), heldFor: now - glideStart)
        let vector = CursorGlide.vector(Array(heldKeys.values))
        guard speed > 0, vector != CGVector.zero else { return }
        cursor.move(by: CGVector(dx: vector.dx * speed * elapsed, dy: vector.dy * speed * elapsed))
        NSCursor.setHiddenUntilMouseMoves(true)
        onChange?()
    }

    private func stopGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        heldKeys = [:]
    }

    private func jump(_ jump: EditCursor.Jump) {
        cursor.jump(jump)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// `1`…`6` pick the colors in toolbar order.
    private static let colorKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]

    /// Anchors the tool at the cursor, or finishes it if it is already anchored.
    private func toolKey(_ newTool: Tool) {
        if case .anchored = action, tool == newTool {
            finishAnchored()
            return
        }
        tool = newTool
        action = .anchored(cursor.position)
    }

    /// One line of text. `event.characters`, so any layout types normally.
    private func handleTyping(_ event: NSEvent, keyCode: Int, flags: NSEvent.ModifierFlags, text: String, at point: CGPoint) {
        if flags.contains(.command) {
            switch keyCode {
            case kVK_ANSI_Z: undo()
            case kVK_ANSI_S: finish(.saveAs)
            default: break
            }
            return
        }
        switch keyCode {
        // Esc keeps the label too; ⌘z or ⌫ drop it.
        case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter: placeText()
        case kVK_Delete: action = .typing(String(text.dropLast()), at: point)
        case kVK_Tab: color = color.cycled(by: flags.contains(.shift) ? -1 : 1)
        default:
            guard !flags.contains(.control) else { return }
            let typed = (event.characters ?? "").filter(Self.isPrintable)
            action = .typing(text + typed, at: point)
        }
    }

    /// Drops control characters and the private-use characters AppKit gives arrow and function keys.
    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private func escape(confirmed: Bool) {
        if action != .idle {
            cancelAction()
        } else if document.snapshot != EditSnapshot(annotations: [], crop: nil), !confirmed {
            confirmsDiscard = true
            message = "esc again to discard"
        } else {
            onFinish?(.discard, nil)
        }
    }

    // MARK: - Mouse

    /// Points are in CoreGraphics global space.
    func mouseMoved(to point: CGPoint) {
        cursor.move(to: imagePoint(point))
    }

    func mouseDown(at point: CGPoint) {
        let local = imagePoint(point)
        // The dimmed area around the image does nothing.
        guard CGRect(origin: .zero, size: document.size).contains(local) else { return }
        message = ""
        confirmsDiscard = false
        cursor.move(to: local)
        pressedAt = cursor.position
    }

    func mouseDragged(to point: CGPoint) {
        guard let start = pressedAt else { return }
        cursor.move(to: imagePoint(point))
        if action == .idle, tool != .text, !Drag.isClick(from: start, to: cursor.position) {
            action = .dragging(start)
        }
    }

    func mouseUp(at point: CGPoint) {
        guard let start = pressedAt else { return }
        pressedAt = nil
        cursor.move(to: imagePoint(point))
        let isClick = Drag.isClick(from: start, to: cursor.position)
        switch action {
        case .dragging(let origin), .anchored(let origin):
            commit(from: origin, to: cursor.position, beepsWhenEmpty: true)
        case .typing:
            guard isClick else { return }
            placeText()
            if tool == .text { startTyping(at: start) }
        case .idle:
            if isClick, tool == .text { startTyping(at: start) }
        }
    }

    private func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - imageOrigin.x, y: point.y - imageOrigin.y)
    }

    // MARK: - Toolbar

    func select(_ item: ToolbarItem) {
        message = ""
        let confirmed = confirmsDiscard
        confirmsDiscard = false
        switch item {
        case .tool(let newTool):
            // Only selects the tool. The keys also anchor it.
            if case .typing = action { placeText() } else { cancelAction() }
            tool = newTool
        case .color(let newColor): color = newColor
        case .undo: undo()
        case .redo: redo()
        case .finish(.discard): escape(confirmed: confirmed)
        case .finish(let kind): finish(kind)
        }
    }

    // MARK: - Edits

    private enum Shape {
        case annotation(Annotation)
        case crop(CGRect)
    }

    /// What the current tool makes between two points, or nil if it would be empty.
    private func shape(from start: CGPoint, to end: CGPoint) -> Shape? {
        let rect = CGRect(corners: start, end)
        switch tool {
        case .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return nil }
            return .annotation(.arrow(from: start, to: end, color: color))
        case .rect:
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return .annotation(.rect(rect, color: color))
        case .crop:
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return .crop(rect)
        case .text:
            return nil
        }
    }

    private func finishAnchored() {
        guard case let .anchored(start) = action else { return }
        commit(from: start, to: cursor.position, beepsWhenEmpty: true)
    }

    private func commit(from start: CGPoint, to end: CGPoint, beepsWhenEmpty: Bool) {
        action = .idle
        guard let shape = shape(from: start, to: end) else {
            if beepsWhenEmpty { NSSound.beep() }
            return
        }
        var next = document.snapshot
        switch shape {
        case .annotation(let annotation): next.annotations.append(annotation)
        case .crop(let rect): next.crop = rect
        }
        apply(next)
    }

    private func startTyping(at point: CGPoint) {
        cancelAction()
        stopGlide()
        tool = .text
        action = .typing("", at: point)
    }

    /// An empty label is cancelled.
    private func placeText() {
        guard case let .typing(text, at) = action else { return }
        action = .idle
        guard !text.isEmpty else { return }
        var next = document.snapshot
        next.annotations.append(.text(text, at: at, color: color))
        apply(next)
    }

    private func cancelAction() {
        action = .idle
        pressedAt = nil
    }

    private func apply(_ next: EditSnapshot) {
        history.push(document.snapshot)
        document.snapshot = next
    }

    /// With an action in progress, undo only cancels it.
    private func undo() {
        if action != .idle {
            cancelAction()
            return
        }
        var state = document.snapshot
        guard history.undo(&state) else {
            NSSound.beep()
            return
        }
        document.snapshot = state
    }

    /// With an action in progress, redo only cancels it, like undo.
    private func redo() {
        if action != .idle {
            cancelAction()
            return
        }
        var state = document.snapshot
        guard history.redo(&state) else {
            NSSound.beep()
            return
        }
        document.snapshot = state
    }

    /// What you see is what you get, so an action in progress is committed first.
    private func finish(_ kind: Finish) {
        switch action {
        case .anchored(let start), .dragging(let start): commit(from: start, to: cursor.position, beepsWhenEmpty: false)
        case .typing: placeText()
        case .idle: break
        }
        pressedAt = nil
        guard let image = AnnotationRenderer.export(document) else {
            NSSound.beep()
            message = "export failed"
            return
        }
        onFinish?(kind, (image, document.scale))
    }

    // MARK: - Output

    func render(on panels: [OverlayPanel]) {
        let frame = CGRect(origin: imageOrigin, size: document.size)
        var annotations = document.annotations
        var crop = document.crop
        var isCropping = false
        var caret: CGRect?
        switch action {
        case .anchored(let start), .dragging(let start):
            switch shape(from: start, to: cursor.position) {
            case .annotation(let annotation): annotations.append(annotation)
            case .crop(let rect):
                crop = rect
                isCropping = true
            case nil: break
            }
        case let .typing(text, at):
            if !text.isEmpty { annotations.append(.text(text, at: at, color: color)) }
            caret = AnnotationRenderer.caret(after: text, at: at)
        case .idle: break
        }
        let scene = EditorScene(
            image: document.image,
            frame: frame.flippedBetweenCocoaAndCG,
            annotations: annotations,
            crop: crop,
            isCropping: isCropping,
            cursor: caret == nil ? cursor.position : nil,
            caret: caret,
            tool: tool,
            color: color,
            canUndo: history.canUndo,
            canRedo: history.canRedo,
            status: status
        )
        // The toolbar goes on the screen showing most of the image.
        let toolbarPanel = panels.max { visibleArea(of: frame, on: $0) < visibleArea(of: frame, on: $1) }
        for panel in panels {
            panel.showEditor(scene, showsToolbar: panel === toolbarPanel)
        }
    }

    private func visibleArea(of frame: CGRect, on panel: OverlayPanel) -> CGFloat {
        let visible = frame.intersection(panel.frame.flippedBetweenCocoaAndCG)
        return visible.isNull ? 0 : visible.width * visible.height
    }

    private var status: String {
        if !message.isEmpty { return message }
        switch action {
        case .idle:
            return "\(color.name) · 1–6 or tab color · hjkl move (⇧ far, ⌥ slow) · 0 $ g G M jump"
        case .anchored:
            return "\(color.name) \(tool.name) · move, then ↵ or \(tool.key) to finish · esc cancel"
        case .dragging:
            return "\(color.name) \(tool.name) · release to finish · esc cancel"
        case .typing:
            return "\(color.name) text · type a label · ↵ or esc place · ⌘z cancel"
        }
    }
}
