import CoreGraphics

/// The parts of a UI element that filtering looks at. Implemented over Accessibility in
/// `ElementCatalog`, and by plain values in tests.
protocol ElementNode {
    /// CoreGraphics global space.
    var frame: CGRect? { get }
    var subrole: String? { get }
    var hasChildren: Bool { get }
    func children() -> [Self]
}

enum ElementFilter {
    static let minSide: CGFloat = 8
    /// Bounds the auto-descent, in case an app reports a cyclic or absurdly deep tree.
    static let maxDescent = 30
    /// Window buttons, and `AXEmptyGroup` nodes that exist only for screen readers.
    private static let droppedSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton", "AXEmptyGroup",
    ]

    /// A childless element this close to its parent's frame is a background view.
    private static let backgroundTolerance: CGFloat = 2

    /// The selectable elements one level below `root`. A level with a single element is replaced by
    /// that element's level, so wrapper groups (common in Electron and Chromium) are skipped.
    static func level<Node: ElementNode>(below root: Node, clippedTo window: CGRect) -> [Node] {
        var nodes = children(of: root, clippedTo: window)
        var steps = 0
        while nodes.count == 1, steps < maxDescent {
            // A single leaf stays selectable rather than leaving an empty level.
            let inner = children(of: nodes[0], clippedTo: window)
            guard !inner.isEmpty else { break }
            nodes = inner
            steps += 1
        }
        return nodes
    }

    private static func children<Node: ElementNode>(of parent: Node, clippedTo window: CGRect) -> [Node] {
        let parentFrame = parent.frame
        return parent.children().filter { keeps($0, parentFrame: parentFrame, clippedTo: window) }
    }

    private static func keeps<Node: ElementNode>(_ node: Node, parentFrame: CGRect?, clippedTo window: CGRect) -> Bool {
        if let subrole = node.subrole, droppedSubroles.contains(subrole) { return false }
        guard let frame = node.frame else { return false }
        let visible = frame.intersection(window)
        guard !visible.isNull, visible.width >= minSide, visible.height >= minSide else { return false }
        // `hasChildren` may cost an Accessibility call, so it is checked last.
        if let parentFrame, isClose(frame, parentFrame), !node.hasChildren { return false }
        return true
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= backgroundTolerance && abs(a.minY - b.minY) <= backgroundTolerance
            && abs(a.maxX - b.maxX) <= backgroundTolerance && abs(a.maxY - b.maxY) <= backgroundTolerance
    }
}
