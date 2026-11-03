import AppKit
import XCTest
@testable import Vishot

final class SetupWindowTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func button(_ title: String, in setup: SetupWindow) throws -> NSButton {
        let content = try XCTUnwrap(setup.window?.contentView)
        return try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func fixture(at root: URL) throws -> CLIInstallation {
        let installation = CLIInstallation(bundleURL: root.appendingPathComponent("Custom Apps/Vishot Beta.app"),
                                           homeURL: root.appendingPathComponent("User Home"), environment: [:])
        try FileManager.default.createDirectory(at: installation.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: installation.executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.executableURL.path)
        return installation
    }

    func testCLIInstallConflictAndFailureAllAllowFirstScreenshot() throws {
        _ = NSApplication.shared
        for scenario in ["install", "conflict", "failure"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let installation = try fixture(at: root)
            if scenario == "conflict" {
                try FileManager.default.createDirectory(at: installation.directoryURL, withIntermediateDirectories: true)
                try Data("keep command".utf8).write(to: installation.linkURL)
            } else if scenario == "failure" {
                try FileManager.default.createDirectory(at: installation.homeURL, withIntermediateDirectories: true)
                try Data("keep file".utf8).write(to: installation.homeURL.appendingPathComponent(".local"))
            }
            var complete = false
            var captures = 0
            let captured = expectation(description: "First screenshot after \(scenario)")
            let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true }, readAccess: { (true, true) })
            var setup: SetupWindow!
            setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: {
                XCTAssertTrue(complete)
                XCTAssertFalse(setup.window?.isVisible == true)
                captures += 1
                captured.fulfill()
            }, cliInstallation: installation)
            try button("Continue", in: setup).performClick(nil)
            let content = try XCTUnwrap(setup.window?.contentView)
            let shared = try XCTUnwrap(descendants(content).compactMap { $0 as? CLIInstallationView }.first)
            XCTAssertFalse(shared.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(try button("Copy PATH Command", in: setup).isEnabled)
            let install = try button("Install CLI", in: setup)
            if scenario != "conflict" { install.performClick(nil) }
            let feedback = descendants(shared).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
            switch scenario {
            case "install":
                XCTAssertTrue(feedback.contains(installation.executableURL.path))
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installation.linkURL.path), installation.executableURL.path)
            case "conflict":
                XCTAssertTrue(feedback.contains("conflict"))
                XCTAssertEqual(try String(contentsOf: installation.linkURL), "keep command")
            default:
                XCTAssertTrue(feedback.contains("Couldn’t install"))
                XCTAssertEqual(try String(contentsOf: installation.homeURL.appendingPathComponent(".local")), "keep file")
            }
            XCTAssertFalse(complete)
            XCTAssertEqual(captures, 0)
            try button("Continue to guide", in: setup).performClick(nil)
            XCTAssertTrue(flow.isShowingGuide)
            setup.takeFirstScreenshot()
            XCTAssertEqual(captures, 0, "Capture waits for focus/layout handoff")
            wait(for: [captured], timeout: 2)
            XCTAssertEqual(captures, 1)
        }
    }

    func testSkipCanInstallLaterInSettingsWithoutResettingCompletion() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try fixture(at: root)
        var completions = 0
        let flow = SetupFlow(isComplete: { completions > 0 }, rememberCompletion: { completions += 1 }, readAccess: { (true, true) })
        let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: {}, cliInstallation: installation)
        try button("Continue", in: setup).performClick(nil)
        try button("Skip for now", in: setup).performClick(nil)
        try button("Done", in: setup).performClick(nil)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(installation.status(), .notInstalled)
        let store = SettingsStore(url: root.appendingPathComponent("config.toml")) { _ in NSObject() }
        store.start(watching: false)
        let settings = SettingsWindow(store: store, cliInstallation: installation)
        let content = try XCTUnwrap(settings.window?.contentView)
        let install = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Install CLI" })
        install.performClick(nil)
        XCTAssertEqual(installation.status(), .installed)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(flow.needsSetup)
    }

    func testBackNavigationAndPermissionRevocationKeepOptionalStepFromBypassingChecklist() throws {
        _ = NSApplication.shared
        var screen = false
        var accessibility = false
        var complete = false
        let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true }, readAccess: { (screen, accessibility) })
        let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: { XCTFail("Access must gate capture") })
        XCTAssertFalse(try button("Continue without Accessibility", in: setup).isEnabled)
        screen = true
        setup.refresh()
        try button("Continue without Accessibility", in: setup).performClick(nil)
        try button("Skip for now", in: setup).performClick(nil)
        try button("Back", in: setup).performClick(nil)
        XCTAssertEqual(flow.step, .commandLine)
        try button("Back", in: setup).performClick(nil)
        XCTAssertEqual(flow.step, .permissions)
        accessibility = true
        setup.refresh()
        try button("Continue", in: setup).performClick(nil)
        accessibility = false
        // Stale UI action must recheck permissions, not implicitly waive Accessibility.
        try button("Continue to guide", in: setup).performClick(nil)
        XCTAssertEqual(flow.step, .permissions)
        try button("Continue without Accessibility", in: setup).performClick(nil)
        screen = false
        setup.refresh()
        XCTAssertEqual(flow.step, .permissions)
        XCTAssertFalse(try button("Continue without Accessibility", in: setup).isEnabled)
        setup.takeFirstScreenshot()
        XCTAssertFalse(complete)
    }

    func testSkipOptionalCLIReachesGuideAndFinishesWithoutInstalling() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var complete = false
        let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true }, readAccess: { (true, false) })
        let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: { XCTFail("Done must not capture") },
                                cliInstallation: CLIInstallation(bundleURL: root.appendingPathComponent("Vishot.app"), homeURL: root))
        let window = try XCTUnwrap(setup.window)
        let initialFrame = window.frame
        try button("Continue without Accessibility", in: setup).performClick(nil)
        XCTAssertEqual(flow.step, .commandLine)
        XCTAssertFalse(complete)
        setup.takeFirstScreenshot()
        XCTAssertFalse(complete, "The capture shortcut cannot bypass the optional step")
        XCTAssertFalse(try button("Skip for now", in: setup).isHidden)
        try button("Skip for now", in: setup).performClick(nil)
        XCTAssertTrue(flow.isShowingGuide)
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertFalse(try button("Take a screenshot", in: setup).isHidden)
        try button("Done", in: setup).performClick(nil)
        XCTAssertTrue(complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

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
        try? button("Continue without Accessibility", in: setup).performClick(nil)
        XCTAssertEqual(flow.step, .commandLine)
        setup.takeFirstScreenshot()
        XCTAssertFalse(complete)
        XCTAssertEqual(captures, 0)
        try? button("Skip for now", in: setup).performClick(nil)
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

        next.performClick(nil)
        XCTAssertEqual(flow.step, .commandLine)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(setup.window === window)
        XCTAssertEqual(window.frame, windowFrame)
        XCTAssertEqual(logo.convert(logo.bounds, to: content), logoFrame)
        XCTAssertEqual(heading.convert(heading.bounds, to: content).origin, headingFrame.origin)
        let skip = try button("Skip for now", in: setup)
        XCTAssertEqual(skip.convert(skip.bounds, to: content).midY, footerFrame.midY, accuracy: 1)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 200, "Long PATH guidance stays in the scrolling body")
        skip.performClick(nil)
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
