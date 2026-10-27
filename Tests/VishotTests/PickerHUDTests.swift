import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Vishot

final class PickerHUDTests: XCTestCase {
    func testEveryPreparedPickerStateRendersItsApplicableGuidanceIncludingCountdownAndPreparing() throws {
        for visual in VisualStyle.allCases {
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            let hud = PickerHUD(scale: 2, style: theme.hud)
            hud.prepare(theme: theme)
            for type in PickerHUD.CaptureType.allCases {
                for picker in PickerHUD.Picker.allCases {
                    for region in PickerHUD.RegionState.allCases {
                        for countdown in [false, true] {
                            let content = PickerHUD.Content(captureType: type, picker: picker, regionState: region, isCountingDown: countdown)
                            for width: CGFloat in [320, 800] {
                                hud.show(content, status: countdown ? "Preparing…" : "", size: CGSize(width: width, height: 900), visible: true)
                                XCTAssertNotNil(text(content.captureName, in: hud.root))
                                for key in content.actions + content.navigation + content.choices.map(\.key) {
                                    let layer = try XCTUnwrap(text(key.action, in: hud.root))
                                    XCTAssertTrue(hud.root.bounds.contains(hud.root.convert(layer.bounds, from: layer)), "\(key.action)")
                                }
                                if countdown {
                                    XCTAssertNil(text("Record", in: hud.root))
                                    XCTAssertNil(text("Window", in: hud.root))
                                    XCTAssertNotNil(text("Preparing…", in: hud.root))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testRegionGuidanceTracksRealDrawingWithoutAdvertisingCaptureUntilFinished() throws {
        let frame = CGRect(x: -800, y: 0, width: 800, height: 600)
        let display = CaptureTarget(kind: .display(1), frame: frame,
            anchor: CGPoint(x: -400, y: 300), label: "Display")
        let region = RegionSelector(displays: [display], start: display.anchor)
        XCTAssertEqual(region.hudState, .empty)
        region.mouseDown(at: CGPoint(x: -500, y: 100))
        region.mouseDragged(to: CGPoint(x: -200, y: 300))
        XCTAssertNotNil(region.target, "The outline is visible while drawing")
        XCTAssertEqual(region.hudState, .drawing)
        XCTAssertFalse(PickerHUD.Content(picker: .region, regionState: region.hudState).actions.contains { $0.action == "Copy" })
        _ = region.mouseUp(at: CGPoint(x: -200, y: 300))
        XCTAssertEqual(region.hudState, .ready)
        let target = try XCTUnwrap(region.target)
        var content = PickerHUD.Content(picker: .region, regionState: region.hudState)
        _ = content.handleCaptureTypeKey(kVK_ANSI_R)
        XCTAssertEqual(region.target?.frame, target.frame)
        XCTAssertEqual(region.status(captureType: .video), "v or drag to redraw · click it to record · 0 $ g G M jump")
        XCTAssertEqual(region.status(captureType: .screenshot), "v or drag to redraw · click it to copy · 0 $ g G M jump")
    }

    func testPhysicalCaptureTypeKeysPreservePickerContextAndYieldToHintsAndHistoryOff() {
        var content = PickerHUD.Content(picker: .region, regionState: .drawing)
        XCTAssertEqual(content.handleCaptureTypeKey(kVK_ANSI_R), .handled)
        XCTAssertEqual(content.captureType, .video)
        XCTAssertEqual(content.picker, .region)
        XCTAssertEqual(content.regionState, .drawing)
        XCTAssertEqual(content.handleCaptureTypeKey(kVK_ANSI_S), .handled)
        XCTAssertEqual(content.captureType, .screenshot)
        content.historyAvailable = false
        XCTAssertEqual(content.handleCaptureTypeKey(kVK_ANSI_R), .unavailable)
        XCTAssertEqual(content.captureType, .screenshot)
        content.picker = .hint
        for key in [kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_F] {
            XCTAssertEqual(content.handleCaptureTypeKey(key), .unhandled)
        }
        XCTAssertEqual(content.captureType, .screenshot)
        XCTAssertEqual(PickerHUD.Content().captureType, .screenshot)
    }

    func testCaptureTypeIsProminentWithOnlyTheAlternativeSwitchAndContextualActions() {
        let screenshot = PickerHUD.Content(captureType: .screenshot, picker: .window)
        XCTAssertEqual(screenshot.captureName, "Screenshot")
        XCTAssertEqual(screenshot.typeSwitch, HUDKey("r", action: "Video"))
        XCTAssertEqual(screenshot.actions, [HUDKey("↵", action: "Copy"), HUDKey("⇧↵", "e", action: "Edit"), HUDKey("esc", action: "Cancel")])
        let video = PickerHUD.Content(captureType: .video, picker: .window)
        XCTAssertEqual(video.captureName, "Video")
        XCTAssertEqual(video.typeSwitch, HUDKey("s", action: "Screenshot"))
        XCTAssertEqual(video.actions, [HUDKey("↵", action: "Record"), HUDKey("esc", action: "Cancel")])
    }

    func testPickerChoicesRemainStableWhileHintsPermissionsAndRegionActionsAreContextual() {
        for picker in PickerHUD.Picker.allCases {
            var content = PickerHUD.Content(picker: picker)
            XCTAssertEqual(content.choices.map(\.picker), [.window, .element, .screen, .region])
            XCTAssertEqual(content.choices.filter(\.isActive).map(\.picker), [picker == .hint ? .element : picker])
            XCTAssertTrue(content.choices.allSatisfy { $0.key.keys.isEmpty }, "Choices must not invent direct shortcuts")
            if picker == .hint {
                XCTAssertNil(content.typeSwitch)
                XCTAssertEqual(content.navigation, [HUDKey(action: "Type a hint"), HUDKey("⌫", action: "Undo")])
                XCTAssertEqual(content.actions, [HUDKey("esc", action: "Back")])
            }
            content.accessibilityAvailable = false
            XCTAssertEqual(content.choices[1].key.unavailableReason, PickerHUD.elementUnavailableReason)
            content.historyAvailable = false
            if picker != .hint { XCTAssertEqual(content.typeSwitch?.unavailableReason, PickerHUD.historyUnavailableReason) }
        }
        var region = PickerHUD.Content(picker: .region)
        region.regionState = .empty
        XCTAssertEqual(region.actions, [HUDKey("esc", action: "Back"), HUDKey("q", action: "Cancel")])
        XCTAssertTrue(region.navigation.contains(HUDKey("v", action: "Start region")))
        region.regionState = .drawing
        XCTAssertEqual(region.actions, [HUDKey("esc", action: "Cancel region"), HUDKey("q", action: "Cancel")])
        XCTAssertFalse(region.navigation.contains { $0.keys.contains("tab") })
        XCTAssertTrue(region.navigation.contains(HUDKey("v", action: "Finish region")))
        region.regionState = .ready
        XCTAssertEqual(region.actions.first, HUDKey("↵", action: "Copy"))
        region.captureType = .video
        XCTAssertEqual(region.actions.first, HUDKey("↵", action: "Record"))
        XCTAssertFalse(region.actions.contains { $0.action == "Edit" })
        region.isCountingDown = true
        XCTAssertEqual(region.actions, [HUDKey("esc", action: "Cancel")])
        XCTAssertNil(region.typeSwitch)
        XCTAssertTrue(region.navigation.isEmpty)
        XCTAssertTrue(region.choices.isEmpty)
    }

    func testUnavailableEntryRetainsItsReasonAndDimsTheWholeControl() {
        let reason = "Element selection needs Accessibility. Enable it in Vishot Settings."
        let key = PickerHUD.elementsKey(accessibilityAvailable: false)
        XCTAssertFalse(key.isEnabled)
        XCTAssertEqual(key.unavailableReason, reason)
        let disabled = HUD.makeEntry(key, scale: 2, style: ThemeCatalog.pixel.hud)
        let enabledKey = PickerHUD.elementsKey(accessibilityAvailable: true)
        XCTAssertTrue(enabledKey.isEnabled)
        XCTAssertNil(enabledKey.unavailableReason)
        XCTAssertEqual(enabledKey.keys, ["f"])
        XCTAssertEqual(enabledKey.action, "elements")
        let enabled = HUD.makeEntry(enabledKey, scale: 2, style: ThemeCatalog.pixel.hud)
        XCTAssertLessThan(disabled.layer.opacity, enabled.layer.opacity)
        XCTAssertEqual(disabled.layer.bounds.size, enabled.layer.bounds.size)
        XCTAssertTrue(HUDKey("hjkl", action: "move").isEnabled)
    }

    func testThreeAreasWrapWithoutClippingAndPermissionFeedbackKeepsControlsStill() throws {
        for visual in VisualStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for scale: CGFloat in [1, 2] {
                    let theme = ThemeCatalog.resolve(style: visual, colorScheme: scheme)
                    let hud = PickerHUD(scale: scale, style: theme.hud)
                    hud.prepare(theme: theme)
                    let content = PickerHUD.Content(accessibilityAvailable: false)
                    for width: CGFloat in [320, 800, 1440] {
                        let size = CGSize(width: width, height: 900)
                        hud.show(content, status: "", size: size, visible: true)
                        for label in ["Screenshot", "Video", "Window", "Element", "Screen", "Region", "Copy", "Edit", "Cancel"] {
                            let layer = try XCTUnwrap(text(label, in: hud.root))
                            let rect = hud.root.convert(layer.bounds, from: layer)
                            XCTAssertTrue(hud.root.bounds.contains(rect), "\(label) clipped at \(width)")
                            XCTAssertFalse(layer.isHidden)
                        }
                        let element = try XCTUnwrap(text("Element", in: hud.root))
                        let point = element.convert(CGPoint(x: element.bounds.midX, y: element.bounds.midY), to: hud.root)
                            .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                        XCTAssertEqual(hud.unavailableReason(at: point), PickerHUD.elementUnavailableReason)
                        XCTAssertTrue(hud.contains(point))
                        XCTAssertFalse(hud.contains(CGPoint(x: -1, y: -1)))
                        let before = element.convert(element.bounds, to: hud.root)
                        hud.show(content, status: PickerHUD.elementUnavailableReason, size: size, visible: true)
                        XCTAssertEqual(element.convert(element.bounds, to: hud.root), before)
                        XCTAssertEqual(hud.unavailableReason(at: point), PickerHUD.elementUnavailableReason)
                        XCTAssertLessThanOrEqual(hud.root.frame.maxX, size.width)
                        XCTAssertGreaterThanOrEqual(hud.root.frame.minX, 0)
                    }
                }
            }
        }
    }

    func testHoverFollowsVisibleEntryThroughStatusResizingClippingAndAvailabilityChanges() throws {
        for scale: CGFloat in [1, 2] {
            for width: CGFloat in [320, 800, 1440] {
                let hud = PickerHUD(scale: scale)
                let reason = "Element selection needs Accessibility. Enable it in Vishot Settings."
                hud.prepare(theme: ThemeCatalog.pixel)
                var content = PickerHUD.Content(accessibilityAvailable: false)
                let size = CGSize(width: width, height: 900)
                hud.show(content, status: "", size: size, visible: true)
                let entry = try XCTUnwrap(text("Element", in: hud.root)?.superlayer)
                let point = hud.root.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry)
                    .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                let row = try XCTUnwrap(entry.superlayer)
                let visible = row.bounds.contains(row.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry))
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil)
                hud.show(content, status: reason, size: size, visible: true)
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
                let move = try XCTUnwrap(text("Move / arrows", in: hud.root)?.superlayer)
                let movePoint = hud.root.convert(CGPoint(x: move.bounds.midX, y: move.bounds.midY), from: move)
                    .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                XCTAssertNil(hud.unavailableReason(at: movePoint))
                hud.show(content, status: "", size: size, visible: false)
                XCTAssertNil(hud.unavailableReason(at: point))
                content.accessibilityAvailable = true
                hud.show(content, status: "", size: size, visible: true)
                XCTAssertNil(hud.unavailableReason(at: point))
                content.accessibilityAvailable = false
                hud.show(content, status: "", size: size, visible: true)
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil)
                content.isCountingDown = true
                hud.show(content, status: "", size: size, visible: true)
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
