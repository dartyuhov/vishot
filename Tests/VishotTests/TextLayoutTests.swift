import XCTest
@testable import Vishot

final class TextLayoutTests: XCTestCase {
    func testNewlineMovesCaretDownAndBackToLineStart() {
        let origin = CGPoint(x: 30, y: 50)
        let first = AnnotationRenderer.caret(after: "", at: origin)
        let next = AnnotationRenderer.caret(after: "hello\n", at: origin)
        XCTAssertEqual(next.minX, first.minX)
        XCTAssertGreaterThan(next.minY, first.maxY)
        let bounds = AnnotationRenderer.textBounds("hello\nworld", at: origin)
        XCTAssertGreaterThan(bounds.height, AnnotationRenderer.textBounds("hello", at: origin).height)
    }
}
