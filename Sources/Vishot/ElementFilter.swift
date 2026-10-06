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

enum ElementFilter {
    static let minSide: CGFloat = 8
    /// Bounds the auto-descent and the hint walk, in case an app reports a cyclic or absurdly deep tree.
    static let maxDescent = 30
    /// A child covering this share of its level's root is flattened into its children: selecting it
    /// separately would capture almost the same image as the root.
    static let dominantShare: CGFloat = 0.8
    /// Hinted elements are at least this tall and wide, and cover at least `minHintShare` of the window.
    /// Smaller ones (icon buttons, emoji, timestamps, mentions) are rarely worth a screenshot alone.
    static let minHintSide: CGFloat = 24
    static let minHintShare: CGFloat = 0.01
    /// An element covering this share of its hinted ancestor shares that ancestor's label.
    static let duplicateShare: CGFloat = 0.85
    /// Keeps the tree walk short.
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

    /// The elements that get hint labels, at any depth below `root`, each before the elements inside it.
    /// The walk doesn't go below elements too small for a hint, since what is inside them is smaller still.
    static func hints<Node: ElementNode>(below root: Node, clippedTo window: CGRect) -> [Node] {
        let minArea = minHintShare * area(window)
        var hints: [Node] = []

        func walk(_ parent: Node, hintedArea: CGFloat, depth: Int) {
            guard depth < maxDescent else { return }
            for node in level(below: parent, clippedTo: window) {
                guard hints.count < maxHints else { return }
                let visible = (node.frame ?? .zero).intersection(window)
                guard !visible.isNull, min(visible.width, visible.height) >= minHintSide, area(visible) >= minArea else {
                    continue
                }
                let isDuplicate = area(visible) >= duplicateShare * hintedArea
                if !isDuplicate { hints.append(node) }
                walk(node, hintedArea: isDuplicate ? hintedArea : area(visible), depth: depth + 1)
            }
        }
        // The window itself is Window mode's target, so nothing filling it gets a label.
        walk(root, hintedArea: area(window), depth: 0)
        return hints
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
