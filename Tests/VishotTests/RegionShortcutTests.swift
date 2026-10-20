import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Vishot

final class RegionShortcutTests: XCTestCase {
    func testYFinishesDrawnRegionAndRequestsCopyLikeEnter() throws {
        for code in [kVK_ANSI_Y, kVK_Return] {
            let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let display = CaptureTarget(kind: .display(1), frame: frame,
                                        anchor: CGPoint(x: 400, y: 300), label: "Test display")
            let selector = RegionSelector(displays: [display], start: CGPoint(x: 100, y: 100))
            let anchor = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
            _ = selector.handle(anchor)
            selector.mouseMoved(to: CGPoint(x: 200, y: 180))
            let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: code == kVK_ANSI_Y ? "y" : "\r",
                charactersIgnoringModifiers: code == kVK_ANSI_Y ? "y" : "\r",
                isARepeat: false, keyCode: UInt16(code)))
            guard case .copy = selector.handle(copy) else {
                return XCTFail("Both y and Enter must request copy, not editing")
            }
            XCTAssertEqual(selector.target?.frame, CGRect(x: 100, y: 100, width: 100, height: 80))
        }
    }
}
