import AppKit
import XCTest
@testable import Vishot

final class PermissionControlViewTests: XCTestCase {
    func testGrantReplacesEnableActionAndRevocationRestoresIt() throws {
        var allowed = false
        let view = PermissionControlView(permission: .screenRecording, readAccess: { allowed })
        let row = try XCTUnwrap(view.arrangedSubviews.first as? NSStackView)
        let button = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        let enabled = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(enabled.isHidden)

        allowed = true
        view.refresh()
        XCTAssertTrue(button.isHidden, "Granted permissions must not offer Enable again")
        XCTAssertFalse(enabled.isHidden)
        XCTAssertTrue(enabled.stringValue.contains("Enabled"))
        XCTAssertTrue(view.arrangedSubviews.dropFirst(2).allSatisfy(\.isHidden),
                      "Granted permissions need no recovery instructions")

        allowed = false
        view.refresh()
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(enabled.isHidden)
    }
}
