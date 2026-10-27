import XCTest
import CoreImage
@testable import Vishot

final class VideoGeometryTests: XCTestCase {
    func testNormalizationPreservesOddCropEdgeAndCursorPixelsWithoutSecondFit() throws {
        let canvas = try VideoCanvas(native: CGSize(width: 101, height: 55))
        let bounds = CGRect(x: 0, y: 0, width: 102, height: 56)
        let black = CIImage(color: .black).cropped(to: bounds)
        // A one-pixel marker at the selected right edge stands in for both picture
        // detail and the pointer. The stream has already fitted/padded the frame.
        let marker = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 100, y: 20, width: 1, height: 1))
        let normalized = canvas.normalize(marker.composited(over: black))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        context.render(normalized, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 100, y: 20, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        XCTAssertEqual(pixel, [255, 0, 0, 255])
        context.render(normalized, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 101, y: 20, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        XCTAssertEqual(pixel, [0, 0, 0, 255])
    }

    func testElementTranslationUsesCachedRelativeBoundsThenFreezesWithoutWindow() throws {
        let target = CaptureTarget(kind: .element(windowID: 7, rect: CGRect(x: 130, y: 240, width: 101, height: 55)),
            frame: CGRect(x: 130, y: 240, width: 101, height: 55), anchor: .zero, label: "Element")
        let selection = try VideoSelection(target: target, windowFrame: CGRect(x: 100, y: 200, width: 500, height: 400))
        let display = VideoDisplay(id: 1, frame: CGRect(x: -1000, y: -800, width: 1000, height: 800), scale: 2)
        let frozen = try selection.resolve(displays: [display], windowFrame: CGRect(x: -900, y: -700, width: 500, height: 400))
        XCTAssertEqual(frozen.rect, CGRect(x: -870, y: -660, width: 101, height: 55))
        XCTAssertEqual(frozen.sourceRect, CGRect(x: 130, y: 140, width: 101, height: 55))
        let resized = try selection.resolve(displays: [display], windowFrame: CGRect(x: -900, y: -700, width: 40, height: 50))
        XCTAssertEqual(resized.rect, CGRect(x: -870, y: -660, width: 101, height: 55),
            "Cached element size survives parent resize; startup translates rather than rewalking or reflowing AX")
        let canvas = try VideoCanvas(native: CGSize(width: frozen.rect.width * display.scale, height: frozen.rect.height * display.scale))
        XCTAssertEqual(canvas.width, 202)
        XCTAssertEqual(canvas.height, 110)
        XCTAssertThrowsError(try selection.resolve(displays: [display], windowFrame: nil))
        // The resolved recording value remains usable after the window disappears.
        XCTAssertEqual(frozen.sourceRect, CGRect(x: 130, y: 140, width: 101, height: 55))
        XCTAssertThrowsError(try VideoSelection(target: target, windowFrame: nil))
    }

    func testRegionStaysOnChosenDisplayWithFractionalScaleAndPaddedEdges() throws {
        let target = CaptureTarget(kind: .region(displayID: 2, rect: CGRect(x: -900, y: 900, width: 101, height: 55)),
            frame: .zero, anchor: .zero, label: "Region")
        let selection = try VideoSelection(target: target, windowFrame: nil)
        let display = VideoDisplay(id: 2, frame: CGRect(x: -1000, y: 800, width: 1000, height: 800), scale: 1.5)
        let rectangle = try selection.resolve(displays: [display], windowFrame: nil)
        XCTAssertEqual(rectangle.sourceRect, CGRect(x: 100, y: 100, width: 101, height: 55))
        let canvas = try VideoCanvas(native: CGSize(width: 151.5, height: 82.5))
        XCTAssertEqual(canvas.width, 152)
        XCTAssertEqual(canvas.height, 84)
        XCTAssertEqual(canvas.contentSize, CGSize(width: 151.5, height: 82.5))
        XCTAssertThrowsError(try selection.resolve(displays: [VideoDisplay(id: 3, frame: display.frame, scale: 1)], windowFrame: nil))
    }

    func testWindowUsesCurrentBoundsAndLargestIntersectionWithOrderedTies() throws {
        let target = CaptureTarget(kind: .window(7), frame: CGRect(x: 10, y: 10, width: 100, height: 100),
            anchor: .zero, label: "Window")
        let selection = try VideoSelection(target: target, windowFrame: nil)
        let displays = [
            VideoDisplay(id: 2, frame: CGRect(x: -1000, y: -200, width: 1000, height: 800), scale: 2),
            VideoDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1),
        ]
        let tied = try selection.resolve(displays: displays, windowFrame: CGRect(x: -100, y: 50, width: 200, height: 101))
        XCTAssertEqual(tied.display.id, 2)
        XCTAssertEqual(tied.rect, CGRect(x: -100, y: 50, width: 100, height: 101))
        XCTAssertEqual(tied.sourceRect, CGRect(x: 900, y: 250, width: 100, height: 101))
        let moved = try selection.resolve(displays: displays, windowFrame: CGRect(x: -50, y: 50, width: 200, height: 101))
        XCTAssertEqual(moved.display.id, 1)
        XCTAssertEqual(moved.rect, CGRect(x: 0, y: 50, width: 150, height: 101))
        XCTAssertThrowsError(try selection.resolve(displays: displays, windowFrame: nil))
        XCTAssertThrowsError(try selection.resolve(displays: displays, windowFrame: CGRect(x: 2000, y: 0, width: 100, height: 100)))
    }
}
