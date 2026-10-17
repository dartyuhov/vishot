import Foundation

/// Pure placement in panel-local Cocoa coordinates. Exhaust outside positions before overlapping.
struct EditorHUDPlacement {
    enum Layout { case horizontal, vertical, compact }
    let layout: Layout
    let frame: CGRect

    static func choose(around selection: CGRect, in bounds: CGRect,
                       horizontal: CGSize, vertical: CGSize, compact: CGSize, hidden: Bool) -> Self {
        let margin: CGFloat = 12
        let available = bounds.insetBy(dx: margin, dy: margin)
        func clamped(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(max(value, lower), max(lower, upper))
        }
        func outside(_ size: CGSize, layout: Layout, sides: Bool) -> Self? {
            guard size.width <= available.width, size.height <= available.height else { return nil }
            let x = clamped(selection.midX - size.width / 2, available.minX, available.maxX - size.width)
            let y = clamped(selection.midY - size.height / 2, available.minY, available.maxY - size.height)
            let origins: [CGPoint]
            if sides {
                let right = CGPoint(x: selection.maxX + margin, y: y)
                let left = CGPoint(x: selection.minX - margin - size.width, y: y)
                origins = bounds.maxX - selection.maxX >= selection.minX - bounds.minX ? [right, left] : [left, right]
            } else {
                origins = [CGPoint(x: x, y: selection.minY - margin - size.height),
                           CGPoint(x: x, y: selection.maxY + margin)]
            }
            for origin in origins {
                let frame = CGRect(origin: origin, size: size)
                if available.contains(frame), !selection.intersects(frame) {
                    return Self(layout: layout, frame: frame)
                }
            }
            return nil
        }
        if hidden {
            if let placement = outside(compact, layout: .compact, sides: false)
                ?? outside(compact, layout: .compact, sides: true) { return placement }
        } else {
            if let placement = outside(horizontal, layout: .horizontal, sides: false)
                ?? outside(vertical, layout: .vertical, sides: true)
                ?? outside(vertical, layout: .vertical, sides: false)
                ?? outside(horizontal, layout: .horizontal, sides: true) { return placement }
        }
        let layout: Layout = hidden ? .compact : (horizontal.width <= available.width ? .horizontal : .vertical)
        let size = hidden ? compact : (layout == .horizontal ? horizontal : vertical)
        let origin = CGPoint(x: clamped(selection.midX - size.width / 2, available.minX, available.maxX - size.width),
                             y: clamped(max(selection.minY, bounds.minY) + 24, available.minY, available.maxY - size.height))
        return Self(layout: layout, frame: CGRect(origin: origin, size: size))
    }
}
