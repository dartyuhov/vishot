import Foundation

/// Pure geometry in panel-local Cocoa coordinates.
enum HintLayout {
    struct Item: Equatable {
        let element: CGRect
        let size: CGSize
    }

    struct Placement: Equatable {
        let frame: CGRect
        let connector: [CGPoint]
    }

    static func place(_ items: [Item], in bounds: CGRect) -> [Placement] {
        let gap: CGFloat = 2
        var placements: [Placement] = []
        for item in items {
            let size = CGSize(width: min(item.size.width, bounds.width), height: min(item.size.height, bounds.height))
            let origin = CGPoint(
                x: min(max(item.element.minX, bounds.minX), bounds.maxX - size.width),
                y: min(max(item.element.maxY - size.height, bounds.minY), bounds.maxY - size.height)
            )
            let preferred = CGRect(origin: origin, size: size)
            let occupied = placements.map { $0.frame.insetBy(dx: -gap, dy: -gap) }
            var best: CGRect?
            var bestDistance = CGFloat.infinity

            func consider(_ candidate: CGRect) {
                let dx = candidate.minX - origin.x
                let dy = candidate.minY - origin.y
                let distance = dx * dx + dy * dy
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
            if !occupied.contains(where: { $0.intersects(preferred) }) { consider(preferred) }
            if best == nil {
                // Every free horizontal band starts or ends at an occupied edge. Search those
                // bands, jumping past blocked x intervals rather than walking screen pixels.
                let rows = [origin.y, item.element.minY, bounds.minY, bounds.maxY - size.height]
                    + occupied.flatMap { [$0.minY - size.height, $0.maxY] }
                let orderedRows = Set(rows).sorted {
                    let a = abs($0 - origin.y), b = abs($1 - origin.y)
                    return a == b ? $0 > $1 : a < b
                }
                let byX = occupied.sorted { $0.minX < $1.minX }
                for y in orderedRows where y >= bounds.minY && y + size.height <= bounds.maxY {
                    if (y - origin.y) * (y - origin.y) >= bestDistance { continue }
                    let blockers = byX.filter { $0.minY < y + size.height && $0.maxY > y }
                    var left = bounds.minX
                    for blocker in blockers {
                        let right = min(blocker.minX, bounds.maxX)
                        if right - left >= size.width {
                            let x = min(max(origin.x, left), right - size.width)
                            consider(CGRect(x: x, y: y, width: size.width, height: size.height))
                        }
                        left = max(left, blocker.maxX)
                    }
                    if bounds.maxX - left >= size.width {
                        let x = min(max(origin.x, left), bounds.maxX - size.width)
                        consider(CGRect(x: x, y: y, width: size.width, height: size.height))
                    }
                }
            }
            // Only a display too small to hold all hints can exhaust the available space.
            let frame = best ?? preferred
            let visibleElement = item.element.intersection(bounds)
            var connector: [CGPoint] = []
            if !visibleElement.contains(frame) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                var target = CGPoint(x: min(max(center.x, visibleElement.minX), visibleElement.maxX),
                                     y: min(max(center.y, visibleElement.minY), visibleElement.maxY))
                if frame.contains(target) {
                    let corners = [
                        CGPoint(x: visibleElement.minX, y: visibleElement.minY),
                        CGPoint(x: visibleElement.maxX, y: visibleElement.minY),
                        CGPoint(x: visibleElement.minX, y: visibleElement.maxY),
                        CGPoint(x: visibleElement.maxX, y: visibleElement.maxY),
                    ]
                    target = corners.max {
                        hypot($0.x - center.x, $0.y - center.y) < hypot($1.x - center.x, $1.y - center.y)
                    }!
                }
                let start = CGPoint(x: min(max(target.x, frame.minX), frame.maxX),
                                    y: min(max(target.y, frame.minY), frame.maxY))
                if start != target { connector = [start, target] }
            }
            placements.append(Placement(frame: frame, connector: connector))
        }
        return placements
    }
}
