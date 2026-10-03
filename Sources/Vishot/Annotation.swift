import CoreGraphics

/// Geometry here is in image space: points from the image's top-left, y down. Screen positions are
/// never stored, so the document is the same on every screen and in the export.

enum AnnotationColor: CaseIterable {
    case red, yellow, green, blue, white, black

    var name: String {
        switch self {
        case .red: "red"
        case .yellow: "yellow"
        case .green: "green"
        case .blue: "blue"
        case .white: "white"
        case .black: "black"
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        case .green: CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    /// The next color in the palette, wrapping around. `step` is 1 or -1.
    func cycled(by step: Int) -> AnnotationColor {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[(index + step + all.count) % all.count]
    }
}

enum Annotation: Equatable {
    case arrow(from: CGPoint, to: CGPoint, color: AnnotationColor)
    case rect(CGRect, color: AnnotationColor)
    /// `at` is the left end of the line, at its vertical centre.
    case text(String, at: CGPoint, color: AnnotationColor)
}

/// The captured image and what has been drawn on it.
struct EditDocument {
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
    var annotations: [Annotation] = []
    /// In image space. Nil keeps the whole image.
    var crop: CGRect?

    /// In points.
    var size: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var snapshot: EditSnapshot {
        get { EditSnapshot(annotations: annotations, crop: crop) }
        set {
            annotations = newValue.annotations
            crop = newValue.crop
        }
    }
}

/// The part of a document that undo and redo restore.
struct EditSnapshot: Equatable {
    var annotations: [Annotation]
    var crop: CGRect?
}

struct EditHistory {
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state before a change.
    mutating func push(_ snapshot: EditSnapshot) {
        undoStack.append(snapshot)
        redoStack = []
    }

    /// Returns false, leaving `state` as it is, when there is nothing to undo.
    mutating func undo(_ state: inout EditSnapshot) -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(state)
        state = previous
        return true
    }

    /// Returns false, leaving `state` as it is, when there is nothing to redo.
    mutating func redo(_ state: inout EditSnapshot) -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(state)
        state = next
        return true
    }
}

/// The aiming point, in image space. It stays inside the whole image, not just the crop, so a new
/// crop can grow back.
struct EditCursor {
    enum Speed {
        case fine, normal, fast

        var distance: CGFloat {
            switch self {
            case .fine: 1
            case .normal: 8
            case .fast: 64
            }
        }
    }

    enum Jump {
        case left, right, top, bottom, center
    }

    let size: CGSize
    private(set) var position: CGPoint

    init(size: CGSize) {
        self.size = size
        position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    mutating func move(to point: CGPoint) {
        position = CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    mutating func move(_ direction: Direction, speed: Speed) {
        let v = direction.vector
        move(to: CGPoint(x: position.x + v.dx * speed.distance, y: position.y + v.dy * speed.distance))
    }

    mutating func jump(_ jump: Jump) {
        switch jump {
        case .left: position.x = 0
        case .right: position.x = size.width
        case .top: position.y = 0
        case .bottom: position.y = size.height
        case .center: position = CGPoint(x: size.width / 2, y: size.height / 2)
        }
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
