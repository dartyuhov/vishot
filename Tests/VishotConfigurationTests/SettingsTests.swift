import XCTest
import VishotConfiguration

final class SettingsTests: XCTestCase {
    func testDefaultsAndGeneratedSourceAgree() throws {
        XCTAssertEqual(try AppSettings.parse(""), .defaults)
        XCTAssertEqual(try AppSettings.parse(AppSettings.defaultSource), .defaults)
        XCTAssertEqual(AppSettings.defaults.appearance, .system)
        XCTAssertEqual(AppSettings.defaults.style, .pixel)
        XCTAssertTrue(AppSettings.defaults.watermark)
        XCTAssertEqual(AppSettings.defaults.shortcut, CaptureShortcut(key: "S", modifiers: ["command", "shift"]))
        XCTAssertEqual(AppSettings.defaults.historyRetention, .sevenDays)
        XCTAssertNil(AppSettings.defaults.historyShortcut)
    }

    func testIndependentAppearanceAndStyleCompatibility() throws {
        XCTAssertEqual(try AppSettings.parse("theme = 'clean'").appearance, .dark)
        XCTAssertEqual(try AppSettings.parse("theme = 'clean'").style, .smooth)
        XCTAssertEqual(try AppSettings.parse("theme = 'pixel'").style, .pixel)
        let explicit = try AppSettings.parse("theme = 'clean'\nappearance = 'light'\nstyle = 'pixel'")
        XCTAssertEqual(explicit.appearance, .light)
        XCTAssertEqual(explicit.style, .pixel)
        for source in ["appearance = 'auto'", "style = 'clean'", "appearance = true", "style = 1"] {
            XCTAssertThrowsError(try AppSettings.parse(source), source)
        }
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

    func testStyleIdentityAndLegacyAnnotationMapping() throws {
        XCTAssertEqual(VisualStyle.allCases.map(\.rawValue), ["pixel", "smooth"])
        XCTAssertEqual(VisualStyle.allCases.map(\.label), ["Pixel", "Smooth"])
        XCTAssertEqual(VisualStyle.pixel.annotationID.rawValue, "pixel")
        XCTAssertEqual(VisualStyle.smooth.annotationID.rawValue, "clean")
        XCTAssertEqual(VisualStyle(annotationID: .pixel), .pixel)
        XCTAssertEqual(VisualStyle(annotationID: .clean), .smooth)
        XCTAssertNil(VisualStyle(rawValue: "clean"))
        XCTAssertNil(VisualStyle(rawValue: "unregistered"))
    }

    func testAppearanceResolutionIsIndependentOfStyle() {
        XCTAssertEqual(AppearancePreference.system.resolve(system: .light), .light)
        XCTAssertEqual(AppearancePreference.system.resolve(system: .dark), .dark)
        XCTAssertEqual(AppearancePreference.light.resolve(system: .dark), .light)
        XCTAssertEqual(AppearancePreference.dark.resolve(system: .light), .dark)
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

    func testInvalidValuesRejectTheFullConfiguration() {
        for source in ["watermark = 'yes'", "shortcut = false", "[shortcut]\nkey = 'banana'", "[shortcut]\nmodifiers = ['shift']", "[shortcut]\nmodifiers = ['command', 'command']", "[shortcut]\nmodifiers = [3]", "watermark = ["] {
            XCTAssertThrowsError(try AppSettings.parse(source), source)
        }
    }

    func testHistoryRetentionAndOptionalShortcutValidation() throws {
        for days in [0, 1, 3, 7, 30] {
            XCTAssertEqual(try AppSettings.parse("[history]\nretention_days = \(days)").historyRetention.rawValue, days)
        }
        XCTAssertNil(try AppSettings.parse("[history]\nshortcut = false").historyShortcut)
        XCTAssertEqual(try AppSettings.parse("[history.shortcut]").historyShortcut,
                       CaptureShortcut(key: "H", modifiers: ["command", "shift"]))
        let inline = try AppSettings.parse("[history]\nshortcut = { key = 'J', modifiers = ['control'] }")
        XCTAssertEqual(inline.historyShortcut, CaptureShortcut(key: "J", modifiers: ["control"]))
        for source in ["[history]\nretention_days = 2", "[history.shortcut]\nkey = 'S'", "[history]\nshortcut = true", "[history]\nretention_days = '7'"] {
            XCTAssertThrowsError(try AppSettings.parse(source), source)
        }
    }

    func testShortcutValidationNormalizesModifierOrderAndDetectsHistoryConflict() throws {
        let settings = try AppSettings.parse("[shortcut]\nmodifiers = ['shift', 'command']")
        XCTAssertEqual(settings.shortcut.modifiers, ["command", "shift"])
        XCTAssertEqual(settings.shortcut.display, "⇧⌘S")
        XCTAssertThrowsError(try AppSettings.parse("[shortcut]\nmodifiers = ['shift', 'command']\n[history.shortcut]\nkey = 'S'"))
    }
}
