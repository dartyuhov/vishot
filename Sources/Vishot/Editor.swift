import AppKit
import Carbon.HIToolbox

/// A toolbar button.
enum ToolbarItem: Hashable {
    case tool(EditorController.Tool)
    case color(AnnotationColor)
    case undo, redo
    case toggleHUD
    case escape
    case finish(EditorController.Finish)
}

/// The meaning of the current action, shared by input and every HUD layout.
enum EditorActionContext: Equatable {
    case idle(EditorController.Tool?)
    case drawing(EditorController.Tool, mouse: Bool)
    case typing
    case resizing

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    var tool: EditorController.Tool? {
        switch self {
        case .idle(let tool): return tool
        case .drawing(let tool, _): return tool
        case .typing: return .text
        case .resizing: return .crop
        }
    }

    var escapeLabel: String {
        switch self {
        case .idle: return "discard"
        case .resizing: return "apply"
        case .drawing, .typing: return "place"
        }
    }

    var status: String {
        switch self {
        case .idle(let tool):
            return tool == nil ? "choose a tool to start editing · arrows/hjkl move" : "arrows/hjkl move · choose a tool or drag to draw"
        case .drawing(let tool, mouse: false):
            return "move, then ↵ / \(tool.key) / esc place · u cancel"
        case .drawing(_, mouse: true): return "release / esc place · u cancel"
        case .typing: return "⇧↵ new line · ↵ / esc place · ⌘z cancel · tab color"
        case .resizing: return "tab corner · hjkl / drag resize · ↵ / esc apply · u cancel"
        }
    }
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
    var isCropping: Bool { context == .resizing }
    let cropHandle: CGPoint?
    /// Nil while typing, when the caret shows instead.
    let cursor: CGPoint?
    let caret: CGRect?
    let context: EditorActionContext
    let isHUDHidden: Bool
    let color: AnnotationColor
    let canUndo: Bool
    let canRedo: Bool
    let status: String
    var viewScale: CGFloat = 1
}

/// Edits a capture in place, over the overlay panels. Takes keys and mouse events until it finishes.
final class EditorController {
    /// Surrounding UI appearance; document markup style is independent when restoring history.
    let theme: ResolvedTheme
    enum Tool: CaseIterable, Hashable {
        case arrow, rect, text, crop

        var name: String {
            switch self {
            case .arrow: "arrow"
            case .rect: "rect"
            case .text: "text"
            case .crop: "resize"
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

    enum Finish: Hashable {
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

    private(set) var document: EditDocument
    private(set) var history = EditHistory()
    private let viewScale: CGFloat
    private let cursor: KeyboardCursor
    private var tool: Tool?
    private var color = AnnotationColor.purple
    /// The image's top-left, in CoreGraphics global space.
    private let imageOrigin: CGPoint
    /// The last key asked to discard, so the next esc does it.
    private var confirmsDiscard = false
    private var action = Action.idle
    /// Where the mouse went down on the image, until it goes up.
    private var pressedAt: CGPoint?
    /// Shown instead of the key help until the next input.
    private var message = ""
    private let baseline: EditSnapshot
    private struct Resize {
        let original: CGRect
        var area: EditArea
        var handle: EditArea.Handle
        var mouseOrigin: CGPoint?
        var dragRect: CGRect?
        var staysActive = false
    }
    private var resizing: Resize?
    private var hoveredHandle: EditArea.Handle?
    private(set) var isHUDHidden = false
    /// Refreshed from the rendered toolbar's placement on its host panel.
    var canHideHUD = false

    init(capture: Capture, restored: HistoryDocument? = nil, viewScale: CGFloat = 1,
         theme: ResolvedTheme = ThemeCatalog.pixel) {
        self.theme = theme
        document = restored?.document ?? EditDocument(image: capture.image, scale: capture.scale, crop: capture.initialCrop)
        history = EditHistory(snapshots: restored?.undo ?? [])
        self.viewScale = viewScale
        baseline = document.snapshot
        cursor = KeyboardCursor(EditCursor(bounds: document.crop ?? CGRect(origin: .zero, size: document.size)))
        imageOrigin = capture.frame.origin
        cursor.onChange = { [weak self] in
            self?.updateResizeFromCursor()
            self?.onChange?()
        }
    }

    // MARK: - Keys

    /// Key codes, not characters, as in the picker. Only typed text reads characters.
    func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        // A held esc must not run past "esc again to discard".
        if event.isARepeat, keyCode == kVK_Escape || keyCode == kVK_ANSI_Q { return }
        message = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Plain letters still type normally in a label; the clickable toggle remains available.
        if keyCode == kVK_ANSI_O, flags.intersection([.command, .control, .option]).isEmpty,
           !isTyping {
            if !event.isARepeat { toggleHUD() }
            return
        }
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
        if resizing != nil {
            if resizing?.mouseOrigin != nil {
                if keyCode == kVK_Escape || keyCode == kVK_ANSI_Q { finishResize(commit: true) }
                return
            }
            switch keyCode {
            case kVK_Tab:
                cursor.stop()
                resizing!.handle = resizing!.handle.cycled(by: shift ? -1 : 1)
                cursor.move(to: resizing!.handle.point(in: resizing!.area.rect))
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_ANSI_C:
                if !event.isARepeat { finishResize(commit: true) }
            case kVK_Escape, kVK_ANSI_Q: finishResize(commit: true)
            case kVK_ANSI_U: finishResize(commit: false)
            default:
                if cursor.handle(event) { updateResizeFromCursor() }
            }
            return
        }
        if cursor.handle(event) { return }
        switch keyCode {
        case kVK_ANSI_A: toolKey(.arrow)
        case kVK_ANSI_R: toolKey(.rect)
        case kVK_ANSI_C:
            if !event.isARepeat { beginResize() }
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

    func keyUp(_ event: NSEvent) {
        cursor.keyUp(event)
    }

    private var isTyping: Bool {
        actionContext == .typing
    }

    private var actionContext: EditorActionContext {
        if resizing != nil { return .resizing }
        switch action {
        case .idle: return .idle(tool)
        case .anchored: return .drawing(tool!, mouse: false)
        case .dragging: return .drawing(tool!, mouse: true)
        case .typing: return .typing
        }
    }

    private func toggleHUD() {
        if isHUDHidden || canHideHUD { isHUDHidden.toggle() }
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

    /// Typed text uses `event.characters`, so any layout types normally.
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
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.shift) { action = .typing(text + "\n", at: point) } else { placeText() }
        case kVK_Escape: placeText()
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

    /// Like a label, a shape in progress is kept. Only ⌘z or u drop it.
    private func escape(confirmed: Bool) {
        switch actionContext {
        case .resizing: finishResize(commit: true)
        case .drawing:
            pressedAt = nil
            if case .anchored(let start) = action {
                commit(from: start, to: cursor.position, beepsWhenEmpty: false)
            } else if case .dragging(let start) = action {
                commit(from: start, to: cursor.position, beepsWhenEmpty: false)
            }
        case .typing:
            placeText()
        case .idle:
            if document.snapshot != baseline, !confirmed {
                confirmsDiscard = true
                message = "esc again to discard"
            } else {
                onFinish?(.discard, nil)
            }
        }
    }

    // MARK: - Mouse

    /// Points are in CoreGraphics global space.
    func mouseMoved(to point: CGPoint) {
        if resizing?.mouseOrigin != nil { return }
        if resizing == nil { cursor.move(to: imagePoint(point)) }
        let handle = editArea.hitTest(imagePoint(point))
        hoveredHandle = handle
        switch handle {
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .topLeft, .topRight, .bottomLeft, .bottomRight: NSCursor.crosshair.set()
        case nil: NSCursor.arrow.set()
        }
    }

    func mouseDown(at point: CGPoint) {
        let local = imagePoint(point)
        if let handle = editArea.hitTest(local) {
            if resizing != nil {
                cursor.stop()
                resizing!.handle = handle
                resizing!.mouseOrigin = local
                resizing!.dragRect = resizing!.area.rect
                resizing!.staysActive = true
                cursor.move(to: handle.point(in: resizing!.area.rect))
                return
            }
            beginResize(handle: handle, mouseOrigin: local)
            return
        }
        guard resizing == nil, editArea.rect.contains(local) else { return }
        message = ""
        confirmsDiscard = false
        cursor.move(to: local)
        pressedAt = cursor.position
    }

    func mouseDragged(to point: CGPoint) {
        if let resize = resizing, let origin = resize.mouseOrigin {
            let point = imagePoint(point)
            let rect = resize.dragRect ?? resize.original
            let start = resize.handle.point(in: rect)
            var area = EditArea(rect: rect, bounds: resize.area.bounds)
            area.resize(resize.handle, to: CGPoint(x: start.x + point.x - origin.x, y: start.y + point.y - origin.y))
            resizing!.area = area
            cursor.move(to: resize.handle.point(in: area.rect))
            return
        }
        guard let start = pressedAt else { return }
        cursor.move(to: imagePoint(point))
        if action == .idle, tool != nil, tool != .text, !Drag.isClick(from: start, to: cursor.position) {
            action = .dragging(start)
        }
    }

    func mouseUp(at point: CGPoint) {
        if resizing?.mouseOrigin != nil {
            mouseDragged(to: point)
            if resizing!.staysActive {
                // A clicked edge becomes a corner again for subsequent keyboard input.
                let point = cursor.position
                let rect = resizing!.area.rect
                let corner = EditArea.Handle.allCases.prefix(4).min {
                    let a = $0.point(in: rect), b = $1.point(in: rect)
                    return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
                }!
                resizing!.handle = corner
                resizing!.mouseOrigin = nil
                resizing!.dragRect = nil
                cursor.move(to: corner.point(in: rect))
            } else {
                finishResize(commit: true)
            }
            return
        }
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
        CGPoint(x: (point.x - imageOrigin.x) / viewScale, y: (point.y - imageOrigin.y) / viewScale)
    }

    // MARK: - Toolbar

    func select(_ item: ToolbarItem) {
        message = ""
        let confirmed = confirmsDiscard
        confirmsDiscard = false
        switch item {
        case .toggleHUD: toggleHUD()
        case .tool(let newTool):
            if newTool == .crop {
                if resizing != nil { finishResize(commit: true) } else { beginResize() }
                return
            }
            if resizing != nil { finishResize(commit: true) }
            // Only selects the tool. The keys also anchor it.
            if case .typing = action { placeText() } else { cancelAction() }
            tool = newTool
        case .color(let newColor): color = newColor
        case .undo: undo()
        case .redo: redo()
        case .escape, .finish(.discard): escape(confirmed: confirmed)
        case .finish(let kind): finish(kind)
        }
    }

    // MARK: - Edits

    private var editArea: EditArea {
        resizing?.area ?? EditArea(rect: document.crop ?? CGRect(origin: .zero, size: document.size),
                                  bounds: CGRect(origin: .zero, size: document.size))
    }

    private func beginResize(handle: EditArea.Handle = .topLeft, mouseOrigin: CGPoint? = nil) {
        guard resizing == nil else { return }
        if case .typing = action { placeText() } else { cancelAction() }
        cursor.stop()
        let area = editArea
        resizing = Resize(original: area.rect, area: area, handle: handle, mouseOrigin: mouseOrigin)
        hoveredHandle = nil
        cursor.cursor = EditCursor(bounds: area.bounds)
        cursor.move(to: handle.point(in: area.rect))
    }

    private func updateResizeFromCursor() {
        guard var resize = resizing, resize.mouseOrigin == nil else { return }
        resize.area.resize(resize.handle, to: cursor.position)
        resizing = resize
        cursor.move(to: resize.handle.point(in: resize.area.rect))
    }

    private func finishResize(commit: Bool) {
        guard let resize = resizing else { return }
        cursor.stop()
        resizing = nil
        hoveredHandle = nil
        if commit, resize.area.rect != resize.original {
            var next = document.snapshot
            next.crop = resize.area.rect
            apply(next)
        }
        constrainCursor()
    }

    private func constrainCursor() {
        let position = cursor.position
        cursor.stop()
        cursor.cursor = EditCursor(bounds: document.crop ?? CGRect(origin: .zero, size: document.size))
        cursor.move(to: position)
    }

    /// What the current tool makes between two points, or nil if it would be empty.
    private func shape(from start: CGPoint, to end: CGPoint) -> Annotation? {
        let rect = CGRect(corners: start, end)
        switch tool {
        case .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return nil }
            return .arrow(from: start, to: end, color: color)
        case .rect:
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return .rect(rect, color: color)
        case .crop, .text, nil:
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
        next.annotations.append(shape)
        apply(next)
    }

    private func startTyping(at point: CGPoint) {
        cancelAction()
        cursor.stop()
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
        if actionContext.isActive {
            cancelCurrentAction()
            return
        }
        var state = document.snapshot
        guard history.undo(&state) else {
            NSSound.beep()
            return
        }
        document.snapshot = state
        constrainCursor()
    }

    /// With an action in progress, redo only cancels it, like undo.
    private func redo() {
        if actionContext.isActive {
            cancelCurrentAction()
            return
        }
        var state = document.snapshot
        guard history.redo(&state) else {
            NSSound.beep()
            return
        }
        document.snapshot = state
        constrainCursor()
    }

    /// What you see is what you get, so an action in progress is committed first.
    private func finish(_ kind: Finish) {
        cursor.stop()
        if resizing != nil { finishResize(commit: true) }
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

    private func cancelCurrentAction() {
        if actionContext == .resizing { finishResize(commit: false) } else { cancelAction() }
    }

    func makeScene() -> EditorScene {
        let frame = CGRect(origin: imageOrigin, size: CGSize(width: document.size.width * viewScale, height: document.size.height * viewScale))
        var annotations = document.annotations
        var crop = document.crop
        if let resize = resizing {
            crop = resize.area.rect
        }
        var caret: CGRect?
        switch action {
        case .anchored(let start), .dragging(let start):
            if let annotation = shape(from: start, to: cursor.position) { annotations.append(annotation) }
        case let .typing(text, at):
            if !text.isEmpty { annotations.append(.text(text, at: at, color: color)) }
            caret = AnnotationRenderer.caret(after: text, at: at)
        case .idle: break
        }
        return EditorScene(
            image: document.image,
            frame: frame.flippedBetweenCocoaAndCG,
            annotations: annotations,
            crop: crop,
            cropHandle: resizing.map { $0.handle.point(in: $0.area.rect) }
                ?? hoveredHandle.map { $0.point(in: editArea.rect) },
            cursor: caret == nil ? cursor.position : nil,
            caret: caret,
            context: actionContext,
            isHUDHidden: isHUDHidden,
            color: color,
            canUndo: history.canUndo,
            canRedo: history.canRedo,
            status: status,
            viewScale: viewScale
        )
    }

    func render(on panels: [OverlayPanel]) {
        let scene = makeScene()
        let frame = scene.frame.flippedBetweenCocoaAndCG
        // The toolbar goes on the screen showing most of the image.
        let toolbarPanel = panels.max { visibleArea(of: frame, on: $0) < visibleArea(of: frame, on: $1) }
        for panel in panels {
            panel.showEditor(scene, showsToolbar: panel === toolbarPanel)
        }
        canHideHUD = toolbarPanel?.canHideEditorHUD ?? false
    }

    private func visibleArea(of frame: CGRect, on panel: OverlayPanel) -> CGFloat {
        let visible = frame.intersection(panel.frame.flippedBetweenCocoaAndCG)
        return visible.isNull ? 0 : visible.width * visible.height
    }

    private var status: String {
        if !message.isEmpty { return message }
        return actionContext.status
    }
}
