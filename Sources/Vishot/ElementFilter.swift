import CoreGraphics

/// The parts of a UI element that filtering looks at. Implemented over Accessibility in
/// `ElementCatalog`, and by plain values in tests.
protocol ElementNode {
    /// CoreGraphics global space.
    var frame: CGRect? { get }
    var role: String? { get }
    var subrole: String? { get }
    var title: String { get }
    var hasChildren: Bool { get }
    func children() -> [Self]
}

/// One level of the element tree: the elements below `root`, and which one is selected.
struct ElementLevel<Node> {
    let root: Node
    var nodes: [Node]
    var selected = 0
}

enum ElementFilter {
    static let minSide: CGFloat = 8
    /// Bounds the auto-descent, in case an app reports a cyclic or absurdly deep tree.
    static let maxDescent = 30
    /// A child covering this share of its level's root is flattened into its children: selecting it
    /// separately would capture almost the same image as the root.
    static let dominantShare: CGFloat = 0.8
    /// Containers this big relative to the hint root get no hint label.
    static let bigShare: CGFloat = 0.4
    /// Keeps hint labels readable, and the tree walk short.
    static let maxHints = 300
    /// How many nested tiny or frameless containers can pass their children up.
    private static let maxHoists = 3
    /// Window buttons, and `AXEmptyGroup` nodes that exist only for screen readers.
    private static let droppedSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton", "AXEmptyGroup",
    ]

    /// A childless element this close to its parent's frame is a background view.
    private static let backgroundTolerance: CGFloat = 2

    /// The selectable elements one level below `root`. An element that is alone in the level, or covers
    /// most of `root`, is replaced by its own children, so wrapper groups (common in Electron and
    /// Chromium) are skipped and each level down is a visible step.
    static func level<Node: ElementNode>(below root: Node, clippedTo window: CGRect) -> [Node] {
        let rootArea = area((root.frame ?? window).intersection(window))
        var nodes = children(of: root, clippedTo: window)
        var steps = 0
        var index = 0
        while index < nodes.count, steps < maxDescent {
            let node = nodes[index]
            let isWrapper = nodes.count == 1 || area((node.frame ?? .zero).intersection(window)) >= dominantShare * rootArea
            // A leaf stays selectable rather than leaving a hole in the level.
            if isWrapper, case let inner = children(of: node, clippedTo: window), !inner.isEmpty {
                nodes.replaceSubrange(index...index, with: inner)
                steps += 1
            } else {
                index += 1
            }
        }
        // A lone element with the root's own frame would capture the same image as the root.
        if nodes.count == 1, let frame = nodes[0].frame, let rootFrame = root.frame, isClose(frame, rootFrame) {
            return []
        }
        return nodes
    }

    /// The levels from `root` down to the deepest element under `point`, each selecting the smallest
    /// element that contains it. Empty when nothing below `root` is under the point.
    /// `level` loads the elements below a node, so callers can cache it.
    static func path<Node: ElementNode>(to point: CGPoint, below root: Node, level: (Node) -> [Node]) -> [ElementLevel<Node>] {
        var path: [ElementLevel<Node>] = []
        var parent = root
        while path.count < maxDescent {
            let nodes = level(parent)
            let hits = nodes.indices.filter { nodes[$0].frame?.contains(point) == true }
            guard let hit = hits.min(by: { area(nodes[$0].frame!) < area(nodes[$1].frame!) }) else { break }
            path.append(ElementLevel(root: parent, nodes: nodes, selected: hit))
            parent = nodes[hit]
        }
        return path
    }

    /// Paths to the elements that get hint labels: everything up to `maxDepth` levels below `root`,
    /// except containers covering `bigShare` of it or more, which `v` and `o` already reach.
    static func hintPaths<Node: ElementNode>(below root: Node, maxDepth: Int, level: (Node) -> [Node]) -> [[ElementLevel<Node>]] {
        let rootArea = area(root.frame ?? .zero)
        var paths: [[ElementLevel<Node>]] = []

        func walk(_ parent: Node, prefix: [ElementLevel<Node>]) {
            guard prefix.count < maxDepth, paths.count < maxHints else { return }
            let nodes = level(parent)
            for index in nodes.indices {
                let path = prefix + [ElementLevel(root: parent, nodes: nodes, selected: index)]
                if area(nodes[index].frame ?? .zero) < bigShare * rootArea {
                    paths.append(path)
                }
                walk(nodes[index], prefix: path)
            }
        }
        walk(root, prefix: [])
        return Array(paths.prefix(maxHints))
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private static func children<Node: ElementNode>(of parent: Node, clippedTo window: CGRect) -> [Node] {
        children(of: parent, parentFrame: parent.frame, clippedTo: window, hoists: 0)
    }

    /// `parentFrame` is the frame of the nearest real ancestor, as hoisted containers have no usable frame.
    private static func children<Node: ElementNode>(
        of parent: Node, parentFrame: CGRect?, clippedTo window: CGRect, hoists: Int
    ) -> [Node] {
        parent.children().flatMap { child -> [Node] in
            switch verdict(for: child, parentFrame: parentFrame, clippedTo: window) {
            case .keep: [child]
            case .drop: []
            case .hoist:
                hoists < maxHoists
                    ? children(of: child, parentFrame: parentFrame, clippedTo: window, hoists: hoists + 1)
                    : []
            }
        }
    }

    private enum Verdict { case keep, drop, hoist }

    private static func verdict<Node: ElementNode>(for node: Node, parentFrame: CGRect?, clippedTo window: CGRect) -> Verdict {
        if let subrole = node.subrole, droppedSubroles.contains(subrole) { return .drop }
        // `hasChildren` may cost an Accessibility call, so it is checked last.
        guard let frame = node.frame else { return node.hasChildren ? .hoist : .drop }
        let visible = frame.intersection(window)
        guard !visible.isNull, visible.width >= minSide, visible.height >= minSide else {
            // Screen-reader-only containers (Slack's message list is 1×1) can hold visible children.
            return node.hasChildren ? .hoist : .drop
        }
        if let parentFrame, isClose(frame, parentFrame), !node.hasChildren { return .drop }
        // An untitled group with nothing inside is spacing or decoration.
        if node.role == "AXGroup", node.title.isEmpty, !node.hasChildren { return .drop }
        return .keep
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= backgroundTolerance && abs(a.minY - b.minY) <= backgroundTolerance
            && abs(a.maxX - b.maxX) <= backgroundTolerance && abs(a.maxY - b.maxY) <= backgroundTolerance
    }
}
