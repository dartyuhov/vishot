import CoreGraphics
import Foundation

/// Geometry here is in image space: points from the image's top-left, y down. Screen positions are
/// never stored, so the document is the same on every screen and in the export.

enum AnnotationColor: String, CaseIterable, Codable {
    case red, yellow, green, purple, white, black

    var name: String {
        switch self {
        case .red: "red"
        case .yellow: "yellow"
        case .green: "green"
        case .purple: "purple"
        case .white: "white"
        case .black: "black"
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 1, green: 0.27, blue: 0.3, alpha: 1)
        case .yellow: CGColor(srgbRed: 1, green: 0.82, blue: 0.2, alpha: 1)
        case .green: CGColor(srgbRed: 0.2, green: 0.8, blue: 0.5, alpha: 1)
        // Palette.accent, the app's own color and the default.
        case .purple: CGColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1)
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

enum Annotation: Equatable, Codable {
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
struct EditSnapshot: Equatable, Codable {
    var annotations: [Annotation]
    var crop: CGRect?
}

struct EditHistory {
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []

    init(snapshots: [EditSnapshot] = []) { undoStack = snapshots }
    var snapshots: [EditSnapshot] { undoStack }

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
