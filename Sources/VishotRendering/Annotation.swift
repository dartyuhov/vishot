import CoreGraphics
import Foundation

/// Geometry here is in image space: points from the image's top-left, y down. Screen positions are
/// never stored, so the document is the same on every screen and in the export.

public enum AnnotationColor: String, CaseIterable, Codable {
    case red, yellow, green, purple, white, black

    public var name: String {
        switch self {
        case .red: "red"
        case .yellow: "yellow"
        case .green: "green"
        case .purple: "purple"
        case .white: "white"
        case .black: "black"
        }
    }

    public var cgColor: CGColor {
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
    public func cycled(by step: Int) -> AnnotationColor {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[(index + step + all.count) % all.count]
    }
}

public enum Annotation: Equatable, Codable {
    case arrow(from: CGPoint, to: CGPoint, color: AnnotationColor)
    case rect(CGRect, color: AnnotationColor)
    /// `at` is the left end of the line, at its vertical centre.
    case text(String, at: CGPoint, color: AnnotationColor)
}

/// The captured image and what has been drawn on it.
public struct EditDocument {
    public let image: CGImage
    /// Pixels per point.
    public let scale: CGFloat
    public var annotations: [Annotation] = []
    /// In image space. Nil keeps the whole image.
    public var crop: CGRect?

    /// Fixed for the editable screenshot's lifetime; snapshots only restore geometry/content.
    public let annotationStyle: ThemeID
    public let resolvedAnnotationStyle: AnnotationStyle

    public init(image: CGImage, scale: CGFloat, annotations: [Annotation] = [], crop: CGRect? = nil,
         annotationStyle: ThemeID = .pixel, resolvedStyle: AnnotationStyle? = nil) {
        self.image = image
        self.scale = scale
        self.annotations = annotations
        self.crop = crop
        self.annotationStyle = annotationStyle
        resolvedAnnotationStyle = resolvedStyle ?? AnnotationCatalog.annotation(annotationStyle)
    }

    /// In points.
    public var size: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    public var snapshot: EditSnapshot {
        get { EditSnapshot(annotations: annotations, crop: crop) }
        set {
            annotations = newValue.annotations
            crop = newValue.crop
        }
    }
}

/// The part of a document that undo and redo restore.
public struct EditSnapshot: Equatable, Codable {
    public var annotations: [Annotation]
    public var crop: CGRect?

    public init(annotations: [Annotation], crop: CGRect?) {
        self.annotations = annotations
        self.crop = crop
    }
}

public struct EditHistory {
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []

    public init(snapshots: [EditSnapshot] = []) { undoStack = snapshots }
    public var snapshots: [EditSnapshot] { undoStack }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state before a change.
    public mutating func push(_ snapshot: EditSnapshot) {
        undoStack.append(snapshot)
        redoStack = []
    }

    /// Returns false, leaving `state` as it is, when there is nothing to undo.
    public mutating func undo(_ state: inout EditSnapshot) -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(state)
        state = previous
        return true
    }

    /// Returns false, leaving `state` as it is, when there is nothing to redo.
    public mutating func redo(_ state: inout EditSnapshot) -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(state)
        state = next
        return true
    }
}
