import AppKit
import XCTest
import VishotConfiguration
@testable import Vishot

final class ThemeCatalogTests: XCTestCase {
    func testSingleAppearanceDefinitionsResolveRequestsBeforeBuildingStyles() {
        for (availability, supported) in [(ThemeDefinition.Appearances.light, ColorScheme.light), (.dark, .dark)] {
            let definition = ThemeDefinition(id: "single", label: "Single",
                annotationID: .clean, appearances: availability) { scheme in
                    XCTAssertEqual(scheme, supported, "Factories must receive the effective appearance")
                    return SmoothTheme.definition.makeStyles(scheme)
                }
            for preference in [AppearancePreference.system, .light, .dark] {
                for system in [ColorScheme.light, .dark] {
                    let resolved = ThemeCatalog.resolve(definition, appearance: preference, system: system)
                    XCTAssertEqual(resolved.colorScheme, supported)
                    XCTAssertEqual(resolved.settings.appearance.name, supported.appearance.name)
                    XCTAssertEqual(resolved.definition.id, "single")
                    XCTAssertEqual(resolved.definition.label, "Single")
                    XCTAssertEqual(resolved.id, .clean, "New themes can reuse stable saved markup")
                }
            }
        }
    }

    func testDualAppearanceDefinitionFollowsPreferenceAndSystem() {
        for (preference, system, expected) in [
            (AppearancePreference.system, ColorScheme.light, ColorScheme.light),
            (.system, .dark, .dark), (.light, .dark, .light), (.dark, .light, .dark),
        ] {
            let resolved = ThemeCatalog.resolve(PixelTheme.definition, appearance: preference, system: system)
            XCTAssertEqual(resolved.colorScheme, expected)
        }
    }

    func testRegisteredThemesAreSelectableAndResolveBothShippingAppearances() throws {
        XCTAssertEqual(ThemeCatalog.definitions.map(\.id), ["pixel", "smooth"])
        XCTAssertEqual(ThemeCatalog.definitions.map(\.label), ["Pixel", "Smooth"])
        XCTAssertEqual(Set(ThemeCatalog.definitions.map(\.id)).count, ThemeCatalog.definitions.count)
        for definition in ThemeCatalog.definitions {
            let settings = try AppSettings.parse("style = '\(definition.id)'")
            XCTAssertEqual(settings.style.label, definition.label)
            for scheme in [ColorScheme.light, .dark] {
                let resolved = ThemeCatalog.resolve(style: settings.style, colorScheme: scheme)
                XCTAssertEqual(resolved.definition.id, settings.style.rawValue)
                XCTAssertEqual(resolved.colorScheme, scheme)
                XCTAssertGreaterThan(resolved.hud.nameFont.pointSize, 0)
                XCTAssertGreaterThan(resolved.picker.borderWidth, 0)
                XCTAssertEqual(resolved.settings.appearance.name, scheme.appearance.name)
            }
        }
        XCTAssertNil(VisualStyle(rawValue: "unregistered"))
    }
}
