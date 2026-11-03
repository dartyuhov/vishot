import AppKit
import XCTest
@testable import Vishot

final class CLISettingsTests: XCTestCase {
    func testActualBundledCLIInstallAndInPlaceUpgradeKeepExecutableLink() throws {
        let products = Bundle(for: CLISettingsTests.self).bundleURL.deletingLastPathComponent()
        let helper = bundle.appendingPathComponent("Contents/Helpers/vishot")
        try fm.removeItem(at: helper)
        try fm.copyItem(at: products.appendingPathComponent("VishotCLI"), to: helper)
        func writeVersion(_ version: String) throws {
            let metadata = ["CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        func runVersion(_ link: URL) throws -> String? {
            let process = Process()
            process.executableURL = link
            process.arguments = ["--version"]
            process.environment = ["PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
        }
        try writeVersion("1.2.3")
        let installation = CLIInstallation(bundleURL: bundle, homeURL: home)
        XCTAssertEqual(installation.install(), .installed)
        let inode = try fm.attributesOfItem(atPath: installation.linkURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(try runVersion(installation.linkURL), "1.2.3")
        // Replace the whole bundle, as both distribution paths do on upgrade.
        try fm.removeItem(at: bundle)
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: products.appendingPathComponent("VishotCLI"), to: helper)
        try writeVersion("1.2.4")
        XCTAssertEqual(installation.install(), .installed)
        XCTAssertEqual(try runVersion(installation.linkURL), "1.2.4")
        XCTAssertEqual(try fm.attributesOfItem(atPath: installation.linkURL.path)[.systemFileNumber] as? NSNumber, inode)
    }

    private let fm = FileManager.default
    private var root: URL!
    private var bundle: URL!
    private var home: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        bundle = root.appendingPathComponent("Custom Apps/Vishot Beta.app")
        home = root.appendingPathComponent("User Home")
        let helper = bundle.appendingPathComponent("Contents/Helpers/vishot")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func controls(environment: [String: String] = [:]) -> CLIInstallationView {
        CLIInstallationView(installation: CLIInstallation(bundleURL: bundle, homeURL: home, environment: environment))
    }

    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func text(in view: NSView) -> String {
        descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
    }

    func testSettingsInstallationIsOptionalAndLinksActualBundleInPlace() throws {
        let installer = CLIInstallation(bundleURL: bundle, homeURL: home, environment: [:])
        let store = SettingsStore(url: root.appendingPathComponent("config.toml")) { _ in NSObject() }
        store.start(watching: false)
        let original = store.active
        let settings = SettingsWindow(store: store, cliInstallation: installer)
        let content = try XCTUnwrap(settings.window?.contentView)
        let install = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Install CLI" })
        let link = home.appendingPathComponent(".local/bin/vishot")
        XCTAssertFalse(fm.fileExists(atPath: link.path), "Opening Settings must not install anything")
        install.performClick(nil)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), bundle.appendingPathComponent("Contents/Helpers/vishot").path)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Installed") })
        XCTAssertEqual(store.active, original)
        // An in-place app update is immediately visible through the installed link.
        try Data("updated helper".utf8).write(to: bundle.appendingPathComponent("Contents/Helpers/vishot"))
        XCTAssertEqual(try String(contentsOf: link), "updated helper")
    }

    func testReopeningSettingsRecognizesLinkAndPreservesItAcrossRepeatedInstallation() throws {
        let view = controls()
        try button("Install CLI", in: view).performClick(nil)
        let installer = CLIInstallation(bundleURL: bundle, homeURL: home)
        let before = try fm.attributesOfItem(atPath: installer.linkURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(installer.install(), .installed)
        let reopened = controls()
        XCTAssertFalse(try button("CLI Installed", in: reopened).isEnabled)
        XCTAssertEqual(try fm.attributesOfItem(atPath: installer.linkURL.path)[.systemFileNumber] as? NSNumber, before)
        XCTAssertTrue(text(in: reopened).contains(bundle.path))
    }

    func testConflictingFilesDirectoriesAndUnrelatedIncludingBrokenLinksArePreserved() throws {
        let installer = CLIInstallation(bundleURL: bundle, homeURL: home)
        try fm.createDirectory(at: installer.directoryURL, withIntermediateDirectories: true)
        for kind in ["file", "directory", "link", "broken link"] {
            switch kind {
            case "file": try Data("another command".utf8).write(to: installer.linkURL)
            case "directory": try fm.createDirectory(at: installer.linkURL, withIntermediateDirectories: false)
            case "link": try fm.createSymbolicLink(atPath: installer.linkURL.path, withDestinationPath: "/bin/sh")
            default: try fm.createSymbolicLink(atPath: installer.linkURL.path, withDestinationPath: "/missing/tool")
            }
            let before = try fm.attributesOfItem(atPath: installer.linkURL.path)[.systemFileNumber] as? NSNumber
            let view = controls()
            XCTAssertTrue(text(in: view).contains("conflict"), kind)
            XCTAssertTrue(text(in: view).contains("left untouched"), kind)
            XCTAssertFalse(try button("Install CLI", in: view).isEnabled)
            XCTAssertEqual(installer.install(), .conflict)
            XCTAssertEqual(try fm.attributesOfItem(atPath: installer.linkURL.path)[.systemFileNumber] as? NSNumber, before)
            if kind == "file" { XCTAssertEqual(try String(contentsOf: installer.linkURL), "another command") }
            try fm.removeItem(at: installer.linkURL)
        }
    }

    func testInstallationFailureIsVisibleAndCanBeRetriedAfterDirectoryIsFixed() throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let blocked = home.appendingPathComponent(".local")
        try Data("keep me".utf8).write(to: blocked)
        let view = controls()
        try button("Install CLI", in: view).performClick(nil)
        XCTAssertTrue(text(in: view).contains("Couldn’t install"))
        XCTAssertTrue(text(in: view).contains(home.path))
        XCTAssertEqual(try String(contentsOf: blocked), "keep me")
        try fm.removeItem(at: blocked)
        try button("Install CLI", in: view).performClick(nil)
        XCTAssertTrue(text(in: view).contains("Installed:"))
    }

    func testMissingOrNonExecutableBundledHelperCannotInstallDanglingLink() throws {
        let helper = bundle.appendingPathComponent("Contents/Helpers/vishot")
        for missing in [false, true] {
            if missing { try fm.removeItem(at: helper) }
            else { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path) }
            let view = controls()
            XCTAssertFalse(try button("Install CLI", in: view).isEnabled)
            XCTAssertTrue(text(in: view).contains("Bundled CLI unavailable"))
            XCTAssertEqual(CLIInstallation(bundleURL: bundle, homeURL: home).install(), .unavailable)
            XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".local").path))
        }
    }

    func testPATHGuidanceCanBeSelectedAndCopiedForSupportedShellsWithoutEditingFiles() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let installer = CLIInstallation(bundleURL: bundle, homeURL: home, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
        let view = CLIInstallationView(installation: installer, pasteboard: pasteboard)
        let shells = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(shells.itemTitles, ["zsh", "bash", "fish"])
        for (shell, command, file) in [
            ("zsh", "export PATH=\"$HOME/.local/bin:$PATH\"", "~/.zshrc"),
            ("bash", "export PATH=\"$HOME/.local/bin:$PATH\"", "~/.bash_profile"),
            ("fish", "fish_add_path --universal --move --prepend \"$HOME/.local/bin\"", "future fish sessions"),
        ] {
            shells.selectItem(withTitle: shell)
            _ = shells.sendAction(shells.action!, to: shells.target)
            XCTAssertTrue(text(in: view).contains(command))
            XCTAssertTrue(text(in: view).contains(file))
            try button("Copy PATH Command", in: view).performClick(nil)
            XCTAssertEqual(pasteboard.string(forType: .string), command)
        }
        XCTAssertTrue(text(in: view).contains("app’s PATH snapshot"))
        XCTAssertTrue(text(in: view).contains("terminal or agent"))
        XCTAssertFalse(fm.fileExists(atPath: home.path), "Guidance must not edit shell files or install the CLI")
    }

    func testPATHSnapshotNeverClaimsTerminalIsConfiguredOrHidesGuidance() throws {
        for path in [nil, "/usr/bin:/bin", home.appendingPathComponent(".local/bin").path + ":/bin"] {
            let environment = path.map { ["PATH": $0, "SHELL": "/custom/unsupported-shell"] } ?? [:]
            let view = controls(environment: environment)
            XCTAssertTrue(try button("Copy PATH Command", in: view).isEnabled)
            XCTAssertTrue(text(in: view).contains("cannot verify"))
            XCTAssertTrue(text(in: view).contains("command -v vishot"))
            let fields = descendants(view).compactMap { $0 as? NSTextField }
            XCTAssertTrue(fields.contains { $0.isSelectable && $0.stringValue.contains("export PATH=") })
        }
    }

    func testConflictCreatedAfterSettingsOpensIsPreservedAndReportedOnInstall() throws {
        let view = controls()
        let installer = CLIInstallation(bundleURL: bundle, homeURL: home)
        try fm.createDirectory(at: installer.directoryURL, withIntermediateDirectories: true)
        try Data("new command".utf8).write(to: installer.linkURL)
        try button("Install CLI", in: view).performClick(nil)
        XCTAssertEqual(try String(contentsOf: installer.linkURL), "new command")
        XCTAssertTrue(text(in: view).contains("conflict"))
        try fm.removeItem(at: installer.linkURL)
        view.refresh()
        XCTAssertTrue(try button("Install CLI", in: view).isEnabled)
    }

    func testRelativeCorrectLinkIsRecognizedWithoutRewritingIt() throws {
        let installer = CLIInstallation(bundleURL: bundle, homeURL: home)
        try fm.createDirectory(at: installer.directoryURL, withIntermediateDirectories: true)
        let destination = "../../../Custom Apps/Vishot Beta.app/Contents/Helpers/vishot"
        try fm.createSymbolicLink(atPath: installer.linkURL.path, withDestinationPath: destination)
        XCTAssertFalse(try button("CLI Installed", in: controls()).isEnabled)
        XCTAssertEqual(installer.install(), .installed)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: installer.linkURL.path), destination)
    }

    func testInstallationControlsFitSettingsWidthAndExposeSelectableFeedback() throws {
        let store = SettingsStore(url: root.appendingPathComponent("config.toml")) { _ in NSObject() }
        store.start(watching: false)
        let settings = SettingsWindow(store: store, cliInstallation: CLIInstallation(bundleURL: bundle, homeURL: home))
        let content = try XCTUnwrap(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(descendants(content).compactMap { $0 as? CLIInstallationView }.first)
        XCTAssertGreaterThan(view.bounds.width, 400)
        for field in descendants(view).compactMap({ $0 as? NSTextField }) {
            // AppKit text fields extend two points outside their alignment rect.
            let rect = field.convert(field.alignmentRect(forFrame: field.bounds), to: view)
            XCTAssertGreaterThanOrEqual(rect.minX, -1)
            XCTAssertLessThanOrEqual(rect.maxX, view.bounds.maxX + 1)
        }
        XCTAssertTrue(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.isSelectable && $0.stringValue.contains("Not installed") })
    }
}
