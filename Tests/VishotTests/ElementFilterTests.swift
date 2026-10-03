import XCTest
@testable import Vishot

private final class FakeNode: ElementNode {
    let name: String
    let frame: CGRect?
    let role: String?
    let subrole: String?
    let title: String
    private let kids: [FakeNode]

    init(
        _ name: String, _ frame: CGRect?, role: String? = nil, subrole: String? = nil, title: String = "",
        children: [FakeNode] = []
    ) {
        self.name = name
        self.frame = frame
        self.role = role
        self.subrole = subrole
        self.title = title
        kids = children
    }

    var hasChildren: Bool { !kids.isEmpty }
    func children() -> [FakeNode] { kids }
}

final class ElementFilterTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func names(below root: FakeNode) -> [String] {
        ElementFilter.level(below: root, clippedTo: window).map(\.name)
    }

    func testDropsChildrenWithoutFrame() {
        let root = FakeNode("window", window, children: [
            FakeNode("sidebar", CGRect(x: 0, y: 0, width: 200, height: 800)),
            FakeNode("ghost", nil),
            FakeNode("content", CGRect(x: 200, y: 0, width: 800, height: 800)),
        ])
        XCTAssertEqual(names(below: root), ["sidebar", "content"])
    }

    func testDropsChildrenUnder8PointsOnEitherSideOnceClippedToWindow() {
        let root = FakeNode("window", window, children: [
            FakeNode("sidebar", CGRect(x: 0, y: 0, width: 200, height: 800)),
            FakeNode("thin", CGRect(x: 200, y: 0, width: 7, height: 800)),
            FakeNode("short", CGRect(x: 200, y: 0, width: 800, height: 7)),
            // 400 pt wide, but only 5 pt of it is inside the window.
            FakeNode("offscreen", CGRect(x: 995, y: 0, width: 400, height: 800)),
            FakeNode("outside", CGRect(x: 1200, y: 0, width: 400, height: 800)),
            FakeNode("just-big-enough", CGRect(x: 200, y: 10, width: 8, height: 8)),
        ])
        XCTAssertEqual(names(below: root), ["sidebar", "just-big-enough"])
    }

    func testDropsWindowButtonsAndEmptyGroups() {
        let button = CGRect(x: 10, y: 10, width: 14, height: 14)
        let root = FakeNode("window", window, children: [
            FakeNode("close", button, subrole: "AXCloseButton"),
            FakeNode("minimize", button, subrole: "AXMinimizeButton"),
            FakeNode("fullscreen", button, subrole: "AXFullScreenButton"),
            FakeNode("zoom", button, subrole: "AXZoomButton"),
            FakeNode("reader-only", CGRect(x: 0, y: 0, width: 500, height: 500), subrole: "AXEmptyGroup"),
            FakeNode("toolbar", CGRect(x: 0, y: 0, width: 1000, height: 50)),
            FakeNode("search", CGRect(x: 800, y: 10, width: 150, height: 30), subrole: "AXSearchField"),
        ])
        XCTAssertEqual(names(below: root), ["toolbar", "search"])
    }

    func testDropsChildlessBackgroundViewsCoveringTheParent() {
        let leaf = FakeNode("leaf", CGRect(x: 0, y: 0, width: 10, height: 10))
        let root = FakeNode("window", window, children: [
            FakeNode("background", CGRect(x: 1, y: 2, width: 998, height: 797)),
            // Same size, but it has content, so it is a real container.
            FakeNode("split-view", CGRect(x: 0, y: 0, width: 1000, height: 800), children: [leaf]),
            // Childless, but 3 pt smaller than the parent, so it is kept.
            FakeNode("canvas", CGRect(x: 3, y: 0, width: 997, height: 800)),
        ])
        // The split view is kept, then flattened into its content because it fills the window.
        XCTAssertEqual(names(below: root), ["leaf", "canvas"])
    }

    func testDescendsThroughSingleWrappers() {
        let root = FakeNode("window", window, children: [
            FakeNode("close", CGRect(x: 10, y: 10, width: 14, height: 14), subrole: "AXCloseButton"),
            FakeNode("browser-root", window, children: [
                FakeNode("web-wrapper", CGRect(x: 0, y: 50, width: 1000, height: 750), children: [
                    FakeNode("nav", CGRect(x: 0, y: 50, width: 200, height: 750)),
                    FakeNode("article", CGRect(x: 200, y: 50, width: 800, height: 750)),
                ]),
            ]),
        ])
        XCTAssertEqual(names(below: root), ["nav", "article"])
    }

    func testStopsAtASingleLeaf() {
        let root = FakeNode("window", window, children: [
            FakeNode("wrapper", CGRect(x: 0, y: 50, width: 1000, height: 750), children: [
                FakeNode("image", CGRect(x: 100, y: 100, width: 300, height: 200)),
            ]),
        ])
        XCTAssertEqual(names(below: root), ["image"])
    }

    func testStopsAtASingleChildWhoseChildrenAreAllFilteredOut() {
        let root = FakeNode("window", window, children: [
            FakeNode("panel", CGRect(x: 0, y: 50, width: 1000, height: 750), children: [
                FakeNode("hairline", CGRect(x: 0, y: 50, width: 1000, height: 1)),
            ]),
        ])
        XCTAssertEqual(names(below: root), ["panel"])
    }

    func testDescendsAtMost30Steps() {
        // n1 → n2 → … → n40, each the only child of the one before, and a little smaller.
        func frame(_ depth: Int) -> CGRect { window.insetBy(dx: CGFloat(depth) * 5, dy: CGFloat(depth) * 5) }
        var chain = FakeNode("n40", frame(40))
        for depth in stride(from: 39, through: 1, by: -1) {
            chain = FakeNode("n\(depth)", frame(depth), children: [chain])
        }
        let root = FakeNode("window", window, children: [chain])
        XCTAssertEqual(names(below: root), ["n31"])
    }

    func testHoistsChildrenOfTinyOrFramelessContainers() {
        // Slack's message list is a 1×1 screen-reader-only node whose items have real frames.
        let root = FakeNode("window", window, children: [
            FakeNode("header", CGRect(x: 0, y: 0, width: 1000, height: 60)),
            FakeNode("sr-only-list", CGRect(x: 0, y: 700, width: 1, height: 1), children: [
                FakeNode("message-1", CGRect(x: 0, y: 60, width: 1000, height: 100)),
                FakeNode("message-2", CGRect(x: 0, y: 160, width: 1000, height: 100)),
            ]),
            FakeNode("frameless", nil, children: [
                FakeNode("composer", CGRect(x: 0, y: 700, width: 1000, height: 100)),
            ]),
            FakeNode("sr-only-text", CGRect(x: 0, y: 700, width: 1, height: 1), children: [
                FakeNode("sr-only-leaf", CGRect(x: 0, y: 700, width: 1, height: 1)),
            ]),
        ])
        XCTAssertEqual(names(below: root), ["header", "message-1", "message-2", "composer"])
    }

    func testDropsEmptyUntitledGroups() {
        let root = FakeNode("window", window, children: [
            FakeNode("empty-banner", CGRect(x: 600, y: 0, width: 400, height: 800), role: "AXGroup"),
            FakeNode("titled-group", CGRect(x: 0, y: 0, width: 300, height: 300), role: "AXGroup", title: "Inbox"),
            FakeNode("image", CGRect(x: 0, y: 300, width: 300, height: 300), role: "AXImage"),
            FakeNode("pane", CGRect(x: 300, y: 0, width: 300, height: 800), role: "AXGroup", children: [
                FakeNode("text", CGRect(x: 300, y: 0, width: 100, height: 20)),
            ]),
        ])
        XCTAssertEqual(names(below: root), ["titled-group", "image", "pane"])
    }

    func testFlattensAChildCoveringMostOfTheRoot() {
        let root = FakeNode("window", window, children: [
            FakeNode("toolbar", CGRect(x: 0, y: 0, width: 1000, height: 50)),
            // 94% of the window: replaced by its children, in place.
            FakeNode("content", CGRect(x: 0, y: 50, width: 1000, height: 750), children: [
                FakeNode("sidebar", CGRect(x: 0, y: 50, width: 200, height: 750)),
                // 75% of the window: kept as a region.
                FakeNode("main", CGRect(x: 200, y: 50, width: 800, height: 750), children: [
                    FakeNode("article", CGRect(x: 200, y: 50, width: 800, height: 400)),
                    FakeNode("comments", CGRect(x: 200, y: 450, width: 800, height: 350)),
                ]),
            ]),
            FakeNode("status", CGRect(x: 0, y: 780, width: 1000, height: 20)),
        ])
        XCTAssertEqual(names(below: root), ["toolbar", "sidebar", "main", "status"])
    }

    private var page: FakeNode {
        FakeNode("window", window, children: [
            FakeNode("toolbar", CGRect(x: 0, y: 0, width: 1000, height: 50)),
            FakeNode("content", CGRect(x: 0, y: 50, width: 1000, height: 750), children: [
                FakeNode("sidebar", CGRect(x: 0, y: 50, width: 200, height: 750)),
                FakeNode("main", CGRect(x: 200, y: 50, width: 800, height: 750), children: [
                    FakeNode("article", CGRect(x: 200, y: 50, width: 800, height: 400)),
                    FakeNode("comments", CGRect(x: 200, y: 450, width: 800, height: 350), children: [
                        FakeNode("comment-1", CGRect(x: 220, y: 460, width: 760, height: 100)),
                        FakeNode("comment-2", CGRect(x: 220, y: 580, width: 760, height: 100)),
                    ]),
                ]),
            ]),
        ])
    }

    private func pathNames(to point: CGPoint) -> [String] {
        ElementFilter.path(to: point, below: page) { ElementFilter.level(below: $0, clippedTo: self.window) }
            .map { $0.nodes[$0.selected].name }
    }

    func testPathReachesTheDeepestElementUnderAPoint() {
        XCTAssertEqual(pathNames(to: CGPoint(x: 500, y: 600)), ["main", "comments", "comment-2"])
    }

    func testPathStopsAtTheDeepestContainerWhenThePointIsInAGap() {
        XCTAssertEqual(pathNames(to: CGPoint(x: 500, y: 570)), ["main", "comments"])
    }

    func testPathIsEmptyWhenNothingIsUnderThePoint() {
        let root = FakeNode("window", window, children: [
            FakeNode("left", CGRect(x: 0, y: 0, width: 400, height: 800)),
            FakeNode("right", CGRect(x: 600, y: 0, width: 400, height: 800)),
        ])
        let path = ElementFilter.path(to: CGPoint(x: 500, y: 400), below: root) {
            ElementFilter.level(below: $0, clippedTo: self.window)
        }
        XCTAssertTrue(path.isEmpty)
    }

    private func hintNames(maxDepth: Int) -> [String] {
        ElementFilter.hintPaths(below: page, maxDepth: maxDepth) { ElementFilter.level(below: $0, clippedTo: self.window) }
            .map { path in path.last.map { $0.nodes[$0.selected].name } ?? "" }
    }

    func testHintsSkipContainersCoveringMuchOfTheRoot() {
        // main is 75% and article 40% of the window: reachable with `v` and `o` instead.
        XCTAssertEqual(hintNames(maxDepth: 3), ["toolbar", "sidebar", "comments", "comment-1", "comment-2"])
    }

    func testHintsStopAtMaxDepth() {
        XCTAssertEqual(hintNames(maxDepth: 2), ["toolbar", "sidebar", "comments"])
    }

    func testHintPathsLeadToTheirElement() {
        let paths = ElementFilter.hintPaths(below: page, maxDepth: 3) { ElementFilter.level(below: $0, clippedTo: self.window) }
        let comment2 = paths.first { $0.last.map { $0.nodes[$0.selected].name } == "comment-2" }
        XCTAssertEqual(comment2?.map { $0.nodes[$0.selected].name }, ["main", "comments", "comment-2"])
        XCTAssertEqual(comment2?.map(\.root.name), ["window", "main", "comments"])
    }

    func testALoneChildFillingTheRootIsNotALevel() {
        // Slack day dividers: a group whose only child has the same frame and nothing selectable inside.
        let divider = CGRect(x: 0, y: 300, width: 1000, height: 50)
        let root = FakeNode("divider", divider, children: [
            FakeNode("inner", divider, children: [
                FakeNode("hairline", CGRect(x: 0, y: 325, width: 1000, height: 1)),
            ]),
        ])
        XCTAssertEqual(names(below: root), [])
    }

    func testLeafLevelIsEmpty() {
        let leaf = FakeNode("image", CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(names(below: leaf), [])
    }
}
