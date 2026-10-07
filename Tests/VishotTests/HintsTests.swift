import Carbon.HIToolbox
import XCTest
@testable import Vishot

final class HintsTests: XCTestCase {
    func testUsesSingleHomeRowLettersWhenTheyAreEnough() {
        XCTAssertEqual(Hints.make(count: 4), ["a", "s", "d", "f"])
    }

    func testUsesUniformTwoLetterLabelsWhenSingleLettersRunOut() {
        let hints = Hints.make(count: 30)
        XCTAssertEqual(hints.count, 30)
        XCTAssertEqual(Array(hints.prefix(3)), ["aa", "as", "ad"])
        XCTAssertEqual(Set(hints).count, 30)
        // Prefix-free, so a label is complete as soon as it is typed.
        XCTAssertTrue(hints.allSatisfy { $0.count == 2 })
    }

    func testMapsKeyCodesToLettersIndependentOfLayout() {
        XCTAssertEqual(Hints.letter(forKeyCode: kVK_ANSI_A), "a")
        XCTAssertEqual(Hints.letter(forKeyCode: kVK_ANSI_M), "m")
        XCTAssertNil(Hints.letter(forKeyCode: kVK_ANSI_1))
        XCTAssertNil(Hints.letter(forKeyCode: kVK_Escape))
    }
}
