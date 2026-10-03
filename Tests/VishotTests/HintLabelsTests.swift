import Carbon.HIToolbox
import XCTest
@testable import Vishot

final class HintLabelsTests: XCTestCase {
    func testUsesSingleHomeRowLettersWhenTheyAreEnough() {
        XCTAssertEqual(HintLabels.make(count: 4), ["a", "s", "d", "f"])
    }

    func testUsesUniformTwoLetterLabelsWhenSingleLettersRunOut() {
        let labels = HintLabels.make(count: 30)
        XCTAssertEqual(labels.count, 30)
        XCTAssertEqual(Array(labels.prefix(3)), ["aa", "as", "ad"])
        XCTAssertEqual(Set(labels).count, 30)
        // Prefix-free, so a label is complete as soon as it is typed.
        XCTAssertTrue(labels.allSatisfy { $0.count == 2 })
    }

    func testMapsKeyCodesToLettersIndependentOfLayout() {
        XCTAssertEqual(HintLabels.letter(forKeyCode: kVK_ANSI_A), "a")
        XCTAssertEqual(HintLabels.letter(forKeyCode: kVK_ANSI_M), "m")
        XCTAssertNil(HintLabels.letter(forKeyCode: kVK_ANSI_1))
        XCTAssertNil(HintLabels.letter(forKeyCode: kVK_Escape))
    }
}
