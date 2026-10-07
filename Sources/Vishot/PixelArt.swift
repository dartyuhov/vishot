import CoreGraphics

/// Annotations as pixel art, to match the landing page: shapes made of square cells on a grid anchored
/// at the image's top-left. Coordinates are in image space (points, y down).
enum PixelArt {
    /// One cell, in points. Silkscreen at 24 pt has pixels this size, so text lands on the same grid.
    static let cell: CGFloat = 3

    struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    /// The cell holding `point`.
    static func cell(at point: CGPoint) -> Cell {
        Cell(x: Int((point.x / cell).rounded(.down)), y: Int((point.y / cell).rounded(.down)))
    }

    /// The square `cell` covers, in points.
    static func rect(of cell: Cell) -> CGRect {
        CGRect(x: CGFloat(cell.x) * self.cell, y: CGFloat(cell.y) * self.cell, width: self.cell, height: self.cell)
    }

    /// `point` moved to the nearest grid line, so whatever starts there shares the cells' edges.
    static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / cell).rounded() * cell, y: (point.y / cell).rounded() * cell)
    }

    /// A line one cell thick from the cell of `from` to the cell of `to`, both included (Bresenham).
    /// Each cell shares an edge with the one before, as a diagonal step through a corner looks thin.
    static func line(from: CGPoint, to: CGPoint) -> [Cell] {
        let start = cell(at: from)
        let end = cell(at: to)
        let dx = abs(end.x - start.x)
        let dy = -abs(end.y - start.y)
        let stepX = start.x < end.x ? 1 : -1
        let stepY = start.y < end.y ? 1 : -1
        var (x, y, error) = (start.x, start.y, dx + dy)
        var cells = [Cell(x: x, y: y)]
        while x != end.x || y != end.y {
            let doubled = 2 * error
            let movesX = doubled >= dy
            let movesY = doubled <= dx
            if movesX { error += dy; x += stepX }
            if movesX && movesY { cells.append(Cell(x: x, y: y)) }
            if movesY { error += dx; y += stepY }
            cells.append(Cell(x: x, y: y))
        }
        return cells
    }

    /// The cells whose centers lie inside the triangle, plus the cell of its first corner, so even a
    /// sliver of a triangle keeps its tip.
    static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> [Cell] {
        let low = cell(at: CGPoint(x: min(a.x, b.x, c.x), y: min(a.y, b.y, c.y)))
        let high = cell(at: CGPoint(x: max(a.x, b.x, c.x), y: max(a.y, b.y, c.y)))
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        var cells = [cell(at: a)]
        for y in low.y...high.y {
            for x in low.x...high.x {
                let center = CGPoint(x: (CGFloat(x) + 0.5) * cell, y: (CGFloat(y) + 0.5) * cell)
                let sides = [side(a, b, center), side(b, c, center), side(c, a, center)]
                if sides.allSatisfy({ $0 >= 0 }) || sides.allSatisfy({ $0 <= 0 }) {
                    cells.append(Cell(x: x, y: y))
                }
            }
        }
        return cells
    }

    /// A one-cell ring around the cells `rect` touches, with the outer corner cells left out and the
    /// inner ones filled, like the logo's selection border. Too small for a ring, the cells are all filled.
    static func outline(_ rect: CGRect) -> [Cell] {
        let low = cell(at: CGPoint(x: rect.minX, y: rect.minY))
        let high = cell(at: CGPoint(x: max(rect.minX, rect.maxX - cell / 2), y: max(rect.minY, rect.maxY - cell / 2)))
        guard high.x - low.x >= 3, high.y - low.y >= 3 else {
            return (low.y...high.y).flatMap { y in (low.x...high.x).map { Cell(x: $0, y: y) } }
        }
        var cells: [Cell] = []
        for x in (low.x + 1)...(high.x - 1) {
            cells += [Cell(x: x, y: low.y), Cell(x: x, y: high.y)]
        }
        for y in (low.y + 1)...(high.y - 1) {
            cells += [Cell(x: low.x, y: y), Cell(x: high.x, y: y)]
        }
        cells += [
            Cell(x: low.x + 1, y: low.y + 1), Cell(x: high.x - 1, y: low.y + 1),
            Cell(x: low.x + 1, y: high.y - 1), Cell(x: high.x - 1, y: high.y - 1),
        ]
        return cells
    }
}
