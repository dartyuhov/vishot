import XCTest
@testable import Vishot

final class WindowCatalogTests: XCTestCase {
    func testInitialSelectionPrefersBrowserOverContainedBottomStrip() {
        let windows = [
            window(1, frame: CGRect(x: 100, y: 950, width: 460, height: 86)),
            window(2, frame: CGRect(x: 100, y: 100, width: 1200, height: 936)),
        ]
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: 7), 1)
        XCTAssertEqual(windows[0].id, 1, "The strip remains available for navigation")
    }

    func testInitialSelectionPrefersBrowserOverObservedHeliumDownloadPopup() {
        let windows = [
            window(2291, frame: CGRect(x: 2162, y: 41, width: 320, height: 212)),
            window(192, frame: CGRect(x: 1304, y: 10, width: 1245, height: 1419)),
        ]
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: 7), 1)
    }

    func testInitialSelectionKeepsLargeContainedWindow() {
        let windows = [
            window(1, frame: CGRect(x: 200, y: 200, width: 800, height: 600)),
            window(2, frame: CGRect(x: 100, y: 100, width: 1200, height: 900)),
        ]
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: 7), 0)
    }

    func testInitialSelectionRequiresContainmentAndSameApp() {
        let small = window(1, frame: CGRect(x: 100, y: 100, width: 200, height: 100))
        let otherApp = window(2, pid: 8, frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let overlapping = window(3, frame: CGRect(x: 200, y: 0, width: 1200, height: 900))
        XCTAssertEqual(WindowCatalog.initialSelection(in: [small, otherApp, overlapping], frontPID: 7), 0)
    }

    func testInitialSelectionUsesFrontmostContainingWindow() {
        let windows = [
            window(1, frame: CGRect(x: 200, y: 200, width: 200, height: 100)),
            window(2, frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
            window(3, frame: CGRect(x: 0, y: 0, width: 1200, height: 900)),
        ]
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: 7), 1)
    }

    func testInitialSelectionUsesActiveAppAndFallsBackForMissingApp() {
        let windows = [
            window(1, pid: 8, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            window(2, frame: CGRect(x: 900, y: 0, width: 800, height: 600)),
        ]
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: 7), 1)
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: 9), 0)
        XCTAssertEqual(WindowCatalog.initialSelection(in: windows, frontPID: nil), 0)
        XCTAssertNil(WindowCatalog.initialSelection(in: [], frontPID: 7))
    }

    private func window(_ id: CGWindowID, pid: pid_t = 7, frame: CGRect) -> WindowInfo {
        WindowInfo(id: id, pid: pid, appName: "App", frame: frame,
                   anchor: CGPoint(x: frame.midX, y: frame.midY))
    }
}
