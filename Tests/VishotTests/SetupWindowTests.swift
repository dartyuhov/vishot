import AppKit
import XCTest
@testable import Vishot

final class SetupWindowTests: XCTestCase {
    func testCaptureShortcutCompletesOnlyGuideAndStartsAfterUIUpdates() {
        _ = NSApplication.shared
        var complete = false
        var captures = 0
        let captured = expectation(description: "Picker starts on the next main-queue turn")
        let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true },
                             readAccess: { (true, false) })
        var setup: SetupWindow!
        setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: {
            XCTAssertTrue(complete)
            XCTAssertFalse(setup.window?.isVisible == true, "Setup must be dismissed before the picker takes focus")
            captures += 1
            captured.fulfill()
        })
        setup.takeFirstScreenshot()
        XCTAssertFalse(complete)
        XCTAssertEqual(captures, 0, "The checklist cannot be skipped with the capture shortcut")
        flow.continueToGuide(withoutAccessibility: true)
        setup.refresh()
        setup.takeFirstScreenshot()
        XCTAssertTrue(complete)
        XCTAssertEqual(captures, 0, "Do not open the picker while setup focus/layout is still unwinding")
        wait(for: [captured], timeout: 1)
        XCTAssertEqual(captures, 1)
    }

    func testStepsKeepHeaderAndFooterInSameWindow() throws {
        _ = NSApplication.shared
        let flow = SetupFlow(isComplete: { false }, rememberCompletion: {}, readAccess: { (true, true) })
        let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: {})
        let window = try XCTUnwrap(setup.window)
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let views = descendants(content)
        let logo = try XCTUnwrap(views.compactMap { $0 as? NSImageView }.first)
        let heading = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Welcome to Vishot" })
        let next = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Continue" })
        content.layoutSubtreeIfNeeded()
        let logoFrame = logo.convert(logo.bounds, to: content)
        let headingFrame = heading.convert(heading.bounds, to: content)
        let footerFrame = next.convert(next.bounds, to: content)
        let windowFrame = window.frame
        XCTAssertLessThan(footerFrame.maxY, 65, "Continue stays at the bottom of the window")

        flow.continueToGuide()
        setup.refresh()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(setup.window === window)
        XCTAssertEqual(window.frame, windowFrame)
        XCTAssertEqual(logo.convert(logo.bounds, to: content), logoFrame)
        XCTAssertEqual(heading.convert(heading.bounds, to: content).origin, headingFrame.origin)
        XCTAssertTrue(next.isHidden)
        let first = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Take a screenshot" })
        XCTAssertFalse(first.isHidden)
        XCTAssertEqual(first.bezelColor, NSColor.controlColor)
        XCTAssertEqual(first.convert(first.bounds, to: content).midY, footerFrame.midY, accuracy: 1)
    }
}
