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
    /// Picks the index of the nearest target in a direction. Targets that overlap the current one on
    /// the perpendicular axis (true neighbours in a tiled layout) win over diagonal ones.
    static func neighbor(of currentIndex: Int, in targets: [CaptureTarget], toward direction: Direction) -> Int? {
        let current = targets[currentIndex]
        let v = direction.vector
        var best: (index: Int, rank: (Int, CGFloat))?

        for (index, target) in targets.enumerated() where index != currentIndex {
            let dx = target.anchor.x - current.anchor.x
            let dy = target.anchor.y - current.anchor.y
            let along = dx * v.dx + dy * v.dy
            guard along > 1 else { continue }
            let across = abs(dx * v.dy - dy * v.dx)

            let overlaps = direction.isHorizontal
                ? target.frame.minY < current.frame.maxY && current.frame.minY < target.frame.maxY
                : target.frame.minX < current.frame.maxX && current.frame.minX < target.frame.maxX
            let rank = overlaps ? (0, along) : (1, along + 2 * across)

            if best == nil || rank < best!.rank {
                best = (index, rank)
            }
        }
        return best?.index
    }
}
