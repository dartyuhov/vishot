import XCTest
@testable import Vishot

final class PermissionControlTests: XCTestCase {
    func testScreenEnrollmentIsUserInitiatedAndOnlyPreflightCanAuthorize() {
        var effects: [String] = []
        var granted = false
        var control = PermissionControl(permission: .screenRecording, readAccess: { granted },
            requestScreenAccess: { effects.append("request"); return true },
            openPage: { _ in effects.append("open"); return true })
        control.refresh()
        XCTAssertTrue(effects.isEmpty, "Reading status must not prompt")
        control.enable()
        XCTAssertEqual(effects, ["request", "open"], "Enroll before opening the privacy page")
        XCTAssertFalse(control.isAllowed, "Neither the request result nor opening Settings is authorization")
        granted = true
        control.refresh()
        XCTAssertTrue(control.isAllowed)
    }

    func testFailedOpeningKeepsManualInstructionsUntilSuccessfulRetry() throws {
        for permission in CapturePermission.allCases {
            var opens = false
            var control = PermissionControl(permission: permission, readAccess: { false }, requestScreenAccess: { false }, openPage: { _ in opens })
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
            var requests = 0
            var control = PermissionControl(permission: permission, readAccess: { false },
                requestScreenAccess: { requests += 1; return false }, openPage: { opened = $0; return true })
            control.enable()
            XCTAssertEqual(opened?.absoluteString, destination)
            XCTAssertFalse(control.isAllowed)
            XCTAssertNil(control.openingError)
            XCTAssertEqual(requests, permission == .screenRecording ? 1 : 0)
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
