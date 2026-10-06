import AppKit
import Carbon.HIToolbox

/// The aiming point, shared by the editor and region mode. The editor keeps it inside the whole image
/// (image space), not just the crop, so a new crop can grow back. Region mode keeps it on one display
/// (CoreGraphics global space).
struct EditCursor {
    enum Speed {
        case slow, normal, fast

        var distance: CGFloat {
            switch self {
            case .slow: 6
            case .normal: 15
            case .fast: 48
            }
        }
    }

    enum Jump {
        case left, right, top, bottom, center
    }

    let bounds: CGRect
    private(set) var position: CGPoint

    init(bounds: CGRect) {
        self.bounds = bounds
        position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    init(size: CGSize) {
        self.init(bounds: CGRect(origin: .zero, size: size))
    }

    mutating func move(to point: CGPoint) {
        position = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    mutating func move(_ direction: Direction, speed: Speed) {
        let v = direction.vector
        move(by: CGVector(dx: v.dx * speed.distance, dy: v.dy * speed.distance))
    }

    mutating func move(by offset: CGVector) {
        move(to: CGPoint(x: position.x + offset.dx, y: position.y + offset.dy))
    }

    mutating func jump(_ jump: Jump) {
        switch jump {
        case .left: position.x = bounds.minX
        case .right: position.x = bounds.maxX
        case .top: position.y = bounds.minY
        case .bottom: position.y = bounds.maxY
        case .center: position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

/// Holding direction keys glides the cursor, and keys held together move it diagonally. macOS only
/// repeats the last key pressed, so `KeyboardCursor` tracks held keys and moves on a timer instead.
enum CursorGlide {
    /// A press shorter than this is a single step.
    static let delay: TimeInterval = 0.15
    /// The plain glide speeds up from 525 to 1800 pt/s over this long.
    private static let rampDuration: TimeInterval = 0.7

    /// Points per second after holding for `heldFor` seconds.
    static func speed(_ speed: EditCursor.Speed, heldFor held: TimeInterval) -> CGFloat {
        guard held >= delay else { return 0 }
        switch speed {
        case .slow: return 120
        case .fast: return 2400
        case .normal:
            let progress = min((held - delay) / rampDuration, 1)
            return 525 + 1275 * CGFloat(progress)
        }
    }

    /// One unit per axis for the held directions. Opposite directions cancel.
    static func vector(_ directions: [Direction]) -> CGVector {
        let unique = Set(directions)
        return CGVector(
            dx: unique.reduce(0) { $0 + $1.vector.dx },
            dy: unique.reduce(0) { $0 + $1.vector.dy }
        )
    }
}

/// Moves an `EditCursor` from the keyboard, the same way in the editor and in region mode: hjkl and
/// the arrows step (⇧ far, ⌥ slow), holding them glides, and `0 $ g G M` jump to the edges and centre.
final class KeyboardCursor {
    /// Called when the cursor glides, outside of any input event.
    var onChange: (() -> Void)?
    /// Replaced when region mode moves to another display.
    var cursor: EditCursor
    /// Direction keys held down, by key code, so h and ← count once.
    private var heldKeys: [Int: Direction] = [:]
    private var glideTimer: Timer?
    private var glideStart: TimeInterval = 0
    private var lastGlide: TimeInterval = 0

    init(_ cursor: EditCursor) {
        self.cursor = cursor
    }

    deinit {
        glideTimer?.invalidate()
    }

    var position: CGPoint { cursor.position }

    func move(to point: CGPoint) {
        cursor.move(to: point)
    }

    /// Moves for a movement key and returns true. Returns false for any other key.
    func handle(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let direction = Self.directionKeys[keyCode] {
            // Holding is the glide's job, so repeats are ignored.
            guard !event.isARepeat else { return true }
            heldKeys[keyCode] = direction
            cursor.move(direction, speed: Self.speed(for: flags))
            NSCursor.setHiddenUntilMouseMoves(true)
            startGlide()
            return true
        }
        let shift = flags.contains(.shift)
        let jump: EditCursor.Jump
        switch keyCode {
        case kVK_ANSI_0: jump = .left
        case kVK_ANSI_4 where shift: jump = .right
        case kVK_ANSI_G: jump = shift ? .bottom : .top
        case kVK_ANSI_M where shift: jump = .center
        default: return false
        }
        cursor.jump(jump)
        NSCursor.setHiddenUntilMouseMoves(true)
        return true
    }

    private static let directionKeys: [Int: Direction] = [
        kVK_ANSI_H: .left, kVK_LeftArrow: .left,
        kVK_ANSI_J: .down, kVK_DownArrow: .down,
        kVK_ANSI_K: .up, kVK_UpArrow: .up,
        kVK_ANSI_L: .right, kVK_RightArrow: .right,
    ]

    func keyUp(_ event: NSEvent) {
        heldKeys[Int(event.keyCode)] = nil
        if heldKeys.isEmpty { stop() }
    }

    func stop() {
        glideTimer?.invalidate()
        glideTimer = nil
        heldKeys = [:]
    }

    private static func speed(for flags: NSEvent.ModifierFlags) -> EditCursor.Speed {
        flags.contains(.option) ? .slow : flags.contains(.shift) ? .fast : .normal
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
            stop()
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
}

extension CGRect {
    /// The rect spanned by two opposite corners, in whichever direction it was drawn.
    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum Drag {
    /// A press that moves less than this before release is a click, not a drag.
    static let clickDistance: CGFloat = 3

    static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < clickDistance
    }
}
