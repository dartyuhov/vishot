import AppKit
import XCTest
@testable import Vishot

final class MicrophonePermissionViewTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    func testCancelledCardCanRejoinPendingPromptWithoutRevivingOldCallback() throws {
        var state = MicrophoneAuthorization.notDetermined
        var reply: ((Bool) -> Void)?
        var prompts = 0
        let permission = MicrophonePermission(readStatus: { state }, requestAccess: { prompts += 1; reply = $0 })
        let view = MicrophonePermissionView(permission: permission)
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        view.cancelPendingRequest()
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        XCTAssertEqual(prompts, 1)
        var updates = 0
        view.onLayoutChange = { updates += 1 }
        state = .authorized
        reply?(true)
        drain()
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(button.isHidden)
    }

    func testSetupCanSkipOrDenyMicrophoneAndStillTakeFirstScreenshot() throws {
        _ = NSApplication.shared
        for request in [false, true] {
            var state = MicrophoneAuthorization.notDetermined
            var reply: ((Bool) -> Void)?
            var prompts = 0
            let permission = MicrophonePermission(readStatus: { state }, requestAccess: { prompts += 1; reply = $0 })
            var complete = false
            let captured = expectation(description: "First screenshot")
            let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true }, readAccess: { (true, true) })
            let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: { captured.fulfill() }, microphonePermission: permission)
            let views = descendants(try XCTUnwrap(setup.window?.contentView))
            func click(_ title: String) throws {
                try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == title }).performClick(nil)
            }
            XCTAssertEqual(prompts, 0)
            if request {
                try click("Allow Microphone…")
                state = .denied
                reply?(false)
                drain()
            }
            try click("Continue")
            try click("Skip for now")
            setup.takeFirstScreenshot()
            wait(for: [captured], timeout: 2)
            XCTAssertTrue(complete)
            XCTAssertEqual(prompts, request ? 1 : 0)
            XCTAssertFalse(setup.window?.isVisible == true)
        }
    }

    func testLeavingSetupAbandonsPendingRequestAndLateGrantCannotReopenOrAdvance() throws {
        _ = NSApplication.shared
        for close in [false, true] {
            var state = MicrophoneAuthorization.notDetermined
            var reply: ((Bool) -> Void)?
            let permission = MicrophonePermission(readStatus: { state }, requestAccess: { reply = $0 })
            let flow = SetupFlow(isComplete: { false }, rememberCompletion: {}, readAccess: { (true, true) })
            let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: { XCTFail("No capture") }, microphonePermission: permission)
            let views = descendants(try XCTUnwrap(setup.window?.contentView))
            try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Allow Microphone…" }).performClick(nil)
            if close { setup.window?.performClose(nil) }
            else { try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Continue" }).performClick(nil) }
            let card = try XCTUnwrap(views.compactMap { $0 as? MicrophonePermissionView }.first)
            card.onLayoutChange = { XCTFail("Abandoned UI must not resume") }
            state = .authorized
            reply?(true)
            drain()
            XCTAssertEqual(flow.step, close ? .permissions : .commandLine)
            XCTAssertFalse(setup.window?.isVisible == true)
        }
    }

    func testSettingsReturnRefreshesLiveStatusAndClosingCancelsPendingUI() throws {
        _ = NSApplication.shared
        var state = MicrophoneAuthorization.notDetermined
        var reply: ((Bool) -> Void)?
        let permission = MicrophonePermission(readStatus: { state }, requestAccess: { reply = $0 })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(url: root.appendingPathComponent("config.toml")) { _ in NSObject() }
        store.start(watching: false)
        let settings = SettingsWindow(store: store, microphonePermission: permission)
        let card = try XCTUnwrap(descendants(try XCTUnwrap(settings.window?.contentView)).compactMap { $0 as? MicrophonePermissionView }.first)
        let button = try XCTUnwrap(descendants(card).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        settings.window?.performClose(nil)
        card.onLayoutChange = { XCTFail("Closed Settings must not resume UI") }
        state = .authorized
        reply?(true)
        drain()
        card.onLayoutChange = nil
        settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(button.isHidden)
        state = .denied
        settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.title, "Open System Settings…")
    }

    func testExplicitRequestAndLiveRecoveryStates() throws {
        _ = NSApplication.shared
        var state = MicrophoneAuthorization.notDetermined
        var reply: ((Bool) -> Void)?
        var prompts = 0
        var opened: URL?
        let permission = MicrophonePermission(readStatus: { state }, requestAccess: { prompts += 1; reply = $0 })
        let view = MicrophonePermissionView(permission: permission, openPage: { opened = $0; return false })
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first)
        func text() -> String {
            descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue).joined(separator: "\n")
        }
        XCTAssertTrue(text().contains("Not requested"))
        XCTAssertTrue(text().contains("Optional"))
        XCTAssertEqual(prompts, 0)
        button.performClick(nil)
        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(text().contains("Waiting"))
        XCTAssertNil(opened)
        state = .denied
        reply?(false)
        drain()
        XCTAssertTrue(text().contains("Denied"))
        XCTAssertEqual(button.title, "Open System Settings…")
        button.performClick(nil)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(opened?.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertTrue(text().contains("Couldn’t open System Settings"))
        state = .restricted
        view.refresh()
        XCTAssertTrue(text().contains("Restricted"))
        XCTAssertTrue(text().contains("administrator"))
        button.performClick(nil)
        XCTAssertEqual(prompts, 1)
        state = .authorized
        view.refresh()
        XCTAssertTrue(text().contains("Enabled"))
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(text().contains("Couldn’t open"))
        state = .denied
        view.refresh()
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(text().contains("Denied"))
    }

    private func drain() {
        let drained = expectation(description: "Main callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
