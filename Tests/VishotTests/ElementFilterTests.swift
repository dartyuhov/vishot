import XCTest
@testable import Vishot

private final class FakeNode: ElementNode {
    let name: String
    let frame: CGRect?
    let subrole: String?
    private let kids: [FakeNode]

    init(_ name: String, _ frame: CGRect?, subrole: String? = nil, children: [FakeNode] = []) {
        self.name = name
        self.frame = frame
        self.subrole = subrole
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
        XCTAssertEqual(names(below: root), ["split-view", "canvas"])
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
        // n1 → n2 → … → n40, each the only child of the one before.
        var chain = FakeNode("n40", window)
        for depth in stride(from: 39, through: 1, by: -1) {
            chain = FakeNode("n\(depth)", window, children: [chain])
        }
        let root = FakeNode("window", window, children: [chain])
        XCTAssertEqual(names(below: root), ["n31"])
    }

    func testLeafLevelIsEmpty() {
        let leaf = FakeNode("image", CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(names(below: leaf), [])
    }
}
