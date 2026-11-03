import AppKit
import XCTest
@testable import Vishot

final class SkillInstallationViewTests: XCTestCase {
    func testOptionalSkillCommandIsVisibleSelectableAndCopiesWithoutRunningInstaller() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = SkillInstallationView(pasteboard: pasteboard)
        let fields = view.arrangedSubviews.compactMap { $0 as? NSTextField }
        let command = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "skill-install-command" })
        let button = try XCTUnwrap(view.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(command.stringValue, "npx skills add dartyuhov/vishot --skill vishot-capture")
        XCTAssertTrue(command.isSelectable)
        XCTAssertFalse(command.isEditable)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(fields.contains { $0.stringValue.contains("Optional") })
        XCTAssertTrue(fields.contains { $0.stringValue.contains("Node.js") && $0.stringValue.contains("network") })
        XCTAssertTrue(fields.contains { $0.stringValue.contains("Vishot only copies") })
        XCTAssertNil(pasteboard.string(forType: .string), "Rendering must not copy automatically")
        button.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "npx skills add dartyuhov/vishot --skill vishot-capture")
    }

    func testSeparateHostsCanPresentTheSameCommandWithoutSharedViewOwnership() throws {
        let setupHost = NSStackView()
        let settingsHost = NSStackView()
        let setupView = SkillInstallationView()
        let settingsView = SkillInstallationView()
        setupHost.addArrangedSubview(setupView)
        settingsHost.addArrangedSubview(settingsView)
        XCTAssertTrue(setupView.superview === setupHost)
        XCTAssertTrue(settingsView.superview === settingsHost)
        XCTAssertEqual(SkillInstallation.command, "npx skills add dartyuhov/vishot --skill vishot-capture")
    }
}
