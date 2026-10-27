import XCTest
@testable import Vishot

final class SettingsTests: XCTestCase {
    func testSingleAppearanceFallbackPreservesPreferencesAcrossSessionsAndRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        let darkOnly = ThemeDefinition(id: "smooth", label: "Dark fixture",
            annotationID: .clean, appearances: .dark, makeStyles: SmoothTheme.definition.makeStyles)
        let resolve: (VisualStyle, ColorScheme) -> ColorScheme = { style, requested in
            ThemeCatalog.resolve(style == .smooth ? darkOnly : style.definition,
                colorScheme: requested).colorScheme
        }
        let store = SettingsStore(url: url, resolveColorScheme: resolve) { _ in NSObject() }
        store.start(watching: false)
        store.systemAppearanceChanged(.light)
        store.update(appearance: .light, style: .smooth)
        XCTAssertEqual(store.activeColorScheme, .dark)
        XCTAssertEqual(store.active.appearance, .light)
        XCTAssertFalse(store.hasPendingAppearance)
        let restarted = SettingsStore(url: url, resolveColorScheme: resolve) { _ in NSObject() }
        restarted.start(watching: false)
        XCTAssertEqual(restarted.active.appearance, .light)
        XCTAssertEqual(restarted.activeColorScheme, .dark)

        store.setSessionActive(true)
        store.update(style: .pixel)
        XCTAssertEqual(store.active.style, .smooth)
        XCTAssertEqual(store.activeColorScheme, .dark)
        XCTAssertTrue(store.hasPendingAppearance)
        store.setSessionActive(false)
        XCTAssertEqual(store.activeColorScheme, .light)
        XCTAssertEqual(store.active.appearance, .light)

        store.update(appearance: .system, style: .smooth)
        store.setSessionActive(true)
        store.systemAppearanceChanged(.dark)
        store.systemAppearanceChanged(.light)
        XCTAssertFalse(store.hasPendingAppearance, "Unsupported system variants do not change the effective appearance")
        store.update(style: .pixel)
        XCTAssertEqual(store.activeColorScheme, .dark)
        store.setSessionActive(false)
        XCTAssertEqual(store.activeColorScheme, .light)
        XCTAssertEqual(store.active.appearance, .system)
    }

    func testSystemAppearanceAndIndependentPreferencesDeferUntilSessionEnds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        let store = SettingsStore(url: url) { _ in NSObject() }
        store.start(watching: false)
        store.systemAppearanceChanged(.light)
        XCTAssertEqual(store.activeColorScheme, .light)
        store.update(style: .smooth)
        XCTAssertEqual(store.active.style, .smooth)
        XCTAssertEqual(store.active.appearance, .system)
        store.setSessionActive(true)
        store.systemAppearanceChanged(.dark)
        XCTAssertEqual(store.activeColorScheme, .light)
        XCTAssertTrue(store.hasPendingAppearance)
        store.setSessionActive(false)
        XCTAssertEqual(store.activeColorScheme, .dark)
        XCTAssertFalse(store.hasPendingAppearance)
        store.update(appearance: .light)
        store.systemAppearanceChanged(.dark)
        XCTAssertEqual(store.activeColorScheme, .light)
        XCTAssertEqual(store.active.style, .smooth)
        let restarted = SettingsStore(url: url) { _ in NSObject() }
        restarted.start(watching: false)
        XCTAssertEqual(restarted.active.appearance, .light)
        XCTAssertEqual(restarted.active.style, .smooth)
        let lastGood = store.active
        try "appearance = 'bad'\nstyle = 'pixel'".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(store.active, lastGood)
        XCTAssertEqual(store.activeColorScheme, .light)
        XCTAssertNotNil(store.error)
        // Last-good System still follows a deferred OS change if the file becomes invalid.
        try "appearance = 'system'\nstyle = 'smooth'".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        store.systemAppearanceChanged(.light)
        store.setSessionActive(true)
        try "appearance = 'bad'".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        store.systemAppearanceChanged(.dark)
        XCTAssertEqual(store.activeColorScheme, .light)
        store.setSessionActive(false)
        XCTAssertEqual(store.activeColorScheme, .dark)
    }

    func testIndependentAppearanceAndStyleCompatibility() throws {
        XCTAssertEqual(try AppSettings.parse("").appearance, .system)
        XCTAssertEqual(try AppSettings.parse("theme = 'clean'").appearance, .dark)
        XCTAssertEqual(try AppSettings.parse("theme = 'clean'").style, .smooth)
        let explicit = try AppSettings.parse("theme = 'clean'\nappearance = 'light'\nstyle = 'pixel'")
        XCTAssertEqual(explicit.appearance, .light)
        XCTAssertEqual(explicit.style, .pixel)
        let source = "# keep\r\ntheme = 'clean' # old choice\r\n[notes]\r\nx = 1\r\n"
        let edited = try AppSettings.edit(source, appearance: .system)
        XCTAssertEqual(try AppSettings.parse(edited).appearance, .system)
        XCTAssertEqual(try AppSettings.parse(edited).style, .smooth)
        XCTAssertFalse(edited.contains("theme ="))
        XCTAssertTrue(edited.contains("# old choice"))
        XCTAssertTrue(edited.contains("[notes]\r\nx = 1"))
        for source in ["appearance = 'auto'", "style = 'clean'", "appearance = true", "style = 1"] {
            XCTAssertThrowsError(try AppSettings.parse(source))
        }
    }

    func testThemeStorePersistsReloadsAndDefersWithoutLosingLastGoodSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        var registrations = 0
        let store = SettingsStore(url: url) { _ in registrations += 1; return NSObject() }
        store.start(watching: false)
        store.update(style: .smooth)
        XCTAssertEqual(store.active.theme, .clean)
        let restarted = SettingsStore(url: url) { _ in NSObject() }
        restarted.start(watching: false)
        XCTAssertEqual(restarted.active.theme, .clean)
        store.setSessionActive(true)
        store.update(style: .pixel)
        XCTAssertEqual(store.configured?.theme, .pixel)
        XCTAssertEqual(store.active.theme, .clean)
        // A history-to-editor transition remains the same active session.
        store.setSessionActive(true)
        XCTAssertEqual(store.active.theme, .clean)
        try "theme = 'pixel'\nwatermark = false".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(store.active.theme, .clean)
        XCTAssertTrue(store.active.watermark)
        XCTAssertEqual(store.configured?.theme, .pixel)
        store.setSessionActive(false)
        XCTAssertEqual(store.active.theme, .pixel)
        XCTAssertFalse(store.active.watermark)
        try "# external\ntheme = 'clean'\nwatermark = false".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(store.active.theme, .clean)
        XCTAssertFalse(store.active.watermark)
        let lastGood = store.active
        for value in ["'missing'", "false"] {
            let invalid = "theme = \(value)\nwatermark = true"
            try invalid.write(to: url, atomically: true, encoding: .utf8)
            store.reload()
            store.update(style: .pixel)
            XCTAssertEqual(store.active, lastGood)
            XCTAssertNil(store.configured)
            XCTAssertNotNil(store.error)
            XCTAssertEqual(try String(contentsOf: url), invalid)
        }
        XCTAssertEqual(registrations, 1, "Theme-only changes must not re-register hotkeys")
    }

    func testThemeEditsPreserveSourceAndInsertAtRoot() throws {
        let source = "# café\r\n\"theme\"  = 'pixel' # appearance\r\nwatermark = false\r\n[notes]\r\ntheme = 'unrelated'\r\n"
        let edited = try AppSettings.edit(source, style: .smooth)
        XCTAssertTrue(edited.contains("# café"))
        XCTAssertTrue(edited.contains("# appearance"))
        XCTAssertTrue(edited.contains("[notes]\r\ntheme = 'unrelated'"))
        XCTAssertEqual(try AppSettings.parse(edited).appearance, .dark)
        XCTAssertEqual(try AppSettings.parse(edited).theme, .clean)
        let missing = "# keep\r\n[notes]\r\nx = 'untouched'\r\n"
        XCTAssertEqual(try AppSettings.edit(missing, style: .smooth), "style = \"smooth\"\r\n" + missing)
        XCTAssertEqual(try AppSettings.parse(AppSettings.edit(source, style: .pixel)).appearance, .dark)
        XCTAssertThrowsError(try AppSettings.edit("theme = '''\npixel'''", style: .smooth))
    }

    func testThemeDefaultsAndValidation() throws {
        XCTAssertEqual(try AppSettings.parse("").theme, .pixel)
        XCTAssertEqual(try AppSettings.parse(AppSettings.defaultSource).theme, .pixel)
        XCTAssertEqual(try AppSettings.parse("theme = 'clean'").theme, .clean)
        for value in ["'unknown'", "'Clean'", "true", "7", "[]", "{}"] {
            XCTAssertThrowsError(try AppSettings.parse("theme = \(value)")) { error in
                XCTAssertTrue(error.localizedDescription.contains("theme"))
            }
        }
    }

    func testMultilineClosingQuotesDoNotHideRealInsertionHeader() throws {
        for delimiter in ["\"", "'"] {
            let source = "[notes]\ntext = \(String(repeating: delimiter, count: 3))note\(String(repeating: delimiter, count: 4))\n[history] # real"
            let edited = try AppSettings.edit(source, historyRetention: .oneDay)
            XCTAssertEqual(edited, source + "\nretention_days = 1\n")
            XCTAssertEqual(try AppSettings.parse(edited).historyRetention, .oneDay)
        }
    }

    func testHistoryShortcutWithExtraInlineFieldsIsRefusedWithoutChangingLastGoodSettings() throws {
        let source = "[history]\nshortcut = { key = 'H', modifiers = ['control'], note = 'keep me' } # optional\n"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url) { _ in NSObject() }
        store.start(watching: false)
        let lastGood = store.active
        store.update(clearHistoryShortcut: true)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.active, lastGood)
        XCTAssertEqual(try String(contentsOf: url), source)
        XCTAssertThrowsError(try AppSettings.edit(source, historyShortcut: CaptureShortcut(key: "J", modifiers: ["control"])))
        let edited = try AppSettings.edit(source, historyRetention: .oneDay)
        XCTAssertEqual(edited, "[history]\nretention_days = 1\nshortcut = { key = 'H', modifiers = ['control'], note = 'keep me' } # optional\n")
        XCTAssertEqual(try AppSettings.parse(edited).historyRetention, .oneDay)
    }

    func testInsertionAndEditsUseQuotedPathsAndIgnoreMultilineFakeHeaders() throws {
        let source = "# café\r\n[notes]\r\ntext = \"\"\"\r\n[history]\r\n[shortcut]\r\n\"\"\"\r\nvalues = [\r\n  '[history]', # retain array notes\r\n]\r\n[ 'history' ] # real\r\n'shortcut' = false\r\n[\"shortcut\"]\r\n'key' = 'S' # physical\r\n"
        let edited = try AppSettings.edit(source, shortcut: CaptureShortcut(key: "K", modifiers: ["control"]), historyRetention: .oneDay)
        XCTAssertEqual(edited, "# café\r\n[notes]\r\ntext = \"\"\"\r\n[history]\r\n[shortcut]\r\n\"\"\"\r\nvalues = [\r\n  '[history]', # retain array notes\r\n]\r\n[ 'history' ] # real\r\nretention_days = 1\r\n'shortcut' = false\r\n[\"shortcut\"]\r\nmodifiers = [\"control\"]\r\n'key' = \"K\" # physical\r\n")
        XCTAssertEqual(try AppSettings.parse(edited).shortcut, CaptureShortcut(key: "K", modifiers: ["control"]))
        XCTAssertEqual(try AppSettings.parse(edited).historyRetention, .oneDay)
    }

    func testQuotedHistoryTableMigrationPreservesHeaderAndFieldComments() throws {
        let source = "['history'.\"shortcut\"] # optional\r\n'key' = 'H' # key\r\n\"modifiers\" = ['control'] # modifiers\r\n[notes]\r\nx = { 'a.b' = 'untouched', text = '# []' }"
        let shortcut = CaptureShortcut(key: "J", modifiers: ["command"])
        let edited = try AppSettings.edit(source, historyShortcut: shortcut)
        XCTAssertEqual(edited, " # optional\r\n # key\r\n # modifiers\r\n[notes]\r\nx = { 'a.b' = 'untouched', text = '# []' }\r\n[history]\r\nshortcut = { key = \"J\", modifiers = [\"command\"] }\r\n")
        XCTAssertEqual(try AppSettings.parse(edited).historyShortcut, shortcut)
    }

    func testHistoryTableMigrationIgnoresMultilineHeadersAndPreservesSource() throws {
        let source = "# café\r\n[notes]\r\ntext = '''\r\n[history]\r\n[history.shortcut]\r\nkey = 'fake'\r\n'''\r\n[history] # retention\r\nretention_days = 3\r\n[history.shortcut] # optional\r\nkey = 'H' # physical\r\nmodifiers = ['command', 'shift']\r\n[other]\r\nvalues = [1, 2]\r\n"
        let edited = try AppSettings.edit(source, clearHistoryShortcut: true)
        XCTAssertEqual(edited, "# café\r\n[notes]\r\ntext = '''\r\n[history]\r\n[history.shortcut]\r\nkey = 'fake'\r\n'''\r\n[history] # retention\r\nshortcut = false\r\nretention_days = 3\r\n # optional\r\n # physical\r\n\r\n[other]\r\nvalues = [1, 2]\r\n")
        XCTAssertNil(try AppSettings.parse(edited).historyShortcut)
        XCTAssertEqual(try AppSettings.parse(edited).historyRetention, .threeDays)
    }

    func testHistoryShortcutIsOptInAndCanBeAssignedClearedAndReassigned() throws {
        XCTAssertNil(try AppSettings.parse(AppSettings.defaultSource).historyShortcut)
        XCTAssertNil(try AppSettings.parse("").historyShortcut)
        let shortcut = CaptureShortcut(key: "J", modifiers: ["control"])
        let assigned = try AppSettings.edit(AppSettings.defaultSource, historyShortcut: shortcut)
        XCTAssertEqual(try AppSettings.parse(assigned).historyShortcut, shortcut)
        let cleared = try AppSettings.edit(assigned, clearHistoryShortcut: true)
        XCTAssertNil(try AppSettings.parse(cleared).historyShortcut)
        XCTAssertEqual(try AppSettings.parse(AppSettings.edit(cleared, historyShortcut: shortcut)).historyShortcut, shortcut)
        let legacy = "[history]\nretention_days = 3\n[history.shortcut]\nkey = 'H' # keep note\nmodifiers = ['command', 'shift']\n[notes]\nx = 1\n"
        let migrated = try AppSettings.edit(legacy, clearHistoryShortcut: true)
        XCTAssertNil(try AppSettings.parse(migrated).historyShortcut)
        XCTAssertTrue(migrated.contains("# keep note"))
        XCTAssertTrue(migrated.contains("[notes]\nx = 1"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var registrations = 0
        let store = SettingsStore(url: folder.appendingPathComponent("config.toml"), registerHistory: { _ in
            registrations += 1
            return NSObject()
        }) { _ in NSObject() }
        store.start(watching: false)
        XCTAssertEqual(registrations, 0)
        store.update(historyShortcut: shortcut)
        XCTAssertEqual(registrations, 1)
        store.update(clearHistoryShortcut: true)
        XCTAssertNil(store.active.historyShortcut)
        XCTAssertNil(store.error)
    }
    func testHistorySettingsValidateAndPreserveUnrelatedContent() throws {
        let source = "# keep\n[notes]\nx = 1\n"
        let shortcut = CaptureShortcut(key: "J", modifiers: ["control"])
        let edited = try AppSettings.edit(source, historyRetention: .threeDays, historyShortcut: shortcut)
        XCTAssertTrue(edited.contains("# keep\n[notes]\nx = 1"))
        XCTAssertEqual(try AppSettings.parse(edited).historyRetention, .threeDays)
        XCTAssertEqual(try AppSettings.parse(edited).historyShortcut, shortcut)
        XCTAssertThrowsError(try AppSettings.parse("[history]\nretention_days = 2"))
        XCTAssertThrowsError(try AppSettings.parse("[history.shortcut]\nkey = 'S'"))
    }
    func testHistoryShortcutConflictKeepsAllLastGoodPreferencesAndDefersDuringSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        let store = SettingsStore(url: url, registerHistory: { shortcut in
            if shortcut.key == "K" { throw SettingsError(message: "History shortcut taken") }
            return NSObject()
        }) { _ in NSObject() }
        store.start(watching: false)
        store.setSessionActive(true)
        store.update(historyRetention: .oneDay, historyShortcut: CaptureShortcut(key: "J", modifiers: ["control"]))
        XCTAssertEqual(store.active.historyRetention, .sevenDays)
        store.setSessionActive(false)
        XCTAssertEqual(store.active.historyRetention, .oneDay)
        XCTAssertEqual(store.active.historyShortcut?.key, "J")
        store.update(watermark: false, historyShortcut: CaptureShortcut(key: "K", modifiers: ["control"]))
        XCTAssertEqual(store.active.historyShortcut?.key, "J")
        XCTAssertTrue(store.active.watermark)
        XCTAssertNotNil(store.error)
    }
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
        store.update(style: .smooth, watermark: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try String(contentsOf: target), "style = \"smooth\"\n# external change\nwatermark = false\n[shortcut]\nkey = 'K'")
        XCTAssertEqual(store.active.theme, .clean)
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
        store.onChange = { if !store.active.watermark && store.active.theme == .clean { changed.fulfill() } }
        try "theme = 'clean'\nwatermark = false".write(to: target, atomically: true, encoding: .utf8)
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
