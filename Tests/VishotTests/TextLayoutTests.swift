import XCTest
@testable import Vishot

final class TextLayoutTests: XCTestCase {
    func testNewlineMovesCaretDownAndBackToLineStart() {
        let origin = CGPoint(x: 30, y: 50)
        let style = ThemeCatalog.pixel.annotation
        let first = AnnotationRenderer.caret(after: "", at: origin, style: style)
        let next = AnnotationRenderer.caret(after: "hello\n", at: origin, style: style)
        XCTAssertEqual(next.minX, first.minX)
        XCTAssertGreaterThan(next.minY, first.maxY)
        let bounds = AnnotationRenderer.textBounds("hello\nworld", at: origin, style: style)
        XCTAssertGreaterThan(bounds.height, AnnotationRenderer.textBounds("hello", at: origin, style: style).height)
    }
}
