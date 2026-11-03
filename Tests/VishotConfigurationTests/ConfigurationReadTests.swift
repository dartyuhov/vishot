import XCTest
import VishotConfiguration

final class ConfigurationReadTests: XCTestCase {
    func testMissingConfigurationUsesDefaultsWithoutCreatingDirectoriesOrFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("config.toml")
        XCTAssertEqual(try AppSettings.read(url: url), .defaults)
        XCTAssertEqual(try AppSettings.annotationStyleSnapshot(url: url), .pixel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testSnapshotUsesFullInterpretationAndNeverRewritesSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for (source, expected) in [("# keep\ntheme = 'clean'", VisualStyle.smooth),
                                   ("theme = 'clean'\nstyle = 'pixel'", .pixel),
                                   ("appearance = 'light'\nstyle = 'smooth'", .smooth)] {
            try source.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(try AppSettings.annotationStyleSnapshot(url: url), expected)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
        }
    }

    func testValidStyleCannotMaskInvalidUnrelatedConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for invalid in ["[shortcut]\nkey = 'banana'", "[shortcut]\nmodifiers = ['shift']",
                        "[history]\nretention_days = 2", "[history.shortcut]\nkey = 'S'",
                        "watermark = 'yes'", "appearance = 'auto'", "watermark = ["] {
            let source = "style = 'smooth'\n" + invalid
            try source.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try AppSettings.read(url: url), source)
            XCTAssertThrowsError(try AppSettings.annotationStyleSnapshot(url: url)) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("Could not resolve the selected annotation style from \(url.path): "))
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
        }
    }

    func testSnapshotRejectsUnknownStyleAndUnreadableConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "style = 'unknown'".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AppSettings.annotationStyleSnapshot(url: url))
        try Data([0xff, 0xfe, 0xff]).write(to: url)
        XCTAssertThrowsError(try AppSettings.annotationStyleSnapshot(url: url))
    }
}
