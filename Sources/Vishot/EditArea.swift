import CoreGraphics

/// The export boundary within one frozen image, in image-space points.
struct EditArea {
    static func displaySelection(for target: CGRect, displays: [CGRect]) -> (index: Int, crop: CGRect)? {
        var best: (index: Int, crop: CGRect)?
        var largest: CGFloat = 0
        for (index, display) in displays.enumerated() {
            let overlap = target.intersection(display)
            guard !overlap.isNull, overlap.width * overlap.height > largest else { continue }
            largest = overlap.width * overlap.height
            best = (index, overlap.offsetBy(dx: -display.minX, dy: -display.minY))
        }
        return best
    }

    enum Handle: Int, CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft, top, right, bottom, left

        var isLeft: Bool { self == .topLeft || self == .bottomLeft || self == .left }
        var isRight: Bool { self == .topRight || self == .bottomRight || self == .right }
        var isTop: Bool { self == .topLeft || self == .topRight || self == .top }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }

        func cycled(by step: Int) -> Handle {
            Handle(rawValue: (rawValue + step + 4) % 4)!
        }

        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: isLeft ? rect.minX : isRight ? rect.maxX : rect.midX,
                    y: isTop ? rect.minY : isBottom ? rect.maxY : rect.midY)
        }
    }

    private(set) var rect: CGRect
    let bounds: CGRect

    init(rect: CGRect, bounds: CGRect) {
        self.rect = rect
        self.bounds = bounds
    }

    mutating func resize(_ handle: Handle, to point: CGPoint) {
        var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        if handle.isLeft { x0 = min(max(point.x, bounds.minX), x1 - 1) }
        if handle.isRight { x1 = max(min(point.x, bounds.maxX), x0 + 1) }
        if handle.isTop { y0 = min(max(point.y, bounds.minY), y1 - 1) }
        if handle.isBottom { y1 = max(min(point.y, bounds.maxY), y0 + 1) }
        rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 8) -> Handle? {
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        for corner in Handle.allCases.prefix(4) {
            let p = corner.point(in: rect)
            if abs(point.x - p.x) <= tolerance && abs(point.y - p.y) <= tolerance { return corner }
        }
        if abs(point.y - rect.minY) <= tolerance { return .top }
        if abs(point.x - rect.maxX) <= tolerance { return .right }
        if abs(point.y - rect.maxY) <= tolerance { return .bottom }
        if abs(point.x - rect.minX) <= tolerance { return .left }
        return nil
    }
}
