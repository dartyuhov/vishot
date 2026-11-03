import AppKit
import XCTest
@testable import Vishot

final class AgentInstallationHostTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func verifySkill(in content: NSView, pasteboard: NSPasteboard) throws {
        content.layoutSubtreeIfNeeded()
        let skill = try XCTUnwrap(descendants(content).compactMap { $0 as? SkillInstallationView }.first)
        XCTAssertFalse(skill.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(skill.bounds.width, 400)
        let command = try XCTUnwrap(descendants(skill).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "skill-install-command"
        })
        XCTAssertEqual(command.stringValue, "npx skills add dartyuhov/vishot --skill vishot-capture")
        XCTAssertTrue(command.isSelectable)
        XCTAssertFalse(command.isEditable)
        let copy = try button("Copy Skill Install Command", in: skill)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertFalse(copy.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged", "Presentation must not copy or install automatically")
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), command.stringValue)
        let labels = descendants(skill).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Vishot only copies") })
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Node.js") && $0.stringValue.contains("network") })
        let rect = command.convert(command.alignmentRect(forFrame: command.bounds), to: skill)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        XCTAssertLessThanOrEqual(rect.maxX, skill.bounds.maxX + 1)
    }

    func testBothHostsOfferCopyableSkillRegardlessOfCLIInstallationState() throws {
        _ = NSApplication.shared
        let files = FileManager.default
        for state in ["skipped", "installed", "conflict", "failure", "unavailable"] {
            let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? files.removeItem(at: root) }
            let installation = CLIInstallation(bundleURL: root.appendingPathComponent("Apps/Vishot.app"),
                                               homeURL: root.appendingPathComponent("Home"), environment: [:])
            try files.createDirectory(at: installation.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if state != "unavailable" {
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: installation.executableURL)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.executableURL.path)
            }
            switch state {
            case "installed": XCTAssertEqual(installation.install(), .installed)
            case "conflict":
                try files.createDirectory(at: installation.directoryURL, withIntermediateDirectories: true)
                try Data("keep tool".utf8).write(to: installation.linkURL)
            case "failure":
                try files.createDirectory(at: installation.homeURL, withIntermediateDirectories: true)
                try Data("keep file".utf8).write(to: installation.homeURL.appendingPathComponent(".local"))
            default: break
            }
            let setupBoard = NSPasteboard.withUniqueName()
            let settingsBoard = NSPasteboard.withUniqueName()
            defer { setupBoard.releaseGlobally(); settingsBoard.releaseGlobally() }
            setupBoard.setString("unchanged", forType: .string)
            settingsBoard.setString("unchanged", forType: .string)
            var complete = false
            let flow = SetupFlow(isComplete: { complete }, rememberCompletion: { complete = true }, readAccess: { (true, false) })
            let setup = SetupWindow(flow: flow, shortcut: { "⇧⌘S" }, capture: { XCTFail("Copy/skip/Done must not capture") },
                                    cliInstallation: installation, skillPasteboard: setupBoard)
            let setupContent = try XCTUnwrap(setup.window?.contentView)
            let initialSkill = try XCTUnwrap(descendants(setupContent).compactMap { $0 as? SkillInstallationView }.first)
            XCTAssertTrue(initialSkill.isHiddenOrHasHiddenAncestor, "Skill belongs in the optional step")
            try button("Continue without Accessibility", in: setupContent).performClick(nil)
            if state == "failure" { try button("Install CLI", in: setupContent).performClick(nil) }
            let beforeCopy = installation.status()
            try verifySkill(in: setupContent, pasteboard: setupBoard)
            XCTAssertEqual(installation.status(), beforeCopy, "Copying a skill command cannot install the CLI")
            XCTAssertEqual(flow.step, .commandLine)
            XCTAssertFalse(complete)
            try button("Skip for now", in: setupContent).performClick(nil)
            XCTAssertTrue(flow.isShowingGuide)
            XCTAssertTrue(initialSkill.isHiddenOrHasHiddenAncestor)
            try button("Done", in: setupContent).performClick(nil)
            XCTAssertTrue(complete)

            let store = SettingsStore(url: root.appendingPathComponent("config.toml")) { _ in NSObject() }
            store.start(watching: false)
            let settings = SettingsWindow(store: store, cliInstallation: installation, skillPasteboard: settingsBoard)
            let settingsContent = try XCTUnwrap(settings.window?.contentView)
            if state == "failure" { try button("Install CLI", in: settingsContent).performClick(nil) }
            try verifySkill(in: settingsContent, pasteboard: settingsBoard)
            let settingsSkill = try XCTUnwrap(descendants(settingsContent).compactMap { $0 as? SkillInstallationView }.first)
            XCTAssertFalse(settingsSkill === initialSkill, "Each window owns its own control")
            XCTAssertEqual(installation.status(), beforeCopy)
            XCTAssertTrue(complete)
            if state == "conflict" { XCTAssertEqual(try String(contentsOf: installation.linkURL), "keep tool") }
            if state == "failure" { XCTAssertEqual(try String(contentsOf: installation.homeURL.appendingPathComponent(".local")), "keep file") }
        }
    }
}
