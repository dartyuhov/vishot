import AppKit
import XCTest
@testable import Vishot

final class HintLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let size = CGSize(width: 28, height: 16)

    func testNestedElementsSharingACornerDoNotOverlap() {
        let items = (0..<12).map { index in
            HintLayout.Item(element: CGRect(x: 100, y: 100 + index * 10, width: 300, height: 400 - index * 10), size: size)
        }
        assertReadable(HintLayout.place(items, in: bounds))
    }

    func testNearbyElementsAndScreenEdgeClampingDoNotOverlap() {
        let items = (0..<20).map { index in
            HintLayout.Item(element: CGRect(x: 790 + index % 3, y: 550 + index % 4, width: 40, height: 60), size: size)
        }
        assertReadable(HintLayout.place(items, in: bounds))
    }

    func testUncontestedHintKeepsItsTopLeftPosition() {
        let item = HintLayout.Item(element: CGRect(x: 100, y: 100, width: 200, height: 200), size: size)
        let placement = HintLayout.place([item], in: bounds)[0]
        XCTAssertEqual(placement.frame, CGRect(x: 100, y: 284, width: 28, height: 16))
        XCTAssertTrue(placement.connector.isEmpty)
    }

    func testDisplacedHintsHaveConnectorsToTheirElements() {
        let item = HintLayout.Item(element: CGRect(x: 100, y: 100, width: 24, height: 24), size: size)
        let placements = HintLayout.place(Array(repeating: item, count: 6), in: bounds)
        assertReadable(placements)
        for placement in placements where !item.element.contains(placement.frame) {
            XCTAssertEqual(placement.connector.count, 2)
            if let endpoint = placement.connector.last {
                XCTAssertGreaterThanOrEqual(endpoint.x, item.element.minX)
                XCTAssertLessThanOrEqual(endpoint.x, item.element.maxX)
                XCTAssertGreaterThanOrEqual(endpoint.y, item.element.minY)
                XCTAssertLessThanOrEqual(endpoint.y, item.element.maxY)
            }
        }
    }

    func testDenseLayoutIsDeterministicAndKeepsEveryHint() {
        let items = (0..<300).map { index in
            HintLayout.Item(element: CGRect(x: 300 + index % 10, y: 250 + index % 15, width: 80, height: 60), size: size)
        }
        let placements = HintLayout.place(items, in: bounds)
        XCTAssertEqual(placements.count, items.count)
        XCTAssertEqual(placements, HintLayout.place(items, in: bounds))
        assertReadable(placements)
    }

    func testPanelKeepsSurvivingHintsStableWhileTypingAndDeleting() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = OverlayPanel(screen: screen, theme: ThemeCatalog.resolve(.pixel))
        defer { panel.close() }
        let rect = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 200, height: 200)
        let marks = ["aa", "sa", "as", "ss"].map { HintMark(rect: rect, code: $0, colorIndex: nil) }
        panel.showHints(marks, prefix: "")
        let root = try XCTUnwrap(panel.contentView?.layer)
        let before = hintFrames(in: root)
        XCTAssertEqual(before.count, 4)
        let frames = Array(before.values)
        for (index, frame) in frames.enumerated() {
            XCTAssertFalse(frames.prefix(index).contains { $0.intersects(frame) })
        }
        panel.showHints(marks, prefix: "a")
        XCTAssertEqual(hintFrames(in: root), before.filter { $0.key.hasPrefix("a") })
        panel.showHints(marks, prefix: "")
        XCTAssertEqual(hintFrames(in: root), before)
        panel.showHints([], prefix: "")
        XCTAssertTrue(hintFrames(in: root).isEmpty)
    }

    private func hintFrames(in root: CALayer) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        func visit(_ layer: CALayer) {
            guard !layer.isHidden else { return }
            if let text = layer as? CATextLayer, let string = text.string as? NSAttributedString,
               let background = layer.superlayer {
                result[string.string] = background.frame
            }
            for child in layer.sublayers ?? [] { visit(child) }
        }
        visit(root)
        return result
    }

    private func assertReadable(_ placements: [HintLayout.Placement], file: StaticString = #filePath, line: UInt = #line) {
        for (index, placement) in placements.enumerated() {
            XCTAssertTrue(bounds.contains(placement.frame), file: file, line: line)
            for other in placements.prefix(index) {
                if placement.frame.insetBy(dx: -1, dy: -1).intersects(other.frame) {
                    XCTFail("Hints overlap or lack spacing: \(placement.frame), \(other.frame)", file: file, line: line)
                    return
                }
            }
        }
    }
}
