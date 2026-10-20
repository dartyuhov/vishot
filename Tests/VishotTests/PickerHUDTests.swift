import AppKit
import XCTest
@testable import Vishot

final class PickerHUDTests: XCTestCase {
    func testUnavailableEntryRetainsItsReasonAndDimsTheWholeControl() {
        let reason = "Element selection needs Accessibility. Enable it in Vishot Settings."
        let key = PickerHUD.elementsKey(accessibilityAvailable: false)
        XCTAssertFalse(key.isEnabled)
        XCTAssertEqual(key.unavailableReason, reason)
        let disabled = HUD.makeEntry(key, scale: 2)
        let enabledKey = PickerHUD.elementsKey(accessibilityAvailable: true)
        XCTAssertTrue(enabledKey.isEnabled)
        XCTAssertNil(enabledKey.unavailableReason)
        XCTAssertEqual(enabledKey.keys, ["f"])
        XCTAssertEqual(enabledKey.action, "elements")
        let enabled = HUD.makeEntry(enabledKey, scale: 2)
        XCTAssertLessThan(disabled.layer.opacity, enabled.layer.opacity)
        XCTAssertEqual(disabled.layer.bounds.size, enabled.layer.bounds.size)
        XCTAssertTrue(HUDKey("hjkl", action: "move").isEnabled)
    }

    func testHoverFollowsVisibleEntryThroughStatusResizingClippingAndAvailabilityChanges() throws {
        for scale: CGFloat in [1, 2] {
            for width: CGFloat in [320, 800, 1440] {
                let hud = PickerHUD(scale: scale)
                let reason = "Element selection needs Accessibility. Enable it in Vishot Settings."
                let keys = [HUDKey("hjkl", action: "move"),
                            PickerHUD.elementsKey(accessibilityAvailable: false),
                            HUDKey("esc", action: "cancel")]
                let size = CGSize(width: width, height: 900)
                hud.show(name: "WINDOW", keys: keys, status: "", size: size, visible: true)
                let entry = try XCTUnwrap(text("elements", in: hud.root)?.superlayer)
                let point = hud.root.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry)
                    .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                let row = try XCTUnwrap(entry.superlayer)
                let visible = row.bounds.contains(row.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry))
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil)
                hud.show(name: "WINDOW", keys: keys, status: reason, size: size, visible: true)
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil, "status must not move the hovered entry")
                let entryRect = row.convert(entry.bounds, from: entry)
                let clipped = entryRect.intersection(row.bounds)
                if !clipped.isEmpty {
                    let visiblePoint = row.convert(CGPoint(x: clipped.minX + 0.5, y: clipped.midY), to: hud.root)
                        .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                    XCTAssertEqual(hud.unavailableReason(at: visiblePoint), reason)
                }
                if entryRect.maxX > row.bounds.maxX {
                    let clippedPoint = row.convert(CGPoint(x: row.bounds.maxX + 1, y: entryRect.midY), to: hud.root)
                        .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                    XCTAssertNil(hud.unavailableReason(at: clippedPoint))
                }
                let move = try XCTUnwrap(text("move", in: hud.root)?.superlayer)
                let movePoint = hud.root.convert(CGPoint(x: move.bounds.midX, y: move.bounds.midY), from: move)
                    .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                XCTAssertNil(hud.unavailableReason(at: movePoint))
                hud.show(name: "WINDOW", keys: keys, status: "", size: size, visible: false)
                XCTAssertNil(hud.unavailableReason(at: point))
                hud.show(name: "WINDOW", keys: [PickerHUD.elementsKey(accessibilityAvailable: true)], status: "", size: size, visible: true)
                XCTAssertNil(hud.unavailableReason(at: point))
                hud.show(name: "WINDOW", keys: keys, status: "", size: size, visible: true)
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil)
                hud.show(name: "SCREEN", keys: [HUDKey("hjkl", action: "move")], status: "", size: size, visible: true)
                XCTAssertNil(hud.unavailableReason(at: point))
            }
        }
    }

    private func text(_ value: String, in layer: CALayer) -> CATextLayer? {
        if let text = layer as? CATextLayer, text.string as? String == value { return text }
        for child in layer.sublayers ?? [] {
            if let found = text(value, in: child) { return found }
        }
        return nil
    }
}
