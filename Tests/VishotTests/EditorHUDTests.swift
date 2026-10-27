import AppKit
import Carbon.HIToolbox
import CoreText
import XCTest
@testable import Vishot

final class EditorHUDTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("site/fonts")
        for file in ["silkscreen-latin-400-normal.woff2", "jetbrains-mono-latin-400-normal.woff2",
                     "jetbrains-mono-latin-700-normal.woff2"] {
            CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(file) as CFURL, .process, nil)
        }
    }

    func testRenderedControlsKeepIdentityAndHiddenControlsIgnoreHitsAcrossLayouts() throws {
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 800, height: 600)] {
            let bounds = CGRect(origin: .zero, size: size)
            let editor = try makeEditor()
            let layer = EditorLayer(size: size, scale: 2, theme: ThemeCatalog.pixel)
            func show() -> CALayer {
                var scene = editor.makeScene()
                // A full-screen source forces the inside placement, where hiding is available.
                scene = EditorScene(image: scene.image, frame: bounds, annotations: scene.annotations, crop: nil,
                                    cropHandle: nil, cursor: nil, caret: nil, context: scene.context,
                                    isHUDHidden: editor.isHUDHidden, color: scene.color, canUndo: scene.canUndo,
                                    canRedo: scene.canRedo, status: scene.status)
                layer.show(scene, panelFrame: bounds, showsToolbar: true)
                return layer.root.sublayers!.last { !$0.isHidden && $0.borderWidth == 2 }!
            }
            func point(_ label: String, in toolbar: CALayer) throws -> CGPoint {
                let entry = try XCTUnwrap(text(label, in: toolbar)?.superlayer)
                return layer.root.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry)
            }
            var toolbar = show()
            let prebuilt = layer.root.sublayers!
            let arrow = try point("arrow", in: toolbar)
            let copy = try point("copy to clipboard", in: toolbar)
            let escape = try point("discard", in: toolbar)
            let undo = try point("undo", in: toolbar)
            let hide = try point("hide HUD", in: toolbar)
            let number = try XCTUnwrap(text("1", in: toolbar))
            let swatchLayer = try XCTUnwrap(number.superlayer?.superlayer?.superlayer)
            let swatch = layer.root.convert(CGPoint(x: swatchLayer.bounds.midX, y: swatchLayer.bounds.midY), from: swatchLayer)
            XCTAssertEqual(layer.toolbarItem(at: swatch), .color(.red))
            XCTAssertEqual(layer.toolbarItem(at: arrow), .tool(.arrow))
            XCTAssertNil(layer.toolbarItem(at: undo))
            key(kVK_ANSI_A, editor)
            editor.mouseMoved(to: CGPoint(x: 220, y: 200))
            toolbar = show()
            XCTAssertNil(layer.toolbarItem(at: arrow))
            XCTAssertEqual(try point("place", in: toolbar), escape)
            XCTAssertEqual(layer.toolbarItem(at: copy), .finish(.copy))
            editor.select(try XCTUnwrap(layer.toolbarItem(at: escape)))
            XCTAssertEqual(editor.document.annotations.count, 1)
            toolbar = show()
            XCTAssertEqual(layer.toolbarItem(at: undo), .undo)
            editor.select(try XCTUnwrap(layer.toolbarItem(at: undo)))
            XCTAssertTrue(editor.document.annotations.isEmpty)
            toolbar = show()
            let redo = try point("redo", in: toolbar)
            XCTAssertEqual(layer.toolbarItem(at: redo), .redo)
            editor.select(.redo)

            key(kVK_ANSI_T, editor)
            key(kVK_ANSI_A, editor, characters: "label")
            toolbar = show()
            XCTAssertEqual(try point("place", in: toolbar), escape)
            XCTAssertNil(layer.toolbarItem(at: undo))
            editor.select(try XCTUnwrap(layer.toolbarItem(at: escape)))
            XCTAssertEqual(editor.document.annotations.count, 2)

            key(kVK_ANSI_C, editor)
            toolbar = show()
            XCTAssertEqual(try point("apply", in: toolbar), escape)
            XCTAssertNil(layer.toolbarItem(at: swatch))
            editor.canHideHUD = layer.canHideHUD
            editor.select(.toggleHUD)
            toolbar = show()
            XCTAssertEqual(layer.toolbarItem(at: try point("show HUD", in: toolbar)), .toggleHUD)
            XCTAssertEqual(layer.toolbarItem(at: try point("apply", in: toolbar)), .escape)
            for label in ["arrow", "copy to clipboard", "undo", "redo"] {
                XCTAssertNil(layer.toolbarItem(at: try point(label, in: toolbar)), label)
            }
            XCTAssertEqual(layer.root.sublayers!.count, prebuilt.count)
            for (before, after) in zip(prebuilt, layer.root.sublayers!) { XCTAssertTrue(before === after) }
            editor.select(.toggleHUD)
            toolbar = show()
            XCTAssertEqual(try point("hide HUD", in: toolbar), hide)
            XCTAssertEqual(layer.toolbarItem(at: hide), .toggleHUD)
            layer.show(editor.makeScene(), panelFrame: bounds, showsToolbar: false)
            XCTAssertNil(layer.toolbarItem(at: hide))
            layer.hide()
            XCTAssertNil(layer.toolbarItem(at: try point("apply", in: toolbar)))
        }
    }

    func testMouseDragContextPlacesOnEscapeAndIdleDiscardNeedsConfirmation() throws {
        let editor = try makeEditor()
        editor.select(.tool(.rect))
        editor.mouseDown(at: CGPoint(x: 140, y: 140))
        editor.mouseDragged(to: CGPoint(x: 240, y: 200))
        XCTAssertEqual(editor.makeScene().context.escapeLabel, "place")
        editor.select(.escape)
        XCTAssertEqual(editor.document.annotations, [.rect(CGRect(x: 140, y: 140, width: 100, height: 60), color: .purple)])
        var discarded = false
        editor.onFinish = { kind, result in
            XCTAssertEqual(kind, .discard)
            XCTAssertNil(result)
            discarded = true
        }
        editor.select(.escape)
        XCTAssertFalse(discarded)
        XCTAssertEqual(editor.makeScene().status, "esc again to discard")
        key(kVK_Escape, editor)
        XCTAssertTrue(discarded)
    }

    func testContextualMouseAndKeysPlaceDrawingTextAndResizeThenUndoRedo() throws {
        for useMouse in [false, true] {
            let editor = try makeEditor()
            key(kVK_ANSI_A, editor)
            editor.mouseMoved(to: CGPoint(x: 220, y: 200))
            XCTAssertEqual(editor.makeScene().context.escapeLabel, "place")
            if useMouse { editor.select(.escape) } else { key(kVK_Escape, editor) }
            XCTAssertEqual(editor.document.annotations.count, 1)
            XCTAssertEqual(editor.makeScene().context.escapeLabel, "discard")
            if useMouse { editor.select(.undo) } else { key(kVK_ANSI_U, editor) }
            XCTAssertTrue(editor.document.annotations.isEmpty)
            if useMouse { editor.select(.redo) } else { key(kVK_ANSI_R, editor, flags: .control) }
            XCTAssertEqual(editor.document.annotations.count, 1)

            key(kVK_ANSI_T, editor)
            key(kVK_ANSI_A, editor, characters: "label")
            XCTAssertEqual(editor.makeScene().context.escapeLabel, "place")
            if useMouse { editor.select(.escape) } else { key(kVK_Return, editor) }
            XCTAssertEqual(editor.document.annotations.count, 2)

            key(kVK_ANSI_C, editor)
            key(kVK_ANSI_H, editor)
            XCTAssertEqual(editor.makeScene().context.escapeLabel, "apply")
            if useMouse { editor.select(.escape) } else { key(kVK_Escape, editor) }
            XCTAssertEqual(editor.document.crop, CGRect(x: 85, y: 100, width: 215, height: 150))
        }
    }

    func testUndoAndRedoCancelOnlyTheActiveAction() throws {
        for useMouse in [false, true] {
            for item in [ToolbarItem.undo, .redo] {
                for code in [kVK_ANSI_A, kVK_ANSI_T, kVK_ANSI_C] {
                    let editor = try makeEditor()
                    key(kVK_ANSI_A, editor)
                    editor.mouseMoved(to: CGPoint(x: 220, y: 200))
                    key(kVK_Return, editor)
                    let committed = editor.document.snapshot
                    key(code, editor)
                    if useMouse {
                        editor.select(item)
                    } else {
                        key(kVK_ANSI_Z, editor, flags: item == .undo ? .command : [.command, .shift])
                    }
                    XCTAssertEqual(editor.document.snapshot, committed)
                    XCTAssertEqual(editor.makeScene().context.escapeLabel, "discard")
                    editor.select(.undo)
                    XCTAssertTrue(editor.document.annotations.isEmpty)
                }
            }
        }
    }

    func testActualToolbarFitsSmallAndPortraitDisplays() throws {
        for theme in [ThemeCatalog.pixel, ThemeCatalog.clean] {
            try assertToolbarFitsSmallAndPortraitDisplays(theme: theme)
        }
    }

    private func assertToolbarFitsSmallAndPortraitDisplays(theme: ResolvedTheme) throws {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1024, height: 768),
                     CGSize(width: 1440, height: 900), CGSize(width: 800, height: 1000)] {
            let bounds = CGRect(origin: .zero, size: size)
            let layer = EditorLayer(size: size, scale: 2, theme: theme)
            layer.prepare(theme: theme)
            layer.show(try scene(frame: bounds), panelFrame: bounds, showsToolbar: true)
            let toolbar = try XCTUnwrap(layer.root.sublayers?.last { !$0.isHidden && $0.borderWidth == theme.hud.panel.borderWidth })
            XCTAssertTrue(bounds.insetBy(dx: 12, dy: 12).contains(toolbar.frame), "\(size): \(toolbar.frame)")
            for label in ["copy to clipboard", "save", "save+copy", "save as", "discard"] {
                let text = try XCTUnwrap(text(label, in: toolbar))
                let entry = try XCTUnwrap(text.superlayer)
                XCTAssertTrue(toolbar.bounds.contains(toolbar.convert(entry.bounds, from: entry)), label)
                let center = toolbar.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry)
                XCTAssertNotNil(layer.toolbarItem(at: CGPoint(x: center.x + toolbar.frame.minX,
                                                              y: center.y + toolbar.frame.minY)), label)
            }
            for label in ["arrow", "rect", "text", "resize", "undo", "redo"] {
                let entry = try XCTUnwrap(text(label, in: toolbar)?.superlayer)
                XCTAssertTrue(toolbar.bounds.contains(toolbar.convert(entry.bounds, from: entry)), label)
            }
            for pair in [("arrow", "rect"), ("text", "resize"), ("undo", "redo")] {
                let first = try XCTUnwrap(text(pair.0, in: toolbar)?.superlayer)
                let second = try XCTUnwrap(text(pair.1, in: toolbar)?.superlayer)
                XCTAssertFalse(toolbar.convert(first.bounds, from: first).intersects(toolbar.convert(second.bounds, from: second)))
            }
        }
    }

    private func scene(frame: CGRect) throws -> EditorScene {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditorScene(image: try XCTUnwrap(context.makeImage()), frame: frame, annotations: [], crop: nil,
                           cropHandle: nil, cursor: nil, caret: nil, context: .idle(nil),
                           isHUDHidden: false, color: .purple, canUndo: false,
                           canRedo: false, status: "choose a tool")
    }

    private func makeEditor() throws -> EditorController {
        let scene = try scene(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        return EditorController(capture: Capture(image: scene.image, scale: 1, frame: scene.frame,
                                                initialCrop: CGRect(x: 100, y: 100, width: 200, height: 150)))
    }

    private func key(_ code: Int, _ editor: EditorController, flags: NSEvent.ModifierFlags = [], characters: String = "") {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: UInt16(code))!
        editor.handle(event)
        editor.keyUp(event)
    }

    private func text(_ value: String, in layer: CALayer) -> CATextLayer? {
        if let text = layer as? CATextLayer, text.string as? String == value { return text }
        for child in layer.sublayers ?? [] {
            if let found = text(value, in: child) { return found }
        }
        return nil
    }
}
