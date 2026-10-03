import CoreGraphics

enum Direction {
    case left, right, up, down

    /// Unit vector in CoreGraphics space (y grows downward).
    var vector: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }
}

enum Navigator {
    /// Picks the nearest window in a direction. Windows that overlap the current one on the
    /// perpendicular axis (true neighbours in a tiled layout) win over diagonal ones.
    static func neighbor(of current: WindowInfo, in windows: [WindowInfo], toward direction: Direction) -> WindowInfo? {
        let v = direction.vector
        var best: (window: WindowInfo, rank: (Int, CGFloat))?

        for window in windows where window.id != current.id {
            let dx = window.anchor.x - current.anchor.x
            let dy = window.anchor.y - current.anchor.y
            let along = dx * v.dx + dy * v.dy
            guard along > 1 else { continue }
            let across = abs(dx * v.dy - dy * v.dx)

            let overlaps = direction.isHorizontal
                ? window.frame.minY < current.frame.maxY && current.frame.minY < window.frame.maxY
                : window.frame.minX < current.frame.maxX && current.frame.minX < window.frame.maxX
            let rank = overlaps ? (0, along) : (1, along + 2 * across)

            if best == nil || rank < best!.rank {
                best = (window, rank)
            }
        }
        return best?.window
    }
}
