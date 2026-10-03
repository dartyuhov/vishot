import XCTest
@testable import Vishot

final class ConfigTests: XCTestCase {
    func testFileNameUsesTheDateAndTimeInTheGivenTimeZone() throws {
        // 2026-10-03 12:22:05 UTC.
        let date = Date(timeIntervalSince1970: 1_791_030_125)
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(Config.fileName(for: date, in: berlin), "vishot-2026-10-03-142205.png")
        XCTAssertEqual(Config.fileName(for: date, in: TimeZone(identifier: "UTC")!), "vishot-2026-10-03-122205.png")
    }
}
