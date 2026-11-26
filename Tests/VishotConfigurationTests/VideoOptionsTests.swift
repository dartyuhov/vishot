import XCTest
@testable import VishotConfiguration

final class VideoOptionsTests: XCTestCase {
    func testSystemAudioDefaultsAndToggleValidation() throws {
        let defaults = try AppSettings.parse("")
        XCTAssertFalse(defaults.systemAudioEnabled)
        let settings = try AppSettings.parse("[video]\nsystem_audio = true\n")
        XCTAssertTrue(settings.systemAudioEnabled)
        XCTAssertFalse(settings.microphoneEnabled)
        for value in ["system_audio = 'yes'", "system_audio = 1"] {
            XCTAssertThrowsError(try AppSettings.parse("[video]\n" + value))
        }
    }
    func testMicrophoneDefaultsAndStableIdentityValidation() throws {
        XCTAssertFalse(try AppSettings.parse("").microphoneEnabled)
        XCTAssertEqual(try AppSettings.parse("").microphoneDevice, "")
        let settings = try AppSettings.parse("[video]\nmicrophone = true\nmicrophone_device = 'usb:stable-42'\n")
        XCTAssertTrue(settings.microphoneEnabled)
        XCTAssertEqual(settings.microphoneDevice, "usb:stable-42")
        for source in ["[video]\nmicrophone = 'yes'", "[video]\nmicrophone_device = 12", "video = false"] {
            XCTAssertThrowsError(try AppSettings.parse(source))
        }
    }
}
