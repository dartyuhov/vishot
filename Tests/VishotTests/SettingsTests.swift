import XCTest
@testable import Vishot

final class SettingsTests: XCTestCase {
    func testCRLFEditsKeepUnrelatedTables() throws {
        let source = "watermark = true\r\n[notes]\r\nx = 1\r\n"
        XCTAssertEqual(try AppSettings.edit(source, watermark: false), "watermark = false\r\n[notes]\r\nx = 1\r\n")
    }
    func testSymlinkWritesUseFreshSourceAndKeepLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("dotfile.toml")
        let link = folder.appendingPathComponent("config.toml")
        try AppSettings.defaultSource.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = SettingsStore(url: link) { _ in NSObject() }
        store.start(watching: false)
        try "# external change\nwatermark = true\n[shortcut]\nkey = 'K'".write(to: target, atomically: true, encoding: .utf8)
        store.update(watermark: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertTrue(try String(contentsOf: target).hasPrefix("# external change\nwatermark = false"))
        XCTAssertEqual(store.active.shortcut.key, "K")
        XCTAssertFalse(store.active.watermark)
    }

    func testInvalidValuesAndUnsafeEditsDoNotSilentlyChangeMeaning() throws {
        for source in ["watermark = 'yes'", "shortcut = false", "[shortcut]\nkey = 'banana'", "[shortcut]\nmodifiers = ['shift']", "[shortcut]\nmodifiers = ['command', 'command']", "[shortcut]\nmodifiers = [3]", "watermark = ["] {
            XCTAssertThrowsError(try AppSettings.parse(source), source)
        }
        let commented = "[shortcut]\nmodifiers = [\n 'command', # keep this\n 'shift'\n]"
        XCTAssertThrowsError(try AppSettings.edit(commented, shortcut: CaptureShortcut(key: "S", modifiers: ["control"])))
        let inline = "shortcut = { key = 'S', modifiers = ['command', 'shift'] }"
        XCTAssertThrowsError(try AppSettings.edit(inline, shortcut: CaptureShortcut(key: "K", modifiers: ["control"])))
        let multiline = "[notes]\ntext = '''\n[shortcut]\nkey = 'pretend'\n'''\n[shortcut]\nkey = 'S'"
        let edited = try AppSettings.edit(multiline, shortcut: CaptureShortcut(key: "K", modifiers: ["command", "shift"]))
        XCTAssertTrue(edited.contains("key = 'pretend'"))
        XCTAssertEqual(try AppSettings.parse(edited).shortcut.key, "K")
        XCTAssertEqual(try AppSettings.parse(AppSettings.edit("[notes]\nx = 1", watermark: false)).watermark, false)
    }

    func testWindowCanFillMissingShortcutFields() throws {
        for source in ["", "[shortcut]\nkey = 'S'", "[shortcut]\nmodifiers = ['command', 'shift']"] {
            let shortcut = CaptureShortcut(key: "K", modifiers: ["control"])
            XCTAssertEqual(try AppSettings.parse(AppSettings.edit(source, shortcut: shortcut)).shortcut, shortcut)
        }
    }

    func testWatcherSeesAtomicSavesAndSymlinkTargetChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("dotfile.toml")
        let link = folder.appendingPathComponent("config.toml")
        try AppSettings.defaultSource.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = SettingsStore(url: link) { _ in NSObject() }
        store.start()
        let changed = expectation(description: "Reload symlink target after atomic save")
        store.onChange = { if !store.active.watermark { changed.fulfill() } }
        try "watermark = false".write(to: target, atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 3)
        store.onChange = nil
    }

    func testInvalidStartupKeepsFileAndUsesDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "watermark = 'invalid'".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url) { _ in NSObject() }
        store.start(watching: false)
        XCTAssertEqual(store.active, .defaults)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try String(contentsOf: url), "watermark = 'invalid'")
    }
    func testReloadDefersDuringSessionAndRejectsTakenShortcutAsAWhole() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        let store = SettingsStore(url: url) { shortcut in
            if shortcut.key == "K" { throw SettingsError(message: "Shortcut is taken") }
            return NSObject()
        }
        store.start(watching: false)
        XCTAssertEqual(store.active, .defaults)
        store.setSessionActive(true)
        try "watermark = false".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertTrue(store.active.watermark)
        XCTAssertFalse(try XCTUnwrap(store.configured).watermark)
        store.setSessionActive(false)
        XCTAssertFalse(store.active.watermark)
        try "watermark = true\n[shortcut]\nkey = 'K'".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertFalse(store.active.watermark)
        XCTAssertEqual(store.active.shortcut, .defaults)
        XCTAssertNotNil(store.error)
        try "watermark = [broken".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertFalse(store.active.watermark)
        XCTAssertNil(store.configured)
    }
    func testWindowEditsPreserveCommentsAndUnrelatedTOML() throws {
        let source = """
        # Personal notes: café
        watermark  = true # credit
        [shortcut] # capture
        key = 'S' # physical
        modifiers = ["command", "shift"]
        [notes]
        text = "do not rewrite me"
        """
        let edited = try AppSettings.edit(source, watermark: false, shortcut: CaptureShortcut(key: "K", modifiers: ["control"]))
        XCTAssertEqual(edited, """
        # Personal notes: café
        watermark  = false # credit
        [shortcut] # capture
        key = "K" # physical
        modifiers = ["control"]
        [notes]
        text = "do not rewrite me"
        """)
        XCTAssertEqual(try AppSettings.parse(edited), AppSettings(watermark: false, shortcut: CaptureShortcut(key: "K", modifiers: ["control"])))
    }
    func testStandardTOMLLoadsPhysicalShortcutAndWatermark() throws {
        let settings = try AppSettings.parse("""
        # Hand-edited config
        watermark = false
        [shortcut]
        key = 'K'
        modifiers = [
          'control', # not Command
          'option',
        ]
        """)
        XCTAssertFalse(settings.watermark)
        XCTAssertEqual(settings.shortcut.key, "K")
        XCTAssertEqual(settings.shortcut.modifiers, ["control", "option"])
        XCTAssertEqual(try AppSettings.parse(""), .defaults)
    }
}
