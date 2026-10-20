import AppKit
import Carbon.HIToolbox

/// A rectangle drawn between two corners, like a crop in the editor: from the keyboard, the first `v`
/// anchors at the cursor and the second finishes; with the mouse, a drag. Points are in CoreGraphics
/// global space, and corners are rounded to whole points.
struct RegionSelection: Equatable {
    /// The first corner while a region is being drawn. The cursor is the other.
    private(set) var anchor: CGPoint?
    /// The last finished region.
    private(set) var region: CGRect?
    /// Where the mouse went down, until it goes up.
    private(set) var pressedAt: CGPoint?

    /// Neither drawing nor pressed, so the cursor may move to another display.
    var isIdle: Bool { anchor == nil && pressedAt == nil }

    /// What is shown: the region being drawn, else the finished one.
    func rect(to cursor: CGPoint) -> CGRect? {
        anchor.map { Self.rect($0, cursor) } ?? region
    }

    /// Anchors at the cursor, or finishes the region being drawn. Returns false when that region is
    /// empty, as `finish` does.
    mutating func corner(at cursor: CGPoint) -> Bool {
        guard anchor != nil else {
            anchor = cursor
            return true
        }
        return finish(at: cursor)
    }

    /// Finishes the region being drawn, which replaces the finished one. An empty region (thinner than a
    /// point) is dropped and returns false, keeping the old one.
    @discardableResult
    mutating func finish(at cursor: CGPoint) -> Bool {
        guard let start = anchor else { return true }
        anchor = nil
        let rect = Self.rect(start, cursor)
        guard rect.width >= 1, rect.height >= 1 else { return false }
        region = rect
        return true
    }

    /// Drops the region being drawn. Returns false if there was none.
    mutating func cancel() -> Bool {
        guard anchor != nil else { return false }
        anchor = nil
        pressedAt = nil
        return true
    }

    mutating func press(at point: CGPoint) {
        pressedAt = point
    }

    /// A press that moves past a click starts a region where it went down.
    mutating func drag(to point: CGPoint) {
        guard anchor == nil, let start = pressedAt, !Drag.isClick(from: start, to: point) else { return }
        anchor = start
    }

    enum Release: Equatable {
        case none, finished, empty
        /// A click inside the finished region.
        case clickInRegion
    }

    /// Finishes a region being drawn, by a drag or from the keyboard.
    mutating func release(at point: CGPoint) -> Release {
        guard let start = pressedAt else { return .none }
        pressedAt = nil
        if anchor != nil { return finish(at: point) ? .finished : .empty }
        if Drag.isClick(from: start, to: point), region?.contains(point) == true { return .clickInRegion }
        return .none
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(corners: CGPoint(x: a.x.rounded(), y: a.y.rounded()), CGPoint(x: b.x.rounded(), y: b.y.rounded()))
    }
}

/// Region mode: a cursor on one display at a time, moved like the editor's, that draws a
/// `RegionSelection`. The cursor stays on its display while a region is drawn.
final class RegionSelector {
    enum Command {
        case none, copy, edit, back, cancel
    }

    /// Called when the cursor glides, outside of any input event.
    var onChange: (() -> Void)?

    private let displays: [CaptureTarget]
    private var display: Int
    private let keyboard: KeyboardCursor
    private var selection = RegionSelection()

    /// `displays` must not be empty. The cursor starts at `start`, on the display holding it.
    init(displays: [CaptureTarget], start: CGPoint) {
        self.displays = displays
        display = displays.firstIndex { $0.frame.contains(start) } ?? 0
        var cursor = EditCursor(bounds: displays[display].frame)
        cursor.move(to: start)
        keyboard = KeyboardCursor(cursor)
        keyboard.onChange = { [weak self] in self?.onChange?() }
    }

    /// In CoreGraphics global space.
    var cursor: CGPoint { keyboard.position }

    /// The region shown, being drawn or finished, as something to capture.
    var target: CaptureTarget? {
        guard let rect = selection.rect(to: cursor) else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // A region never leaves its display, so its centre is on it.
        guard case let .display(displayID)? = displays.first(where: { $0.frame.contains(center) })?.kind else { return nil }
        return CaptureTarget(
            kind: .region(displayID: displayID, rect: rect),
            frame: rect,
            anchor: center,
            label: "\(Int(rect.width)) × \(Int(rect.height))"
        )
    }

    var status: String {
        if selection.anchor != nil { return "move, then v to finish · esc cancel" }
        if selection.region != nil { return "v or drag to redraw · click it to copy · 0 $ g G M jump" }
        return "v or drag to start · 0 $ g G M jump"
    }

    // MARK: - Keys

    func handle(_ event: NSEvent) -> Command {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return .none }
        if keyboard.handle(event) { return .none }
        // A held key must not run past a corner or a cancel.
        guard !event.isARepeat else { return .none }
        switch keyCode {
        case kVK_ANSI_V:
            if !selection.corner(at: cursor) { NSSound.beep() }
        case kVK_Tab where selection.isIdle:
            switchDisplay(to: (display + (flags.contains(.shift) ? -1 : 1) + displays.count) % displays.count)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space, kVK_ANSI_E, kVK_ANSI_Y:
            // What you see is what you get, so a region being drawn is finished first.
            guard selection.finish(at: cursor), selection.region != nil else {
                NSSound.beep()
                return .none
            }
            return keyCode == kVK_ANSI_E || (flags.contains(.shift) && keyCode != kVK_ANSI_Y) ? .edit : .copy
        case kVK_Escape:
            if !selection.cancel() { return .back }
        case kVK_ANSI_Q:
            return .cancel
        default: break
        }
        return .none
    }

    func keyUp(_ event: NSEvent) {
        keyboard.keyUp(event)
    }

    // MARK: - Mouse

    /// Points are in CoreGraphics global space.
    func mouseMoved(to point: CGPoint) {
        if selection.isIdle, let index = displays.firstIndex(where: { $0.frame.contains(point) }), index != display {
            switchDisplay(to: index)
        }
        keyboard.move(to: point)
    }

    func mouseDown(at point: CGPoint) {
        mouseMoved(to: point)
        selection.press(at: cursor)
    }

    func mouseDragged(to point: CGPoint) {
        keyboard.move(to: point)
        selection.drag(to: cursor)
    }

    func mouseUp(at point: CGPoint) -> Command {
        keyboard.move(to: point)
        switch selection.release(at: cursor) {
        case .clickInRegion: return .copy
        case .empty: NSSound.beep()
        case .none, .finished: break
        }
        return .none
    }

    /// The cursor starts at the display's centre.
    private func switchDisplay(to index: Int) {
        display = index
        keyboard.cursor = EditCursor(bounds: displays[index].frame)
    }
}
