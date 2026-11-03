import AppKit
import Carbon.HIToolbox
import XCTest
import VishotRendering
@testable import Vishot

final class EditorAreaTests: XCTestCase {
    func testDraggingDoesNotDrawUntilAToolIsSelected() throws {
        let editor = try makeEditor()
        let original = try exportedBytes(editor)
        func drag() {
            editor.mouseDown(at: CGPoint(x: 140, y: 140))
            editor.mouseDragged(to: CGPoint(x: 240, y: 200))
            editor.mouseUp(at: CGPoint(x: 240, y: 200))
        }
        drag()
        XCTAssertEqual(original, try exportedBytes(editor))
        editor.select(.tool(.arrow))
        drag()
        XCTAssertNotEqual(original, try exportedBytes(editor))
    }

    func testHUDToggleWorksDuringResizeAndDoesNotConsumeTypedO() throws {
        let editor = try makeEditor()
        key(kVK_ANSI_O, editor)
        XCTAssertFalse(editor.isHUDHidden)
        editor.select(.toggleHUD)
        XCTAssertFalse(editor.isHUDHidden)
        editor.canHideHUD = true
        key(kVK_ANSI_O, editor)
        XCTAssertTrue(editor.isHUDHidden)
        editor.canHideHUD = false
        key(kVK_ANSI_C, editor)
        key(kVK_ANSI_O, editor)
        XCTAssertFalse(editor.isHUDHidden)
        key(kVK_Return, editor)
        editor.canHideHUD = true
        key(kVK_ANSI_T, editor)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "o", charactersIgnoringModifiers: "o",
                                    isARepeat: false, keyCode: UInt16(kVK_ANSI_O))!
        editor.handle(event)
        XCTAssertFalse(editor.isHUDHidden)
        editor.select(.toggleHUD)
        XCTAssertTrue(editor.isHUDHidden)
        key(kVK_Return, editor)
        let withText = try exportedBytes(editor)
        key(kVK_ANSI_U, editor)
        XCTAssertNotEqual(withText, try exportedBytes(editor))
    }

    func testShiftReturnAddsLineWhileReturnPlacesText() throws {
        let editor = try makeEditor()
        func type(_ text: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: UInt16(kVK_ANSI_A))!
            editor.handle(event)
        }
        key(kVK_ANSI_T, editor)
        type("first")
        key(kVK_Return, editor, flags: .shift)
        type("second")
        key(kVK_Return, editor)
        let multiline = try exportedBytes(editor)
        key(kVK_ANSI_U, editor)
        key(kVK_ANSI_T, editor)
        type("first")
        key(kVK_Return, editor)
        XCTAssertNotEqual(multiline, try exportedBytes(editor))
    }

    func testResizeKeyTogglesOffAndCommits() throws {
        let editor = try makeEditor()
        key(kVK_ANSI_C, editor)
        key(kVK_ANSI_K, editor)
        key(kVK_ANSI_C, editor)
        // Undo after toggling must undo a committed resize, not merely cancel a preview.
        key(kVK_ANSI_U, editor)
        key(kVK_ANSI_Z, editor, flags: [.command, .shift])
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 165))
        key(kVK_ANSI_U, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 150))
    }

    func testMouseCanResizeAfterEnteringWithKeyboard() throws {
        let editor = try makeEditor()
        key(kVK_ANSI_C, editor)
        editor.mouseDown(at: CGPoint(x: 200, y: 100))
        editor.mouseUp(at: CGPoint(x: 200, y: 50))
        key(kVK_Return, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 200))
    }

    func testTabDuringMouseDragDoesNotChangeGrabbedHandle() throws {
        let editor = try makeEditor()
        editor.mouseDown(at: CGPoint(x: 200, y: 100))
        editor.mouseDragged(to: CGPoint(x: 200, y: 80))
        key(kVK_Tab, editor)
        editor.mouseUp(at: CGPoint(x: 240, y: 50))
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 200))
    }

    func testToolbarEscapeAppliesResizeWithoutClosingEditor() throws {
        let editor = try makeEditor()
        var closed = false
        editor.onFinish = { _, _ in closed = true }
        key(kVK_ANSI_C, editor)
        key(kVK_ANSI_K, editor)
        editor.select(.finish(.discard))
        XCTAssertFalse(closed)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 165))
        key(kVK_ANSI_U, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 150))
    }

    func testEscapeAppliesResizeAndUndoRestoresPreviousBounds() throws {
        let editor = try makeEditor()
        key(kVK_ANSI_C, editor)
        key(kVK_ANSI_H, editor)
        key(kVK_Escape, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 215, height: 150))
        key(kVK_ANSI_U, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 150))
    }

    func testTabAndReverseTabChooseCornersRatherThanChangeColor() throws {
        let editor = try makeEditor()
        key(kVK_ANSI_C, editor)
        key(kVK_Tab, editor)
        key(kVK_ANSI_L, editor)
        key(kVK_Tab, editor, flags: .shift)
        key(kVK_ANSI_H, editor)
        key(kVK_Return, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 230, height: 150))
        key(kVK_ANSI_U, editor)
        key(kVK_ANSI_Z, editor, flags: [.command, .shift])
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 230, height: 150))
    }

    func testMouseEdgeDragPreservesGrabOffsetAndCanUndo() throws {
        let editor = try makeEditor()
        editor.mouseDown(at: CGPoint(x: 200, y: 103))
        editor.mouseDragged(to: CGPoint(x: 200, y: 53))
        editor.mouseUp(at: CGPoint(x: 200, y: 53))
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 200))
        key(kVK_ANSI_U, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 150))
    }

    func testAnnotationSurvivesShrinkingAndExpandingArea() throws {
        let editor = try makeEditor()
        editor.select(.tool(.arrow))
        editor.mouseDown(at: CGPoint(x: 120, y: 130))
        editor.mouseDragged(to: CGPoint(x: 180, y: 180))
        editor.mouseUp(at: CGPoint(x: 180, y: 180))
        let original = try exportedBytes(editor)
        editor.mouseDown(at: CGPoint(x: 100, y: 180))
        editor.mouseUp(at: CGPoint(x: 200, y: 180))
        editor.mouseDown(at: CGPoint(x: 200, y: 180))
        editor.mouseUp(at: CGPoint(x: 100, y: 180))
        XCTAssertEqual(try exportedBytes(editor), original)
    }

    private func exportedBytes(_ editor: EditorController) throws -> Data {
        var image: CGImage?
        editor.onFinish = { _, result in image = result?.image }
        key(kVK_ANSI_Y, editor)
        return try XCTUnwrap(ImageEncoding.data(try XCTUnwrap(image), scale: 1, type: .png))
    }

    func testCornerResizeCommitsAndUndoRestoresInitialArea() throws {
        let editor = try makeEditor()
        key(kVK_ANSI_C, editor)
        key(kVK_ANSI_K, editor)
        key(kVK_Return, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 165))
        key(kVK_ANSI_U, editor)
        XCTAssertEqual(try exportedSize(editor), CGSize(width: 200, height: 150))
    }

    private func makeEditor() throws -> EditorController {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditorController(capture: Capture(image: try XCTUnwrap(context.makeImage()), scale: 1,
                                                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                initialCrop: CGRect(x: 100, y: 100, width: 200, height: 150)))
    }

    private func key(_ code: Int, _ editor: EditorController, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: UInt16(code))!
        editor.handle(event)
        editor.keyUp(event)
    }

    private func exportedSize(_ editor: EditorController) throws -> CGSize {
        var image: CGImage?
        editor.onFinish = { _, result in image = result?.image }
        key(kVK_ANSI_Y, editor)
        let result = try XCTUnwrap(image)
        return CGSize(width: result.width, height: result.height)
    }
}
