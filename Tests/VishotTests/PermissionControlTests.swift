import XCTest
@testable import Vishot

final class PermissionControlTests: XCTestCase {
    func testFailedOpeningKeepsManualInstructionsUntilSuccessfulRetry() throws {
        for permission in CapturePermission.allCases {
            var opens = false
            var control = PermissionControl(permission: permission, readAccess: { false }, openPage: { _ in opens })
            control.enable()
            let error = try XCTUnwrap(control.openingError)
            XCTAssertTrue(error.contains("Couldn’t open System Settings"))
            XCTAssertTrue(error.contains("Privacy & Security"))
            XCTAssertTrue(error.contains(permission.title))
            XCTAssertTrue(error.contains("enable Vishot"))
            XCTAssertFalse(control.isAllowed)
            control.refresh()
            XCTAssertEqual(control.openingError, error)
            opens = true
            control.enable()
            XCTAssertNil(control.openingError)
            XCTAssertFalse(control.isAllowed)
        }
    }

    func testEnableOpensEachPrivacyPageWithoutTreatingOpeningAsAuthorization() {
        for (permission, destination) in [
            (CapturePermission.screenRecording, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            (.accessibility, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
        ] {
            var opened: URL?
            var control = PermissionControl(permission: permission, readAccess: { false }, openPage: { opened = $0; return true })
            control.enable()
            XCTAssertEqual(opened?.absoluteString, destination)
            XCTAssertFalse(control.isAllowed)
            XCTAssertNil(control.openingError)
        }
    }

    func testRefreshRecognizesExistingAccessAndLaterGrantsAndRevocations() {
        var authorized = true
        var control = PermissionControl(permission: .screenRecording, readAccess: { authorized }, openPage: { _ in true })
        XCTAssertTrue(control.isAllowed)

        authorized = false
        control.refresh()
        XCTAssertFalse(control.isAllowed)

        authorized = true
        control.refresh()
        XCTAssertTrue(control.isAllowed)
    }
}
